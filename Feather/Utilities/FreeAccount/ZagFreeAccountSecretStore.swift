import Foundation
import Security

/// Secrets of a free Apple Account. The Apple Account password is not one of
/// them: it is used for one sign-in and never stored, so an expired session
/// always needs the user to sign in again.
enum ZagFreeAccountSecretKind: String, CaseIterable, Sendable {
	/// The developer-services session token and the account's DSID.
	case session
	/// A team's development signing identity (`ZagSigningIdentity`: the
	/// certificate and its PKCS #1 private key), stored per account and team.
	/// The pinned Zsign reads the key from a file, so it cannot be a
	/// non-exportable key yet (see SIGNING-KEY-SECURITY.md); it is kept in the
	/// Keychain and written to a temporary file only while signing.
	case signingPrivateKey
	/// Anisette provisioning state for this device, if the provider keeps any.
	case anisetteProvisioning
}

/// Secrets are owned by one account, and optionally by one of its teams
/// (`team`, a validated team ID): one account's items are never read,
/// written or removed through another account's ID.
protocol ZagFreeAccountSecretStore: Sendable {
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data?
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws
	/// Removes every item of the account, of every kind and team (account removal).
	func deleteAll(account: UUID) throws
}

extension ZagFreeAccountSecretStore {
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws {
		try save(secret, kind: kind, account: account, team: nil)
	}

	func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data? {
		try load(kind, account: account, team: nil)
	}

	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws {
		try delete(kind, account: account, team: nil)
	}

	/// The Keychain account name of an item: `<account>.<kind>[.<team>]`.
	static func itemName(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) -> String {
		"\(account.uuidString).\(kind.rawValue)" + (team.map { ".\($0)" } ?? "")
	}
}

/// Generic-password Keychain items, readable after the first unlock (so a
/// background refresh can use them), never synchronised to iCloud and never
/// restored to another device.
struct ZagKeychainFreeAccountSecretStore: ZagFreeAccountSecretStore {
	enum StoreError: Error, Equatable {
		case keychain(OSStatus)
		case empty
		case invalidTeam
	}

	let service: String

	init(service: String = "app.zagstore.free-account.v1") {
		self.service = service
	}

	private func identity(_ kind: ZagFreeAccountSecretKind, _ account: UUID, _ team: String?) throws -> [String: Any] {
		if let team, !ZagDeveloperTeam.isValidIdentifier(team) { throw StoreError.invalidTeam }
		return [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: Self.itemName(kind, account: account, team: team),
			kSecAttrSynchronizable as String: kCFBooleanFalse as Any
		]
	}

	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		guard !secret.isEmpty else { throw StoreError.empty }
		var add = try identity(kind, account, team)
		add[kSecValueData as String] = secret
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecSuccess { return }
		guard status == errSecDuplicateItem else { throw StoreError.keychain(status) }
		let update: [String: Any] = [
			kSecValueData as String: secret,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]
		let updateStatus = SecItemUpdate(try identity(kind, account, team) as CFDictionary, update as CFDictionary)
		guard updateStatus == errSecSuccess else { throw StoreError.keychain(updateStatus) }
	}

	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? {
		var query = try identity(kind, account, team)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw StoreError.keychain(status) }
		return result as? Data
	}

	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		let status = SecItemDelete(try identity(kind, account, team) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
	}

	/// Finds the account's items by name prefix (the Keychain has no wildcard
	/// delete) and removes each one; other accounts' items are not touched.
	func deleteAll(account: UUID) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
			kSecReturnAttributes as String: true,
			kSecMatchLimit as String: kSecMatchLimitAll
		]
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return }
		guard status == errSecSuccess else { throw StoreError.keychain(status) }
		let prefix = "\(account.uuidString)."
		for attributes in (result as? [[String: Any]]) ?? [] {
			guard let name = attributes[kSecAttrAccount as String] as? String, name.hasPrefix(prefix) else { continue }
			let item: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: name,
				kSecAttrSynchronizable as String: kCFBooleanFalse as Any
			]
			let deleted = SecItemDelete(item as CFDictionary)
			guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw StoreError.keychain(deleted) }
		}
	}

	/// The protection class of a stored item, for the tests.
	func accessibility(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String? = nil) -> String? {
		guard var query = try? identity(kind, account, team) else { return nil }
		query[kSecReturnAttributes as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			  let attributes = result as? [String: Any] else { return nil }
		return attributes[kSecAttrAccessible as String] as? String
	}
}

/// Removes account secrets from text before it is logged or shown in
/// diagnostics: email addresses, Apple authentication headers and cookies,
/// DSIDs, PEM blocks and long base64 or hex runs (tokens, keys, anisette).
enum ZagSensitiveRedactor {
	private static let rules: [(NSRegularExpression, String)] = [
		(#"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----"#, "[redacted key]"),
		(#"(?i)\b(X-Apple-[A-Za-z0-9-]+|X-Mme-[A-Za-z0-9-]+|Authorization|Cookie|Set-Cookie)\s*[:=]\s*[^\r\n]+"#, "$1: [redacted]"),
		(#"(?i)\b(myacinfo|dsid|adsid|GsIdmsToken|idmsToken|token|password|passwd|secret)("?\s*[:=]\s*"?)[^\s",;&<]+"#, "$1$2[redacted]"),
		(#"(?i)<key>(password|token|dsid|adsid|GsIdmsToken|myacinfo)</key>\s*<(string|integer)>[^<]*</\2>"#, "<key>$1</key><$2>[redacted]</$2>"),
		(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
		(#"[A-Za-z0-9+/_-]{32,}={0,2}"#, "[redacted]")
	].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

	static func redact(_ text: String) -> String {
		rules.reduce(text) { text, rule in
			rule.0.stringByReplacingMatches(
				in: text,
				range: NSRange(text.startIndex..., in: text),
				withTemplate: rule.1
			)
		}
	}
}
