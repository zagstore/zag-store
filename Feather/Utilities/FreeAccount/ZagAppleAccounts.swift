import CryptoKit
import Foundation

// Several Apple Accounts at once, free and paid, each with its own Keychain
// session, teams and signing assets. Isolation is enforced here and in the
// stores (every secret, session summary and refresh record names its
// account), not by what the UI happens to show. Live sign-in stays
// disabled; see MULTI-ACCOUNT.md.

/// An account and one of its teams: the unit that owns a signing identity,
/// devices, App IDs, profiles and installed apps.
struct ZagSigningScope: Codable, Hashable, Sendable, CustomStringConvertible {
	let accountID: UUID
	let teamID: String

	var description: String { "[\(accountID.uuidString.prefix(8))/\(teamID)]" }
}

/// What Apple allows a team, by team kind. Apple's published limits only;
/// `MULTI-ACCOUNT.md` lists the sources and what Apple does not publish.
struct ZagTeamLimits: Equatable, Sendable {
	/// App IDs registered at once (nil: no published limit).
	let appIDs: Int?
	/// How long an App ID lasts (nil: until removed).
	let appIDLifetime: TimeInterval?
	/// Registered devices of one platform (per membership year for paid teams).
	let devicesPerPlatform: Int
	/// Whether the team's apps count towards iOS's 3-app limit for free
	/// development profiles, which Zag Store treats as device-wide.
	let countsTowardsFreeAppLimit: Bool
	/// The longest a profile from this team is expected to last.
	let profileLifetime: TimeInterval

	static let free = ZagTeamLimits(
		appIDs: ZagFreeAccountLimits.appIDsAtOnce,
		appIDLifetime: ZagFreeAccountLimits.appIDLifetime,
		devicesPerPlatform: ZagFreeAccountLimits.devicesPerPlatform,
		countsTowardsFreeAppLimit: true,
		profileLifetime: 7 * 86_400
	)
	static let paid = ZagTeamLimits(
		appIDs: nil,
		appIDLifetime: nil,
		devicesPerPlatform: 100,
		countsTowardsFreeAppLimit: false,
		profileLifetime: 365 * 86_400
	)

	static func forTeam(_ kind: ZagDeveloperTeam.Kind) -> ZagTeamLimits {
		kind == .personalFree || kind == .unknown ? .free : .paid
	}
}

/// Zag Store's record of one Apple Account. No secrets and no email address:
/// the account is recognised by a hash of Apple's own account identifier,
/// so a changed email keeps the same account and its assets.
struct ZagAppleAccountRecord: Codable, Equatable, Sendable {
	let id: UUID
	/// SHA-256 of Apple's account identifier (hex).
	let accountKey: String
	var maskedAppleID: String
	var teams: [ZagDeveloperTeam]
	let addedAt: Date
	var lastAuthenticatedAt: Date

	func team(_ identifier: String) -> ZagDeveloperTeam? { teams.first { $0.identifier == identifier } }

