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
	func token(_ scope: String) -> ZagPersistedDeveloperToken?
	func saveToken(_ value: ZagPersistedDeveloperToken, scope: String) throws
	func session(_ scope: String) -> Data?
	func saveSession(_ value: Data, scope: String) throws
	func deleteCredentials(_ scope: String) throws
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

	func token(_ scope: String) -> ZagPersistedDeveloperToken? { ZagDeveloperTokenStore().load(scope: scope) }
	func saveToken(_ value: ZagPersistedDeveloperToken, scope: String) throws {
		try ZagDeveloperTokenStore().save(value, scope: scope)
	}
	func session(_ scope: String) -> Data? { ZagAppleAuthSessionStore().load(scope: scope) }
	func saveSession(_ value: Data, scope: String) throws {
		try ZagAppleAuthSessionStore().save(value, scope: scope)
	}
	func deleteCredentials(_ scope: String) throws {
		try ZagDeveloperTokenStore().delete(scope: scope)
		try ZagAppleAuthSessionStore().delete(scope: scope)
	}
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
		guard !catalog.migratedLegacy, let legacy = vault.token("device") else { return catalog }
		let id = legacy.nativeAccountID
		if vault.token(Self.scope(id)) == nil { try copyCredentials(from: "device", token: legacy) }
		guard vault.token(Self.scope(id))?.nativeAccountID == id else { throw Failure.storage }
		catalog.register(id: id, email: nil)
		catalog.migratedLegacy = true
		try vault.saveCatalog(catalog)
		return catalog
	}

	func connectedToken(_ id: UUID, now: Date = Date()) -> ZagPersistedDeveloperToken? {
		guard (try? catalog().accounts.contains { $0.id == id }) == true,
			  let token = vault.token(Self.scope(id)), token.nativeAccountID == id, token.isUsable(at: now) else { return nil }
		return token
	}

	func completeAuthentication(temporaryScope: String, email: String, expected: UUID?) throws -> UUID {
		var catalog = try catalog()
		guard let token = vault.token(temporaryScope), token.isUsable(at: Date()) else { throw Failure.storage }
		let id = token.nativeAccountID
		if let expected, expected != id || !catalog.accounts.contains(where: { $0.id == expected }) { throw Failure.wrongAccount }
		try copyCredentials(from: temporaryScope, token: token)
		catalog.register(id: id, email: email.isEmpty ? nil : email)
		catalog.migratedLegacy = true
		try vault.saveCatalog(catalog)
		return id
	}

	private func copyCredentials(from source: String, token: ZagPersistedDeveloperToken) throws {
		let destination = Self.scope(token.nativeAccountID)
		if let session = vault.session(source) {
			try vault.saveSession(session, scope: destination)
			guard vault.session(destination) == session else { throw Failure.storage }
		}
		try vault.saveToken(token, scope: destination)
		guard vault.token(destination) == token else { throw Failure.storage }
	}

	func invalidate(_ token: ZagPersistedDeveloperToken) throws {
		let scope = Self.scope(token.nativeAccountID)
		guard vault.token(scope) == token else { return }
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
		if vault.token("device")?.nativeAccountID == id { try vault.deleteCredentials("device") }
	}

	func remove(_ id: UUID) throws {
		var catalog = try catalog()
		try signOut(id)
		catalog.remove(id)
		try vault.saveCatalog(catalog)
	}
}
