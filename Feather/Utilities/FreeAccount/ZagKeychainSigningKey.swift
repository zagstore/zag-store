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

	/// The tag of a team's key. Each new key gets its own slot, and the stored
	/// identity names the slot its key is in (`ZagSigningIdentity.keySlot`), so
	/// a new key never replaces the one in use: the identity is switched by a
	/// single write once the new certificate is verified. No slot is the tag
	/// used before slots existed. Keys are never retagged (the macOS file
	/// keychain reports success for a tag update without applying it).
	func tag(account: UUID, team: String, slot: String? = nil) throws -> Data {
		guard !team.isEmpty, team.count <= 32, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
			throw Failure.invalidTeam
		}
		if let slot, !Self.isValidSlot(slot) { throw Failure.invalidTeam }
		return Data("\(label(account: account)).\(team)\(slot.map { ".\($0)" } ?? "")".utf8)
	}

	static func isValidSlot(_ slot: String) -> Bool {
		!slot.isEmpty && slot.count <= 16 && slot.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
	}

	static func newSlot() -> String {
		String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
	}

	/// Creates a key in the Keychain (after first unlock, this device only,
	/// never synchronised) and its certificate request. An existing key is
	/// never replaced.
	func create(account: UUID, team: String, slot: String? = nil, commonName: String) throws -> (key: SecKey, request: ZagCertificateRequest) {
		let tag = try tag(account: account, team: team, slot: slot)
		if try key(tag: tag) != nil { throw Failure.exists }
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
			try? remove([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag])
			throw Failure.keyGeneration
		}
		return (key, ZagCertificateRequest(data: request))
	}

	/// A reference to the key; the key itself stays in the Keychain.
	func key(account: UUID, team: String, slot: String? = nil) throws -> SecKey? {
		try key(tag: try tag(account: account, team: team, slot: slot))
	}

	private func key(tag: Data) throws -> SecKey? {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassKey,
			kSecAttrKeyClass: kSecAttrKeyClassPrivate,
			kSecAttrApplicationTag: tag,
			kSecReturnRef: true
		] as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			// Anything but a key reference is refused, never cast.
			guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else { throw Failure.keychain(errSecInternalError) }
			return (result as! SecKey)
		case errSecItemNotFound: return nil
		default: throw Failure.keychain(status)
		}
	}

	func delete(account: UUID, team: String, slot: String? = nil) throws {
		try remove([kSecClass: kSecClassKey, kSecAttrApplicationTag: try tag(account: account, team: team, slot: slot)])
	}

	/// The slots of the team's keys (nil: the tag without a slot), from the
	/// account's keys (matched by label, `kSecMatchLimitAll`,
	/// `kSecReturnAttributes`).
	func slots(account: UUID, team: String) throws -> [String?] {
		let base = String(decoding: try tag(account: account, team: team), as: UTF8.self)
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassKey,
			kSecAttrKeyClass: kSecAttrKeyClassPrivate,
			kSecAttrLabel: label(account: account),
			kSecReturnAttributes: true,
			kSecMatchLimit: kSecMatchLimitAll
		] as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess else { throw Failure.keychain(status) }
		return ((result as? [[String: Any]]) ?? []).compactMap { attributes -> String?? in
			guard let data = attributes[kSecAttrApplicationTag as String] as? Data else { return nil }
			let tag = String(decoding: data, as: UTF8.self)
			if tag == base { return .some(nil) }
			guard tag.hasPrefix(base + ".") else { return nil }
			let slot = String(tag.dropFirst(base.count + 1))
			return Self.isValidSlot(slot) ? .some(slot) : nil
		}
	}

	/// The accounts with key items in this namespace (current or pending),
	/// from each key's label: every private key the app can see is matched
	/// (`kSecMatchLimitAll`, `kSecReturnAttributes`) and only this
	/// namespace's labels are kept.
	func accountsWithKeys() throws -> Set<UUID> {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassKey,
			kSecAttrKeyClass: kSecAttrKeyClassPrivate,
			kSecReturnAttributes: true,
			kSecMatchLimit: kSecMatchLimitAll
		] as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess else { throw Failure.keychain(status) }
		let prefix = "\(namespace).signing-key."
		return Set(((result as? [[String: Any]]) ?? []).compactMap { attributes in
			guard let label = attributes[kSecAttrLabel as String] as? String, label.hasPrefix(prefix) else { return nil }
			return UUID(uuidString: String(label.dropFirst(prefix.count)))
		})
	}

	/// Every key of the account (every team, current and pending), for
	/// confirmed account removal. Repeated until none is left, because some
	/// Keychains (the macOS file keychain) delete one match per call.
	func deleteAll(account: UUID) throws {
		let query = [kSecClass: kSecClassKey, kSecAttrLabel: label(account: account)] as CFDictionary
		for _ in 0..<256 {
			let status = SecItemDelete(query)
			if status == errSecItemNotFound { return }
			guard status == errSecSuccess else { throw Failure.keychain(status) }
		}
		throw Failure.keychain(errSecInternalError)
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

	/// Every new key gets a new slot beside the key in use.
	func makePendingKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest, keySlot: String?) {
		let slot = ZagKeychainSigningKeys.newSlot()
		return (Data(), try keys.create(account: account, team: team, slot: slot, commonName: commonName).request, slot)
	}

	func hasKey(account: UUID, team: String, keySlot: String?) -> Bool { (try? keys.key(account: account, team: team, slot: keySlot)) != nil }
	func discardKey(account: UUID, team: String, keySlot: String?) throws { try keys.delete(account: account, team: team, slot: keySlot) }
	func discardKeys(account: UUID, team: String, except keeping: Set<String?>) throws {
		for slot in try keys.slots(account: account, team: team) where !keeping.contains(slot) {
			try keys.delete(account: account, team: team, slot: slot)
		}
	}

	/// The certificate is for the key item: a fresh challenge signed by the
	/// key verifies with the certificate's public key.
	func check(certificate: Data, privateKey: Data, account: UUID, team: String, keySlot: String?) -> ZagIssuedCertificateCheck {
		check(certificate: certificate, privateKey: privateKey, key: try? keys.key(account: account, team: team, slot: keySlot))
	}

	private func check(certificate: Data, privateKey: Data, key: SecKey?) -> ZagIssuedCertificateCheck {
		var challenge = Data(count: 32)
		guard privateKey.isEmpty,
			  let inspection = ZagCertificateInspection(der: certificate),
			  let parsed = SecCertificateCreateWithData(nil, certificate as CFData),
			  let certificateKey = SecCertificateCopyKey(parsed),
			  let key,
			  challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
			  let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, nil),
			  SecKeyVerifySignature(certificateKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, signature, nil) else {
			return .mismatch
		}
		return .matches(serialNumber: inspection.serialNumber, expiresAt: inspection.expiresAt)
	}
}
