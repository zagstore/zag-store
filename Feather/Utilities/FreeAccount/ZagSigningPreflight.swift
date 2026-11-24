import Foundation

// The single real-signing preflight. It is the ONLY path the signing flow uses
// to decide a provisioning profile is usable, and it derives CMS trust solely
// from on-device cryptographic verification (`ZagCMSVerifier` against the pinned
// Apple Root CA). There is deliberately no parameter by which a caller can
// assert `cmsVerified = true`: the flag passed to the compatibility check is set
// here, and only after `parseAppleVerified` returns authenticated content.

enum ZagSigningPreflightResult: Equatable, Sendable {
	/// The profile verified and matches the identity/device/bundle/entitlements.
	case ready(ZagProfileContents)
	/// The CMS signature/chain did not verify against the pinned Apple Root CA.
	case profileNotTrusted
	/// Parsed, verified, but incompatible with the identity/device/bundle.
	case incompatible(ZagProfileMatchResult)
}

enum ZagSigningPreflight {
	/// Verifies the raw `.mobileprovision` bytes cryptographically, then checks
	/// full compatibility with the imported identity. `profileData` is the exact
	/// file the user provided — it is NOT trusted until the CMS verifier
	/// authenticates it.
	static func prepare(
		profileData: Data,
		identityCertificateDER: Data,
		identityTeam: String?,
		identityIsDevelopment: Bool,
		deviceProvisioningUDID: String,
		targetBundleID: String,
		requestedEntitlements: [String: ZagEntitlementValue],
		trustedRootSHA256: Set<String> = [ZagCMSVerifier.appleRootCASHA256],
		now: Date = Date()
	) -> ZagSigningPreflightResult {
		// Trust comes ONLY from cryptographic verification of the CMS blob.
		guard case .success(let authenticatedPayload) = ZagCMSVerifier.verify(profileData, trustedRootSHA256: trustedRootSHA256, now: now),
			  let plist = (try? PropertyListSerialization.propertyList(from: authenticatedPayload, format: nil)) as? [String: Any],
			  let profile = ZagMobileProvision.contents(from: plist) else {
			return .profileNotTrusted
		}
		let result = ZagImportedIdentityProfileMatch.evaluate(
			identityCertificateDER: identityCertificateDER,
			identityTeam: identityTeam,
			identityIsDevelopment: identityIsDevelopment,
			profile: profile,
			deviceProvisioningUDID: deviceProvisioningUDID,
			targetBundleID: targetBundleID,
			requestedEntitlements: requestedEntitlements,
			cmsVerified: true,            // set here, ONLY because ZagCMSVerifier succeeded above
			now: now)
		return result == .compatible ? .ready(profile) : .incompatible(result)
	}
}
