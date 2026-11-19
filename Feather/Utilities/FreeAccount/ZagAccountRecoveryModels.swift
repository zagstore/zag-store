import Foundation
import Combine

// The two recovery screens of Apple Accounts, compiled in every build:
// Stored Account Data (leftover Keychain items and anisette state) and an
// unresolved certificate request. Release builds reach them only when the
// Apple Accounts feature is enabled, which it is not in this version.

/// The Apple Accounts feature in Release builds. Off: Settings shows none of
/// its screens. Debug builds reach the same screens through the simulated
/// Apple Accounts screen.
enum ZagAppleAccountsFeature {
	static let isEnabled = false

	/// The production account directory (this app's own Keychain service and
	/// namespace). Creating it reads the registry only; nothing is removed.
	static func makeDirectory() -> ZagAccountDirectory {
		ZagAccountDirectory(
			anisette: ZagNoAnisetteSource(),
			secrets: ZagKeychainFreeAccountSecretStore(),
			preferences: ZagUserDefaultsPreferences()
		)
	}
}

/// The recovery screens never sign in, so they get no anisette data.
private struct ZagNoAnisetteSource: ZagAnisetteSource {
	func anisetteData() async throws -> ZagAnisetteData { throw ZagAnisetteError.liveProvidersDisabled }
}

// MARK: - Stored Account Data

protocol ZagStoredAccountDataSource: Sendable {
	func orphanedItems() async throws -> ZagOrphanedAccountItems
	func removeOrphanedItems(_ confirmed: ZagOrphanedAccountItems) async throws -> ZagOrphanRemoval
}

extension ZagAccountDirectory: ZagStoredAccountDataSource {}

/// Lists leftover items when the screen asks, and removes only what the user
/// confirmed. The directory checks each item again just before deleting it.
@MainActor
final class ZagStoredAccountDataModel: ObservableObject {
	/// What was found when last loaded; nil until then, or if reading failed.
	@Published private(set) var data: ZagOrphanedAccountItems?
	/// What the user chose to remove, awaiting confirmation.
	@Published private(set) var pendingRemoval: ZagOrphanedAccountItems?
	@Published private(set) var result: String?
	@Published private(set) var failed = false
	private let source: ZagStoredAccountDataSource

	init(source: ZagStoredAccountDataSource) {
		self.source = source
	}

	func load() async {
		do {
			data = try await source.orphanedItems()
			failed = false
		} catch {
			data = nil
			failed = true
		}
	}

	func prepareRemoval(accounts: [ZagOrphanedAccountItems.Account], scopes: [String]) {
		guard !accounts.isEmpty || !scopes.isEmpty else { return }
		result = nil
		pendingRemoval = ZagOrphanedAccountItems(accounts: accounts, localStateScopes: scopes)
	}

	func cancelRemoval() { pendingRemoval = nil }

	func confirmRemoval() async {
		guard let confirmed = pendingRemoval else { return }
		pendingRemoval = nil
		do {
			result = Self.describe(try await source.removeOrphanedItems(confirmed))
		} catch {
			result = "Nothing was removed: stored data could not be checked."
		}
		await load()
	}

	static func describe(_ removal: ZagOrphanRemoval) -> String {
		let removed = removal.removed.count + removal.removedLocalState.count
		let failed = removal.failed.count + removal.failedLocalState.count
		var parts = ["Removed \(removed)."]
		if !removal.skipped.isEmpty {
			parts.append("\(removal.skipped.count) changed since you confirmed and \(removal.skipped.count == 1 ? "was" : "were") kept.")
		}
		if failed > 0 { parts.append("\(failed) could not be removed and \(failed == 1 ? "is" : "are") still listed; try again.") }
		return parts.joined(separator: " ")
	}
}

// MARK: - Unresolved certificate request

protocol ZagCertificateRecoveryService: Sendable {
	func unresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagUnresolvedCertificateRequest?
	func checkUnresolvedCertificateRequest(accountID: UUID, team: String, authorization: ZagSigningAuthorization) async -> ZagCertificateRecoveryOutcome
	func abandonUnresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagCertificateRecoveryOutcome
}

