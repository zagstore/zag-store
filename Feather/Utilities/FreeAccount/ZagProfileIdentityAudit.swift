import Foundation

// Compares a local Xcode-provisioned profile against the discovered developer
// team and this device, for the OFFLINE reuse decision (which existing resources
// can be reused before any mutation). The result is sanitized by construction:
// it carries only booleans and coarse counts — never a UDID, team id, bundle id,
// certificate serial or date — so it is safe to log and report.

struct ZagProfileIdentityAudit: Equatable, Sendable {
	/// The profile's team equals the team discovered via listTeams.
	let teamMatchesDiscovered: Bool
	/// This device's provisioning UDID is already listed in the profile.
	let deviceInProfile: Bool
	/// The profile is for the target bundle identifier (true when no target given).
	let bundleMatchesTarget: Bool
	/// Developer certificates embedded in the profile.
	let certificateCount: Int
	/// Devices provisioned in the profile.
	let deviceCount: Int
	/// The profile is past its expiration (7-day free-account profiles are short).
	let profileExpired: Bool
	/// Whole days until the profile expires (negative if already expired).
	let profileExpiresInDays: Int

	/// Pure audit from already-extracted profile primitives. Comparisons are
	/// case-insensitive (Apple identifiers are case-stable but mixed-case in
	/// places); the output exposes no identifier, only verdicts.
	static func audit(profileTeam: String,
					  profileDevices: [String],
					  profileCertificateSerials: [String],
					  profileBundle: String,
					  profileExpiresAt: Date,
					  discoveredTeam: String,
					  expectedDeviceUDID: String?,
					  targetBundle: String?,
					  now: Date = Date()) -> ZagProfileIdentityAudit {
		let teamMatch = profileTeam.caseInsensitiveCompare(discoveredTeam) == .orderedSame
		let deviceIn = expectedDeviceUDID.map { want in
			profileDevices.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
		} ?? false
		let bundleMatch = targetBundle.map { profileBundle.caseInsensitiveCompare($0) == .orderedSame } ?? true
		let seconds = profileExpiresAt.timeIntervalSince(now)
		return ZagProfileIdentityAudit(
			teamMatchesDiscovered: teamMatch,
			deviceInProfile: deviceIn,
			bundleMatchesTarget: bundleMatch,
			certificateCount: profileCertificateSerials.count,
			deviceCount: profileDevices.count,
			profileExpired: seconds <= 0,
			profileExpiresInDays: Int((seconds / 86_400).rounded(.towardZero)))
	}

	/// A sanitized dictionary for diagnostics (no identifiers).
	var sanitized: [String: Any] {
		["team_matches_discovered": teamMatchesDiscovered,
		 "device_in_profile": deviceInProfile,
		 "bundle_matches_target": bundleMatchesTarget,
		 "certificate_count": certificateCount,
		 "device_count": deviceCount,
		 "profile_expired": profileExpired,
		 "profile_expires_in_days": profileExpiresInDays]
	}
}
