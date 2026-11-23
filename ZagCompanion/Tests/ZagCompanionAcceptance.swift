#if ZAG_ZSIGN_STRICT
import Foundation

// Real end-to-end acceptance test for the Zag Companion core service, driving
// the SAME code the SwiftUI app calls. It installs a source IPA on the
// connected iPhone through the service (provision -> engine-sign -> verify ->
// install), launches it, and renews it reusing the valid profile (no new
// certificate). It never authorises new provisioning (allowNewProvisioning:
// false), so it consumes no device slots and triggers no Apple-side action.
//
// Environment: ZAG_REPO (repo root), ZAG_SOURCE_IPA (the PT Team Probe IPA),
// ZAG_SUPPORT (scratch Application Support dir).

@main enum ZagCompanionAcceptance {
	static var failures = 0
	static func check(_ ok: Bool, _ label: String) { print("\(ok ? "PASS" : "FAIL"): \(label)"); if !ok { failures += 1 } }
	static func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

	static func main() {
		setvbuf(stdout, nil, _IOLBF, 0)
		guard let repo = env("ZAG_REPO"), let ipaPath = env("ZAG_SOURCE_IPA") else {
			print("FAIL: ZAG_REPO and ZAG_SOURCE_IPA are required"); exit(1)
		}
		let template = URL(fileURLWithPath: repo).appendingPathComponent("experiments/XcodePTTeamProbe")
		let support = URL(fileURLWithPath: env("ZAG_SUPPORT") ?? NSTemporaryDirectory()).appendingPathComponent("zag-companion-accept")
		let config = ZagCompanionConfig(templateProjectURL: template, supportDirectory: support)
		let service = ZagCompanionService(config: config)

		// 1. Device.
		let device: ZagCompanionDevice
		do { device = try ZagDeviceControl.firstConnectedPhone() } catch { print("FAIL: device: \(error)"); exit(1) }
		check(device.connected && !device.udid.isEmpty, "a connected iPhone is detected (\(device.name))")

		// 2. Team (the free Personal Team).
		let teams = ZagCompanionProvisioning.availableTeams()
		guard let team = teams.first(where: { $0.isFree }) ?? teams.first else { print("FAIL: no team"); exit(1) }
		check(team.isFree, "a free Personal Team is identified (\(team.identifier))")

		// 3. Install through the companion service (reusing the existing profile).
		let ipa = URL(fileURLWithPath: ipaPath)
		let managed: ZagManagedApp
		do {
			managed = try service.install(ipa: ipa, on: device, team: team, allowNewProvisioning: false) { p in
				print("   [\(p.stage.rawValue)] \(p.message)")
			}
		} catch { print("FAIL: install through companion: \(error)"); exit(1) }
		check(true, "the companion provisioned, engine-signed, verified and installed \(managed.displayName)")
		check(!managed.certificateSerial.isEmpty, "the install recorded a certificate serial")
		check(managed.profileExpiresAt > Date(), "the managed app has a future expiry (\(managed.profileExpiresAt))")

		// 4. Launch (the developer certificate was trusted in the prior proof).
		do {
			try ZagDeviceControl.launch(bundleID: managed.bundleIdentifier, on: device)
			check(true, "the installed app launches on the device")
		} catch {
			check(false, "launch (if this reports an untrusted developer, trust the cert in Settings then re-run): \(error)")
		}

		// 5. Renew with the valid profile — must NOT issue a new certificate.
		let serialBefore = managed.certificateSerial
		do {
			let renewed = try service.renew(managed, on: device, team: team, allowNewProvisioning: false) { p in
				print("   [renew:\(p.stage.rawValue)] \(p.message)")
			}
			check(renewed.certificateSerial == serialBefore, "renewal reused the same certificate (no new cert issued)")
			check(renewed.lastRenewedAt != nil, "renewal was recorded")
		} catch { check(false, "renew: \(error)") }

		// 6. Registry round-trip.
		check(service.registry.all().contains { $0.id == managed.id }, "the managed app is tracked for renewal")

		if failures == 0 { print("SUCCESS: Zag Companion installed, launched and renewed through the service") }
		exit(failures == 0 ? 0 : 1)
	}
}
#endif
