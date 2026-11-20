import Foundation
import Security
import SwiftUI

/// Runs the Keychain secret store against the simulator's real Keychain and
/// writes PASS/FAIL lines to tmp/keychain.log, then DONE.
@main struct KeychainHarness: App {
	init() {
		let log = FileManager.default.temporaryDirectory.appendingPathComponent("keychain.log")
		var lines: [String] = []
		func check(_ value: Bool, _ label: String) { lines.append((value ? "PASS: " : "FAIL: ") + label) }

		let store = ZagKeychainFreeAccountSecretStore(service: "app.zagstore.free-account.test.\(UUID().uuidString)")
		let a = UUID(), b = UUID()
		do {
			try store.save(Data("session-1".utf8), kind: .session, account: a)
			try store.save(Data("key".utf8), kind: .signingPrivateKey, account: a)
			try store.save(Data("other".utf8), kind: .session, account: b)
			check(try store.load(.session, account: a) == Data("session-1".utf8), "a saved secret reads back")
			try store.save(Data("session-2".utf8), kind: .session, account: a)
			check(try store.load(.session, account: a) == Data("session-2".utf8), "saving again replaces the secret")
			check(store.accessibility(.session, account: a) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
				  "stored after-first-unlock, this device only (never restored elsewhere)")
			var query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: store.service,
				kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
				kSecMatchLimit as String: kSecMatchLimitAll
			]
			check(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound, "nothing is synchronised to iCloud Keychain")
			check(try store.load(.anisetteProvisioning, account: a) == nil, "a missing secret is nil, not an error")
			var refusedEmpty = false
			do { try store.save(Data(), kind: .session, account: a) } catch { refusedEmpty = true }
			check(refusedEmpty, "an empty secret is refused")
			try store.save(Data("team-1".utf8), kind: .signingPrivateKey, account: a, team: "SIMTEAM001")
			try store.save(Data("team-2".utf8), kind: .signingPrivateKey, account: a, team: "SIMORG0001")
			try store.save(Data("b-team".utf8), kind: .signingPrivateKey, account: b, team: "SIMTEAM001")
			let teamItems = [
				try store.load(.signingPrivateKey, account: a, team: "SIMTEAM001"),
				try store.load(.signingPrivateKey, account: a, team: "SIMORG0001"),
				try store.load(.signingPrivateKey, account: b, team: "SIMTEAM001"),
				try store.load(.signingPrivateKey, account: a)
			]
			check(teamItems == ["team-1", "team-2", "b-team", "key"].map { Data($0.utf8) },
				  "each account and team has its own signing item")
			check(store.accessibility(.signingPrivateKey, account: a, team: "SIMTEAM001") == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
				  "team signing items are this-device-only too")
			var refusedTeam = false
			do { try store.save(Data("x".utf8), kind: .signingPrivateKey, account: a, team: "bad.team*") } catch { refusedTeam = true }
			check(refusedTeam, "a malformed team ID is refused")
			try store.deleteAll(account: a)
			check(try store.load(.session, account: a) == nil && store.accessibility(.signingPrivateKey, account: a) == nil
				  && store.accessibility(.signingPrivateKey, account: a, team: "SIMTEAM001") == nil
				  && store.accessibility(.signingPrivateKey, account: a, team: "SIMORG0001") == nil,
				  "removing an account deletes every secret of it, all teams included")
			check(try store.load(.signingPrivateKey, account: b, team: "SIMTEAM001") == Data("b-team".utf8), "another account's team item is untouched")
			check(try store.load(.session, account: b) == Data("other".utf8), "another account's secrets are untouched")
			try store.save(Data("record".utf8), kind: .accountRecord, account: a)
			check(try store.accountIDs() == [a, b], "the accounts owning items are found from the service's own items (L1)")
			try store.deleteAll(account: a)
			try store.deleteAll(account: b)
			query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
			check(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound, "no test items are left behind")
		} catch {
			lines.append("FAIL: unexpected error \(error)")
		}
		signingKeys(check)
		lines.append("DONE")
		try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
	}

	/// Signing keys as Keychain key items: made, used and removed without
	/// the private key ever being exported.
	func signingKeys(_ check: (Bool, String) -> Void) {
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.test.\(UUID().uuidString)")
		let a = UUID(), b = UUID()
		do {
			let made = try keys.create(account: a, team: "SIMTEAM001", commonName: "Zag Test")
			_ = try keys.create(account: a, team: "SIMORG0001", commonName: "Zag Test")
			_ = try keys.create(account: b, team: "SIMTEAM001", commonName: "Zag Test")
			if case .success(let contents) = ZagCertificateSigningRequest.validate(made.request.data),
			   let publicKey = SecKeyCopyPublicKey(made.key), contents.publicKey == SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
				check(true, "the certificate request is made from the Keychain key, with its public key")
			} else {
				check(false, "the certificate request is made from the Keychain key, with its public key")
			}
			var duplicate = false
			do { _ = try keys.create(account: a, team: "SIMTEAM001", commonName: "Zag Test") } catch ZagKeychainSigningKeys.Failure.exists { duplicate = true }
			check(duplicate, "an existing key is never replaced silently")
			guard let stored = try keys.key(account: a, team: "SIMTEAM001"), let other = try keys.key(account: b, team: "SIMTEAM001") else {
				check(false, "the keys are found again"); return
			}
			// Platform fact, recorded in SIGNING-KEY-SECURITY.md: the simulator
			// does not enforce kSecAttrIsExtractable for software RSA keys, so
			// the owning app could still export it. Zag Store's code never does
			// (checked by source in the signing suite). If this changes, the
			// document must be updated.
			check(SecKeyCopyExternalRepresentation(stored, nil) != nil,
				  "platform fact as documented: the owning app can still export a software RSA key (not-extractable is not enforced)")
			var attributes: CFTypeRef?
			SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrApplicationTag: try keys.tag(account: a, team: "SIMTEAM001"),
								 kSecReturnAttributes: true] as CFDictionary, &attributes)
			let item = attributes as? [String: Any] ?? [:]
			check(item[kSecAttrAccessible as String] as? String == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
				  && (item[kSecAttrSynchronizable as String] as? Bool ?? false) == false,
				  "the key is after-first-unlock, this device only, never synchronised")

			// A DigestInfo for SHA-256, as Zsign passes it to the signer.
			let digest = Data((0..<32).map { UInt8($0) })
			let digestInfo = Data([0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]) + digest
			let signature = ZagKeychainSigningKeys.signer(stored)(digestInfo)
			let publicKey = SecKeyCopyPublicKey(stored)!
			check(signature.map { SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA256, digest as CFData, $0 as CFData, nil) } == true,
				  "the Keychain key signs through the raw-signer callback; the signature verifies")
			check(signature.map { SecKeyVerifySignature(SecKeyCopyPublicKey(other)!, .rsaSignatureDigestPKCS1v15SHA256, digest as CFData, $0 as CFData, nil) } == false,
				  "another account's key is a different key")
			var badTeam = false
			do { _ = try keys.key(account: a, team: "bad.team*") } catch ZagKeychainSigningKeys.Failure.invalidTeam { badTeam = true }
			check(badTeam, "a malformed team ID is refused")

			// Slots: a new key beside the one in use, found again by label.
			_ = try keys.create(account: a, team: "SIMTEAM001", slot: "SLOT1", commonName: "Zag Test")
			_ = try keys.create(account: a, team: "SIMTEAM001", slot: "SLOT2", commonName: "Zag Test")
			let teamSlots = Set(try keys.slots(account: a, team: "SIMTEAM001")), orgSlots = try keys.slots(account: a, team: "SIMORG0001")
			check(teamSlots == [nil, "SLOT1", "SLOT2"] && orgSlots == [nil],
				  "a team's keys in every slot are found from the account's label, and only that team's (L2)")
			let inUse = try keys.key(account: a, team: "SIMTEAM001")
			check(try keys.key(account: a, team: "SIMTEAM001", slot: "SLOT1") != nil && inUse.map { SecKeyCopyPublicKey($0).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } } == SecKeyCopyPublicKey(stored).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? },
				  "a key in a new slot leaves the key in use unchanged (L2)")
			try keys.delete(account: a, team: "SIMTEAM001", slot: "SLOT1")
			check(try keys.slots(account: a, team: "SIMTEAM001").count == 2, "one slot's key is deleted alone")
			check(try keys.accountsWithKeys().isSuperset(of: [a, b]), "accounts with key items are found from this namespace's labels (L1)")

			try keys.deleteAll(account: a)
			check(try keys.key(account: a, team: "SIMTEAM001") == nil && keys.key(account: a, team: "SIMORG0001") == nil
				  && keys.slots(account: a, team: "SIMTEAM001").isEmpty,
				  "removing an account deletes all of its keys, every team and slot")
			check(try keys.key(account: b, team: "SIMTEAM001") != nil, "another account's key is untouched")
			try keys.delete(account: b, team: "SIMTEAM001")
			check(try keys.key(account: b, team: "SIMTEAM001") == nil, "a single key is deleted")
		} catch {
			check(false, "signing keys: unexpected error \(error)")
		}
	}

	var body: some Scene { WindowGroup { Text("Keychain harness") } }
}
