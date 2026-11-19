import Foundation
import Security

// The development signing key and its certificate signing request, made on
// the device with the Security framework. The private key is exported once,
// into memory, because Zsign reads it from a file at signing time; it is
// kept only in the non-synchronizing Keychain (`ZagSigningIdentity`) and is
// never logged or sent. Only the request, which holds the public key, leaves
// the device.

// MARK: - DER

/// The small part of DER that requests and certificates need.
enum ZagDER {
	struct Node {
		let tag: UInt8
		let content: Data
		/// The whole element, tag and length included.
		let encoded: Data

		func children() throws -> [Node] { try ZagDER.elements(content) }
	}

	enum ParseError: Error { case truncated, unsupportedLength, trailingData }

	static func element(_ tag: UInt8, _ content: Data) -> Data {
		var out = Data([tag])
		let count = content.count
		if count < 0x80 {
			out.append(UInt8(count))
		} else {
			var bytes: [UInt8] = []
			var value = count
			while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
			out.append(0x80 | UInt8(bytes.count))
			out.append(contentsOf: bytes)
		}
		out.append(content)
		return out
	}

	static func sequence(_ parts: [Data]) -> Data { element(0x30, parts.reduce(Data(), +)) }
	static func set(_ parts: [Data]) -> Data { element(0x31, parts.reduce(Data(), +)) }
	static let null = Data([0x05, 0x00])
	static func utf8String(_ value: String) -> Data { element(0x0C, Data(value.utf8)) }
	static func bitString(_ value: Data) -> Data { element(0x03, Data([0x00]) + value) }

	static func integer(_ value: Data) -> Data {
		var bytes = Data(value.drop { $0 == 0 })
		if bytes.isEmpty || bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
		return element(0x02, bytes)
	}

	static func objectIdentifier(_ dotted: String) -> Data {
		let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
		var out = Data([UInt8(parts[0] * 40 + parts[1])])
		for var part in parts.dropFirst(2) {
			var group: [UInt8] = [UInt8(part & 0x7F)]
			part >>= 7
			while part > 0 { group.insert(UInt8(part & 0x7F) | 0x80, at: 0); part >>= 7 }
			out.append(contentsOf: group)
		}
		return element(0x06, out)
	}

	/// Reads consecutive elements filling `data` exactly.
	static func elements(_ data: Data) throws -> [Node] {
		let bytes = [UInt8](data)
		var nodes: [Node] = []
		var index = 0
		while index < bytes.count {
			let start = index
			guard index + 2 <= bytes.count else { throw ParseError.truncated }
			let tag = bytes[index]
			var length = Int(bytes[index + 1])
			index += 2
			if length & 0x80 != 0 {
				let count = length & 0x7F
				guard count > 0, count <= 4, index + count <= bytes.count else { throw ParseError.unsupportedLength }
				length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
				index += count
			}
			guard length <= bytes.count - index else { throw ParseError.truncated }
			nodes.append(Node(
				tag: tag,
				content: Data(bytes[index..<index + length]),
				encoded: Data(bytes[start..<index + length])
			))
			index += length
		}
		return nodes
	}

	static func single(_ data: Data) throws -> Node {
		let nodes = try elements(data)
		guard nodes.count == 1 else { throw ParseError.trailingData }
		return nodes[0]
	}

	enum OID {
		static let rsaEncryption = "1.2.840.113549.1.1.1"
		static let sha256WithRSAEncryption = "1.2.840.113549.1.1.11"
		static let commonName = "2.5.4.3"
	}

	static func decodeObjectIdentifier(_ node: Node) -> String? {
		guard node.tag == 0x06, let first = node.content.first else { return nil }
		var parts = [UInt64(first / 40), UInt64(first % 40)]
		var value: UInt64 = 0
		for byte in node.content.dropFirst() {
			value = value << 7 | UInt64(byte & 0x7F)
			if byte & 0x80 == 0 { parts.append(value); value = 0 }
		}
		return parts.map(String.init).joined(separator: ".")
	}

