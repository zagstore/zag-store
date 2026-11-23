import Foundation
import Security

// The test Apple Account credentials for the sign-in experiment, held only in
// the this-device-only Keychain (its own service, never synchronised). They are
// seeded through the harness's secure entry screen and read once at run time;
// they are never placed in an environment variable, a command-line argument, a
// log line or a result file. Harness-only — not part of the app.

struct ZagSignInCredential: Codable, Equatable {
	let email: String
	let password: String
}

struct ZagSignInCredentialStore {
	let service: String
	private let account = "test-account"
	init(service: String = "app.zagstore.signin-experiment.credential.v1") { self.service = service }

	private var base: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account,
		 kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
	}

	func save(_ credential: ZagSignInCredential) throws {
		let data = try JSONEncoder().encode(credential)
		var add = base
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let s = SecItemAdd(add as CFDictionary, nil)
		if s == errSecSuccess { return }
		guard s == errSecDuplicateItem else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
		let upd = [kSecValueData as String: data,
				   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
		let u = SecItemUpdate(base as CFDictionary, upd as CFDictionary)
		guard u == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(u)) }
	}

	func load() -> ZagSignInCredential? {
		var q = base
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
		return try? JSONDecoder().decode(ZagSignInCredential.self, from: data)
	}

	func clear() { SecItemDelete(base as CFDictionary) }
}
