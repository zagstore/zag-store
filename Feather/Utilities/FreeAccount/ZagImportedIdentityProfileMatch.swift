import Foundation
import CryptoKit

// The authoritative compatibility check between an imported signing identity and
// a provisioning profile, for a target device and bundle. Fails CLOSED: any
// mismatch, missing field or unsupported entitlement is a refusal. Pure and
// host-testable. The device UDID compared here is Apple's PROVISIONING UDID
// (as embedded in the profile's ProvisionedDevices), never a CoreDevice id.

enum ZagProfileMatchResult: Equatable, Sendable {
	case compatible
	/// The profile's CMS signature was not verified — refused for real signing.
	case profileNotCMSVerified
	/// The imported certificate is not among the profile's DeveloperCertificates.
	case certificateNotInProfile
	case teamMismatch
	/// The device's provisioning UDID is not in ProvisionedDevices.
	case deviceNotProvisioned
	case profileExpired
	/// The target bundle id is not covered by the profile's application-identifier.
	case bundleMismatch
	/// Requested entitlements the profile does not grant (value/structure compared).
	case disallowedEntitlements([String])
	/// The certificate is not an Apple development signing certificate.
	case notDevelopmentCertificate

	var isCompatible: Bool { self == .compatible }
}

/// Compares requested signing entitlements against what the profile grants —
/// by VALUE and structure, not merely by key. Fails closed: a missing key, a
/// value mismatch, or any unsupported/complex value is a rejection.
enum ZagEntitlementAudit {
	/// The requested entitlement keys that the profile does not grant compatibly.
	static func disallowed(requested: [String: ZagEntitlementValue], granted: [String: ZagEntitlementValue]) -> [String] {
		requested.compactMap { key, want in
			guard let have = granted[key] else { return key }          // not granted at all
			return grants(have, want, key: key) ? nil : key
		}.sorted()
	}

	/// Whether a granted value permits a requested value.
	static func grants(_ granted: ZagEntitlementValue, _ requested: ZagEntitlementValue, key: String) -> Bool {
		switch (granted, requested) {
		case let (.bool(g), .bool(r)):
			return g == r                                              // exact (can't request true when granted false)
		case let (.string(g), .string(r)):
			return stringGrants(granted: g, requested: r)
		case let (.array(g), .array(r)):
			// every requested element must be covered by some granted element
			return r.allSatisfy { want in g.contains { grants($0, want, key: key) } }
		default:
			return false                                              // type mismatch or unsupported -> fail closed
		}
	}

	/// A trailing `*` in a granted string is a prefix wildcard (e.g. keychain
	/// group "TEAM.*" grants "TEAM.foo"); a bare "*" grants anything; otherwise
	/// an exact match is required.
	static func stringGrants(granted: String, requested: String) -> Bool {
		if granted == "*" { return !requested.isEmpty }
		if granted.hasSuffix("*") { return requested.hasPrefix(String(granted.dropLast())) }
		return granted == requested
	}
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
		requestedEntitlements: [String: ZagEntitlementValue],
		cmsVerified: Bool,
		now: Date
	) -> ZagProfileMatchResult {
		// 0. the profile's CMS signature must have been verified — fail closed
		//    for real signing (the parsed plist is otherwise untrusted bytes).
		guard cmsVerified else { return .profileNotCMSVerified }
		// 7. development-signing suitability.
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
		// 6. requested entitlements must all be granted by the profile — compared
		//    by value and structure (wildcards, arrays, booleans), not just keys.
		let disallowed = ZagEntitlementAudit.disallowed(requested: requestedEntitlements, granted: profile.entitlements)
		guard disallowed.isEmpty else { return .disallowedEntitlements(disallowed) }
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
