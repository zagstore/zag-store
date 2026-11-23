import Foundation
import CryptoKit
import Security

// Secure local pairing foundation between Zag Store (iOS) and Zag Companion
// (macOS). v0.1 establishes the cryptographic identity and the authenticated,
// encrypted session it will carry — not a running network transport yet, per
// the v0.1 priority of a complete working local companion.
//
// Design (what the transport will enforce):
//   • The companion has a persistent Curve25519 identity key, stored in the
//     login Keychain (never on disk, never sent).
//   • Pairing shows a short numeric code on the Mac; the phone sends it once
//     over the local link to authenticate the first exchange.
//   • Both sides derive a shared secret by Curve25519 key agreement and use
//     HKDF-SHA256 to key an AEAD (ChaChaPoly) session. Apple Account
//     credentials, private signing keys and unprotected signing material are
//     NEVER transmitted — only install requests, progress and results.

public struct ZagPairingIdentity: Sendable {
	/// The companion's long-term public identity key (base64, safe to show as a QR/code).
	public let publicKey: Data
}

public enum ZagCompanionPairing {
	private static let keychainAccount = "com.zagstore.companion.identity-key"
	private static let service = "ZagCompanion"

	/// The companion's identity public key, creating the key pair on first use.
	public static func identity() throws -> ZagPairingIdentity {
		let key = try loadOrCreateSigningKey()
		return ZagPairingIdentity(publicKey: key.publicKey.rawRepresentation)
	}

	/// A 6-digit pairing code for the current pairing window. The phone echoes
	/// it to prove physical possession before a session is established.
	public static func newPairingCode() -> String {
		var bytes = [UInt8](repeating: 0, count: 4)
		_ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
		let value = bytes.reduce(0) { ($0 << 8) | UInt32($1) } % 1_000_000
		return String(format: "%06u", value)
	}

	/// Derives the shared AEAD session key from the peer's public key and the
	/// pairing code (as salt). Both sides compute the same key.
	public static func sessionKey(peerPublicKey: Data, pairingCode: String) throws -> SymmetricKey {
		let priv = try loadOrCreateAgreementKey()
		let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
		let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
		return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
											  salt: Data(pairingCode.utf8),
											  sharedInfo: Data("zag-companion-session".utf8),
											  outputByteCount: 32)
	}

	/// The companion's key-agreement public key (shared during pairing).
	public static func agreementPublicKey() throws -> Data {
		try loadOrCreateAgreementKey().publicKey.rawRepresentation
	}

	/// Seals a payload for the paired peer (ChaChaPoly).
	public static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
		try ChaChaPoly.seal(plaintext, using: key).combined
	}
	public static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
		try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
	}

	// MARK: - Keychain-backed keys

	private static func loadOrCreateSigningKey() throws -> Curve25519.Signing.PrivateKey {
		if let raw = loadKey(account: keychainAccount) { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw) }
		let key = Curve25519.Signing.PrivateKey()
		storeKey(key.rawRepresentation, account: keychainAccount)
		return key
	}
	private static func loadOrCreateAgreementKey() throws -> Curve25519.KeyAgreement.PrivateKey {
		let account = keychainAccount + ".agreement"
		if let raw = loadKey(account: account) { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) }
		let key = Curve25519.KeyAgreement.PrivateKey()
		storeKey(key.rawRepresentation, account: account)
		return key
	}

	private static func loadKey(account: String) -> Data? {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
			kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
		] as CFDictionary, &result)
		return status == errSecSuccess ? (result as? Data) : nil
	}
	private static func storeKey(_ data: Data, account: String) {
		SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
		SecItemAdd([
			kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
			kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		] as CFDictionary, nil)
	}
}
