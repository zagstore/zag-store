import Foundation

// iOS-safe handling of a `.mobileprovision`. A profile is a CMS (PKCS#7) blob
// whose signed CONTENT is a cleartext XML plist. Two trust levels are kept
// strictly separate:
//
//  * UNVERIFIED extraction — scans the bytes for the embedded plist WITHOUT
//    checking the CMS signature. Suitable ONLY for preview/display of a file the
//    user chose; the bytes are untrusted and could carry a forged plist.
//  * VERIFIED parsing — requires a CMS verifier that confirms the blob is signed
//    by Apple and returns the authentic signed content. iOS has no public
//    high-level CMS-verify API (CMSDecoder is macOS-only), so on iOS this path is
//    NOT yet implemented and callers MUST fail closed for real signing (see
//    `ZagImportedIdentityProfileMatch.evaluate(..., cmsVerified:)`).

/// A single entitlement value, modelled so values (not just keys) can be
/// compared with wildcard rules. `other` is any unsupported/complex value and
/// is always treated as a mismatch (fail closed).
indirect enum ZagEntitlementValue: Equatable, Sendable {
	case bool(Bool)
	case string(String)
	case array([ZagEntitlementValue])
	case other

	init(_ any: Any) {
		switch any {
		case let b as Bool: self = .bool(b)
		case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
		case let s as String: self = .string(s)
		case let a as [Any]: self = .array(a.map(ZagEntitlementValue.init))
		default: self = .other
		}
	}
}

/// The provisioning-profile fields compatibility checks read.
struct ZagProfileContents: Sendable, Equatable {
	let teamIdentifier: String
	/// The DER bytes of each certificate in `DeveloperCertificates`.
	let developerCertificates: [Data]
	let provisionedDevices: [String]
	let expiresAt: Date
	/// The `application-identifier` entitlement, e.g. "TEAMID.com.example.app" or "TEAMID.*".
	let applicationIdentifier: String
	/// The entitlements the profile GRANTS, modelled for value comparison.
	let entitlements: [String: ZagEntitlementValue]
}

enum ZagMobileProvision {
	/// UNVERIFIED: scans the bytes for the embedded plist without checking the
	/// CMS signature. Preview/display only — never a basis for real signing.
	static func extractUnverifiedPlist(from data: Data) -> [String: Any]? {
		guard let start = data.range(of: Data("<?xml".utf8)),
			  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
			return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
		}
		return (try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)) as? [String: Any]
	}

	/// Parses profile contents from an UNVERIFIED plist (preview/display). The
	/// caller is responsible for CMS trust before using the result to sign.
	static func parseUnverified(_ data: Data) -> ZagProfileContents? {
		extractUnverifiedPlist(from: data).flatMap(contents(from:))
	}

	/// Parses profile contents only if `verifier` cryptographically authenticates
	/// the CMS signature over the blob and hands back the AUTHENTIC signed content.
	/// Fails closed (nil) when verification fails. The authenticated payload — not
	/// the raw file bytes — is what gets parsed.
	static func parseVerified(_ data: Data, verifier: (Data) -> Data?) -> ZagProfileContents? {
		guard let verifiedContent = verifier(data),
			  let plist = (try? PropertyListSerialization.propertyList(from: verifiedContent, format: nil)) as? [String: Any] else { return nil }
		return contents(from: plist)
	}

	/// The production path: parse ONLY the content the on-device `ZagCMSVerifier`
	/// authenticates against the pinned Apple Root CA. Returns nil if the CMS
	/// signature or chain does not verify — real signing then has no profile.
	static func parseAppleVerified(_ data: Data, now: Date = Date()) -> ZagProfileContents? {
		parseVerified(data) { cms in (try? ZagCMSVerifier.verify(cms, now: now).get()) }
	}

	/// True now that an on-device CMS verifier (`ZagCMSVerifier`) is wired.
	static var cmsVerificationAvailable: Bool { true }

	static func contents(from plist: [String: Any]) -> ZagProfileContents? {
		guard let team = (plist["TeamIdentifier"] as? [String])?.first,
			  let expires = plist["ExpirationDate"] as? Date,
			  let entitlements = plist["Entitlements"] as? [String: Any],
			  let appID = entitlements["application-identifier"] as? String else { return nil }
		let certs = (plist["DeveloperCertificates"] as? [Data]) ?? []
		let devices = (plist["ProvisionedDevices"] as? [String]) ?? []
		return ZagProfileContents(
			teamIdentifier: team,
			developerCertificates: certs,
			provisionedDevices: devices,
			expiresAt: expires,
			applicationIdentifier: appID,
			entitlements: entitlements.mapValues(ZagEntitlementValue.init))
	}
}
