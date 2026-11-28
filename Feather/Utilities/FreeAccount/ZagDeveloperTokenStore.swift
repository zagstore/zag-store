import Foundation

// Secure, this-device-only persistence of the Xcode developer-services token
// (account id + token + expiry) so a verified token can be reused for
// developer-services requests WITHOUT another GrandSlam login. The token bytes
// are opaque and never logged, printed, returned to callers or placed in any
// diagnostics; callers learn only whether a usable token exists. Stored exactly
// like the ADI profiles and the account session (kSecAttrAccessible after first
// unlock, this device only, never synchronised).

/// The persisted developer token. `token` and `accountID` are sensitive and
/// never appear in any report.
struct ZagPersistedDeveloperToken: Codable, Equatable, Sendable {
	let accountID: String
	let token: String
	/// Milliseconds since the epoch; 0 means Apple reported no expiry.
	let expiresAtMs: Int64

	func isUsable(at now: Date) -> Bool {
		guard !accountID.isEmpty, !token.isEmpty else { return false }
		return expiresAtMs == 0 || Double(expiresAtMs) / 1000 > now.timeIntervalSince1970
	}
}

struct ZagDeveloperTokenStore {
	private let service = "app.zagstore.anisette.appleauth.devtoken.v1"

	private func query(_ scope: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: scope]
	}

	/// Whether a token is persisted for `scope` (no bytes returned).
	func hasToken(scope: String) -> Bool {
		var q = query(scope); q[kSecReturnData as String] = false
		return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
	}

	/// The persisted token for `scope`, decoded, or nil. Never logged.
	func load(scope: String) -> ZagPersistedDeveloperToken? { try? read(scope: scope) }

	func read(scope: String) throws -> ZagPersistedDeveloperToken? {
		var q = query(scope)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		let status = SecItemCopyMatching(q as CFDictionary, &item)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw ZagAppleAuthError.keychain(status) }
		guard let data = item as? Data else { throw ZagAppleAuthError.keychain(errSecDecode) }
		return try JSONDecoder().decode(ZagPersistedDeveloperToken.self, from: data)
	}

	/// Store the token (overwrites). The bytes are opaque and never logged.
	func save(_ token: ZagPersistedDeveloperToken, scope: String) throws {
		let data = try JSONEncoder().encode(token)
		var add = query(scope)
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecSuccess { return }
		guard status == errSecDuplicateItem else { throw ZagAppleAuthError.keychain(status) }
		let update = [kSecValueData as String: data,
					  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
		let s = SecItemUpdate(query(scope) as CFDictionary, update as CFDictionary)
		guard s == errSecSuccess else { throw ZagAppleAuthError.keychain(s) }
	}

	func delete(scope: String) throws {
		let s = SecItemDelete(query(scope) as CFDictionary)
		guard s == errSecSuccess || s == errSecItemNotFound else { throw ZagAppleAuthError.keychain(s) }
	}
}
