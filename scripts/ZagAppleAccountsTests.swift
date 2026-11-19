import Foundation

// Several Apple Accounts at once: concurrent sign-ins, stable account IDs,
// per-account sessions and Keychain items, the default and explicit signing
// scope, migration from the single-account version, expiry, rejection,
// removal and per-account refresh records. Synthetic accounts only
// (@example.invalid, simulated service); nothing contacts Apple.

final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Date(timeIntervalSince1970: 1_795_000_000)
	var now: Date { lock.withLock { value } }
	func advance(days: Double) { lock.withLock { value += days * 86_400 } }
}

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	struct Failure: Error {}
	private let lock = NSLock()
	var items: [String: Data] = [:]
	func accountIDs() throws -> Set<UUID> { lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) } }
	var failDeletes = false
	private func name(_ kind: ZagFreeAccountSecretKind, _ account: UUID, _ team: String?) -> String {
		ZagKeychainFreeAccountSecretStore.itemName(kind, account: account, team: team)
	}
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items[name(kind, account, team)] = secret } }
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items[name(kind, account, team)] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		try lock.withLock {
			if failDeletes { throw Failure() }
			items[name(kind, account, team)] = nil
		}
	}
	func deleteAll(account: UUID) throws {
		try lock.withLock {
			if failDeletes { throw Failure() }
			items = items.filter { !$0.key.hasPrefix("\(account.uuidString).") }
		}
	}
	/// The account's items other than its ownership record (checked on its own).
	func keys(of account: UUID) -> Set<String> {
		lock.withLock { Set(items.keys.filter { $0.hasPrefix("\(account.uuidString).") && !$0.hasSuffix(".accountRecord") }) }
	}
	func hasRecord(_ account: UUID) -> Bool { lock.withLock { items["\(account.uuidString).accountRecord"] != nil } }
}

struct World {
	let clock = TestClock()
	let secrets = MemorySecrets()
	let preferences = TestPreferences()
	let directory: ZagAccountDirectory
	let service: ZagSimulatedAuthenticationService

	init() {
		let clock = clock
		(directory, service) = SimulatedAccounts.directory(now: { clock.now }, secrets: secrets, preferences: preferences)
	}

	/// The same device after a relaunch: a new directory over the same storage.
	func relaunched() -> ZagAccountDirectory {
		let clock = clock
		return SimulatedAccounts.directory(now: { clock.now }, secrets: secrets, preferences: preferences, service: service).directory
	}
}

func signedIn(_ state: ZagFreeAccountState?) -> ZagFreeAccountSession? {
	if case .signedIn(let session)? = state { return session }
	return nil
}

