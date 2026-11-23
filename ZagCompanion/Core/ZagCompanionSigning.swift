#if ZAG_ZSIGN_STRICT
import Foundation
import Security
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// Signs an unpacked .app through Zag Store's existing engine
// (ZagFreeAccountSigningAdapter.signComponents) using an Xcode-issued
// free-account identity located by ZagExternalKeychainSigningKey. The private
// key stays in the Keychain; the signer only ever receives DigestInfo blocks.
// This is a front end on the engine, not a second signer.

public struct ZagCompanionSigningOutcome: Sendable {
	public let certificateSerial: String
	public let teamIdentifier: String
	public let bundleIdentifier: String
	public let profileExpiresAt: Date
	public let signatureCount: Int
}

public struct ZagCompanionSigner {
	public init() {}

	/// Signs `app` in place with the identity the profile authorises, then
	/// verifies the result with both codesign and Zsign. Throws on any mismatch.
	public func sign(app: URL, profileData: Data, workRoot: URL, now: Date = Date()) throws -> ZagCompanionSigningOutcome {
		let external: ZagExternalKeychainSigningKey
		do { external = try ZagExternalKeychainSigningKey(profileData: profileData, now: now) }
		catch { throw ZagCompanionError.signingFailed("identity/profile: \(error)") }

		var signatureCount = 0
		let countingSigner: (Data) -> Data? = { digest in signatureCount += 1; return external.signer(digest) }
		let adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), workRoot: workRoot, gate: .companion)
		do {
			_ = try adapter.signComponents(
				appAt: app, with: external.provisioningResult(), identity: external.identity,
				signer: countingSigner, authorization: external.authorization(), now: now,
				extraIntermediates: Self.appleIntermediates())
		} catch { throw ZagCompanionError.signingFailed("\(error)") }

		try verify(app: app, external: external)
		return ZagCompanionSigningOutcome(
			certificateSerial: external.identity.serialNumber, teamIdentifier: external.team,
			bundleIdentifier: external.bundleIdentifier, profileExpiresAt: external.expiresAt,
			signatureCount: signatureCount)
	}

	/// codesign --verify --strict + Zsign's own component verification + an
	/// embedded-profile identity check.
	private func verify(app: URL, external: ZagExternalKeychainSigningKey) throws {
		let codesign = ZagProcess.run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=4", app.path])
		guard codesign.succeeded else { throw ZagCompanionError.verificationFailed("codesign: \(codesign.combined)") }

		let inspect = ZagProcess.run("/usr/bin/codesign", ["-dvvv", app.path]).combined
		guard inspect.contains("Identifier=\(external.bundleIdentifier)"),
			  inspect.contains("TeamIdentifier=\(external.team)"),
			  inspect.contains("Authority=Apple Development") else {
			throw ZagCompanionError.verificationFailed("unexpected signature identity")
		}
		let embedded = try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
		guard embedded == external.provisioningResult().app.profile.data else {
			throw ZagCompanionError.verificationFailed("embedded profile differs from the one authorised")
		}
		#if canImport(ZsignSwift) || ZAG_ZSIGN_TESTS
		let components: [String: (provision: Data, entitlements: Data)] = [
			"": (external.provisioningResult().app.profile.data,
				 (try? PropertyListSerialization.data(fromPropertyList: external.provisioningResult().app.entitlements.dictionary, format: .xml, options: 0)) ?? Data())
		]
		if Zsign.verifyComponents(appPath: app.path, certificate: external.identity.certificate, components: components) != nil {
			throw ZagCompanionError.verificationFailed("Zsign could not verify the signed component")
		}
		#endif
	}

	/// Apple WWDR / Root intermediates from the Keychain, so the signed app
	/// carries a complete chain for the device to validate.
	static func appleIntermediates() -> [Data] {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassCertificate,
			kSecReturnRef: true,
			kSecMatchLimit: kSecMatchLimitAll,
		] as CFDictionary, &result)
		guard status == errSecSuccess, let certs = result as? [SecCertificate] else { return [] }
		var out: [Data] = []
		for cert in certs {
			let cn = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""
			if cn.contains("Worldwide Developer Relations") || cn == "Apple Root CA" {
				out.append(SecCertificateCopyData(cert) as Data)
			}
		}
		return out
	}
}
#endif