extension ZagFreeAccountProvisioner: ZagCertificateRecoveryService {}

/// The two actions for a certificate request whose outcome is unknown:
/// Check Again (reads the certificate listing only) and Abandon (after
/// confirmation). Neither requests nor revokes a certificate, and nothing
/// here runs by itself.
@MainActor
final class ZagCertificateRecoveryModel: ObservableObject {
	enum Phase: Equatable {
		case idle
		case checking
		case confirmingAbandon
		case abandoning
	}

	let scope: ZagSigningScope
	@Published private(set) var request: ZagUnresolvedCertificateRequest?
	@Published private(set) var phase: Phase = .idle
	@Published private(set) var outcome: ZagCertificateRecoveryOutcome?
	/// Completed Check Again runs, for the screen and tests.
	@Published private(set) var checks = 0
	private let service: ZagCertificateRecoveryService
	private let authorize: @Sendable (ZagSigningScope) async throws -> ZagSigningAuthorization
	private var checkTask: Task<ZagCertificateRecoveryOutcome, Never>?

	init(
		scope: ZagSigningScope,
		service: ZagCertificateRecoveryService,
		authorize: @escaping @Sendable (ZagSigningScope) async throws -> ZagSigningAuthorization
	) {
		self.scope = scope
		self.service = service
		self.authorize = authorize
	}

	func load() async {
		request = await service.unresolvedCertificateRequest(accountID: scope.accountID, team: scope.teamID)
	}

	/// Reads the team's certificate listing. Signed out: reported, nothing
	/// changes (Abandon still works).
	func checkAgain() async {
		guard phase == .idle else { return }
		phase = .checking
		let scope = scope, service = service, authorize = authorize
		let task = Task { () -> ZagCertificateRecoveryOutcome in
			guard let authorization = try? await authorize(scope) else { return .checkFailed(.notAuthorized) }
			if Task.isCancelled { return .checkFailed(.cancelled) }
			return await service.checkUnresolvedCertificateRequest(accountID: scope.accountID, team: scope.teamID, authorization: authorization)
		}
		checkTask = task
		outcome = await task.value
		checkTask = nil
		checks += 1
		await load()
		phase = .idle
	}

	func cancelCheck() { checkTask?.cancel() }

	func requestAbandon() {
		guard phase == .idle, request != nil else { return }
		outcome = nil
		phase = .confirmingAbandon
	}

	func cancelAbandon() {
		if phase == .confirmingAbandon { phase = .idle }
	}

	func confirmAbandon() async {
		guard phase == .confirmingAbandon else { return }
		phase = .abandoning
		outcome = await service.abandonUnresolvedCertificateRequest(accountID: scope.accountID, team: scope.teamID)
		await load()
		phase = .idle
	}

	var message: String? {
		guard let outcome else { return nil }
		switch outcome {
		case .recovered:
			return "Recovered. The certificate Apple issued for the interrupted request is now used. No new certificate was requested."
		case .notIssued:
			return "Resolved. Apple did not issue a certificate for that request, so signing can send it again."
		case .unresolved:
			return "Still unresolved. Apple's certificate list does not show whether the request succeeded. Nothing was requested or revoked."
		case .abandoned:
			return "Request abandoned. The next signing requests a new certificate. If Apple issued one for the abandoned request, it still uses a certificate slot until it expires or you revoke it."
		case .nothingPending:
			return "There is no unresolved certificate request for this team."
		case .checkFailed(.notAuthorized), .checkFailed(.sessionRejected):
			return "Could not check: sign in to this Apple Account first. Nothing was changed."
		case .checkFailed(.cancelled):
			return "Check cancelled. Nothing was changed."
		case .checkFailed(let kind):
			return "Could not check. \(ZagProvisioningFailure(kind: kind, step: .certificate).message) Nothing was changed."
		}
	}

	/// Whether the last action left the request settled one way or another.
	var isSettled: Bool {
		switch outcome {
		case .recovered, .notIssued, .abandoned, .nothingPending: return true
		default: return false
		}
	}
}
