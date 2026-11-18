import Foundation
import Security

/// Secrets of a free Apple Account. The Apple Account password is not one of
/// them: it is used for one sign-in and never stored, so an expired session
/// always needs the user to sign in again.
enum ZagFreeAccountSecretKind: String, CaseIterable, Sendable {
	/// The developer-services session token and the account's DSID.
	case session
	/// The development certificate's private key (PKCS#1 DER). Zsign signs with
	/// a PKCS#12 built from it, so it cannot be a non-exportable Secure Enclave
	/// key (which is also limited to P-256; Apple's development certificates
	/// are RSA). It is kept in the Keychain and written to a temporary file
	/// only while signing.
	case signingPrivateKey
	/// Anisette provisioning state for this device, if the provider keeps any.
	case anisetteProvisioning
}

protocol ZagFreeAccountSecretStore: Sendable {
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data?
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws
}

extension ZagFreeAccountSecretStore {
	/// Signing out removes every secret of the account.
	func deleteAll(account: UUID) throws {
		for kind in ZagFreeAccountSecretKind.allCases { try delete(kind, account: account) }
	}
}

/// Generic-password Keychain items, readable after the first unlock (so a
/// background refresh can use them), never synchronised to iCloud and never
/// restored to another device.
struct ZagKeychainFreeAccountSecretStore: ZagFreeAccountSecretStore {
	enum StoreError: Error, Equatable {
		case keychain(OSStatus)
		case empty
	}

	let service: String

	init(service: String = "app.zagstore.free-account.v1") {
		self.service = service
	}

	private func identity(_ kind: ZagFreeAccountSecretKind, _ account: UUID) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: "\(account.uuidString).\(kind.rawValue)",
			kSecAttrSynchronizable as String: kCFBooleanFalse as Any
		]
	}

	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws {
		guard !secret.isEmpty else { throw StoreError.empty }
		var add = identity(kind, account)
		add[kSecValueData as String] = secret
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecSuccess { return }
		guard status == errSecDuplicateItem else { throw StoreError.keychain(status) }
		let update: [String: Any] = [
			kSecValueData as String: secret,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]
		let updateStatus = SecItemUpdate(identity(kind, account) as CFDictionary, update as CFDictionary)
		guard updateStatus == errSecSuccess else { throw StoreError.keychain(updateStatus) }
	}

	func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data? {
		var query = identity(kind, account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw StoreError.keychain(status) }
		return result as? Data
	}

	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws {
		let status = SecItemDelete(identity(kind, account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
	}

	/// The protection class of a stored item, for the tests.
	func accessibility(_ kind: ZagFreeAccountSecretKind, account: UUID) -> String? {
		var query = identity(kind, account)
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
