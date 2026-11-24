import Foundation

// iOS-safe parsing of a `.mobileprovision` and the authoritative compatibility
// check between an imported signing identity, that profile, the target device
// and the target bundle. A `.mobileprovision` is a CMS (PKCS#7) blob whose
// signed CONTENT is a cleartext XML plist; we extract the plist by scanning for
// it (the same approach the repo's signing tool uses), so no macOS-only
// CMSDecoder is needed. Pure — no I/O, no key — so it is host-testable.

/// The provisioning-profile fields compatibility checks read.
struct ZagProfileContents: Sendable {
	let teamIdentifier: String
	/// The DER bytes of each certificate in `DeveloperCertificates`.
	let developerCertificates: [Data]
	let provisionedDevices: [String]
	let expiresAt: Date
	/// The `application-identifier` entitlement, e.g. "TEAMID.com.example.app" or "TEAMID.*".
	let applicationIdentifier: String
	/// The entitlement KEYS the profile grants (values not needed for the subset check).
	let entitlementKeys: Set<String>
}

enum ZagMobileProvision {
	/// Extracts the embedded plist dictionary from a `.mobileprovision` CMS blob.
	static func plist(from data: Data) -> [String: Any]? {
		guard let start = data.range(of: Data("<?xml".utf8)),
			  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
			// A bare plist (no CMS wrapper) is accepted too (test fixtures / already-extracted).
			return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
		}
		return (try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)) as? [String: Any]
	}

	/// Parses the profile into the fields the compatibility check needs. Returns
	/// nil (fail closed) if any required field is missing or malformed.
	static func parse(_ data: Data) -> ZagProfileContents? {
		guard let plist = plist(from: data),
			  let team = (plist["TeamIdentifier"] as? [String])?.first,
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
			entitlementKeys: Set(entitlements.keys))
	}
}
