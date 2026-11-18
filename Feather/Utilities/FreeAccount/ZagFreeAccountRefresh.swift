import Foundation

/// How soon a signed app needs refreshing, from the real expiry of its
/// profile and certificate (whichever is first). Profiles are not assumed to
/// last 7 days.
enum ZagRefreshUrgency: Int, Comparable, Codable, Sendable {
	case normal
	/// A refresh is allowed but not needed yet.
	case eligible
	case recommended
	case urgent
	case expired

	static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Thresholds as time left before expiry. For a 7-day profile the defaults
/// give days 1-3 normal, day 4 eligible, day 5 recommended, days 6-7 urgent.
/// A profile with a shorter life has its thresholds scaled down with it, so
/// it is not urgent from the moment it is signed.
struct ZagRefreshThresholds: Equatable, Sendable {
	var eligible: TimeInterval = 4 * 86_400
	var recommended: TimeInterval = 3 * 86_400
	var urgent: TimeInterval = 2 * 86_400
	/// The life the thresholds were written for.
	var referenceLifetime: TimeInterval = 7 * 86_400

	static let standard = ZagRefreshThresholds()

	func scaled(toLifetime lifetime: TimeInterval) -> ZagRefreshThresholds {
		guard lifetime > 0, lifetime < referenceLifetime else { return self }
		let factor = lifetime / referenceLifetime
		return ZagRefreshThresholds(
			eligible: eligible * factor,
			recommended: recommended * factor,
			urgent: urgent * factor,
			referenceLifetime: lifetime
		)
	}
}

/// What Zag Store knows about one app it signed with a free account. Stored
/// as JSON in Application Support; it contains no secrets.
struct ZagSignedAppRecord: Codable, Equatable, Sendable {
	struct Failure: Codable, Equatable, Sendable {
		let at: Date
		let reason: ZagRefreshFailureReason
	}

	/// The mapped (team-specific) bundle ID installed on the device.
	let bundleIdentifier: String
	let originalBundleIdentifier: String
	var signedAt: Date
	var profileExpiresAt: Date
	var certificateExpiresAt: Date
	var lastSuccessfulRefresh: Date?
	var lastFailure: Failure?
	var consecutiveFailures: Int = 0

	var expiresAt: Date { min(profileExpiresAt, certificateExpiresAt) }

	/// Thresholds scale with the profile's life, not with a certificate that
	/// happens to expire sooner (that only makes the app more urgent).
	var profileLifetime: TimeInterval { profileExpiresAt.timeIntervalSince(signedAt) }

	func urgency(at now: Date, thresholds: ZagRefreshThresholds = .standard) -> ZagRefreshUrgency {
		let left = expiresAt.timeIntervalSince(now)
		let scaled = thresholds.scaled(toLifetime: profileLifetime)
		if left <= 0 { return .expired }
		if left <= scaled.urgent { return .urgent }
		if left <= scaled.recommended { return .recommended }
		if left <= scaled.eligible { return .eligible }
		return .normal
	}

	/// When to suggest refreshing: the start of the recommended window.
	func recommendedRefreshDate(thresholds: ZagRefreshThresholds = .standard) -> Date {
		let scaled = thresholds.scaled(toLifetime: profileLifetime)
		return expiresAt.addingTimeInterval(-scaled.recommended)
	}

	/// Local notifications to schedule: recommended and urgent reminders that
	/// are still in the future. iOS delivers these at the time even when Zag
	/// Store is not running; the refresh itself still needs the user, a
	/// Shortcut or a background opportunity.
	func reminderDates(after now: Date, thresholds: ZagRefreshThresholds = .standard) -> [Date] {
		let scaled = thresholds.scaled(toLifetime: profileLifetime)
		return [scaled.recommended, scaled.urgent]
			.map { expiresAt.addingTimeInterval(-$0) }
			.filter { $0 > now }
	}
}

enum ZagRefreshFailureReason: String, Codable, Sendable {
	case signedOut
	case network
	/// LocalDevVPN is off or the device's services did not answer.
	case deviceUnreachable
	case appIDCapacity
	case installSlots
	case signingFailed
	case installFailed
	/// iOS did not report the new expiry after installing, so success is not claimed.
	case notVerified
	case cancelled
	/// Zag Store was closed while the refresh ran.
	case interrupted

	/// Retrying cannot help until the user acts.
	var needsUser: Bool {
		switch self {
		case .signedOut, .appIDCapacity, .installSlots, .cancelled: return true
		default: return false
		}
	}
}

/// Refresh bookkeeping: one refresh per app at a time, success only when the
/// device proves it, and failures that back off. Pure value type; the owner
/// persists `records` and `running` together after each change.
struct ZagRefreshLedger: Codable, Equatable, Sendable {
	private(set) var records: [String: ZagSignedAppRecord] = [:]
	/// Bundle IDs with a refresh in progress, and when it started.
	private(set) var running: [String: Date] = [:]