	/// The common name in an X.501 name, if present.
	static func commonName(in name: Node) -> String? {
		for rdn in (try? name.children()) ?? [] {
			for attribute in (try? rdn.children()) ?? [] {
				guard let pair = try? attribute.children(), pair.count == 2,
					  decodeObjectIdentifier(pair[0]) == OID.commonName else { continue }
				return String(data: pair[1].content, encoding: .utf8)
			}
		}
		return nil
	}

	/// The RSA public key (PKCS #1) in a SubjectPublicKeyInfo.
	static func rsaPublicKey(in subjectPublicKeyInfo: Node) -> Data? {
		guard let parts = try? subjectPublicKeyInfo.children(), parts.count == 2,
			  let algorithm = try? parts[0].children().first,
			  decodeObjectIdentifier(algorithm) == OID.rsaEncryption,
			  parts[1].tag == 0x03, parts[1].content.first == 0x00 else { return nil }
		return parts[1].content.dropFirst().isEmpty ? nil : Data(parts[1].content.dropFirst())
	}
}

// MARK: - Certificate signing request

/// A PKCS #10 certificate signing request: an RSA public key and a common
/// name, signed with SHA-256 by the matching private key.
enum ZagCertificateSigningRequest {
	enum Problem: String, Error, Equatable {
		case malformed
		case unsupportedVersion
		case unsupportedKey
		case keyTooSmall
		case unsupportedSignatureAlgorithm
		case badSignature
		case missingCommonName
	}

	struct Contents: Equatable {
		let commonName: String
		/// PKCS #1 RSA public key.
		let publicKey: Data
		let keySizeInBits: Int
	}

	static func make(commonName: String, privateKey: SecKey) throws -> Data {
		guard let publicKey = SecKeyCopyPublicKey(privateKey),
			  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
			throw Problem.unsupportedKey
		}
		let subject = ZagDER.sequence([
			ZagDER.set([ZagDER.sequence([ZagDER.objectIdentifier(ZagDER.OID.commonName), ZagDER.utf8String(commonName)])])
		])
		let subjectPublicKeyInfo = ZagDER.sequence([
			ZagDER.sequence([ZagDER.objectIdentifier(ZagDER.OID.rsaEncryption), ZagDER.null]),
			ZagDER.bitString(publicKeyData)
		])
		let info = ZagDER.sequence([
			ZagDER.integer(Data([0])),
			subject,
			subjectPublicKeyInfo,
			ZagDER.element(0xA0, Data())
		])
		var error: Unmanaged<CFError>?
		guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, &error) as Data? else {
			throw Problem.badSignature
		}
		return ZagDER.sequence([
			info,
			ZagDER.sequence([ZagDER.objectIdentifier(ZagDER.OID.sha256WithRSAEncryption), ZagDER.null]),
			ZagDER.bitString(signature)
		])
	}

	/// Checks the structure, the key and the signature.
	static func validate(_ data: Data, minimumKeySize: Int = 2048) -> Result<Contents, Problem> {
		guard let request = try? ZagDER.single(data), request.tag == 0x30,
			  let parts = try? request.children(), parts.count == 3,
			  let info = try? parts[0].children(), info.count == 4 else { return .failure(.malformed) }
		guard info[0].tag == 0x02, info[0].content == Data([0]) else { return .failure(.unsupportedVersion) }
		guard let publicKeyData = ZagDER.rsaPublicKey(in: info[2]),
			  let publicKey = SecKeyCreateWithData(publicKeyData as CFData, [
				kSecAttrKeyType: kSecAttrKeyTypeRSA,
				kSecAttrKeyClass: kSecAttrKeyClassPublic
			  ] as CFDictionary, nil) else { return .failure(.unsupportedKey) }
		let keySize = SecKeyGetBlockSize(publicKey) * 8
		guard keySize >= minimumKeySize else { return .failure(.keyTooSmall) }
		guard let algorithm = try? parts[1].children().first,
			  ZagDER.decodeObjectIdentifier(algorithm) == ZagDER.OID.sha256WithRSAEncryption else {
			return .failure(.unsupportedSignatureAlgorithm)
		}
		guard parts[2].tag == 0x03, parts[2].content.first == 0x00,
			  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, parts[0].encoded as CFData, Data(parts[2].content.dropFirst()) as CFData, nil) else {
			return .failure(.badSignature)
		}
		guard let name = ZagDER.commonName(in: info[1]), !name.isEmpty else { return .failure(.missingCommonName) }
		return .success(Contents(commonName: name, publicKey: publicKeyData, keySizeInBits: keySize))
	}
}

