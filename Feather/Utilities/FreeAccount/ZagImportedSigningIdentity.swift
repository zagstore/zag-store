import Foundation
import Security

// A SEPARATE, opt-in signing path for a one-time bootstrap: a user-imported,
// password-protected PKCS#12 development identity (e.g. an identity exported
// once from a Mac). It is deliberately kept distinct from the device-generated,
// non-extractable Secure-Enclave/Keychain key path (`ZagKeychainSigningKeys`),
// which stays intact and is the preferred architecture.
//
// IMPORTANT: an imported private key is EXTRACTABLE key material. It is NOT
// equivalent to a device-generated non-extractable key, and this module never
// claims otherwise (`ZagImportedIdentityInfo.isNonExtractable == false`). The
// passphrase is used only transiently and is never stored or logged; no private
// key, password or CSR is ever written to logs, diagnostics or temp files.

enum ZagImportedIdentityError: Error, Equatable, Sendable {
	/// SecPKCS12Import rejected the data or passphrase (wrong password / corrupt).
	case wrongPasswordOrCorrupt
	/// The PKCS#12 held no usable identity (certificate + private key).
	case noIdentity
	/// The private key does not correspond to the certificate.
	case keyCertMismatch
	/// The certificate is past its notAfter date.
	case certExpired
	/// The certificate is not an Apple development signing certificate.
	case notDevelopmentCertificate
	/// The certificate's team (OU) is not the expected team.
	case teamMismatch
	case signFailed
	case keychainStoreFailed(OSStatus)
}

/// Sanitized, non-sensitive facts about an imported identity (safe to surface).
struct ZagImportedIdentityInfo: Equatable, Sendable {
	let commonName: String
	let team: String?          // subject OU
	let serialNumber: String
	let notAfter: Date
	let isDevelopment: Bool
	/// ALWAYS false for an imported identity — extractable key material, not a
	/// device-generated non-extractable key. Preserved so the UI can distinguish.
	let isNonExtractable: Bool
}

enum ZagImportedSigningIdentity {
	// MARK: Import (no persistence; passphrase transient)

	/// Imports a password-protected PKCS#12 into an in-memory `SecIdentity`.
	/// Persists nothing; the passphrase is used only for this call.
	static func importIdentity(pkcs12 data: Data, password: String) -> Result<SecIdentity, ZagImportedIdentityError> {
		var out: CFArray?
		let options = [kSecImportExportPassphrase as String: password] as CFDictionary
		let status = SecPKCS12Import(data as CFData, options, &out)
		guard status == errSecSuccess else { return .failure(.wrongPasswordOrCorrupt) }
		guard let items = out as? [[String: Any]], let first = items.first,
			  let idAny = first[kSecImportItemIdentity as String] else { return .failure(.noIdentity) }
		// SecIdentity is a CF type; the cast is checked by the runtime.
		let identity = idAny as! SecIdentity
		return .success(identity)
	}

	// MARK: Validation (correspondence + suitability; no persistence)

	/// Validates key↔certificate correspondence, development-signing suitability,
	/// validity window and (optionally) team, returning sanitized info.
	static func validate(_ identity: SecIdentity, now: Date = Date(), expectedTeam: String? = nil) -> Result<ZagImportedIdentityInfo, ZagImportedIdentityError> {
		var certRef: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef else { return .failure(.noIdentity) }
		var keyRef: SecKey?
		guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else { return .failure(.noIdentity) }
		guard corresponds(key: key, certificate: cert) else { return .failure(.keyCertMismatch) }
		guard let info = parse(cert) else { return .failure(.notDevelopmentCertificate) }
		guard info.isDevelopment else { return .failure(.notDevelopmentCertificate) }
		guard info.notAfter > now else { return .failure(.certExpired) }
		if let expectedTeam, let team = info.team, team != expectedTeam { return .failure(.teamMismatch) }
		return .success(info)
	}

