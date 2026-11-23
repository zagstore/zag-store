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

		if failures == 0 { print("SUCCESS: companion core tests") }
		exit(failures == 0 ? 0 : 1)
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
