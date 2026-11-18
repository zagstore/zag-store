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
			try store.deleteAll(account: a)
			check(try store.load(.session, account: a) == nil && store.accessibility(.signingPrivateKey, account: a) == nil,
				  "signing out removes every secret of the account")
			check(try store.load(.session, account: b) == Data("other".utf8), "another account's secrets are untouched")
			try store.deleteAll(account: b)
			query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
			check(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound, "no test items are left behind")
		} catch {
			lines.append("FAIL: unexpected error \(error)")
		}
		lines.append("DONE")
		try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
	}

	var body: some Scene { WindowGroup { Text("Keychain harness") } }
}
