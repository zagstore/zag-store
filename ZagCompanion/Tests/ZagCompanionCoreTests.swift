#if ZAG_ZSIGN_STRICT
import Foundation
import CryptoKit

// Device-independent focused tests for the companion core: the managed-app
// registry, renewal-timing logic, IPA inspection, the pairing session crypto,
// and the signer's fail-closed profile handling. Runs in CI with no iPhone.

@main enum ZagCompanionCoreTests {
	static var failures = 0
	static func check(_ ok: Bool, _ label: String) { print("\(ok ? "PASS" : "FAIL"): \(label)"); if !ok { failures += 1 } }

	static func main() {
		setvbuf(stdout, nil, _IOLBF, 0)
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zag-companion-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		registry(tmp)
		renewalTiming()
		ipaInspection(tmp)
		pairingCrypto()
		signerFailsClosed()
		renewalPlanner()
		inputSafety()
		redaction()
		pairingDisabled()
		teamScopedResolution(tmp)
		adversarialSymlinkArchive(tmp)
		renewalSourceBundleGuard(tmp)

		if failures == 0 { print("SUCCESS: companion core tests") }
		exit(failures == 0 ? 0 : 1)
	}

	/// An IPA containing a symlink (e.g. pointing outside the tree) must be
	/// rejected before extraction, so unzip never creates a link to follow.
	static func adversarialSymlinkArchive(_ tmp: URL) {
		let stage = tmp.appendingPathComponent("malstage")
		let app = stage.appendingPathComponent("Payload/Evil.app")
		try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let info: [String: Any] = ["CFBundleIdentifier": "com.example.evil", "CFBundleName": "Evil"]
		if let d = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) { try? d.write(to: app.appendingPathComponent("Info.plist")) }
		// A symlink whose target escapes the tree entirely.
		_ = ZagProcess.run("/bin/ln", ["-s", "/etc/passwd", app.appendingPathComponent("escape").path])
		let ipa = tmp.appendingPathComponent("malicious.ipa")
		// -y stores symlinks AS symlinks (the dangerous case).
		_ = ZagProcess.run("/usr/bin/zip", ["-qry", "-y", ipa.path, "Payload"], currentDirectory: stage)
		do {
			_ = try ZagIPA.unpack(ipa, into: tmp.appendingPathComponent("malout"))
			check(false, "a symlink-bearing IPA should be rejected")
		} catch { check(true, "a symlink-bearing IPA is rejected before extraction") }
	}

	/// Renewal must refuse when the source IPA on disk is no longer the app it
	/// was registered as, rather than signing a different bundle ID.
	static func renewalSourceBundleGuard(_ tmp: URL) {
		let ipa = makeDemoIPA(tmp, bundleID: "com.example.demo", dir: "guardstage")
		let svc = ZagCompanionService(config: ZagCompanionConfig(templateProjectURL: tmp, supportDirectory: tmp.appendingPathComponent("guardsupport")))
		let managed = ZagManagedApp(bundleIdentifier: "com.example.other", displayName: "Other", deviceUDID: "UDIDX", deviceName: "iPhone",
									teamIdentifier: "TEAMX", sourceIPAPath: ipa.path, certificateSerial: "C",
									profileExpiresAt: Date().addingTimeInterval(86_400), installedAt: Date())
		let device = ZagCompanionDevice(id: "x", name: "iPhone", model: "iPhone", udid: "UDIDX", connected: true)
		let team = ZagCompanionTeam(identifier: "TEAMX", name: "t", isFree: true)
		do { _ = try svc.renew(managed, on: device, team: team, allowNewProvisioning: false); check(false, "renew should reject a changed source bundle ID") }
		catch { check(true, "renewal refuses a source IPA whose bundle ID no longer matches the managed app") }
	}

	static func makeDemoIPA(_ tmp: URL, bundleID: String, dir: String) -> URL {
		let stage = tmp.appendingPathComponent(dir)
		let app = stage.appendingPathComponent("Payload/Demo.app")
		try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Demo", "CFBundleShortVersionString": "1.0"]
		if let d = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) { try? d.write(to: app.appendingPathComponent("Info.plist")) }
		let ipa = tmp.appendingPathComponent("\(dir).ipa")
		_ = ZagProcess.run("/usr/bin/zip", ["-qry", ipa.path, "Payload"], currentDirectory: stage)
		return ipa
	}

	// Renewal decides purely from dates + authorisation, and never claims an
	// extension it will not deliver.
	static func renewalPlanner() {
		let now = Date()
		let prev = now.addingTimeInterval(86_400)              // expires in 1 day (near)
		let far = now.addingTimeInterval(6 * 86_400)           // expires in 6 days (not near)
		let threshold: TimeInterval = 2 * 86_400

		let newer = ZagRenewalPlanner.plan(previousExpiry: prev, candidateExpiry: prev.addingTimeInterval(86_400), now: now, threshold: threshold, allowNewProvisioning: false)
		check(newer.action == .reuseNewerProfile && newer.willExtend, "a newer on-disk profile extends by reuse")

		let notNear = ZagRenewalPlanner.plan(previousExpiry: far, candidateExpiry: far, now: now, threshold: threshold, allowNewProvisioning: true)
		check(notNear.action == .reuseWithoutExtension && !notNear.willExtend, "not near expiry: reinstall without claiming extension")

		let fresh = ZagRenewalPlanner.plan(previousExpiry: prev, candidateExpiry: prev, now: now, threshold: threshold, allowNewProvisioning: true)
		check(fresh.action == .provisionFresh && fresh.willExtend, "near expiry + authorised: provision a fresh profile (extends)")

		let blocked = ZagRenewalPlanner.plan(previousExpiry: prev, candidateExpiry: prev, now: now, threshold: threshold, allowNewProvisioning: false)
		check(blocked.action == .blockedNeedsAuthorization && !blocked.willExtend, "near expiry + unauthorised: blocked, no false extension")
	}

	static func inputSafety() {
		check(ZagCompanionSafety.isSafeBundleIdentifier("com.example.app"), "a normal bundle ID is accepted")
		check(!ZagCompanionSafety.isSafeBundleIdentifier("-rf"), "a leading-dash bundle ID (option injection) is rejected")
		check(!ZagCompanionSafety.isSafeBundleIdentifier("com.example/../x"), "a bundle ID with path chars is rejected")
		check(!ZagCompanionSafety.isSafeBundleIdentifier("no-dot"), "a bundle ID without a dot is rejected")
		check(ZagCompanionSafety.isSafeArchiveEntry("Payload/App.app/App"), "a normal archive entry is accepted")
		check(!ZagCompanionSafety.isSafeArchiveEntry("../escape"), "a traversal archive entry is rejected")
		check(!ZagCompanionSafety.isSafeArchiveEntry("/etc/passwd"), "an absolute archive entry is rejected")
		check(!ZagCompanionSafety.isSafeArchiveEntry("Payload/../../x"), "a deep traversal entry is rejected")
	}

	static func redaction() {
		// Synthetic, non-real values shaped like a UDID / serial / email.
		let udid = "0000ABCD-1111222233334444", serial = "AAAABBBBCCCCDDDDEEEEFFFF00001111"
		let clean = ZagRedaction.sanitize("error for user@example.com device \(udid) serial \(serial)")
		check(!clean.contains("@example.com") && !clean.contains(udid) && !clean.contains("AAAABBBB"),
			  "redaction strips emails, UDIDs and serials from tool output")
	}

	static func pairingDisabled() {
		check(!ZagCompanionPairing.remoteInstallEnabled, "remote install is disabled in v0.1")
		do { try ZagCompanionPairing.authorizeRemoteInstall(); check(false, "remote install authorisation should throw") }
		catch { check(true, "remote-install authorisation is refused") }
	}

	// A profile for a different team (or none) must not be returned: resolving
	// an unknown bundle ID for a team with no matching profile is rejected when
	// provisioning is not authorised.
	static func teamScopedResolution(_ tmp: URL) {
		let prov = ZagCompanionProvisioning(templateProjectURL: tmp)
		let device = ZagCompanionDevice(id: "x", name: "iPhone", model: "iPhone", udid: "00000000-0000000000000000", connected: true)
		let team = ZagCompanionTeam(identifier: "ZZZZZZZZZZ", name: "Nonexistent", isFree: true)
		do { _ = try prov.resolve(bundleID: "com.zag.nonexistent.\(UUID().uuidString.prefix(6))", device: device, team: team, allowNewProvisioning: false); check(false, "unknown team/bundle should not resolve") }
		catch { check(true, "no profile is returned for a team/bundle with no match (team isolation)") }
	}

	static func registry(_ tmp: URL) {
		let reg = ZagManagedAppRegistry(url: tmp.appendingPathComponent("reg.json"))
		let app = ZagManagedApp(bundleIdentifier: "com.example.a", displayName: "A", deviceUDID: "UDID1", deviceName: "iPhone",
								teamIdentifier: "TEAM123456", sourceIPAPath: "/tmp/a.ipa", certificateSerial: "AA",
								profileExpiresAt: Date().addingTimeInterval(86_400), installedAt: Date())
		reg.upsert(app)
		check(reg.all().count == 1 && reg.all().first?.certificateSerial == "AA", "registry stores an app")
		var updated = app; updated.certificateSerial = "BB"
		reg.upsert(updated)
		check(reg.all().count == 1 && reg.all().first?.certificateSerial == "BB", "upsert replaces by id, no duplicate")
		reg.remove(app)
		check(reg.all().isEmpty, "registry removes an app")
	}

	static func renewalTiming() {
		let soon = ZagManagedApp(bundleIdentifier: "b", displayName: "B", deviceUDID: "U", deviceName: "i",
								 teamIdentifier: "T", sourceIPAPath: "/x", certificateSerial: "C",
								 profileExpiresAt: Date().addingTimeInterval(86_400), installedAt: Date())
		let expired = ZagManagedApp(bundleIdentifier: "c", displayName: "C", deviceUDID: "U", deviceName: "i",
									teamIdentifier: "T", sourceIPAPath: "/x", certificateSerial: "C",
									profileExpiresAt: Date().addingTimeInterval(-3600), installedAt: Date())
		check(soon.needsRenewalSoon && !soon.isExpired, "an app expiring tomorrow needs renewal soon, not yet expired")
		check(expired.isExpired && expired.daysUntilExpiry < 0, "a past-expiry app reads as expired")
	}

	static func ipaInspection(_ tmp: URL) {
		// Craft a minimal IPA: Payload/Demo.app/Info.plist.
		let app = tmp.appendingPathComponent("stage/Payload/Demo.app")
		try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let info: [String: Any] = ["CFBundleIdentifier": "com.example.demo", "CFBundleName": "Demo", "CFBundleShortVersionString": "2.3"]
		let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
		try? data?.write(to: app.appendingPathComponent("Info.plist"))
		let ipa = tmp.appendingPathComponent("demo.ipa")
		_ = ZagProcess.run("/usr/bin/zip", ["-qry", ipa.path, "Payload"], currentDirectory: tmp.appendingPathComponent("stage"))
		if let read = try? ZagIPA.info(ipa) {
			check(read.bundleIdentifier == "com.example.demo" && read.displayName == "Demo" && read.version == "2.3",
				  "IPA inspection reads bundle ID, name and version")
			check(read.extensionBundleIdentifiers.isEmpty, "an extension-free IPA reports no extensions")
		} else { check(false, "IPA inspection failed to read the crafted IPA") }
	}

	static func pairingCrypto() {
		// The companion derives a session key from the peer's public key + code;
		// a peer computing it the mirror way derives the same key, and sealed
		// messages round-trip.
		guard let companionPub = try? ZagCompanionPairing.agreementPublicKey() else { return check(false, "pairing: no companion key") }
		let peer = Curve25519.KeyAgreement.PrivateKey()
		let code = ZagCompanionPairing.newPairingCode()
		guard let companionKey = try? ZagCompanionPairing.sessionKey(peerPublicKey: peer.publicKey.rawRepresentation, pairingCode: code),
			  let shared = try? peer.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: companionPub)) else {
			return check(false, "pairing: key agreement failed")
		}
		let peerKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
													 sharedInfo: Data("zag-companion-session".utf8), outputByteCount: 32)
		let message = Data("install com.example.demo".utf8)
		let sealed = (try? ZagCompanionPairing.seal(message, with: companionKey)) ?? Data()
		let opened = try? ZagCompanionPairing.open(sealed, with: peerKey)
		check(opened == message, "paired peers derive the same session key and a sealed request round-trips")
		check(code.count == 6 && Int(code) != nil, "the pairing code is six digits")
	}

	static func signerFailsClosed() {
		do { _ = try ZagExternalKeychainSigningKey(profileData: Data("not a profile".utf8)); check(false, "garbage profile should throw") }
		catch { check(true, "the signer refuses an unreadable profile (fail closed)") }
	}
}
#endif