	static func accountKey(for appleAccountIdentifier: String) -> String {
		SHA256.hash(data: Data(appleAccountIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
	}
}

/// The accounts, the default signing account and team, and migration state.
/// A value type: `ZagAccountDirectory` owns and persists it.
struct ZagAccountRegistry: Codable, Equatable, Sendable {
	static let currentVersion = 2

	var version = ZagAccountRegistry.currentVersion
	private(set) var accounts: [ZagAppleAccountRecord] = []
	private(set) var defaultScope: ZagSigningScope?
	/// Set once the single-account (v1) data has been moved in.
	var migratedSingleAccount = false

	func account(_ id: UUID) -> ZagAppleAccountRecord? { accounts.first { $0.id == id } }
	func account(withKey key: String) -> ZagAppleAccountRecord? { accounts.first { $0.accountKey == key } }

	func team(_ scope: ZagSigningScope) -> ZagDeveloperTeam? { account(scope.accountID)?.team(scope.teamID) }

	/// Adds the account, or updates it (teams, masked ID) when it is known.
	mutating func upsert(id: UUID, accountKey: String, maskedAppleID: String, teams: [ZagDeveloperTeam], now: Date) {
		if let index = accounts.firstIndex(where: { $0.id == id }) {
			accounts[index].maskedAppleID = maskedAppleID
			accounts[index].teams = teams
			accounts[index].lastAuthenticatedAt = now
		} else {
			accounts.append(ZagAppleAccountRecord(id: id, accountKey: accountKey, maskedAppleID: maskedAppleID, teams: teams, addedAt: now, lastAuthenticatedAt: now))
		}
		// A default that no longer names a team of its account is cleared.
		if let defaultScope, team(defaultScope) == nil { self.defaultScope = nil }
		if defaultScope == nil, let first = accounts.first, let preferred = first.teams.first {
			defaultScope = ZagSigningScope(accountID: first.id, teamID: preferred.identifier)
		}
	}

	mutating func setDefault(_ scope: ZagSigningScope) throws {
		guard team(scope) != nil else { throw ZagAccountError.unknownTeam(scope) }
		defaultScope = scope
	}

	mutating func remove(_ id: UUID) {
		accounts.removeAll { $0.id == id }
		if defaultScope?.accountID == id {
			defaultScope = accounts.first.flatMap { account in account.teams.first.map { ZagSigningScope(accountID: account.id, teamID: $0.identifier) } }
		}
	}
}

enum ZagAccountError: Error, Equatable, Sendable {
	case unknownAccount(UUID)
	case unknownTeam(ZagSigningScope)
	/// No account was chosen and there is no default.
	case noSigningAccount
	/// The account is signed out or its session has expired: it cannot sign
	/// or refresh until the user signs in to it again. Never substituted.
	case notSignedIn(UUID)
	case notSignedInYet
	case removalNotConfirmed
	case storage
}

/// Proof, for one scope, that its account was signed in when signing was
/// requested. Only `ZagAccountDirectory` creates one, so nothing can sign for
/// an account that is signed out or expired.
struct ZagSigningAuthorization: Equatable, Sendable {
	let scope: ZagSigningScope
	let teamKind: ZagDeveloperTeam.Kind
	let validUntil: Date

	fileprivate init(scope: ZagSigningScope, teamKind: ZagDeveloperTeam.Kind, validUntil: Date) {
		self.scope = scope
		self.teamKind = teamKind
		self.validUntil = validUntil
	}

	var limits: ZagTeamLimits { .forTeam(teamKind) }
	func isValid(at now: Date) -> Bool { now < validUntil }
}

/// What removing an account would affect. The confirmation must name the
/// same account and the same dependent apps, so a stale confirmation (apps
/// added since it was shown) is refused.
struct ZagAccountRemovalPlan: Equatable, Sendable {
	enum AppHandling: Equatable, Sendable {
		/// Keep the apps installed; they stop refreshing and expire.
		case keepUntilExpiry
		/// Forget their refresh records too (the apps still expire).
		case forgetRecords
	}

	struct Confirmation: Equatable, Sendable {
		let accountID: UUID
		let dependentApps: [String]
		let handling: AppHandling
	}

	let accountID: UUID
	let maskedAppleID: String
	let teams: [ZagDeveloperTeam]
	/// Installed apps signed by this account, by bundle ID.
	let dependentApps: [String]

	func confirm(_ handling: AppHandling) -> Confirmation {
		Confirmation(accountID: accountID, dependentApps: dependentApps, handling: handling)
	}
}

/// Apple account identifier → stable account ID, shared with the
/// authenticators' `identify` closures.
final class ZagAccountKeyIndex: @unchecked Sendable {
	private let lock = NSLock()
	private var ids: [String: UUID] = [:]

	func set(_ id: UUID, for key: String) { lock.withLock { ids[key] = id } }
	func remove(_ id: UUID) { lock.withLock { ids = ids.filter { $0.value != id } } }
	func key(for id: UUID) -> String? { lock.withLock { ids.first { $0.value == id }?.key } }

	/// The known ID for this Apple Account, or a new one remembered for it.
	func id(forAppleAccount identifier: String) -> UUID {
		let key = ZagAppleAccountRecord.accountKey(for: identifier)
		return lock.withLock {
			if let id = ids[key] { return id }
			let id = UUID()
			ids[key] = id
			return id
		}
	}
}

/// The accounts on this device: sign-in, sessions, the default, signing
/// authorisation and removal. Each account has its own authenticator, bound
/// to its ID, its own session summary and its own Keychain items.
actor ZagAccountDirectory {
	struct Configuration: Sendable {
		/// Preferences namespace; the simulation uses its own.
		var namespace = "ZagStore.accounts"
		/// The single-account session key migrated from.
		var legacySessionKey = ZagFreeAccountSessionStore.key
		var authenticator = ZagFreeAccountAuthenticator.Configuration()
		/// How long a signing authorisation lasts.
		var authorizationLifetime: TimeInterval = 600

		/// The Keychain key items of this directory's accounts. The provisioner's
		/// `ZagKeychainSigningKeyFactory` must use these, so that removing an
		/// account removes its keys.
		var signingKeys: ZagKeychainSigningKeys { ZagKeychainSigningKeys(namespace: namespace) }
	}

	private let service: ZagAppleAuthenticationService
	private let anisette: ZagAnisetteSource
	private let secrets: ZagFreeAccountSecretStore
	private let preferences: ZagPreferenceStore
	private let diagnostics: ZagFreeAccountDiagnostics
	private let configuration: Configuration
	private let now: @Sendable () -> Date
	private let keyIndex = ZagAccountKeyIndex()
	private(set) var registry: ZagAccountRegistry
	private var authenticators: [UUID: ZagFreeAccountAuthenticator] = [:]

	init(
		service: ZagAppleAuthenticationService = ZagDisabledAuthenticationService(),
		anisette: ZagAnisetteSource,
		secrets: ZagFreeAccountSecretStore,
		preferences: ZagPreferenceStore,
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		configuration: Configuration = Configuration(),
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.service = service
		self.anisette = anisette
		self.secrets = secrets
		self.preferences = preferences
		self.diagnostics = diagnostics
		self.configuration = configuration
		self.now = now
		registry = preferences.data(forKey: configuration.namespace + ".registry.v2")
			.flatMap { try? JSONDecoder().decode(ZagAccountRegistry.self, from: $0) } ?? ZagAccountRegistry()
		for account in registry.accounts { keyIndex.set(account.id, for: account.accountKey) }
	}

	private var registryKey: String { configuration.namespace + ".registry.v2" }

	var sessionStore: ZagFreeAccountSessionStore {
		ZagFreeAccountSessionStore(preferences: preferences, key: configuration.legacySessionKey, accountKeyPrefix: configuration.namespace + ".session.")
	}

	private func persist() throws {
		do { preferences.set(try JSONEncoder().encode(registry), forKey: registryKey) } catch { throw ZagAccountError.storage }
	}

	private func makeAuthenticator(account: UUID?) -> ZagFreeAccountAuthenticator {
		let index = keyIndex
		return ZagFreeAccountAuthenticator(
			service: service, anisette: anisette, secrets: secrets, sessions: sessionStore,
			diagnostics: diagnostics, configuration: configuration.authenticator,
			account: account, identify: { index.id(forAppleAccount: $0) }, now: now
		)
	}

	// MARK: Launch

	/// Migrates single-account data once, then restores every account's
	/// session (no network). Returns each account's state.
	@discardableResult
	func start() async -> [UUID: ZagFreeAccountState] {
		migrateSingleAccount()
		var states: [UUID: ZagFreeAccountState] = [:]
		for account in registry.accounts {
			let authenticator = authenticators[account.id] ?? makeAuthenticator(account: account.id)
			authenticators[account.id] = authenticator
			states[account.id] = await authenticator.restore()
		}
		return states
	}

	/// Moves the v1 single-account session (and its signing identity, to its
	/// team) into this registry, keeping the account ID so every Keychain
	/// item stays reachable. Each step can be repeated, so an interrupted
	/// migration finishes on the next launch without losing anything.
	private func migrateSingleAccount() {
		guard !registry.migratedSingleAccount else { return }
		let legacy = ZagFreeAccountSessionStore(preferences: preferences, key: configuration.legacySessionKey)
		guard let summary = legacy.load() else {
			registry.migratedSingleAccount = true
			try? persist()
			return
		}
		let identifier = (try? secrets.load(.session, account: summary.accountID))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSessionCredential.self, from: $0) }?.accountIdentifier
		let key = identifier.map(ZagAppleAccountRecord.accountKey(for:)) ?? "legacy-\(summary.accountID.uuidString)"
		registry.upsert(id: summary.accountID, accountKey: key, maskedAppleID: summary.maskedAppleID, teams: summary.teams, now: summary.authenticatedAt)
		keyIndex.set(summary.accountID, for: key)
		guard (try? persist()) != nil, (try? sessionStore.save(summary)) != nil else { return }
		// The v1 signing identity belonged to the session's team.
		if let identity = try? secrets.load(.signingPrivateKey, account: summary.accountID, team: nil) {
			let team = summary.team.identifier
			guard (try? secrets.save(identity, kind: .signingPrivateKey, account: summary.accountID, team: team)) != nil,
				  (try? secrets.load(.signingPrivateKey, account: summary.accountID, team: team)) == identity,
				  (try? secrets.delete(.signingPrivateKey, account: summary.accountID, team: nil)) != nil else { return }
		}
		legacy.remove()
		registry.migratedSingleAccount = true
		try? persist()
		diagnostics.record("Moved the signed-in account to multi-account storage", at: now())
	}

