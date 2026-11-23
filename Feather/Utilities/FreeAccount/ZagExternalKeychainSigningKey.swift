#if ZAG_ZSIGN_STRICT
import Foundation
import Security

// Reuses a development signing identity that already exists in the login
// Keychain — one Xcode issued for a free Apple Account "Personal Team" — to
// drive the existing strict signing engine (ZagStrictComponentSigning) without
// ever exporting the private key. The key stays a Keychain key reference and
// every signature is made through ZagKeychainSigningKeys.signer, the same
// raw-signer callback the first-party free-account key uses, so this is one
// more front end on the existing engine, not a second signer.
//
// The identity is accepted only when the paired .mobileprovision agrees with
// it on the certificate, team, bundle ID, device and clock; any mismatch is a
// refusal (fail closed). A profile authorises exactly the one bundle ID in its
// App ID and only its registered devices — never an arbitrary bundle ID.
//
// Experimental: compiled only under ZAG_ZSIGN_STRICT (tests and the supervised
// experiment build, never the Xcode project's configurations), so production
// signing (AppTesters ZsignHandler, BYOC) is untouched.
struct ZagExternalKeychainSigningKey {
	enum Failure: Error, Equatable, CustomStringConvertible {
		case profileUnreadable
		case profileExpired(expiresAt: Date, now: Date)
		case profileHasNoCertificates
		case profileHasNoTeam
		case wildcardBundleIDNotAllowed(String)
		case profileHasNoDevices
		case identityNotFound(serials: [String])
		case keyUnusable
		case keyDoesNotMatchCertificate

		var description: String {
			switch self {
			case .profileUnreadable: return "the .mobileprovision could not be parsed"
			case let .profileExpired(expiresAt, now): return "the profile expired at \(expiresAt) (now \(now))"
			case .profileHasNoCertificates: return "the profile lists no developer certificates"
			case .profileHasNoTeam: return "the profile names no team"
			case let .wildcardBundleIDNotAllowed(id): return "a wildcard profile (\(id)) cannot sign a concrete bundle ID"
			case .profileHasNoDevices: return "the profile registers no devices (not a free development profile)"
			case let .identityNotFound(serials): return "no Keychain identity has a certificate serial the profile lists (\(serials.joined(separator: ", ")))"
			case .keyUnusable: return "the matched identity's private key is not usable for signing"
			case .keyDoesNotMatchCertificate: return "the located key does not match the certificate"
			}
		}
	}

	/// The profile parsed from the .mobileprovision.
	let profile: ZagIssuedProfile
	/// The identity for the engine: the certificate with an empty private key,
	/// so `keyIsInKeychain` is true and the engine signs through the reference.
	let identity: ZagSigningIdentity
	/// The raw signer Zsign calls, bound to the Keychain key reference. It only
	/// ever receives a DigestInfo and never carries key bytes.
	let signer: (Data) -> Data?

	/// The team the certificate and profile both belong to.
	var team: String { profile.teamIdentifier }
	/// The one bundle ID this profile authorises.
	var bundleIdentifier: String { profile.bundleIdentifier }
	/// The devices this development profile may run on.
	var eligibleDeviceUDIDs: [String] { profile.deviceUDIDs }
	/// When the installed app stops launching.
	var expiresAt: Date { profile.expiresAt }

