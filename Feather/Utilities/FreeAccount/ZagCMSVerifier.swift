import Foundation
import Security
import CryptoKit

// An iOS-safe CMS (PKCS#7 SignedData, RFC 5652) verifier for `.mobileprovision`
// blobs. iOS has no public high-level CMS-verify API (CMSDecoder is macOS-only),
// so this is a small, auditable verifier built on the repo's existing ZagDER
// ASN.1 walker for STRUCTURE only — all cryptography uses the Security framework
// (`SecKeyVerifySignature`) and SecTrust for chain validation. Nothing here
// re-implements ASN.1 crypto from scratch.
//
// It FAILS CLOSED: a malformed structure, a digest/signature mismatch, an
// unexpected signer, or a chain that does not terminate at the explicitly pinned
// Apple Root CA all return a typed failure and NO payload. The only success
// output is the cryptographically authenticated eContent bytes.
//
// Trust anchor: the chain must validate to the classic Apple Root CA, pinned by
// its public SHA-256 fingerprint. The anchor certificate itself is taken from
// the CMS's own certificate set, but is trusted ONLY when its fingerprint equals
// the pinned value — an attacker-substituted root fails the fingerprint check,
// and SHA-256 preimage resistance prevents forging one. This is NOT a
// caller-supplied boolean, sidecar file or unverified digest shortcut.

enum ZagCMSVerifier {
	enum Failure: Error, Equatable {
		case malformedCMS
		case notSignedData
		case noEncapsulatedContent
		case noSignerInfo
		case noSignerCertificate
		case unsupportedDigestAlgorithm
		case digestMismatch          // signed messageDigest attr != digest(eContent)
		case badSignature            // cryptographic signature check failed
		case noTrustedAnchor         // no embedded cert matches the pinned Apple root
		case untrustedChain          // chain did not validate to the pinned anchor
	}

	/// The classic Apple Root CA, pinned by SHA-256 (public, well-known value).
	static let appleRootCASHA256 = "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024"

	// OIDs.
	private static let oidSignedData = "1.2.840.113549.1.7.2"
	private static let oidMessageDigest = "1.2.840.113549.1.9.4"
	private static let oidSHA256 = "2.16.840.1.101.3.4.2.1"
	private static let oidSHA1 = "1.3.14.3.2.26"

	/// Verifies the CMS blob and returns the authentic eContent (the profile
	/// plist bytes) on success. `trustedRootSHA256` defaults to the pinned Apple
	/// Root CA; tests may pass a synthetic root's fingerprint instead.
	static func verify(_ cms: Data,
					   trustedRootSHA256: Set<String> = [appleRootCASHA256],
					   now: Date = Date()) -> Result<Data, Failure> {
		// ContentInfo ::= SEQUENCE { contentType OID, [0] EXPLICIT content }
		guard let contentInfo = try? ZagDER.single(cms), contentInfo.tag == 0x30,
			  let ciParts = try? contentInfo.children(), ciParts.count >= 2,
			  ZagDER.decodeObjectIdentifier(ciParts[0]) == oidSignedData else { return .failure(.notSignedData) }
		guard ciParts[1].tag == 0xA0, let signedData = try? ciParts[1].children().first, signedData.tag == 0x30,
			  let sd = try? signedData.children(), sd.count >= 4 else { return .failure(.malformedCMS) }

		// sd: version, digestAlgorithms(SET), encapContentInfo(SEQ), [certs [0]], [crls [1]], signerInfos(SET)
		// encapContentInfo ::= SEQUENCE { eContentType OID, [0] EXPLICIT OCTET STRING }
		guard let encap = sd.first(where: { $0.tag == 0x30 }),   // first SEQUENCE after the SETs
			  let encapParts = try? encap.children(), encapParts.count >= 2,
			  encapParts[1].tag == 0xA0,
			  let eContentOctet = try? encapParts[1].children().first, eContentOctet.tag == 0x04 else {
			return .failure(.noEncapsulatedContent)
		}
		let eContent = eContentOctet.content

		// Embedded certificates: context [0] (0xA0) after encapContentInfo.
		let certDERs: [Data] = {
			guard let certSet = sd.first(where: { $0.tag == 0xA0 }) else { return [] }
			return ((try? certSet.children()) ?? []).filter { $0.tag == 0x30 }.map { $0.encoded }
		}()
		guard !certDERs.isEmpty else { return .failure(.noSignerCertificate) }

		// signerInfos = the LAST SET (the first SET is digestAlgorithms).
		guard let signerInfos = sd.last(where: { $0.tag == 0x31 }),
			  let signer = try? signerInfos.children().first, signer.tag == 0x30,
			  let si = try? signer.children(), si.count >= 5 else { return .failure(.noSignerInfo) }

		// SignerInfo: version, sid, digestAlgorithm, [signedAttrs [0]], signatureAlgorithm, signature
		let sid = si[1]
		let digestAlg = (try? si[2].children().first).flatMap(ZagDER.decodeObjectIdentifier)
		let hasSignedAttrs = si[3].tag == 0xA0
		let signedAttrs: ZagDER.Node? = hasSignedAttrs ? si[3] : nil
		let sigIndex = hasSignedAttrs ? 5 : 4
		guard si.count > sigIndex, si[sigIndex].tag == 0x04 else { return .failure(.noSignerInfo) }
		let signature = si[sigIndex].content

		guard let algorithm = rsaAlgorithm(for: digestAlg) else { return .failure(.unsupportedDigestAlgorithm) }

		// Locate the signer certificate by issuer+serial (issuerAndSerialNumber).
		guard let signerDER = signerCertificate(matching: sid, in: certDERs),
			  let signerCert = SecCertificateCreateWithData(nil, signerDER as CFData),
			  let signerKey = SecCertificateCopyKey(signerCert) else { return .failure(.noSignerCertificate) }

		// The signed bytes: when signedAttrs are present the signature is over the
		// DER of signedAttrs re-encoded with an explicit SET tag (0x31), and the
		// messageDigest attribute MUST equal digest(eContent) — this binds the
		// authentic content to the signature. Otherwise the signature is over
		// eContent directly.
		let signedBytes: Data
		if let signedAttrs {
			guard let md = messageDigest(in: signedAttrs),
				  md == digest(eContent, algorithm: digestAlg) else { return .failure(.digestMismatch) }
			signedBytes = ZagDER.element(0x31, signedAttrs.content)
		} else {
			signedBytes = eContent
		}
		guard SecKeyVerifySignature(signerKey, algorithm, signedBytes as CFData, signature as CFData, nil) else {
			return .failure(.badSignature)
		}

		// Chain: must validate to an embedded cert whose fingerprint is pinned.
		switch validateChain(signerDER: signerDER, allCertDERs: certDERs, trustedRootSHA256: trustedRootSHA256, now: now) {
		case .success: return .success(eContent)
		case .failure(let f): return .failure(f)
		}
	}

