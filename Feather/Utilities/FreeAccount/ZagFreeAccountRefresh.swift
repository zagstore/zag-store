import Foundation

/// Apple ID profile warnings are based on the exact expiration timestamp.
enum ZagAppleIDProfileValidity: Equatable {
	case valid, soon, urgent, expired

	init(expiresAt: Date, now: Date) {
		let remaining = expiresAt.timeIntervalSince(now)
		switch remaining {
		case ...0: self = .expired
		case ...172_800: self = .urgent
		case ...345_600: self = .soon
		default: self = .valid
		}
	}
}

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

/// Who signed an installed app, and with what: the only account and team
/// allowed to refresh it.
struct ZagAppOwnership: Codable, Equatable, Sendable {
	let scope: ZagSigningScope
	let teamKind: ZagDeveloperTeam.Kind
	var certificateSerial: String
	var profileUUID: String
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
	/// The signing account and team (absent in records made before
	/// multi-account support, which therefore never refresh automatically).
	var owner: ZagAppOwnership? = nil
	/// Whether the expiry was read back from the device (nil: not known).
	var expiryVerified: Bool? = nil
	/// Set when the owning account was removed: the app keeps its owner, is
	/// never given to another account, and stops refreshing.
	var ownerRemovedAt: Date? = nil

	var countsTowardsFreeAppLimit: Bool { owner.map { ZagTeamLimits.forTeam($0.teamKind).countsTowardsFreeAppLimit } ?? true }

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
	/// The record has no signing account (made before multi-account support).
	case noOwner
	/// The account that signed the app was removed.
	case accountRemoved
	/// The account no longer belongs to the team that signed the app.
	case teamUnavailable

