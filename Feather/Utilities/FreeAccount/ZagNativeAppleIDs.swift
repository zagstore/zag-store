import Foundation

struct ZagNativeAppleID: Identifiable, Codable, Equatable, Sendable {
	let id: UUID
	var email: String?
	var teams: [ZagDeveloperTeam] = []
	var label: String { email ?? "Apple ID" }
}

struct ZagNativeAppleIDCatalog: Codable, Equatable, Sendable {
	var accounts: [ZagNativeAppleID] = []
	var activeID: UUID?
	// Read the previous persisted field once, then store only activeID.
	var defaultID: UUID?
	var signedOutAccounts: [ZagNativeAppleID]?
	var pendingSignOuts: Set<UUID>?
	var migratedLegacy = false
	var verifiedLegacyCredentials: Bool?

	mutating func register(id: UUID, email: String?) {
		if let index = accounts.firstIndex(where: { $0.id == id }) {
			if let email { accounts[index].email = email }
		} else {
			accounts.append(.init(id: id, email: email))
		}
		signedOutAccounts?.removeAll { $0.id == id }
	}

	mutating func forget(_ account: ZagNativeAppleID) {
		accounts.removeAll { $0.id == account.id }
		var recovery = signedOutAccounts ?? []
		recovery.removeAll { $0.id == account.id }
		recovery.append(.init(id: account.id, email: account.email))
		signedOutAccounts = recovery
		if activeID == account.id { activeID = nil }
	}
}

protocol ZagNativeAppleIDVault {
	func catalog() throws -> ZagNativeAppleIDCatalog
	func saveCatalog(_ value: ZagNativeAppleIDCatalog) throws
	func token(_ scope: String) throws -> ZagPersistedDeveloperToken?
	func saveToken(_ value: ZagPersistedDeveloperToken, scope: String) throws
	func session(_ scope: String) throws -> Data?
	func saveSession(_ value: Data, scope: String) throws
	func deleteToken(_ scope: String) throws
	func deleteSession(_ scope: String) throws
}

extension ZagNativeAppleIDVault {
	func deleteCredentials(_ scope: String) throws {
		var failure: Error?
		do { try deleteToken(scope) } catch { failure = error }
		do { try deleteSession(scope) } catch { if failure == nil { failure = error } }
		if let failure { throw failure }
	}
}

struct ZagNativeAppleIDKeychain: ZagNativeAppleIDVault {
	private let storage = ZagKeychainFreeAccountSecretStore(service: "app.zagstore.native-apple-id.catalog")
	private let catalogID = UUID(uuidString: "ED955B2B-E85B-4CDE-A1FB-DEA22FE34FBC")!

	func catalog() throws -> ZagNativeAppleIDCatalog {
		guard let data = try storage.load(.accountRecord, account: catalogID) else { return .init() }
		return try JSONDecoder().decode(ZagNativeAppleIDCatalog.self, from: data)
	}

	func saveCatalog(_ value: ZagNativeAppleIDCatalog) throws {
		try storage.save(JSONEncoder().encode(value), kind: .accountRecord, account: catalogID)
	}

	func token(_ scope: String) throws -> ZagPersistedDeveloperToken? { try ZagDeveloperTokenStore().read(scope: scope) }
	func saveToken(_ value: ZagPersistedDeveloperToken, scope: String) throws {
		try ZagDeveloperTokenStore().save(value, scope: scope)
	}
	func session(_ scope: String) throws -> Data? { try ZagAppleAuthSessionStore().read(scope: scope) }
	func saveSession(_ value: Data, scope: String) throws {
		try ZagAppleAuthSessionStore().save(value, scope: scope)
	}
	func deleteToken(_ scope: String) throws { try ZagDeveloperTokenStore().delete(scope: scope) }
	func deleteSession(_ scope: String) throws { try ZagAppleAuthSessionStore().delete(scope: scope) }
}

/// Serialises catalog writes on the main actor. Engine requests carry a
/// snapshot of their own account token and use a separate device ADI scope.
@MainActor
struct ZagNativeAppleIDs {
	enum Failure: LocalizedError {
		case wrongAccount, unavailable, storage

		var errorDescription: String? {
			switch self {
			case .wrongAccount: "This Apple ID does not match the one selected for signing."
			case .unavailable: "Connect this Apple ID to continue."
			case .storage: "The Apple ID session could not be verified in the Keychain."
			}
		}
	}

	static let shared = Self(vault: ZagNativeAppleIDKeychain())
	private static var activeReconciliationHolds = 0

