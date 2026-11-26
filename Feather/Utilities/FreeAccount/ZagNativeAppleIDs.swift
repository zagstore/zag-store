import Foundation

struct ZagNativeAppleID: Identifiable, Codable, Equatable, Sendable {
	let id: UUID
	var email: String?
	var teams: [ZagDeveloperTeam] = []
	var label: String { email ?? "Existing Apple ID" }
}

struct ZagNativeAppleIDCatalog: Codable, Equatable, Sendable {
	var accounts: [ZagNativeAppleID] = []
	var defaultID: UUID?
	var migratedLegacy = false
	var verifiedLegacyCredentials: Bool?

	mutating func register(id: UUID, email: String?) {
		if let index = accounts.firstIndex(where: { $0.id == id }) {
			if let email { accounts[index].email = email }
		} else {
			accounts.append(.init(id: id, email: email))
		}
		if defaultID == nil { defaultID = id }
	}

	mutating func remove(_ id: UUID) {
		accounts.removeAll { $0.id == id }
		if defaultID == id { defaultID = accounts.first?.id }
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
	let vault: ZagNativeAppleIDVault

	nonisolated static func scope(_ id: UUID) -> String { ZagAppleAuthMachine.nativeCredentialScope(id) }

	func catalog() throws -> ZagNativeAppleIDCatalog {
		var catalog = try vault.catalog()
		guard catalog.verifiedLegacyCredentials != true, let legacy = try vault.token("device") else { return catalog }
		let id = legacy.nativeAccountID
		let destination = Self.scope(id)
		let currentToken = try vault.token(destination)
		// A catalog from the previous build may have been committed before
		// the session copy. Repair only a still-listed account with credentials.
		if catalog.migratedLegacy {
			guard catalog.accounts.contains(where: { $0.id == id }), currentToken != nil else { return catalog }
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
		return catalog
	}

	func connectedToken(_ id: UUID, now: Date = Date()) -> ZagPersistedDeveloperToken? {
		guard (try? catalog().accounts.contains { $0.id == id }) == true,
			  let token = try? vault.token(Self.scope(id)), token.nativeAccountID == id, token.isUsable(at: now) else { return nil }
		return token
	}

	func completeAuthentication(temporaryScope: String, email: String, expected: UUID?, attempt: ZagNativeAuthenticationAttempt) throws -> UUID {
		try attempt.checkpoint()
		var catalog = try catalog()
		guard let token = try vault.token(temporaryScope), token.isUsable(at: Date()),
			  let session = try vault.session(temporaryScope), !session.isEmpty else { throw Failure.storage }
		let id = token.nativeAccountID
		if let expected, expected != id || !catalog.accounts.contains(where: { $0.id == expected }) { throw Failure.wrongAccount }
		let destination = Self.scope(id)
		let previous = (try vault.token(destination), try vault.session(destination))
		try copyCredentials(to: destination, token: token, session: session, previous: previous) {
			try attempt.checkpoint()
			catalog.register(id: id, email: email.isEmpty ? nil : email)
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

	func setDefault(_ id: UUID) throws {
		var catalog = try catalog()
		guard catalog.accounts.contains(where: { $0.id == id }) else { throw Failure.unavailable }
		catalog.defaultID = id
		try vault.saveCatalog(catalog)
	}

	func storeTeams(_ teams: [ZagDeveloperTeam], for id: UUID) throws {
		var catalog = try catalog()
		guard let index = catalog.accounts.firstIndex(where: { $0.id == id }) else { return }
		catalog.accounts[index].teams = teams
		try vault.saveCatalog(catalog)
	}

	func signOut(_ id: UUID) throws {
		_ = try catalog()
		try vault.deleteCredentials(Self.scope(id))
		if try vault.token("device")?.nativeAccountID == id { try vault.deleteCredentials("device") }
	}

	func remove(_ id: UUID) throws {
		var catalog = try catalog()
		try signOut(id)
		catalog.remove(id)
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