	/// Locates the identity the profile authorises and validates the pairing.
	/// `now` decides expiry. Reads Keychain references only; exports nothing.
	init(profileData: Data, now: Date = Date()) throws {
		guard let profile = try? ZagIssuedProfile(profileData: profileData) else {
			throw Failure.profileUnreadable
		}
		guard profile.expiresAt > now else { throw Failure.profileExpired(expiresAt: profile.expiresAt, now: now) }
		guard !profile.certificateSerials.isEmpty else { throw Failure.profileHasNoCertificates }
		guard !profile.teamIdentifier.isEmpty else { throw Failure.profileHasNoTeam }
		guard !profile.bundleIdentifier.hasSuffix("*"), profile.bundleIdentifier != "*" else {
			throw Failure.wildcardBundleIDNotAllowed(profile.bundleIdentifier)
		}
		// A free development profile is bound to registered devices; an absent
		// device list would be an "all devices" distribution profile, which a
		// free team cannot issue. Its absence is a refusal.
		guard !profile.deviceUDIDs.isEmpty else { throw Failure.profileHasNoDevices }

		let wanted = Set(profile.certificateSerials)
		guard let (secIdentity, certificate, inspection) = Self.keychainIdentity(serialIn: wanted) else {
			throw Failure.identityNotFound(serials: profile.certificateSerials)
		}
		var keyRef: SecKey?
		guard SecIdentityCopyPrivateKey(secIdentity, &keyRef) == errSecSuccess, let key = keyRef else {
			throw Failure.keyUnusable
		}
		// The identity pairs the key and certificate by construction; confirm
		// the key can produce a signature the certificate verifies, so a broken
		// or access-controlled key is caught before anything is signed.
		guard Self.keyMatchesCertificate(key: key, certificate: certificate) else {
			throw Failure.keyDoesNotMatchCertificate
		}

		self.profile = profile
		self.identity = ZagSigningIdentity(
			serialNumber: inspection.serialNumber,
			certificate: SecCertificateCopyData(certificate) as Data,
			privateKey: Data(),            // empty: the key is a Keychain reference, never exported
			expiresAt: inspection.expiresAt,
			keySlot: nil
		)
		self.signer = ZagKeychainSigningKeys.signer(key)
	}

	/// The engine's provisioning result for this app: the team, the certificate
	/// serial the engine checks against the identity, and the single app
	/// component with its own profile and entitlements. No extensions — a
	/// Personal Team profile covers one App ID, and each extension would need
	/// its own.
	func provisioningResult() -> ZagProvisioningResult {
		ZagProvisioningResult(
			team: profile.teamIdentifier,
			certificateSerial: identity.serialNumber,
			app: ZagProvisioningResult.Component(
				originalBundleIdentifier: profile.bundleIdentifier,
				bundleIdentifier: profile.bundleIdentifier,
				profile: profile,
				entitlements: profile.entitlements,
				rejected: []
			),
			extensions: [],
			changes: ZagProvisioningResult.Changes()
		)
	}

	/// An authorisation for the engine's gate check. This identity's proof is
	/// its presence in the Keychain with a matching profile, not a GrandSlam
	/// session, so it is modelled as a developer-account authorisation (the
	/// shape the paid ASC method uses). `validUntil` is the profile's expiry,
	/// so an expired profile is refused by the authorisation too.
	func authorization(accountID: UUID = UUID()) -> ZagSigningAuthorization {
		.developerAccount(
			scope: ZagSigningScope(accountID: accountID, teamID: profile.teamIdentifier),
			teamKind: .personalFree,
			validUntil: profile.expiresAt
		)
	}

	/// Whether this profile may install on a device.
	func isEligible(deviceUDID: String) -> Bool { profile.deviceUDIDs.contains(deviceUDID) }

	// MARK: - Keychain

	/// The first Keychain identity whose certificate serial the profile lists.
	/// Returns references only; no key material leaves the Keychain.
	private static func keychainIdentity(serialIn wanted: Set<String>) -> (SecIdentity, SecCertificate, ZagCertificateInspection)? {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassIdentity,
			kSecReturnRef: true,
			kSecMatchLimit: kSecMatchLimitAll,
		] as CFDictionary, &result)
		guard status == errSecSuccess, let identities = result as? [SecIdentity] else { return nil }
		for secIdentity in identities {
			var certRef: SecCertificate?
			guard SecIdentityCopyCertificate(secIdentity, &certRef) == errSecSuccess, let certificate = certRef else { continue }
			let der = SecCertificateCopyData(certificate) as Data
			guard let inspection = ZagCertificateInspection(der: der), wanted.contains(inspection.serialNumber) else { continue }
			return (secIdentity, certificate, inspection)
		}
		return nil
	}

	/// Signs a random challenge with the key and verifies it with the
	/// certificate's public key — the same pairing check the first-party key
	/// factory makes.
	private static func keyMatchesCertificate(key: SecKey, certificate: SecCertificate) -> Bool {
		guard let publicKey = SecCertificateCopyKey(certificate) else { return false }
		var challenge = Data(count: 32)
		guard challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
			  let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, nil) else {
			return false
		}
		return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, signature, nil)
	}
}
#endif