	// MARK: chain

	private static func validateChain(signerDER: Data, allCertDERs: [Data], trustedRootSHA256: Set<String>, now: Date) -> Result<Void, Failure> {
		let certs = allCertDERs.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
		let anchors = certs.filter { trustedRootSHA256.contains(sha256Hex(SecCertificateCopyData($0) as Data)) }
		guard !anchors.isEmpty else { return .failure(.noTrustedAnchor) }
		// Leaf first, then the rest of the chain.
		guard let signerCert = SecCertificateCreateWithData(nil, signerDER as CFData) else { return .failure(.noSignerCertificate) }
		let ordered = [signerCert] + certs.filter { SecCertificateCopyData($0) as Data != signerDER }
		var trust: SecTrust?
		guard SecTrustCreateWithCertificates(ordered as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
			  let trust else { return .failure(.untrustedChain) }
		SecTrustSetAnchorCertificates(trust, anchors as CFArray)
		SecTrustSetAnchorCertificatesOnly(trust, true)                 // ONLY the pinned anchor is trusted
		SecTrustSetVerifyDate(trust, now as CFDate)                    // reproducible; enforces cert validity windows
		return SecTrustEvaluateWithError(trust, nil) ? .success(()) : .failure(.untrustedChain)
	}

	// MARK: helpers

	private static func rsaAlgorithm(for digestOID: String?) -> SecKeyAlgorithm? {
		switch digestOID {
		case oidSHA256: return .rsaSignatureMessagePKCS1v15SHA256
		case oidSHA1: return .rsaSignatureMessagePKCS1v15SHA1
		default: return nil
		}
	}

	private static func digest(_ data: Data, algorithm: String?) -> Data {
		switch algorithm {
		case oidSHA1: return Data(Insecure.SHA1.hash(data: data))
		default: return Data(SHA256.hash(data: data))
		}
	}

	private static func messageDigest(in signedAttrs: ZagDER.Node) -> Data? {
		// signedAttrs content is a sequence of Attribute ::= SEQUENCE { OID, SET OF value }
		for attr in (try? ZagDER.elements(signedAttrs.content)) ?? [] {
			guard let pair = try? attr.children(), pair.count == 2,
				  ZagDER.decodeObjectIdentifier(pair[0]) == oidMessageDigest,
				  let value = try? pair[1].children().first, value.tag == 0x04 else { continue }
			return value.content
		}
		return nil
	}

	/// Identifies the signer recorded in a detached code-signature CMS.
	static func embeddedSigner(_ cms: Data) -> Data? {
		if let signer = strictEmbeddedSigner(cms) { return signer }
		return normalizeSignerContainer(cms).flatMap(strictEmbeddedSigner)
	}

	private static func strictEmbeddedSigner(_ cms: Data) -> Data? {
		guard let parts = try? ZagDER.single(cms).children(), parts.count == 2,
			  ZagDER.decodeObjectIdentifier(parts[0]) == oidSignedData,
			  let signed = try? parts[1].children().first?.children(),
			  let certificates = try? signed.first(where: { $0.tag == 0xA0 })?.children(),
			  let signer = try? signed.last(where: { $0.tag == 0x31 })?.children().first?.children(),
			  signer.count >= 2 else { return nil }
		return signerCertificate(matching: signer[1], in: certificates.map(\.encoded))
	}

	/// Distribution signatures can use indefinite BER wrappers. Normalize
	/// structure only for signer lookup in code signatures. Profile signature
	/// verification continues to use the original bytes and strict DER.
	private static func normalizeSignerContainer(_ data: Data) -> Data? {
		guard data.count <= 2 * 1024 * 1024 else { return nil }
		let bytes = [UInt8](data)
		var cursor = 0
		var budget = 16_384

		func element(limit: Int, depth: Int) throws -> Data {
			guard depth < 32, budget > 0, cursor + 2 <= limit else { throw ZagDER.ParseError.truncated }
			budget -= 1
			let start = cursor
			let tag = bytes[cursor]
			let firstLength = Int(bytes[cursor + 1])
			cursor += 2
			guard tag != 0, tag & 0x1f != 0x1f else { throw ZagDER.ParseError.unsupportedLength }
			let constructed = tag & 0x20 != 0

			if firstLength == 0x80 {
				guard constructed else { throw ZagDER.ParseError.unsupportedLength }
				var body = Data()
				while cursor + 2 <= limit {
					if bytes[cursor] == 0, bytes[cursor + 1] == 0 {
						cursor += 2
						return ZagDER.element(tag, body)
					}
					body.append(try element(limit: limit, depth: depth + 1))
				}
				throw ZagDER.ParseError.truncated
			}
			var length = firstLength
			if firstLength > 0x80 {
				let count = firstLength & 0x7f
				guard count <= 4, cursor + count <= limit else { throw ZagDER.ParseError.unsupportedLength }
				length = bytes[cursor ..< cursor + count].reduce(0) { ($0 << 8) | Int($1) }
				cursor += count
			}
			guard length <= limit - cursor else { throw ZagDER.ParseError.truncated }
			let end = cursor + length
			if !constructed {
				cursor = end
				return Data(bytes[start ..< end])
			}
			let bodyStart = cursor
			var body = Data()
			while cursor < end { body.append(try element(limit: end, depth: depth + 1)) }
			// Preserve byte-for-byte DER certificates and issuer names.
			if body.elementsEqual(bytes[bodyStart ..< end]) { return Data(bytes[start ..< end]) }
			return ZagDER.element(tag, body)
		}

		guard let normalized = try? element(limit: bytes.count, depth: 0), cursor == bytes.count else { return nil }
		return normalized
	}

	/// Finds the embedded certificate whose issuer+serial match the SignerInfo
	/// `sid` (issuerAndSerialNumber ::= SEQUENCE { issuer Name, serial INTEGER }).
	private static func signerCertificate(matching sid: ZagDER.Node, in certDERs: [Data]) -> Data? {
		guard sid.tag == 0x30, let sidParts = try? sid.children(), sidParts.count == 2 else {
			// SubjectKeyIdentifier form (v3) not expected for Apple profiles; fail closed.
			return nil
		}
		let wantIssuer = sidParts[0].encoded
		let wantSerial = Data(sidParts[1].content.drop { $0 == 0 })
		for der in certDERs {
			guard let cert = try? ZagDER.single(der), cert.tag == 0x30,
				  let tbs = try? cert.children().first, var f = try? tbs.children() else { continue }
			if f.first?.tag == 0xA0 { f.removeFirst() }               // optional version [0]
			guard f.count >= 3, f[0].tag == 0x02 else { continue }
			let serial = Data(f[0].content.drop { $0 == 0 })
			let issuer = f[2].encoded                                 // issuer is field index 2 (serial, sigAlg, issuer)
			if serial == wantSerial && issuer == wantIssuer { return der }
		}
		return nil
	}

	static func sha256Hex(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}