	/// Retrying cannot help until the user acts.
	var needsUser: Bool {
		switch self {
		case .signedOut, .appIDCapacity, .installSlots, .cancelled, .noOwner, .accountRemoved, .teamUnavailable: return true
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
		/// Its account was removed: it is never refreshed by another one.
		case ownerRemoved
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
		guard app.ownerRemovedAt == nil else { return .ownerRemoved }
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
	/// refreshes held back by it may run again. With `account`, only that
	/// account's apps: one account signing in never releases another's.
	mutating func resolve(_ reason: ZagRefreshFailureReason, account: UUID? = nil) {
		for (bundleIdentifier, app) in records where app.lastFailure?.reason == reason
			&& (account == nil || app.owner?.scope.accountID == account) {
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
	func refreshAllOrder(at now: Date, minimum: ZagRefreshUrgency = .eligible, account: UUID? = nil) -> [String] {
		records.values
			.filter { $0.urgency(at: now) >= minimum && $0.ownerRemovedAt == nil }
			.filter { account == nil || $0.owner?.scope.accountID == account }
			.sorted {
				let lhs = $0.urgency(at: now), rhs = $1.urgency(at: now)
				return lhs != rhs ? lhs > rhs : ($0.expiresAt, $0.bundleIdentifier) < ($1.expiresAt, $1.bundleIdentifier)
			}
			.map(\.bundleIdentifier)
	}

	/// Installed apps signed by the account, by bundle ID.
	func apps(ownedBy account: UUID) -> [String] {
		records.values.filter { $0.owner?.scope.accountID == account }.map(\.bundleIdentifier).sorted()
	}

	/// Apps that count towards iOS's 3-app limit for free development
	/// profiles: every free team's, across all accounts (device-wide).
	var freeAppLimitApps: Set<String> {
		Set(records.values.filter { $0.countsTowardsFreeAppLimit && $0.ownerRemovedAt == nil }.map(\.bundleIdentifier))
	}

	/// A refresh that could not be routed (owner signed out, removed, …):
	/// recorded as a failure without starting.
	mutating func markBlocked(_ bundleIdentifier: String, reason: ZagRefreshFailureReason, at now: Date) {
		guard var app = records[bundleIdentifier] else { return }
		app.lastFailure = .init(at: now, reason: reason)
		app.consecutiveFailures += 1
		records[bundleIdentifier] = app
	}

	/// After a verified refresh: the certificate and profile now in use.
	mutating func updateOwnership(_ bundleIdentifier: String, certificateSerial: String?, profileUUID: String?) {
		guard var owner = records[bundleIdentifier]?.owner else { return }
		if let certificateSerial { owner.certificateSerial = certificateSerial }
		if let profileUUID { owner.profileUUID = profileUUID }
		records[bundleIdentifier]?.owner = owner
		records[bundleIdentifier]?.expiryVerified = true
	}

	/// The account was removed: its apps keep their owner but never refresh.
	mutating func detach(account: UUID, at now: Date = Date()) {
		for (bundleIdentifier, app) in records where app.owner?.scope.accountID == account {
			records[bundleIdentifier]?.ownerRemovedAt = now
			running[bundleIdentifier] = nil
		}
	}

	/// When each app should next be refreshed and reminded about, for apps
	/// that can refresh, earliest first.
	func schedule(at now: Date, thresholds: ZagRefreshThresholds = .standard) -> [ZagRefreshScheduleEntry] {
		records.values
			.filter { $0.ownerRemovedAt == nil }
			.map { app in
				var refreshAt = max(now, app.recommendedRefreshDate(thresholds: thresholds))
				if let failure = app.lastFailure, !failure.reason.needsUser {
					refreshAt = max(refreshAt, failure.at.addingTimeInterval(Self.backoff(afterFailures: app.consecutiveFailures)))
				}
				return ZagRefreshScheduleEntry(
					bundleIdentifier: app.bundleIdentifier,
					owner: app.owner?.scope,
					refreshAt: refreshAt,
					reminders: app.reminderDates(after: now, thresholds: thresholds),
					needsUser: app.lastFailure?.reason.needsUser == true || app.owner == nil
				)
			}
			.sorted { ($0.refreshAt, $0.bundleIdentifier) < ($1.refreshAt, $1.bundleIdentifier) }
	}

	/// 1, 2, 4, 8 … minutes, capped at 6 hours.
	static func backoff(afterFailures failures: Int) -> TimeInterval {
		guard failures > 0 else { return 0 }
		return min(60 * pow(2, Double(min(failures, 20) - 1)), 6 * 3_600)
	}
}

struct ZagRefreshScheduleEntry: Equatable, Sendable {
	let bundleIdentifier: String
	let owner: ZagSigningScope?
	/// The start of the recommended window, or after the backoff.
	let refreshAt: Date
	let reminders: [Date]
	/// Waiting for the user (signed out, no owner, slots): not tried automatically.
	let needsUser: Bool
}

/// Where a refresh goes: to the app's own account and team, or nowhere.
enum ZagRefreshRoute: Equatable, Sendable {
	case refresh(ZagSigningAuthorization)
	case blocked(ZagRefreshFailureReason)
}

extension ZagAccountDirectory {
	/// Routes a refresh to the account and team that signed the app. Blocked,
	/// never redirected, when that account is removed, signed out, expired or
	/// no longer in the team.
	func route(_ bundleIdentifier: String, ledger: ZagRefreshLedger) async -> ZagRefreshRoute {
		guard let app = ledger.records[bundleIdentifier] else { return .blocked(.noOwner) }
		guard let owner = app.owner else { return .blocked(.noOwner) }
		guard app.ownerRemovedAt == nil, registry.account(owner.scope.accountID) != nil else { return .blocked(.accountRemoved) }
		guard registry.team(owner.scope) != nil else { return .blocked(.teamUnavailable) }
		do {
			return .refresh(try await authorize(owner.scope))
		} catch {
			return .blocked(.signedOut)
		}
	}
}

/// The refresh records on disk: one JSON file in Application Support,
/// replaced atomically and excluded from backups (the apps and profiles it
/// describes belong to this device). A file that cannot be read is kept
/// aside, never overwritten, and the ledger starts empty: apps then show as
/// unknown until refreshed, which never signs with a guessed account.
struct ZagRefreshLedgerStore: Sendable {
	enum LoadResult: Equatable, Sendable {
		case loaded(ZagRefreshLedger)
		case empty
		/// The file was unreadable; it was moved to `preservedAt`.
		case recovered(preservedAt: URL)
	}

	let file: URL

	static var standard: ZagRefreshLedgerStore {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return ZagRefreshLedgerStore(file: support.appendingPathComponent("ZagStore/FreeAccount/refresh-ledger.v2.json"))
	}

	/// Loads the ledger and marks refreshes that were running when Zag Store
	/// last closed as interrupted.
	func load(at now: Date) -> (ZagRefreshLedger, LoadResult) {
		guard let data = try? Data(contentsOf: file) else { return (ZagRefreshLedger(), .empty) }
		guard var ledger = try? JSONDecoder().decode(ZagRefreshLedger.self, from: data) else {
			let aside = file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970)).json")
			try? FileManager.default.moveItem(at: file, to: aside)
			return (ZagRefreshLedger(), .recovered(preservedAt: aside))
		}
		ledger.recoverAfterLaunch(at: now)
		return (ledger, .loaded(ledger))
	}

	func save(_ ledger: ZagRefreshLedger) throws {
		let folder = file.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		try encoder.encode(ledger).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var url = file
		try? url.setResourceValues(values)
	}
}