	// MARK: Sign-in and sign-out

	/// A sign-in for an account not yet chosen. Drive it (sign in, verify),
	/// then `adopt` it. Several can run at once.
	func newSignIn() -> ZagFreeAccountAuthenticator { makeAuthenticator(account: nil) }

	/// The authenticator of an existing account, for signing in to it again.
	/// It refuses a sign-in to a different Apple Account.
	func authenticator(for id: UUID) -> ZagFreeAccountAuthenticator? {
		guard registry.account(id) != nil else { return nil }
		if let existing = authenticators[id] { return existing }
		let authenticator = makeAuthenticator(account: id)
		authenticators[id] = authenticator
		return authenticator
	}

	/// Records a completed sign-in: the account (new or known), its teams,
	/// and the authenticator as that account's own.
	@discardableResult
	func adopt(_ authenticator: ZagFreeAccountAuthenticator) async throws -> UUID {
		guard case .signedIn(let summary) = await authenticator.state else { throw ZagAccountError.notSignedInYet }
		guard let key = keyIndex.key(for: summary.accountID) else { throw ZagAccountError.unknownAccount(summary.accountID) }
		registry.upsert(id: summary.accountID, accountKey: key, maskedAppleID: summary.maskedAppleID, teams: summary.teams, now: now())
		try persist()
		authenticators[summary.accountID] = authenticator
		return summary.accountID
	}