	func withStableActiveSelection<T>(_ operation: @MainActor () async -> T) async -> T {
		Self.activeReconciliationHolds += 1
		defer {
			Self.activeReconciliationHolds -= 1
			if Self.activeReconciliationHolds == 0 { _ = try? catalog() }
		}
		return await operation()
	}
	let vault: ZagNativeAppleIDVault

	nonisolated static func scope(_ id: UUID) -> String { ZagAppleAuthMachine.nativeCredentialScope(id) }

	func catalog() throws -> ZagNativeAppleIDCatalog {
		var catalog = try vault.catalog()
		let original = catalog
		for id in catalog.pendingSignOuts ?? [] {
			if (try? clearCredentials(id)) != nil { catalog.pendingSignOuts?.remove(id) }
		}
		if catalog.pendingSignOuts?.isEmpty == true { catalog.pendingSignOuts = nil }
		try migrateLegacy(&catalog)
		catalog.activeID = catalog.activeID ?? catalog.defaultID
		catalog.defaultID = nil
		for account in catalog.accounts {
			let scope = Self.scope(account.id)
			if try vault.token(scope) == nil, try vault.session(scope) == nil {
				catalog.forget(account)
			}
		}
		try updateActiveSelection(&catalog)
		if catalog != original { try vault.saveCatalog(catalog) }
		return catalog
	}

	private func migrateLegacy(_ catalog: inout ZagNativeAppleIDCatalog) throws {
		guard catalog.verifiedLegacyCredentials != true, let legacy = try vault.token("device") else { return }
		let id = legacy.nativeAccountID
		guard catalog.signedOutAccounts?.contains(where: { $0.id == id }) != true else { return }
		let destination = Self.scope(id)
		let currentToken = try vault.token(destination)
		// A catalog from the previous build may have been committed before
		// the session copy. Repair only a still-listed account with credentials.
		if catalog.migratedLegacy {
			guard catalog.accounts.contains(where: { $0.id == id }), currentToken != nil else { return }
		}
		guard currentToken == nil || currentToken?.nativeAccountID == id else { throw Failure.storage }
		let legacySession = try vault.session("device")
		let currentSession = try vault.session(destination)
		try copyCredentials(to: destination, token: currentToken ?? legacy,
			session: currentSession ?? legacySession, previous: (currentToken, currentSession)) {
			catalog.register(id: id, email: nil)
			catalog.migratedLegacy = true
			catalog.verifiedLegacyCredentials = true
			try vault.saveCatalog(catalog)
		}
	}

	private func usableToken(_ id: UUID, now: Date = Date()) throws -> ZagPersistedDeveloperToken? {
		guard let token = try vault.token(Self.scope(id)), token.nativeAccountID == id,
			  token.isUsable(at: now) else { return nil }
		return token
	}

	private func updateActiveSelection(_ catalog: inout ZagNativeAppleIDCatalog) throws {
		guard Self.activeReconciliationHolds == 0 else { return }
		let authenticated = try catalog.accounts.filter { try usableToken($0.id) != nil }
		if !authenticated.contains(where: { $0.id == catalog.activeID }) {
			catalog.activeID = authenticated.count == 1 ? authenticated.first?.id : nil
		}
	}

	func accountForAuthentication(_ id: UUID) throws -> ZagNativeAppleID {
		let catalog = try catalog()
		return catalog.accounts.first { $0.id == id }
			?? catalog.signedOutAccounts?.first { $0.id == id }
			?? .init(id: id, email: nil)
	}

	func connectedToken(_ id: UUID, now: Date = Date()) -> ZagPersistedDeveloperToken? {
		guard (try? catalog().accounts.contains { $0.id == id }) == true else { return nil }
		return try? usableToken(id, now: now)
	}

	func completeAuthentication(temporaryScope: String, email: String, expected: UUID?, attempt: ZagNativeAuthenticationAttempt) throws -> UUID {
		try attempt.checkpoint()
		var catalog = try catalog()
		guard let token = try vault.token(temporaryScope), token.isUsable(at: Date()),
			  let session = try vault.session(temporaryScope), !session.isEmpty else { throw Failure.storage }
		let id = token.nativeAccountID
		guard catalog.pendingSignOuts?.contains(id) != true else { throw Failure.storage }
		if let expected, expected != id { throw Failure.wrongAccount }
		let destination = Self.scope(id)
		let previous = (try vault.token(destination), try vault.session(destination))
		try copyCredentials(to: destination, token: token, session: session, previous: previous) {
			try attempt.checkpoint()
			catalog.register(id: id, email: email.isEmpty ? nil : email)
			try updateActiveSelection(&catalog)
			catalog.migratedLegacy = true
			try vault.saveCatalog(catalog)
		}
		return id
	}

