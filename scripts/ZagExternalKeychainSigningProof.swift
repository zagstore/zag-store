// Proof that Zag Store's existing strict signing engine can sign a disposable
// app with an Xcode-issued free Apple Account ("Personal Team") identity that
// already lives in the login Keychain — reusing ZagExternalKeychainSigningKey
// to locate the identity (no key export) and ZagStrictComponentSigning to sign
// (ZagKeychainSigningKeys.signer, the same raw-signer callback the first-party
// key uses). The engine signs; Apple's codesign is used only to verify the
// result, never to produce it.
//
// Inputs (environment):
//   ZAG_PROFILE        the .mobileprovision Xcode issued
//   ZAG_APP            a disposable .app to sign in place (same bundle ID)
//   ZAG_XCODE_APP      the pristine Xcode-signed app, for comparison
//   ZAG_INTERMEDIATES  dir of extra chain certs (wwdr.der, root.der), optional
//   ZAG_DEVICE_UDID    a device UDID to test eligibility against, optional
//   ZAG_WORK           scratch directory
//
// Compiled only with ZAG_ZSIGN_STRICT, linked against libzsign.a.

import Foundation
#if canImport(ZsignSwift)
import ZsignSwift
#endif

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: tool)
	process.arguments = arguments
	let pipe = Pipe()
	process.standardOutput = pipe
	process.standardError = pipe
	try? process.run()
	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	process.waitUntilExit()
	return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

@main
enum ZagExternalKeychainSigningProof {
	static var failures = 0
	static func check(_ value: Bool, _ label: String) {
		print("\(value ? "PASS" : "FAIL"): \(label)")
		if !value { failures += 1 }
	}

	static func main() {
		setvbuf(stdout, nil, _IOLBF, 0)
		#if ZAG_ZSIGN_STRICT
		guard let profilePath = env("ZAG_PROFILE"), let appPath = env("ZAG_APP"),
			  let workPath = env("ZAG_WORK") else {
			print("FAIL: ZAG_PROFILE, ZAG_APP and ZAG_WORK are required")
			exit(1)
		}
		let app = URL(fileURLWithPath: appPath)
		let work = URL(fileURLWithPath: workPath)

		// 1. Locate the Xcode identity and validate it against its profile,
		//    without exporting the private key.
		let profileData: Data
		do { profileData = try Data(contentsOf: URL(fileURLWithPath: profilePath)) }
		catch { print("FAIL: reading the profile: \(error)"); exit(1) }

		let external: ZagExternalKeychainSigningKey
		do { external = try ZagExternalKeychainSigningKey(profileData: profileData, now: Date()) }
		catch { print("FAIL: locating/validating the Keychain identity: \(error)"); exit(1) }

		check(external.identity.keyIsInKeychain, "the identity's key stays in the Keychain (private key never exported)")
		check(external.identity.privateKey.isEmpty, "no private-key bytes are carried by the identity")
		print("     team=\(external.team) bundleID=\(external.bundleIdentifier) certSerial=\(external.identity.serialNumber) devices=\(external.eligibleDeviceUDIDs.count) expires=\(external.expiresAt)")

		if let udid = env("ZAG_DEVICE_UDID"), !udid.isEmpty {
			check(external.isEligible(deviceUDID: udid), "the target device UDID is eligible under this profile")
		}

		// 2. Sign the disposable app with OUR engine (not codesign).
		var intermediates: [Data] = []
		if let dir = env("ZAG_INTERMEDIATES") {
			for name in ["wwdr.der", "root.der"] {
				if let der = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)) { intermediates.append(der) }
			}
		}
		let result = external.provisioningResult()
		var calls = 0
		let countingSigner: (Data) -> Data? = { digestInfo in calls += 1; return external.signer(digestInfo) }
		let adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), workRoot: work, gate: .simulationOnly)
		do {
			let record = try adapter.signComponents(
				appAt: app, with: result, identity: external.identity, signer: countingSigner,
				authorization: external.authorization(), now: Date(), extraIntermediates: intermediates
			)
			check(record.owner?.certificateSerial == external.identity.serialNumber,
				  "the engine recorded the signed app under the external certificate")
		} catch {
			print("FAIL: the engine refused to sign: \(error)")
			exit(1)
		}
		check(calls >= 1, "every signature came from the Keychain key reference (\(calls) DigestInfo blocks, no key data given to Zsign)")

		// 3. Verify the engine's output independently.
		let verify = run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=4", app.path])
		check(verify.status == 0, "codesign --verify --strict accepts the engine-signed app")
		if verify.status != 0 { print(verify.output) }

		let inspect = run("/usr/bin/codesign", ["-dvvv", app.path]).output
		check(inspect.contains("Identifier=\(external.bundleIdentifier)"), "the signed app carries the profile's bundle ID")
		check(inspect.contains("TeamIdentifier=\(external.team)"), "the signed app carries the team identifier")
		check(inspect.contains("Authority=Apple Development"), "the signing authority is the Apple Development certificate")

		let embedded = try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
		check(embedded == result.app.profile.data, "the app embeds exactly the profile it was authorised with")

		// Engine-side verification of every component, independent of codesign.
		let components: [String: (provision: Data, entitlements: Data)] = [
			"": (result.app.profile.data,
				 (try? PropertyListSerialization.data(fromPropertyList: result.app.entitlements.dictionary, format: .xml, options: 0)) ?? Data())
		]
		check(Zsign.verifyComponents(appPath: app.path, certificate: external.identity.certificate, components: components) == nil,
			  "Zsign verifies the signed component against the external certificate")

		// 4. Compare against Xcode's own signed app.
		if let xcodeAppPath = env("ZAG_XCODE_APP") {
			let xcode = run("/usr/bin/codesign", ["-dvvv", xcodeAppPath]).output
			func field(_ key: String, _ text: String) -> String? {
				text.split(separator: "\n").first { $0.hasPrefix(key) }.map { String($0) }
			}
			check(field("Identifier=", inspect) == field("Identifier=", xcode), "same bundle identifier as Xcode's signed app")
			check(field("TeamIdentifier=", inspect) == field("TeamIdentifier=", xcode), "same team identifier as Xcode's signed app")
			let ourAuthority = inspect.split(separator: "\n").first { $0.hasPrefix("Authority=Apple Development") }
			let xcodeAuthority = xcode.split(separator: "\n").first { $0.hasPrefix("Authority=Apple Development") }
			check(ourAuthority == xcodeAuthority, "same Apple Development signing certificate as Xcode")
		}

		if failures == 0 {
			print("SUCCESS: Zag Store's engine independently signed the app with the Xcode free-account identity, verified by codesign and Zsign")
		}
		exit(failures == 0 ? 0 : 1)
		#else
		print("SKIP: built without ZAG_ZSIGN_STRICT")
		exit(0)
		#endif
	}
}