@main struct Tests {
	static var passed = 0
	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		await concurrentAccounts()
		await selectionAndExpiry()
		await migration()
		await interruptedMigration()
		await removal()
		await reinstall()
		await ambiguousRecords()
		await aliases()
		await localStateLifecycle()
		await cleanupRevalidation()
		unresolvedCertificateIsNotRetried()
		await recoveryActions()
		await storedDataModel()
		await signedOutAndExpiredRemoval()
		check(!ZagAppleAccountsFeature.isEnabled, "release gating: the Apple Accounts feature (its Release screens) is off in this version")
		ledgerOwnership()
		limits()
		print("SUCCESS: \(passed) multi-account checks passed")
	}

	// MARK: Several accounts signed in at once

	static func concurrentAccounts() async {
		let world = World()
		let directory = world.directory
		let a = await directory.newSignIn(), b = await directory.newSignIn(), c = await directory.newSignIn()
		async let signA = a.signIn(appleID: SimulatedAccounts.tester, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		async let signB = b.signIn(appleID: SimulatedAccounts.second, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		async let signC = c.signIn(appleID: SimulatedAccounts.paid, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		let states = await [signA, signB, signC]
		check(states.allSatisfy { signedIn($0) != nil }, "three sign-ins run at the same time")
		let ids = [try? await directory.adopt(a), try? await directory.adopt(b), try? await directory.adopt(c)].compactMap { $0 }
		check(Set(ids).count == 3, "each Apple Account gets its own stable ID")
		let (tester, second, paid) = (ids[0], ids[1], ids[2])

		check(world.secrets.keys(of: tester) == ["\(tester.uuidString).session"] && world.secrets.keys(of: second) == ["\(second.uuidString).session"],
			  "each account has its own Keychain session item")
		check(ids.allSatisfy(world.secrets.hasRecord), "each account has a Keychain ownership record (L1)")
		let summaries = world.preferences.keys.filter { $0.hasPrefix(ZagFreeAccountSimulation.accountsNamespace + ".session.") }
		check(summaries.count == 3 && !world.preferences.keys.contains(ZagFreeAccountSimulation.sessionKey),
			  "each account has its own session summary; the single-account key is not used")
		let registry = await directory.registry
		check(registry.account(paid)?.teams.map(\.identifier) == ["SIMPAID001", "SIMORG0001"] && registry.account(tester)?.teams.first?.kind == .personalFree,
			  "free Personal Teams and a paid account's several teams are recorded")
		check(registry.accounts.allSatisfy { !$0.maskedAppleID.contains("tester@") && $0.accountKey.count == 64 && !$0.accountKey.contains("SIMULATED") },
			  "the registry keeps a masked Apple ID and a hash of Apple's account identifier, never either in clear")
		check(registry.defaultScope == ZagSigningScope(accountID: tester, teamID: "SIMTEAM001"), "the first account's team becomes the default")

		// Signing in again to the same Apple Account finds the same account.
		let again = await directory.newSignIn()
		_ = await again.signIn(appleID: SimulatedAccounts.tester, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		let againID = try? await directory.adopt(again)
		let count = await directory.registry.accounts.count
		check(againID == tester && count == 3, "signing in again to a known Apple Account reuses its ID (no duplicate)")

		// Signing out one account touches nothing else.
		try! await directory.signOut(second)
		let testerState = await directory.state(of: tester), paidState = await directory.state(of: paid)
		check(signedIn(testerState) != nil && signedIn(paidState) != nil && world.secrets.keys(of: second).isEmpty
			  && world.secrets.keys(of: tester).count == 1 && world.secrets.keys(of: paid).count == 1,
			  "signing out one account removes only its session")

		// An account's own authenticator refuses a different Apple Account.
		let bound = await directory.authenticator(for: second)!
		let wrong = await bound.signIn(appleID: SimulatedAccounts.tester, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		if case .failed(let failure) = wrong {
			check(failure.kind == .differentAccount && world.secrets.keys(of: second).isEmpty && world.secrets.keys(of: tester).count == 1,
				  "signing in to one account with another Apple ID is refused and stores nothing")
		} else { check(false, "different account: \(wrong)") }

		// After a relaunch every account is restored separately.
		let relaunched = world.relaunched()
		let restored = await relaunched.start()
		check(signedIn(restored[tester])?.accountID == tester && signedIn(restored[paid])?.accountID == paid && restored[second] == .signedOut,
			  "after a relaunch each account is restored with its own session")
		let restoredDefault = await relaunched.registry.defaultScope
		check(restoredDefault == registry.defaultScope, "the default signing account survives a relaunch")

		// Apple rejecting one account's session leaves the others.
		await world.service.setRejectsSessions(true, forAppleID: SimulatedAccounts.paid)
		let paidCheck = await relaunched.authenticator(for: paid)!.validateStoredSession()
		let testerCheck = await relaunched.authenticator(for: tester)!.validateStoredSession()
		check(signedIn(paidCheck) == nil && signedIn(testerCheck) != nil, "a rejected session affects only its own account")
		await world.service.setRejectsSessions(false, forAppleID: SimulatedAccounts.paid)
		let log = (await relaunched.registry.accounts).map(\.maskedAppleID).joined()
		check(!log.contains("SIMULATED"), "no Apple account identifier is kept in clear")
	}

	// MARK: Default, explicit choice and expiry

	static func selectionAndExpiry() async {
		let world = World()
		let directory = world.directory
		let first = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		let paid = await SimulatedAccounts.signIn(SimulatedAccounts.paid, to: directory)!
		let org = ZagSigningScope(accountID: paid, teamID: "SIMORG0001")

		let byDefault = try? await directory.signingScope()
		check(byDefault == ZagSigningScope(accountID: first, teamID: "SIMTEAM001"), "without a choice the default account and team sign")
		let chosen = try? await directory.signingScope(explicit: org)
		check(chosen == org, "an explicit account and team are used as chosen")
		do { try await directory.setDefault(ZagSigningScope(accountID: first, teamID: "SIMORG0001")); check(false, "default with another account's team") }
		catch { check(error as? ZagAccountError == .unknownTeam(ZagSigningScope(accountID: first, teamID: "SIMORG0001")), "a team of another account cannot be the default") }
		try! await directory.setDefault(org)
		let authorization = try! await directory.authorize(org)
		check(authorization.teamKind == .organization && authorization.limits == .paid, "authorisations carry the team's kind and limits")

		try! await directory.signOut(paid)
		do { _ = try await directory.signingScope(); check(false, "fallback") }
		catch { check(error as? ZagAccountError == .notSignedIn(paid), "a signed-out default is reported, never replaced by another account") }
		let stranger = UUID()
		do { _ = try await directory.authorize(ZagSigningScope(accountID: stranger, teamID: "SIMTEAM001")); check(false, "unknown account") }
		catch { check(error as? ZagAccountError == .unknownAccount(stranger), "an unknown account cannot sign") }

		let firstScope = ZagSigningScope(accountID: first, teamID: "SIMTEAM001")
		check(!authorization.isValid(at: world.clock.now + 3_600), "an authorisation lapses quickly and must be asked for again")
		world.clock.advance(days: 31)
		do { _ = try await directory.authorize(firstScope); check(false, "expired session signs") }
		catch { check(error as? ZagAccountError == .notSignedIn(first), "an expired session cannot sign") }
	}

	// MARK: Migration from the single-account version

	static func legacy(_ world: World, identity: Data) -> UUID {
		let id = UUID()
		let now = world.clock.now
		let session = ZagFreeAccountSession(
			accountID: id, maskedAppleID: "t•••@example.invalid",
			team: ZagDeveloperTeam(identifier: "SIMTEAM001", name: "Personal Team (Simulated)", kind: .personalFree),
			authenticatedAt: now, expiresAt: now + 30 * 86_400
		)
		world.preferences.set(try! JSONEncoder().encode(session), forKey: ZagFreeAccountSimulation.sessionKey)
		let credential = ZagSessionCredential(accountIdentifier: "SIMULATED0001", token: "simulated-session-legacy", expiresAt: now + 30 * 86_400)
		try! world.secrets.save(try! JSONEncoder().encode(credential), kind: .session, account: id)
		try! world.secrets.save(identity, kind: .signingPrivateKey, account: id)
		return id
	}

	static func migration() async {
		let world = World()
		let identity = Data("synthetic signing identity".utf8)
		let id = legacy(world, identity: identity)
		let states = await world.directory.start()
		let registry = await world.directory.registry
		check(registry.migratedSingleAccount && registry.accounts.map(\.id) == [id] && signedIn(states[id])?.accountID == id,
			  "the single signed-in account is moved over with its ID and stays signed in")
		check(world.secrets.items["\(id.uuidString).signingPrivateKey.SIMTEAM001"] == identity && world.secrets.items["\(id.uuidString).signingPrivateKey"] == nil,
			  "its signing identity moves, byte for byte, to its team")
		check(world.preferences.data(forKey: ZagFreeAccountSimulation.sessionKey) == nil && world.secrets.items["\(id.uuidString).session"] != nil,
			  "the old summary is removed and the Keychain session is kept")
		check(registry.defaultScope == ZagSigningScope(accountID: id, teamID: "SIMTEAM001"), "the migrated account becomes the default")

		let again = await world.relaunched().start()
		let registryAgain = await world.directory.registry
		check(signedIn(again[id]) != nil && registryAgain == registry, "migration runs once")
		let signIn = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: world.directory)
		check(signIn == id, "signing in again to the migrated Apple Account finds the same account")

		let empty = World()
		_ = await empty.directory.start()
		let fresh = await empty.directory.registry
		check(fresh.migratedSingleAccount && fresh.accounts.isEmpty, "with nothing to migrate, nothing is created")
	}

	static func interruptedMigration() async {
		let world = World()
		let identity = Data("synthetic signing identity".utf8)
		let id = legacy(world, identity: identity)
		world.secrets.failDeletes = true
		_ = await world.directory.start()
		let partial = await world.directory.registry
		check(!partial.migratedSingleAccount && world.secrets.items["\(id.uuidString).signingPrivateKey"] == identity
			  && world.secrets.items["\(id.uuidString).signingPrivateKey.SIMTEAM001"] == identity
			  && world.preferences.data(forKey: ZagFreeAccountSimulation.sessionKey) != nil,
			  "an interrupted migration loses nothing and is not marked done")
		world.secrets.failDeletes = false
		let states = await world.relaunched().start()
		check(signedIn(states[id]) != nil && world.secrets.items["\(id.uuidString).signingPrivateKey"] == nil
			  && world.secrets.items["\(id.uuidString).signingPrivateKey.SIMTEAM001"] == identity,
			  "the next launch finishes it")
	}

	// MARK: Removal

	static func removal() async {
		let world = World()
		let directory = world.directory
		let keep = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		let gone = await SimulatedAccounts.signIn(SimulatedAccounts.paid, to: directory)!
		try! await directory.setDefault(ZagSigningScope(accountID: gone, teamID: "SIMPAID001"))
		try! world.secrets.save(Data("a".utf8), kind: .signingPrivateKey, account: gone, team: "SIMPAID001")
		try! world.secrets.save(Data("b".utf8), kind: .signingPrivateKey, account: gone, team: "SIMORG0001")
		try! world.secrets.save(Data("c".utf8), kind: .signingPrivateKey, account: keep, team: "SIMTEAM001")

		var ledger = ZagRefreshLedger()
		let now = world.clock.now
		func app(_ bundle: String, _ scope: ZagSigningScope) -> ZagSignedAppRecord {
			ZagSignedAppRecord(bundleIdentifier: bundle, originalBundleIdentifier: bundle, signedAt: now, profileExpiresAt: now + 7 * 86_400,
							   certificateExpiresAt: now + 300 * 86_400, owner: ZagAppOwnership(scope: scope, teamKind: .individualPaid, certificateSerial: "01", profileUUID: "P"))
		}
		ledger.record(app("com.example.a", ZagSigningScope(accountID: gone, teamID: "SIMPAID001")))
		ledger.record(app("com.example.b", ZagSigningScope(accountID: gone, teamID: "SIMORG0001")))
		ledger.record(app("com.example.c", ZagSigningScope(accountID: keep, teamID: "SIMTEAM001")))

		let plan = try! await directory.removalPlan(for: gone, ledger: ledger)
		check(plan.dependentApps == ["com.example.a", "com.example.b"] && plan.teams.count == 2, "the removal plan lists the account's teams and apps")
		ledger.record(app("com.example.late", ZagSigningScope(accountID: gone, teamID: "SIMPAID001")))
		do { try await directory.remove(plan.confirm(.forgetRecords), ledger: &ledger); check(false, "stale") }
		catch { check(error as? ZagAccountError == .removalNotConfirmed && world.secrets.keys(of: gone).count == 3, "a confirmation shown before another app was signed is refused") }

		let current = try! await directory.removalPlan(for: gone, ledger: ledger)
		world.secrets.failDeletes = true
		do { try await directory.remove(current.confirm(.forgetRecords), ledger: &ledger); check(false, "removal with a failing Keychain") }
		catch {
			let still = await directory.registry.account(gone)
			check(still != nil && ledger.records["com.example.a"] != nil, "if the Keychain refuses, the account is not reported removed")
		}
		world.secrets.failDeletes = false
		try! await directory.remove(current.confirm(.forgetRecords), ledger: &ledger)
		let registry = await directory.registry
		check(world.secrets.keys(of: gone).isEmpty && !world.secrets.hasRecord(gone) && world.secrets.hasRecord(keep)
			  && world.secrets.keys(of: keep).count == 2 && registry.account(gone) == nil,
			  "removal deletes all of that account's Keychain items and its record, and nothing of the other")
		check(registry.defaultScope == ZagSigningScope(accountID: keep, teamID: "SIMTEAM001"), "a removed default moves to a remaining account")
		check(Set(ledger.records.keys) == ["com.example.c"], "\"forget\" removes the account's refresh records only")
		let remaining = world.preferences.keys.filter { $0.contains(gone.uuidString) }
		check(remaining.isEmpty, "no summary of the removed account is left")
		let keepState = await directory.state(of: keep)
		check(signedIn(keepState) != nil, "the other account stays signed in")
	}

	// MARK: Refresh records by account

	// MARK: Reinstall: recovery and orphaned items (L1)

	/// Preferences are cleared by a reinstall; Keychain items may remain.
	static func reinstall() async {
		let world = World()
		let keys = ZagKeychainSigningKeys(namespace: ZagFreeAccountSimulation.accountsNamespace)
		let owner = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: world.directory)!
		let other = await SimulatedAccounts.signIn(SimulatedAccounts.second, to: world.directory)!
		try! world.secrets.save(Data("identity".utf8), kind: .signingPrivateKey, account: owner, team: "SIMTEAM001")
		_ = try! keys.create(account: owner, team: "SIMTEAM001", commonName: "Zag Test")
		defer { try? keys.deleteAll(account: owner) }

		let clock = world.clock
		let fresh = SimulatedAccounts.directory(now: { clock.now }, secrets: world.secrets, preferences: TestPreferences(), service: world.service).directory
		_ = await fresh.start()
		let emptyRegistry = await fresh.registry.accounts.isEmpty
		check(emptyRegistry && world.secrets.keys(of: owner).count == 2 && world.secrets.hasRecord(owner) && (try? keys.key(account: owner, team: "SIMTEAM001")) != nil,
			  "after a reinstall, nothing is deleted at launch")
		let found = try! await fresh.orphanedItems().accounts
		let ownerItems = found.first { $0.id == owner }, otherItems = found.first { $0.id == other }
		check(ownerItems?.isRecoverable == true && ownerItems?.maskedAppleID != nil && otherItems?.isRecoverable == true,
			  "earlier accounts' items are listed as recoverable by signing in, with the masked address only")

		let paid = await SimulatedAccounts.signIn(SimulatedAccounts.paid, to: fresh)!
		check(paid != owner && paid != other, "a sign-in to a different Apple Account never takes over an earlier account's items")

		// The user reviews a plan; meanwhile one account is recovered by signing in.
		let plan = try! await fresh.orphanedItems()
		let recovered = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: fresh)
		check(recovered == owner && (try? world.secrets.load(.signingPrivateKey, account: owner, team: "SIMTEAM001")) == Data("identity".utf8)
			  && (try? keys.key(account: owner, team: "SIMTEAM001")) != nil,
			  "signing in again to the same Apple Account recovers its account ID, identity and signing key")
		let removed = try! await fresh.removeOrphanedItems(plan)
		check(removed.removed.contains(other) && !removed.removed.contains(owner) && !removed.removed.contains(paid) && removed.skipped.contains(owner),
			  "cleanup removes only accounts still orphaned when it runs; one recovered meanwhile is reported as skipped")
		check(world.secrets.keys(of: other).isEmpty && !world.secrets.hasRecord(other) && world.secrets.keys(of: owner).count == 2
			  && world.secrets.keys(of: paid).count == 1,
			  "cleanup leaves recovered and registered accounts' items untouched")

		// Items with no ownership record are listed as unowned; only those confirmed go.
		let unownedKey = UUID(), unownedSecret = UUID()
		_ = try! keys.create(account: unownedKey, team: "SIMTEAM001", commonName: "Zag Test")
		_ = try! keys.create(account: unownedKey, team: "SIMTEAM002", slot: "PENDING1", commonName: "Zag Test")
		try! world.secrets.save(Data("x".utf8), kind: .session, account: unownedSecret, team: nil)
		let unowned = try! await fresh.orphanedItems()
		let keyOnly = unowned.accounts.first { $0.id == unownedKey }, secretOnly = unowned.accounts.first { $0.id == unownedSecret }
		check(keyOnly?.isRecoverable == false && secretOnly?.isRecoverable == false,
			  "Keychain key items and secrets with no ownership record are found, and listed as unowned")
		_ = try! await fresh.removeOrphanedItems(ZagOrphanedAccountItems(accounts: [keyOnly!]))
		check((try? keys.key(account: unownedKey, team: "SIMTEAM001")) == nil && (try? keys.key(account: unownedKey, team: "SIMTEAM002", slot: "PENDING1")) == nil
			  && world.secrets.keys(of: unownedSecret).count == 1,
			  "cleanup removes every key of the confirmed account (every team and slot), and nothing it was not asked to")
		_ = try! await fresh.removeOrphanedItems(ZagOrphanedAccountItems(accounts: [secretOnly!]))
		check(world.secrets.keys(of: unownedSecret).isEmpty, "a confirmed unowned account's secrets are removed")
	}

	/// Two ownership records naming the same Apple Account are ambiguous: neither
	/// is used. A sign-in in progress is never listed as orphaned.
	static func ambiguousRecords() async {
		let world = World()
		let other = await SimulatedAccounts.signIn(SimulatedAccounts.second, to: world.directory)!
		let copy = UUID()
		try! world.secrets.save(world.secrets.load(.accountRecord, account: other, team: nil)!, kind: .accountRecord, account: copy, team: nil)
		let clock = world.clock
		let fresh = SimulatedAccounts.directory(now: { clock.now }, secrets: world.secrets, preferences: TestPreferences(), service: world.service).directory
		_ = await fresh.start()
		let inProgress = await fresh.newSignIn()
		_ = await inProgress.signIn(appleID: SimulatedAccounts.second, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		let session = signedIn(await inProgress.state)
		check(session != nil && session?.accountID != other && session?.accountID != copy,
			  "with two records for one Apple Account, neither is recovered; a new account ID is used")
		let orphans = try! await fresh.orphanedItems().accounts.map(\.id)
		check(orphans.contains(other) && orphans.contains(copy) && !orphans.contains(session!.accountID),
			  "a sign-in in progress is never listed as orphaned")
	}

	// MARK: Aliases (fail closed)

	/// The simulation answers an unknown address with the tester's account, as
	/// an alias of it would be answered.
	static func aliases() async {
		let world = World()
		let tester = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: world.directory)!
		let alias = await world.directory.newSignIn()
		let state = await alias.signIn(appleID: "alias\(ZagFreeAccountSimulation.accountDomain)", password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		let count = await world.directory.registry.accounts.count
		let adopted = try? await world.directory.adopt(alias)
		if case .failed(let failure) = state {
			check(failure.kind == .addressNotRecognised && count == 1 && adopted == nil && world.secrets.keys(of: tester) == ["\(tester.uuidString).session"]
				  && Set(world.secrets.items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) == [tester],
				  "aliases: a known Apple Account reached through an unrecorded address is refused, not merged, and nothing is stored")
		} else {
			check(false, "aliases: \(state)")
		}
		let again = await SimulatedAccounts.signIn(" TESTER\(ZagFreeAccountSimulation.accountDomain.uppercased())", to: world.directory)
		check(again == tester, "aliases: the recorded address, in any case and with spaces, still signs in to the same account")
		let record = try! ZagAccountKeyIndex.record(of: tester, in: world.secrets)
		check(record?.addressKeys == [ZagAccountOwnershipRecord.addressKey(for: SimulatedAccounts.tester)]
			  && !(String(data: world.secrets.items["\(tester.uuidString).accountRecord"]!, encoding: .utf8)!.contains("tester")),
			  "aliases: the record keeps a hash of the address, never the address")
	}

	// MARK: Local (anisette) state, removed with the account

	final class FakeLocalState: ZagAccountLocalState, @unchecked Sendable {
		private let lock = NSLock()
		private var stored: Set<String> = []
		var failRemovals = false
		func scope(forAppleID appleID: String) -> String { "s" + ZagAccountOwnershipRecord.addressKey(for: appleID).prefix(16) }
		func create(_ scope: String) { lock.withLock { _ = stored.insert(scope) } }
		func has(_ scope: String) -> Bool { lock.withLock { stored.contains(scope) } }
		func scopes() throws -> Set<String> { lock.withLock { stored } }
		func remove(scope: String) throws {
			try lock.withLock {
				if failRemovals { throw ZagAccountError.storage }
				stored.remove(scope)
			}
		}
	}

	static func localStateLifecycle() async {
		let clock = TestClock(), secrets = MemorySecrets(), state = FakeLocalState()
		let (directory, _) = SimulatedAccounts.directory(now: { clock.now }, secrets: secrets, localState: state)
		let scope = state.scope(forAppleID: SimulatedAccounts.tester)
		state.create(scope) // as the bridge does while signing in
		let tester = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		let paid = await SimulatedAccounts.signIn(SimulatedAccounts.paid, to: directory)!
		let paidScope = state.scope(forAppleID: SimulatedAccounts.paid)
		state.create(paidScope)
		check(try! ZagAccountKeyIndex.record(of: tester, in: secrets)?.localStateScopes == [scope],
			  "local state: the account's anisette scope is recorded with it at sign-in")
		let stray = "sSTRAY0000000000"
		state.create(stray)
		let orphans = try! await directory.orphanedItems()
		check(orphans.localStateScopes == [stray], "local state: only state no account's record names is listed as orphaned")

		var ledger = ZagRefreshLedger()
		state.failRemovals = true
		let plan = try! await directory.removalPlan(for: tester, ledger: ledger)
		do {
			try await directory.remove(plan.confirm(.forgetRecords), ledger: &ledger)
			check(false, "local state: removal with a failing anisette store")
		} catch {
			let still = await directory.registry.account(tester)
			check(error as? ZagAccountError == .localStateNotRemoved && still != nil && secrets.hasRecord(tester) && state.has(scope),
				  "local state: if its anisette state cannot be removed, removal is reported as failed and the account and its record stay")
		}
		state.failRemovals = false
		try! await directory.remove(plan.confirm(.forgetRecords), ledger: &ledger)
		let gone = await directory.registry.account(tester)
		check(gone == nil && !state.has(scope) && !secrets.hasRecord(tester) && state.has(paidScope) && state.has(stray),
			  "local state: removing the account again finishes it: its anisette state goes, another account's stays")

		let result = try! await directory.removeOrphanedItems(ZagOrphanedAccountItems(accounts: [], localStateScopes: [stray, paidScope]))
		check(result.removedLocalState == [stray] && state.has(paidScope) && !state.has(stray),
			  "local state: cleanup removes confirmed orphaned state, never state an account's record names")
		_ = paid
	}

	// MARK: Cleanup revalidates ownership before deleting

	static func cleanupRevalidation() async {
		let world = World()
		let changing = UUID(), failing = UUID()
		try! world.secrets.save(Data("x".utf8), kind: .session, account: changing, team: nil)
		try! world.secrets.save(Data("y".utf8), kind: .session, account: failing, team: nil)
		let plan = try! await world.directory.orphanedItems()
		check(plan.accounts.contains { $0.id == changing && !$0.isRecoverable }, "revalidation: an unowned account is listed")
		// Its ownership changes after the user saw the plan.
		let record = try! JSONEncoder().encode(ZagAccountOwnershipRecord(accountKey: "k", maskedAppleID: "t•••@example.invalid"))
		try! world.secrets.save(record, kind: .accountRecord, account: changing, team: nil)
		world.secrets.failDeletes = true
		let result = try! await world.directory.removeOrphanedItems(plan)
		check(result.skipped.contains(changing) && world.secrets.keys(of: changing).count == 1,
			  "revalidation: an account whose ownership changed since confirmation is skipped, not deleted")
		check(result.failed.contains(failing) && world.secrets.keys(of: failing).count == 1,
			  "revalidation: a deletion the Keychain refuses is reported as failed and the items stay")
		world.secrets.failDeletes = false
		let retry = try! await world.directory.removeOrphanedItems(try! await world.directory.orphanedItems())
		check(retry.removed.contains(failing) && retry.removed.contains(changing) && world.secrets.keys(of: failing).isEmpty,
			  "revalidation: a later, newly confirmed cleanup finishes what failed")
	}

	static func unresolvedCertificateIsNotRetried() {
		check(ZagFreeAccountLifecycle.reason(for: .certificateRequestUnresolved) == .signingFailed,
			  "recovery: an unresolved certificate request is never retried automatically by background refresh")
	}

	// MARK: Unresolved certificate request: the user's recovery actions

	static func provisioning(_ world: World, _ account: UUID) -> (ZagSimulatedDeveloperPortal, ZagFreeAccountProvisioner, ZagProvisioningRequest) {
		let clock = world.clock
		let portal = ZagSimulatedDeveloperPortal(team: "SIMTEAM001", clock: { clock.now })
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: world.secrets, operationTimeout: 5, now: { clock.now })
		let request = ZagProvisioningRequest(
			accountID: account, team: "SIMTEAM001", deviceUDID: "00000000-0000000000000000", deviceName: "Test iPhone",
			app: .init(originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: try! ZagEntitlementSet([:])),
			extensions: [], installedFreeAccountApps: []
		)
		return (portal, provisioner, request)
	}

	static func submissions(_ portal: ZagSimulatedDeveloperPortal) async -> Int {
		await portal.calls.filter { $0 == .submitCertificateRequest }.count
	}

	@MainActor
	static func recoveryActions() async {
		let world = World()
		let directory = world.directory
		let tester = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		let scope = ZagSigningScope(accountID: tester, teamID: "SIMTEAM001")
		let (portal, provisioner, request) = provisioning(world, tester)
		await portal.fail(.submitCertificateRequest, with: .lostResponse)
		let lost = await provisioner.provision(request, authorization: try! await directory.authorize(scope))
		let model = ZagCertificateRecoveryModel(scope: scope, service: provisioner) { try await directory.authorize($0) }
		await model.load()
		check(lost.failureKind == .network && model.request?.attempts == 1 && model.phase == .idle,
			  "recovery: a lost certificate response is shown as an unresolved request")

		for _ in 0..<3 { await model.checkAgain() }
		let afterChecks = await submissions(portal)
		check(model.checks == 3 && model.outcome == .unresolved && model.request != nil && afterChecks == 1
			  && model.message?.contains("Nothing was requested or revoked") == true,
			  "recovery: repeated Check Again only reads the listing; it stays unresolved and nothing is requested")
		let again = await provisioner.provision(request, authorization: try! await directory.authorize(scope))
		let afterSigning = await submissions(portal)
		check(again.failureKind == .certificateRequestUnresolved && afterSigning == 1,
			  "recovery: signing again stops as unresolved and sends nothing (no retry)")

		// Cancelling Check Again while the listing is outstanding.
		await portal.fail(.certificates, with: .noResponse)
		let running = Task { await model.checkAgain() }
		for _ in 0..<200 where model.phase != .checking { await Task.yield() }
		try? await Task.sleep(nanoseconds: 50_000_000)
		model.cancelCheck()
		await running.value
		await portal.fail(.certificates, with: nil)
		let afterCancel = await submissions(portal)
		check(model.outcome == .checkFailed(.cancelled) && model.request != nil && model.phase == .idle && afterCancel == 1
			  && model.message?.contains("cancelled") == true,
			  "recovery: a cancelled Check Again changes nothing")

		// Signed out: Check Again cannot read the listing; Abandon still works.
		try! await directory.signOut(tester)
		await model.checkAgain()
		check(model.outcome == .checkFailed(.notAuthorized) && model.request != nil && model.message?.contains("sign in") == true,
			  "recovery: signed out, Check Again is refused and changes nothing")
		model.requestAbandon()
		check(model.phase == .confirmingAbandon, "recovery: Abandon asks for confirmation")
		model.cancelAbandon()
		check(model.phase == .idle && model.request != nil, "recovery: cancelling the confirmation abandons nothing")
		model.requestAbandon()
		await model.confirmAbandon()
		let afterAbandon = await submissions(portal)
		check(model.outcome == .abandoned && model.request == nil && afterAbandon == 1 && world.secrets.keys(of: tester).allSatisfy { !$0.contains("pendingSigningKey") }
			  && model.message?.contains("certificate slot") == true,
			  "recovery: confirmed Abandon (even signed out) removes the request only, warns of the occupied slot, and requests nothing")
		model.requestAbandon()
		let twice = await provisioner.abandonUnresolvedCertificateRequest(accountID: tester, team: "SIMTEAM001")
		check(model.phase == .idle && twice == .nothingPending, "recovery: with nothing unresolved there is nothing to abandon")

		// A provisioner bound to another account cannot see or act on it.
		let (otherPortal, _, _) = provisioning(world, tester)
		let bound = ZagFreeAccountProvisioner(portal: otherPortal, keys: ZagSimulatedSigningKeyFactory(), secrets: world.secrets, account: UUID())
		let foreign = await bound.abandonUnresolvedCertificateRequest(accountID: tester, team: "SIMTEAM001")
		let foreignView = await bound.unresolvedCertificateRequest(accountID: tester, team: "SIMTEAM001")
		check(foreign == .nothingPending && foreignView == nil, "recovery: another account's provisioner neither sees nor abandons the request")
	}

	// MARK: Stored Account Data model

	@MainActor
	static func storedDataModel() async {
		let world = World()
		let orphan = UUID()
		try! world.secrets.save(Data("x".utf8), kind: .session, account: orphan, team: nil)
		let model = ZagStoredAccountDataModel(source: world.directory)
		await model.load()
		check(model.data?.accounts.map(\.id) == [orphan] && model.pendingRemoval == nil, "stored data: loading lists leftovers and removes nothing")
		model.prepareRemoval(accounts: model.data!.accounts, scopes: [])
		model.cancelRemoval()
		await model.confirmRemoval()
		check(world.secrets.keys(of: orphan).count == 1 && model.result == nil, "stored data: nothing is removed without confirmation")
		model.prepareRemoval(accounts: model.data!.accounts, scopes: [])
		await model.confirmRemoval()
		check(world.secrets.keys(of: orphan).isEmpty && model.result == "Removed 1." && model.data?.isEmpty == true,
			  "stored data: a confirmed removal is reported and the list reloads")
		let partial = ZagStoredAccountDataModel.describe(ZagOrphanRemoval(removed: [UUID()], skipped: [UUID()], failed: [UUID()], failedLocalState: ["s1"]))
		check(partial == "Removed 1. 1 changed since you confirmed and was kept. 2 could not be removed and are still listed; try again.",
			  "stored data: partial failures and skipped items are reported, never hidden")
	}

	// MARK: Signed-out and expired accounts: removal stays local and safe

	static func signedOutAndExpiredRemoval() async {
		let clock = TestClock(), secrets = MemorySecrets(), state = FakeLocalState()
		let (directory, _) = SimulatedAccounts.directory(now: { clock.now }, secrets: secrets, localState: state)
		let scopeOut = state.scope(forAppleID: SimulatedAccounts.second), scopeExpired = state.scope(forAppleID: SimulatedAccounts.paid)
		state.create(scopeOut); state.create(scopeExpired)
		let out = await SimulatedAccounts.signIn(SimulatedAccounts.second, to: directory)!
		let expired = await SimulatedAccounts.signIn(SimulatedAccounts.paid, to: directory)!
		try! await directory.signOut(out)
		let orphans = try! await directory.orphanedItems()
		check(orphans.isEmpty, "signed out: a registered account's items are never listed as orphaned, signed in or not")
		var ledger = ZagRefreshLedger()
		try! await directory.remove(try! await directory.removalPlan(for: out, ledger: ledger).confirm(.forgetRecords), ledger: &ledger)
		check(!state.has(scopeOut) && secrets.keys(of: out).isEmpty && state.has(scopeExpired),
			  "signed out: removing a signed-out account removes its items and anisette state, and only those")
		clock.advance(days: 31)
		let lapsed: Bool
		if case .some(.signedIn(let session)) = await directory.state(of: expired) { lapsed = session.isExpired(at: clock.now) } else { lapsed = true }
		try! await directory.remove(try! await directory.removalPlan(for: expired, ledger: ledger).confirm(.forgetRecords), ledger: &ledger)
		check(lapsed && !state.has(scopeExpired) && secrets.keys(of: expired).isEmpty,
			  "expired: removing an account whose session expired works locally and removes its anisette state")
	}

	static func ledgerOwnership() {
		let now = Date(timeIntervalSince1970: 1_795_000_000)
		let a = ZagSigningScope(accountID: UUID(), teamID: "SIMTEAM001"), b = ZagSigningScope(accountID: UUID(), teamID: "SIMTEAM002")
		func app(_ bundle: String, _ scope: ZagSigningScope?, kind: ZagDeveloperTeam.Kind = .personalFree) -> ZagSignedAppRecord {
			ZagSignedAppRecord(bundleIdentifier: bundle, originalBundleIdentifier: bundle, signedAt: now, profileExpiresAt: now + 7 * 86_400,
							   certificateExpiresAt: now + 300 * 86_400,
							   owner: scope.map { ZagAppOwnership(scope: $0, teamKind: kind, certificateSerial: "01", profileUUID: "P") })
		}
		var ledger = ZagRefreshLedger()
		ledger.record(app("a.one", a)); ledger.record(app("b.one", b)); ledger.record(app("legacy", nil)); ledger.record(app("paid", b, kind: .individualPaid))
		for bundle in ["a.one", "b.one"] {
			_ = ledger.begin(bundle, at: now, userInitiated: true)
			ledger.finishFailed(bundle, reason: .signedOut, at: now)
		}
		ledger.resolve(.signedOut, account: a.accountID)
		check(ledger.records["a.one"]?.lastFailure == nil && ledger.records["b.one"]?.lastFailure?.reason == .signedOut,
			  "signing in to one account releases only its apps")
		check(ledger.apps(ownedBy: b.accountID) == ["b.one", "paid"] && ledger.refreshAllOrder(at: now + 6 * 86_400, account: a.accountID) == ["a.one"],
			  "apps and Refresh All can be listed per account")
		check(ledger.freeAppLimitApps == ["a.one", "b.one", "legacy"], "free-team apps of every account (and unowned ones) count towards the device's limit")
		let schedule = ledger.schedule(at: now)
		check(schedule.first { $0.bundleIdentifier == "legacy" }?.needsUser == true && schedule.first { $0.bundleIdentifier == "b.one" }?.needsUser == true
			  && schedule.first { $0.bundleIdentifier == "a.one" }?.needsUser == false,
			  "the schedule waits for the user on unowned and signed-out apps only")
		ledger.detach(account: b.accountID, at: now)
		check(ledger.schedule(at: now).map(\.bundleIdentifier).sorted() == ["a.one", "legacy"] && ledger.begin("b.one", at: now, userInitiated: true) == .ownerRemoved,
			  "a removed account's apps leave the schedule and cannot be started")

		let encoded = try! JSONEncoder().encode(ledger.records["a.one"]!)
		check(try! JSONDecoder().decode(ZagSignedAppRecord.self, from: encoded) == ledger.records["a.one"], "records keep their owner when stored")
		var old = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
		old["owner"] = nil
		let decoded = try? JSONDecoder().decode(ZagSignedAppRecord.self, from: JSONSerialization.data(withJSONObject: old))
		check(decoded != nil && decoded?.owner == nil, "records from before multi-account support still load, with no owner")

		// On disk: atomic, recovered after a crash, and an unreadable file kept aside.
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zag-ledger-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let store = ZagRefreshLedgerStore(file: folder.appendingPathComponent("ledger.json"))
		check(store.load(at: now).1 == .empty, "no file: an empty ledger")
		var running = ledger
		_ = running.begin("a.one", at: now, userInitiated: true)
		try! store.save(running)
		let (reloaded, result) = store.load(at: now + 60)
		check(result == .loaded(reloaded) && reloaded.running.isEmpty && reloaded.records["a.one"]?.lastFailure?.reason == .interrupted
			  && reloaded.records["b.one"]?.ownerRemovedAt == now && reloaded.records["a.one"]?.owner?.scope == a,
			  "records and owners survive a relaunch; a refresh cut off by it is marked interrupted")
		try! Data("{ not json".utf8).write(to: store.file)
		if case .recovered(let aside) = store.load(at: now).1 {
			check(FileManager.default.fileExists(atPath: aside.path) && !FileManager.default.fileExists(atPath: store.file.path),
				  "an unreadable ledger is kept aside, not overwritten, and nothing is guessed")
		} else { check(false, "corrupt ledger") }
	}

	static func limits() {
		check(ZagTeamLimits.forTeam(.personalFree) == .free && ZagTeamLimits.forTeam(.unknown) == .free && ZagTeamLimits.forTeam(.organization) == .paid,
			  "free limits apply to Personal Teams (and unknown teams); paid limits to paid teams")
		check(ZagTeamLimits.free.appIDs == 10 && ZagTeamLimits.free.devicesPerPlatform == 3 && ZagTeamLimits.free.countsTowardsFreeAppLimit
			  && ZagTeamLimits.paid.devicesPerPlatform == 100 && !ZagTeamLimits.paid.countsTowardsFreeAppLimit,
			  "the published limits: 10 App IDs and 3 devices for free teams, 100 devices per platform for paid teams")
		check(ZagKeychainFreeAccountSecretStore.itemName(.signingPrivateKey, account: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, team: "SIMTEAM001")
			  == "00000000-0000-4000-8000-000000000001.signingPrivateKey.SIMTEAM001", "Keychain items are named by account, kind and team")
	}
}

extension Result where Failure == ZagProvisioningFailure {
	var failureKind: ZagProvisioningFailure.Kind? {
		if case .failure(let failure) = self { return failure.kind }
		return nil
	}
}