	/// Accept only an already live-validated, expiring developer token into
	/// an empty catalog. No raw GrandSlam session is imported, and existing
	/// accounts or signed-out identities are never overwritten or resurrected.
	func importValidatedDesktopToken(_ token: ZagPersistedDeveloperToken, email: String?,
									 teams: [ZagDeveloperTeam]) throws -> UUID {
		var catalog = try catalog()
		let id = token.nativeAccountID
		let destination = Self.scope(id)
		guard token.expiresAtMs > 0, token.isUsable(at: Date()),
			  catalog.accounts.isEmpty,
			  catalog.signedOutAccounts?.contains(where: { $0.id == id }) != true,
			  catalog.pendingSignOuts?.isEmpty != false,
			  try vault.token(destination) == nil, try vault.session(destination) == nil else { throw Failure.storage }
		try copyCredentials(to: destination, token: token, session: nil, previous: (nil, nil)) {
			catalog.register(id: id, email: email)
			catalog.accounts[0].teams = teams
			catalog.activeID = id
			catalog.migratedLegacy = true
			try vault.saveCatalog(catalog)
		}
		return id
	}

	private func copyCredentials(to scope: String, token: ZagPersistedDeveloperToken, session: Data?,
		previous: (token: ZagPersistedDeveloperToken?, session: Data?), commit: () throws -> Void) throws {
		var sessionWritten = false
		var tokenWritten = false
		do {
			if let session, session != previous.session {
				try vault.saveSession(session, scope: scope)
				sessionWritten = true
			}
			if token != previous.token {
				try vault.saveToken(token, scope: scope)
				tokenWritten = true
			}
			guard try vault.session(scope) == session, try vault.token(scope) == token else { throw Failure.storage }
			try commit()
		} catch {
			if tokenWritten {
				if let token = previous.token { try? vault.saveToken(token, scope: scope) }
				else { try? vault.deleteToken(scope) }
			}
			if sessionWritten {
				if let session = previous.session { try? vault.saveSession(session, scope: scope) }
				else { try? vault.deleteSession(scope) }
			}
			throw error
		}
	}

	func invalidate(_ token: ZagPersistedDeveloperToken) throws {
		let scope = Self.scope(token.nativeAccountID)
		guard try vault.token(scope) == token else { return }
		try vault.saveToken(.init(accountID: token.accountID, token: token.token, expiresAtMs: -1), scope: scope)
	}

	func activate(_ id: UUID) throws {
		var catalog = try catalog()
		guard catalog.accounts.contains(where: { $0.id == id }), try usableToken(id) != nil else { throw Failure.unavailable }
		catalog.activeID = id
		try vault.saveCatalog(catalog)
	}

	func storeTeams(_ teams: [ZagDeveloperTeam], for id: UUID) throws {
		var catalog = try catalog()
		guard let index = catalog.accounts.firstIndex(where: { $0.id == id }) else { return }
		catalog.accounts[index].teams = teams
		try vault.saveCatalog(catalog)
	}

	private func clearCredentials(_ id: UUID) throws {
		try vault.deleteCredentials(Self.scope(id))
		if try vault.token("device")?.nativeAccountID == id {
			// Keep the token as attribution if the session deletion needs retrying.
			try vault.deleteSession("device")
			try vault.deleteToken("device")
		}
	}

	func signOut(_ id: UUID) throws {
		var catalog = try catalog()
		guard let account = catalog.accounts.first(where: { $0.id == id }) else { return }
		catalog.forget(account)
		catalog.pendingSignOuts = (catalog.pendingSignOuts ?? []).union([id])
		try updateActiveSelection(&catalog)
		// Persist the removal before touching credentials so an interrupted
		// sign-out cannot resurrect the account or activate it on relaunch.
		try vault.saveCatalog(catalog)
		try clearCredentials(id)
		catalog.pendingSignOuts?.remove(id)
		if catalog.pendingSignOuts?.isEmpty == true { catalog.pendingSignOuts = nil }
		try vault.saveCatalog(catalog)
	}
}

/// Cancellation stays attached to the attempt until the synchronous engine
/// worker returns. A cancelled worker cannot commit staged credentials.
@MainActor
final class ZagNativeAuthenticationAttempt {
	private(set) var cancelled = false
	func cancel() { cancelled = true }
	func checkpoint() throws {
		if cancelled || Task.isCancelled { throw CancellationError() }
	}
}