	func state(of id: UUID) async -> ZagFreeAccountState? {
		guard let authenticator = authenticators[id] else { return nil }
		return await authenticator.state
	}

	/// Signs out one account: its session only. Its signing identities and
	/// refresh records stay; other accounts are untouched.
	func signOut(_ id: UUID) async throws {
		guard let authenticator = authenticator(for: id) else { throw ZagAccountError.unknownAccount(id) }
		try await authenticator.signOut()
	}

	// MARK: Default and signing

	func setDefault(_ scope: ZagSigningScope) throws {
		try registry.setDefault(scope)
		try persist()
	}

	/// The scope to sign with: the explicit choice, else the default. The
	/// account must be signed in; another account is never substituted.
	func signingScope(explicit: ZagSigningScope? = nil) async throws -> ZagSigningScope {
		guard let scope = explicit ?? registry.defaultScope else { throw ZagAccountError.noSigningAccount }
		_ = try await authorize(scope)
		return scope
	}

	/// An authorisation to sign for `scope`, only while its account is
	/// signed in with an unexpired session.
	func authorize(_ scope: ZagSigningScope) async throws -> ZagSigningAuthorization {
		guard registry.account(scope.accountID) != nil else { throw ZagAccountError.unknownAccount(scope.accountID) }
		guard let team = registry.team(scope) else { throw ZagAccountError.unknownTeam(scope) }
		guard let authenticator = authenticators[scope.accountID],
			  case .signedIn(let session) = await authenticator.state,
			  session.accountID == scope.accountID,
			  !session.isExpired(at: now()) else { throw ZagAccountError.notSignedIn(scope.accountID) }
		let until = min(session.expiresAt ?? .distantFuture, now() + configuration.authorizationLifetime)
		return ZagSigningAuthorization(scope: scope, teamKind: team.kind, validUntil: until)
	}

	// MARK: Removal

	func removalPlan(for id: UUID, ledger: ZagRefreshLedger) throws -> ZagAccountRemovalPlan {
		guard let account = registry.account(id) else { throw ZagAccountError.unknownAccount(id) }
		return ZagAccountRemovalPlan(
			accountID: id, maskedAppleID: account.maskedAppleID, teams: account.teams,
			dependentApps: ledger.apps(ownedBy: id)
		)
	}

	/// Removes the account after confirmation: its session, every Keychain
	/// item (all teams' signing identities and signing key items), its
	/// summary and its record.
	/// Its apps are never moved to another account; they keep their owner
	/// and stop refreshing, or are forgotten. Other accounts are untouched.
	func remove(_ confirmation: ZagAccountRemovalPlan.Confirmation, ledger: inout ZagRefreshLedger) async throws {
		let plan = try removalPlan(for: confirmation.accountID, ledger: ledger)
		guard confirmation.dependentApps == plan.dependentApps else { throw ZagAccountError.removalNotConfirmed }
		if let authenticator = authenticators[confirmation.accountID] {
			await authenticator.cancel()
		}
		// Keys first: if the Keychain refuses, nothing has been removed yet and
		// the removal can be repeated.
		try configuration.signingKeys.deleteAll(account: confirmation.accountID)
		try secrets.deleteAll(account: confirmation.accountID)
		sessionStore.remove(account: confirmation.accountID)
		authenticators[confirmation.accountID] = nil
		keyIndex.remove(confirmation.accountID)
		registry.remove(confirmation.accountID)
		try persist()
		switch confirmation.handling {
		case .keepUntilExpiry: ledger.detach(account: confirmation.accountID)
		case .forgetRecords: for bundle in plan.dependentApps { ledger.forget(bundle) }
		}
		diagnostics.record("Account removed; \(plan.dependentApps.count) apps no longer refresh", at: now())
	}
}