	/// A fresh random challenge signed by the key must verify with the
	/// certificate's public key — the same correspondence proof the device-key
	/// path uses (`ZagKeychainSigningKeyFactory.check`).
	static func corresponds(key: SecKey, certificate: SecCertificate) -> Bool {
		var challenge = Data(count: 32)
		guard challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
			  let certKey = SecCertificateCopyKey(certificate),
			  let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, nil) as Data?,
			  SecKeyVerifySignature(certKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, sig as CFData, nil) else {
			return false
		}
		return true
	}

	// MARK: Signing (reuses the device path's Zsign callback)

	/// The Zsign callback for an imported identity: the SAME raw PKCS#1 v1.5
	/// DigestInfo signer the device-generated-key path hands to Zsign
	/// (`ZagKeychainSigningKeys.signer`), so the signing pipeline is unchanged.
	static func zsignSigner(_ identity: SecIdentity) -> ((Data) -> Data?)? {
		var keyRef: SecKey?
		guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else { return nil }
		return ZagKeychainSigningKeys.signer(key)
	}

	/// Convenience message-signing (PKCS#1 v1.5 SHA-256) for validation round-trips.
	static func sign(_ payload: Data, identity: SecIdentity) -> Data? {
		var keyRef: SecKey?
		guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else { return nil }
		return SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, nil) as Data?
	}

	/// Verifies a message signature with the identity's certificate public key.
	static func verify(_ signature: Data, payload: Data, identity: SecIdentity) -> Bool {
		var certRef: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef,
			  let certKey = SecCertificateCopyKey(cert) else { return false }
		return SecKeyVerifySignature(certKey, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, signature as CFData, nil)
	}

	// MARK: Certificate parsing (sanitized facts only)

	static func parse(_ cert: SecCertificate) -> ZagImportedIdentityInfo? {
		// Parse the DER with the iOS-safe inspector the device path uses
		// (SecCertificateCopyValues / kSecOIDX509V1* are macOS-only).
		guard let inspection = ZagCertificateInspection(der: SecCertificateCopyData(cert) as Data) else { return nil }
		let commonName = inspection.commonName ?? ""
		let isDevelopment = commonName.hasPrefix("Apple Development") || commonName.hasPrefix("iPhone Developer")
		return ZagImportedIdentityInfo(commonName: commonName, team: inspection.organizationalUnit,
									   serialNumber: inspection.serialNumber, notAfter: inspection.expiresAt,
									   isDevelopment: isDevelopment, isNonExtractable: false)
	}

	// MARK: Keychain storage (ThisDeviceOnly; imported identity)

	static let labelPrefix = "app.zagstore.importedIdentity.v1."

	/// Stores the imported identity in the Keychain with ThisDeviceOnly
	/// protection (not synchronized). The stored item is an imported identity,
	/// never conflated with the non-extractable device keys.
	static func store(_ identity: SecIdentity, label: String) -> OSStatus {
		let query: [CFString: Any] = [
			kSecClass: kSecClassIdentity,
			kSecValueRef: identity,
			kSecAttrLabel: labelPrefix + label,
			kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
			kSecAttrSynchronizable: false,
		]
		SecItemDelete(query as CFDictionary)
		return SecItemAdd(query as CFDictionary, nil)
	}

	static func load(label: String) -> SecIdentity? {
		let query: [CFString: Any] = [
			kSecClass: kSecClassIdentity,
			kSecAttrLabel: labelPrefix + label,
			kSecReturnRef: true,
			kSecMatchLimit: kSecMatchLimitOne,
		]
		var out: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let ref = out else { return nil }
		return (ref as! SecIdentity)
	}

	static func delete(label: String) {
		SecItemDelete([kSecClass: kSecClassIdentity, kSecAttrLabel: labelPrefix + label] as CFDictionary)
	}

	// MARK: Explicit resolution for the signing pipeline (no silent fallback)

	/// Resolves a stored imported identity to the Zsign signer + its certificate
	/// DER, after re-validating it. Returns a typed failure if the identity is
	/// missing or no longer valid — it NEVER falls back to a device-generated
	/// key; the caller chose `ZagSigningSource.imported` explicitly.
	static func resolve(label: String, now: Date = Date(), expectedTeam: String? = nil)
		-> Result<(signer: (Data) -> Data?, certificateDER: Data, info: ZagImportedIdentityInfo), ZagImportedIdentityError> {
		guard let identity = load(label: label) else { return .failure(.noIdentity) }
		switch validate(identity, now: now, expectedTeam: expectedTeam) {
		case .failure(let e): return .failure(e)
		case .success(let info):
			guard let signer = zsignSigner(identity) else { return .failure(.signFailed) }
			var certRef: SecCertificate?
			guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef else { return .failure(.noIdentity) }
			return .success((signer, SecCertificateCopyData(cert) as Data, info))
		}
	}
}
