import Foundation

/// The entitlements an app is signed with under a free (or any development)
/// profile. Every value comes from the app's request, rewritten for the team
/// and mapped bundle ID, and is kept only when the profile allows it. Nothing
/// is granted that the profile does not contain, and every entitlement left
/// out is reported so the user can be told which features will not work.
enum ZagFreeAccountEntitlements {
	struct Rejection: Equatable, Sendable {
		enum Reason: String, Sendable {
			/// The profile has no such entitlement (for example a capability free
			/// accounts cannot use).
			case notInProfile
			/// The profile has the entitlement but not this value.
			case valueNotAllowed
		}

		let key: String
		let reason: Reason
	}

	struct Result {
		let entitlements: [String: Any]
		let rejected: [Rejection]
	}

	static let applicationIdentifierKey = "application-identifier"
	static let teamIdentifierKey = "com.apple.developer.team-identifier"
	static let keychainGroupsKey = "keychain-access-groups"
	static let appGroupsKey = "com.apple.security.application-groups"
	static let getTaskAllowKey = "get-task-allow"

	/// - Parameters:
	///   - requested: the entitlements in the app's original signature.
	///   - profile: the `Entitlements` dictionary of the profile Apple issued.
	///   - team: the signing team ID.
	///   - bundleIdentifier: the mapped bundle ID the profile was issued for.
	static func resolve(
		requested: [String: Any],
		profile: [String: Any],
		team: String,
		bundleIdentifier: String
	) -> Result {
		var granted: [String: Any] = [:]
		var rejected: [Rejection] = []

		func grant(_ key: String, _ value: Any) {
			guard let allowed = profile[key] else {
				rejected.append(Rejection(key: key, reason: .notInProfile))
				return
			}
			if ZagEntitlementCompatibility.matches(value, allowed) {
				granted[key] = value
			} else {
				rejected.append(Rejection(key: key, reason: .valueNotAllowed))
			}
		}

		// Identity: always the team's, never the original developer's.
		grant(applicationIdentifierKey, "\(team).\(bundleIdentifier)")
		if profile[teamIdentifierKey] != nil { grant(teamIdentifierKey, team) }
		if let allowed = profile[getTaskAllowKey] { granted[getTaskAllowKey] = allowed }

		for key in requested.keys.sorted() {
			guard let value = requested[key] else { continue }
			switch key {
			case applicationIdentifierKey, teamIdentifierKey, getTaskAllowKey:
				continue
			case keychainGroupsKey:
				// "OLDTEAM.com.example.shared" → "TEAM.com.example.shared". Groups
				// the profile does not cover are dropped one by one.
				let groups = (value as? [String] ?? []).map { retargetKeychainGroup($0, team: team) }
				let allowed = profile[key]
				let kept = groups.filter { group in allowed.map { ZagEntitlementCompatibility.matches([group], $0) } ?? false }
				if kept.count < groups.count {
					rejected.append(Rejection(key: key, reason: allowed == nil ? .notInProfile : .valueNotAllowed))
				}
				if !kept.isEmpty { granted[key] = kept }
			case appGroupsKey:
				// App groups are registered per team, so each is mapped like a bundle ID.
				let groups = (value as? [String] ?? []).compactMap {
					ZagBundleIdentifierMapping.mappedAppGroup($0, team: team)
				}
				grant(key, groups)
			default:
				grant(key, value)
			}
		}

		// An app without its own keychain groups still gets its default group.
		if granted[keychainGroupsKey] == nil, requested[keychainGroupsKey] == nil,
		   let allowed = profile[keychainGroupsKey] {
			let own = "\(team).\(bundleIdentifier)"
			if ZagEntitlementCompatibility.matches([own], allowed) { granted[keychainGroupsKey] = [own] }
		}
		return Result(entitlements: granted, rejected: rejected)
	}

	/// Replaces a leading ten-character team prefix; other groups are prefixed.
	static func retargetKeychainGroup(_ group: String, team: String) -> String {
		let parts = group.split(separator: ".", maxSplits: 1)
		if parts.count == 2, ZagDeveloperTeam.isValidIdentifier(String(parts[0])) {
			return "\(team).\(parts[1])"
		}
		return "\(team).\(group)"
	}
}