	enum BeginResult: Equatable, Sendable {
		case started
		case alreadyRunning
		case unknownApp
		/// Too soon after a failure; try again after the date.
		case backingOff(until: Date)
	}

	enum FinishError: Error, Equatable {
		case notRunning
		/// The installed expiry is not later than before the refresh.
		case notVerified
	}

	mutating func record(_ app: ZagSignedAppRecord) {
		records[app.bundleIdentifier] = app
	}

	mutating func forget(_ bundleIdentifier: String) {
		records[bundleIdentifier] = nil
		running[bundleIdentifier] = nil
	}

	/// `userInitiated` skips the backoff: a person asking is always tried.
	mutating func begin(_ bundleIdentifier: String, at now: Date, userInitiated: Bool) -> BeginResult {
		guard let app = records[bundleIdentifier] else { return .unknownApp }
		guard running[bundleIdentifier] == nil else { return .alreadyRunning }
		if !userInitiated, let failure = app.lastFailure {
			if failure.reason.needsUser { return .backingOff(until: .distantFuture) }
			let until = failure.at.addingTimeInterval(Self.backoff(afterFailures: app.consecutiveFailures))
			if until > now { return .backingOff(until: until) }
		}
		running[bundleIdentifier] = now
		return .started
	}

	/// Success needs the expiry read back from the installed app, and it must be
	/// later than the expiry before the refresh. Otherwise the refresh is
	/// recorded as failed (`notVerified`) and the error is thrown.
	mutating func finishSucceeded(
		_ bundleIdentifier: String,
		installedProfileExpiresAt: Date,
		installedCertificateExpiresAt: Date,
		at now: Date
	) throws {
		guard running[bundleIdentifier] != nil, var app = records[bundleIdentifier] else { throw FinishError.notRunning }
		guard min(installedProfileExpiresAt, installedCertificateExpiresAt) > app.expiresAt else {
			finishFailed(bundleIdentifier, reason: .notVerified, at: now)
			throw FinishError.notVerified
		}
		running[bundleIdentifier] = nil
		app.signedAt = now
		app.profileExpiresAt = installedProfileExpiresAt
		app.certificateExpiresAt = installedCertificateExpiresAt
		app.lastSuccessfulRefresh = now
		app.lastFailure = nil
		app.consecutiveFailures = 0
		records[bundleIdentifier] = app
	}

	mutating func finishFailed(_ bundleIdentifier: String, reason: ZagRefreshFailureReason, at now: Date) {
		guard running.removeValue(forKey: bundleIdentifier) != nil, var app = records[bundleIdentifier] else { return }
		app.lastFailure = .init(at: now, reason: reason)
		app.consecutiveFailures += 1
		records[bundleIdentifier] = app
	}

	/// The user fixed the cause (signed in again, freed a slot): automatic
	/// refreshes held back by it may run again.
	mutating func resolve(_ reason: ZagRefreshFailureReason) {
		for (bundleIdentifier, app) in records where app.lastFailure?.reason == reason {
			records[bundleIdentifier]?.lastFailure = nil
			records[bundleIdentifier]?.consecutiveFailures = 0
		}
	}

	/// After a relaunch nothing can still be running: every refresh left
	/// running is recorded as interrupted, never as done.
	mutating func recoverAfterLaunch(at now: Date) {
		for bundleIdentifier in running.keys.sorted() {
			finishFailed(bundleIdentifier, reason: .interrupted, at: now)
		}
	}

	/// Apps for Refresh All: everything at or past `minimum`, most urgent (then
	/// soonest to expire) first. Expired apps are included: refreshing is how
	/// they come back.
	func refreshAllOrder(at now: Date, minimum: ZagRefreshUrgency = .eligible) -> [String] {
		records.values
			.filter { $0.urgency(at: now) >= minimum }
			.sorted {
				let lhs = $0.urgency(at: now), rhs = $1.urgency(at: now)
				return lhs != rhs ? lhs > rhs : ($0.expiresAt, $0.bundleIdentifier) < ($1.expiresAt, $1.bundleIdentifier)
			}
			.map(\.bundleIdentifier)
	}

	/// 1, 2, 4, 8 … minutes, capped at 6 hours.
	static func backoff(afterFailures failures: Int) -> TimeInterval {
		guard failures > 0 else { return 0 }
		return min(60 * pow(2, Double(min(failures, 20) - 1)), 6 * 3_600)
	}
}
