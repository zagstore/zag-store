import Foundation
import CryptoKit

// The authoritative compatibility check between an imported signing identity and
// a provisioning profile, for a target device and bundle. Fails CLOSED: any
// mismatch, missing field or unsupported entitlement is a refusal. Pure and
// host-testable. The device UDID compared here is Apple's PROVISIONING UDID
// (as embedded in the profile's ProvisionedDevices), never a CoreDevice id.

enum ZagProfileMatchResult: Equatable, Sendable {
	case compatible
	/// The imported certificate is not among the profile's DeveloperCertificates.
	case certificateNotInProfile
	case teamMismatch
	/// The device's provisioning UDID is not in ProvisionedDevices.
	case deviceNotProvisioned
	case profileExpired
	/// The target bundle id is not covered by the profile's application-identifier.
	case bundleMismatch
	/// Requested entitlements the profile does not grant.
	case disallowedEntitlements([String])
	/// The certificate is not an Apple development signing certificate.
	case notDevelopmentCertificate

	var isCompatible: Bool { self == .compatible }
}

enum ZagImportedIdentityProfileMatch {
	/// Evaluates full compatibility. `identityCertificateDER` is the imported
	/// identity's certificate; `deviceProvisioningUDID` is the authoritative
	/// provisioning UDID (NOT a CoreDevice id); `requestedEntitlements` are the
	/// entitlement keys the signing step intends to apply.
	static func evaluate(
		identityCertificateDER: Data,
		identityTeam: String?,
		identityIsDevelopment: Bool,
		profile: ZagProfileContents,
		deviceProvisioningUDID: String,
		targetBundleID: String,
		requestedEntitlements: [String],
		now: Date
	) -> ZagProfileMatchResult {
		// 7. development-signing suitability first.
		guard identityIsDevelopment else { return .notDevelopmentCertificate }
		// 1. the imported certificate must be in DeveloperCertificates — compare
		//    the actual DER (SHA-256), not the serial number.
		let fingerprint = sha256(identityCertificateDER)
		guard profile.developerCertificates.contains(where: { sha256($0) == fingerprint }) else {
			return .certificateNotInProfile
		}
		// 2. team.
		guard let team = identityTeam, team == profile.teamIdentifier else { return .teamMismatch }
		// 3. device provisioning UDID (case-insensitive).
		guard profile.provisionedDevices.contains(where: { $0.caseInsensitiveCompare(deviceProvisioningUDID) == .orderedSame }) else {
			return .deviceNotProvisioned
		}
		// 4. expiry.
		guard profile.expiresAt > now else { return .profileExpired }
		// 5. bundle id, respecting wildcard semantics.
		guard bundleMatches(target: targetBundleID, applicationIdentifier: profile.applicationIdentifier, team: profile.teamIdentifier) else {
			return .bundleMismatch
		}
		// 6. requested entitlements must all be granted by the profile.
		let disallowed = requestedEntitlements.filter { !profile.entitlementKeys.contains($0) }
		guard disallowed.isEmpty else { return .disallowedEntitlements(disallowed.sorted()) }
		return .compatible
	}

	/// `application-identifier` is "TEAM.<bundle-pattern>". A bare "*" matches
	/// anything; a trailing ".*" is a prefix wildcard; otherwise an exact match.
	static func bundleMatches(target: String, applicationIdentifier: String, team: String) -> Bool {
		let prefix = team + "."
		guard applicationIdentifier.hasPrefix(prefix) else { return false }
		let pattern = String(applicationIdentifier.dropFirst(prefix.count))
		if pattern == "*" { return !target.isEmpty }
		if pattern.hasSuffix(".*") {
			let base = String(pattern.dropLast(2))               // "com.foo.*" -> "com.foo"
			return target == base || target.hasPrefix(base + ".")
		}
		return target == pattern
	}

	static func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

/// An explicit choice of signing identity. There is NO silent fallback between
/// the two: the caller selects one, and resolution fails if it is unavailable.
enum ZagSigningSource: Equatable, Sendable {
	/// The device-generated, non-extractable key (`ZagKeychainSigningKeys`).
	case deviceGenerated(keySlot: String?)
	/// A user-imported identity (`ZagImportedSigningIdentity`), by its label.
	case imported(label: String)

	var isImported: Bool { if case .imported = self { return true }; return false }
	var usesNonExtractableKey: Bool { if case .deviceGenerated = self { return true }; return false }
}
