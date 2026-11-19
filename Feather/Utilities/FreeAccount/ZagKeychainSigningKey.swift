import Foundation
import Security

// Signing keys kept as Keychain key items, one per account and team, so the
// private key is never exported: the certificate request is made from the
// key reference, and signatures are made with SecKeyCreateSignature through
// Zsign's raw-signer callback (Zsign f34e51a). Not used while
// ZagFreeAccountSigning is disabled. See
// docs/free-developer-accounts/SIGNING-KEY-SECURITY.md.

struct ZagKeychainSigningKeys {
	enum Failure: Error, Equatable {
		case invalidTeam
		case exists
		case keyGeneration
		case keychain(OSStatus)
	}

	static let keySizeInBits = 2048

	/// Keychain namespace, e.g. "ZagStore.accounts"; tests use their own.
	let namespace: String

	/// Groups an account's keys, so removing the account removes them all.
	func label(account: UUID) -> String { "\(namespace).signing-key.\(account.uuidString)" }

	func tag(account: UUID, team: String) throws -> Data {
		guard !team.isEmpty, team.count <= 32, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
			throw Failure.invalidTeam
		}
		return Data("\(label(account: account)).\(team)".utf8)
	}

	/// Creates the account and team's key in the Keychain (after first
	/// unlock, this device only, never synchronised) and its certificate
	/// request. An existing key is never replaced silently.
	func create(account: UUID, team: String, commonName: String) throws -> (key: SecKey, request: ZagCertificateRequest) {
		let tag = try tag(account: account, team: team)
		if try key(account: account, team: team) != nil { throw Failure.exists }
		var error: Unmanaged<CFError>?
		guard let key = SecKeyCreateRandomKey([
			kSecAttrKeyType: kSecAttrKeyTypeRSA,
			kSecAttrKeySizeInBits: Self.keySizeInBits,
			kSecAttrSynchronizable: false,
			kSecPrivateKeyAttrs: [
				kSecAttrIsPermanent: true,
				kSecAttrApplicationTag: tag,
				kSecAttrLabel: label(account: account),
				kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
				kSecAttrIsExtractable: false
			] as [CFString: Any]
		] as CFDictionary, &error) else { throw Failure.keyGeneration }
		let request = try ZagCertificateSigningRequest.make(commonName: commonName, privateKey: key)
		guard case .success = ZagCertificateSigningRequest.validate(request) else {
			try? delete(account: account, team: team)
			throw Failure.keyGeneration
		}
		return (key, ZagCertificateRequest(data: request))
	}

	/// A reference to the key; the key itself stays in the Keychain.
	func key(account: UUID, team: String) throws -> SecKey? {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassKey,
			kSecAttrKeyClass: kSecAttrKeyClassPrivate,
			kSecAttrApplicationTag: try tag(account: account, team: team),
			kSecReturnRef: true
		] as CFDictionary, &result)
		switch status {
		case errSecSuccess: return (result as! SecKey)
		case errSecItemNotFound: return nil
		default: throw Failure.keychain(status)
		}
	}

	func delete(account: UUID, team: String) throws {
		try remove([kSecClass: kSecClassKey, kSecAttrApplicationTag: try tag(account: account, team: team)])
	}

	/// Every key of the account, for confirmed account removal.
	func deleteAll(account: UUID) throws {
		try remove([kSecClass: kSecClassKey, kSecAttrLabel: label(account: account)])
	}

	private func remove(_ query: [CFString: Any]) throws {
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
	}

	/// The raw signer Zsign calls: RSA PKCS #1 v1.5 over a DigestInfo it
	/// has built. Nil when the key refuses.
	static func signer(_ key: SecKey) -> (Data) -> Data? {
		{ digestInfo in SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, digestInfo as CFData, nil) as Data? }
	}
}

/// Makes each account and team's key as a Keychain key item, so the identity
/// stored by the provisioner carries no key bytes (`keyIsInKeychain`) and the
/// adapter signs through the key reference only.
struct ZagKeychainSigningKeyFactory: ZagSigningKeyFactory {
	enum Failure: Error, Equatable { case accountRequired }

	let keys: ZagKeychainSigningKeys

	/// Keychain keys belong to an account and team.
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) {
		throw Failure.accountRequired
	}

	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { .mismatch }

	/// The provisioner asks for a key only when it will request a new
	/// certificate, so a key left by an earlier, unfinished attempt is replaced.
	func makeKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest) {
		try keys.delete(account: account, team: team)
		let made = try keys.create(account: account, team: team, commonName: commonName)
		return (Data(), made.request)
	}

	/// The certificate is for the key item: a fresh challenge signed by the
	/// key verifies with the certificate's public key.
	func check(certificate: Data, privateKey: Data, account: UUID, team: String) -> ZagIssuedCertificateCheck {
		var challenge = Data(count: 32)
		guard privateKey.isEmpty,
			  let inspection = ZagCertificateInspection(der: certificate),
			  let parsed = SecCertificateCreateWithData(nil, certificate as CFData),
			  let certificateKey = SecCertificateCopyKey(parsed),
			  let key = try? keys.key(account: account, team: team),
			  challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
			  let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, nil),
			  SecKeyVerifySignature(certificateKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, signature, nil) else {
			return .mismatch
		}
		return .matches(serialNumber: inspection.serialNumber, expiresAt: inspection.expiresAt)
	}
}