// MARK: - Certificates

/// The fields of an X.509 certificate that provisioning checks.
struct ZagCertificateInspection: Equatable, Sendable {
	/// Upper-case hexadecimal, without leading zeros.
	let serialNumber: String
	let commonName: String?
	let expiresAt: Date
	/// PKCS #1 RSA public key, if the certificate holds an RSA key.
	let publicKey: Data?

	init?(der: Data) {
		guard SecCertificateCreateWithData(nil, der as CFData) != nil,
			  let certificate = try? ZagDER.single(der), certificate.tag == 0x30,
			  let tbs = try? certificate.children().first,
			  var fields = try? tbs.children() else { return nil }
		if fields.first?.tag == 0xA0 { fields.removeFirst() }
		// serial, signature, issuer, validity, subject, subjectPublicKeyInfo
		guard fields.count >= 6, fields[0].tag == 0x02,
			  let validity = try? fields[3].children(), validity.count == 2,
			  let expiresAt = Self.date(validity[1]) else { return nil }
		let serial = fields[0].content.drop { $0 == 0 }
		serialNumber = serial.isEmpty ? "0" : serial.map { String(format: "%02X", $0) }.joined()
		commonName = ZagDER.commonName(in: fields[4])
		self.expiresAt = expiresAt
		publicKey = ZagDER.rsaPublicKey(in: fields[5])
	}

	private static func date(_ node: ZagDER.Node) -> Date? {
		guard let text = String(data: node.content, encoding: .ascii), text.hasSuffix("Z") else { return nil }
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		switch node.tag {
		case 0x17: // UTCTime: years 1950-2049
			formatter.dateFormat = "yyMMddHHmmss'Z'"
			formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631_152_000)
		case 0x18:
			formatter.dateFormat = "yyyyMMddHHmmss'Z'"
		default:
			return nil
		}
		return formatter.date(from: text)
	}
}

// MARK: - Key factory

/// What a factory found when it compared an issued certificate with its key.
enum ZagIssuedCertificateCheck: Equatable, Sendable {
	case matches(serialNumber: String, expiresAt: Date)
	/// The certificate is not for this key, or cannot be read.
	case mismatch
	/// The factory cannot inspect certificates (the simulation's synthetic bytes).
	case notInspected
}

/// RSA 2048 keys from the Security framework. The key is created in memory,
/// not in the Keychain; the caller keeps the exported key in
/// `ZagSigningIdentity`, in the non-synchronizing Keychain.
struct ZagSecuritySigningKeyFactory: ZagSigningKeyFactory {
	enum Failure: Error { case keyGeneration, export }

	static let keySizeInBits = 2048

	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) {
		var error: Unmanaged<CFError>?
		guard let key = SecKeyCreateRandomKey([
			kSecAttrKeyType: kSecAttrKeyTypeRSA,
			kSecAttrKeySizeInBits: Self.keySizeInBits,
			kSecAttrIsPermanent: false
		] as CFDictionary, &error) else { throw Failure.keyGeneration }
		// PKCS #1 RSAPrivateKey, which Zsign reads directly.
		guard let exported = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw Failure.export }
		let request = try ZagCertificateSigningRequest.make(commonName: commonName, privateKey: key)
		guard case .success = ZagCertificateSigningRequest.validate(request) else { throw Failure.keyGeneration }
		return (exported, ZagCertificateRequest(data: request))
	}

	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck {
		guard let inspection = ZagCertificateInspection(der: certificate),
			  let key = SecKeyCreateWithData(privateKey as CFData, [
				kSecAttrKeyType: kSecAttrKeyTypeRSA,
				kSecAttrKeyClass: kSecAttrKeyClassPrivate
			  ] as CFDictionary, nil),
			  let publicKey = SecKeyCopyPublicKey(key),
			  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
			  inspection.publicKey == publicKeyData else { return .mismatch }
		return .matches(serialNumber: inspection.serialNumber, expiresAt: inspection.expiresAt)
	}
}
