import Foundation

// The orchestration layer that connects the pure ZagCertificateReplacementCoordinator
// to the live developer-services client, the mutation-consent coordinator and a
// durable journal. It performs the two Apple mutations (revoke, then CSR) ONLY
// between the coordinator's gates, persisting the journal before every network
// step so an interruption is always recoverable. It reuses the existing portal
// operations and the preserved device-generated key/CSR — it adds no endpoint.
//
// Independent authorization is structural: `confirmAndRevoke` and
// `authorizeAndSubmitCSR` are two separate calls, each requiring its own consent;
// a successful revoke STOPS (it never chains into the CSR), and the CSR consumes
// and persists its authorization before any transmission and submits exactly once.

/// The narrow slice of the portal this service needs — all read-only listing
/// plus the two already-existing mutations. A seam so the flow is testable with
/// a scripted mock and never touches the network in tests. `ZagNativeDeveloperPortal`
/// satisfies it directly.
protocol ZagReplacementPortal: Sendable {
	func revocableCertificates(team: String) async throws -> [ZagRevocableCertificate]
	func revokeCertificate(_ certificate: ZagRevocableCertificate, guard activeGuard: ZagActiveCertificateGuard,
						   override: Bool, team: String) async throws
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate
	/// The last request's sanitized failure reason (HTTP status or transport
	/// refusal), or nil. Default nil; the live native portal records it.
	var lastFailureReason: String? { get }
}

extension ZagReplacementPortal {
	var lastFailureReason: String? { nil }
}

// `ZagNativeDeveloperPortal` conforms to `ZagReplacementPortal` in its own file
// (it already has all three operations), so this service compiles without the
// native portal's transport stack.

/// Durable journal persistence. The app backs it with the Keychain/secret store;
/// tests use an in-memory one. Load/save of the whole coordinator state.
protocol ZagReplacementJournalStore: Sendable {
	func loadReplacementState() -> ZagCertificateReplacementState?
	func saveReplacementState(_ state: ZagCertificateReplacementState)
}

/// Why a step could not proceed — all fail-closed, none advancing a mutation.
enum ZagReplacementError: Error, Equatable, Sendable {
	case notSelectable                 // wrong state for this call
	case targetNoLongerPresent         // stale inventory: the chosen cert is gone
	case fingerprintMismatch           // the listed cert's SHA-1 differs from what was selected
	case targetNowActive               // the chosen cert is now the protected active cert
	case listingUnavailable            // read-only listing could not be read
	case consentMissing                // the required authorization was not given
	case repeatedConflict              // Apple returned 7460 again — freeing a slot did not help
	case certificateLimitReached       // Apple reported a hard certificate limit
	case ambiguousRevoke               // revoke outcome unknown — reconcile (read-only) before any mutation
	case ambiguousSubmission           // CSR outcome unknown — reconcile before anything else
	case sessionRejected
	case network(reason: String?)
}

enum ZagCertificateReplacementService {
	// Stateless helpers so the orchestration logic is fully unit-testable. The
	// app composes these with its portal, consent, journal and team.

	/// Pre-revoke verification against a FRESH read-only listing: the selected
	/// certificate must still exist, match its recorded fingerprint, and not be
	/// the protected active certificate. Returns the exact candidate to revoke.
	static func verifyTargetForRevoke(
		selected: ZagReplacementTarget,
		freshListing: [ZagRevocableCertificate]?,
		activeGuard: ZagActiveCertificateGuard
	) -> Result<ZagRevocableCertificate, ZagReplacementError> {
		guard let freshListing else { return .failure(.listingUnavailable) }
		guard let match = freshListing.first(where: { $0.id == selected.id }) else {
			return .failure(.targetNoLongerPresent)
		}
		// Fingerprint must agree when both are known; a changed/absent fingerprint
		// on a reused id is treated as a mismatch (fail closed, never revoke).
		switch (selected.sha1, match.sha1) {
		case let (.some(a), .some(b)) where a.caseInsensitiveCompare(b) == .orderedSame: break
		case (.none, _): break   // nothing recorded to contradict
		default: return .failure(.fingerprintMismatch)
		}
		if activeGuard.classify(match) == .activeProtected { return .failure(.targetNowActive) }
		return .success(match)
	}

	/// Classifies a thrown portal error for the revoke step. A network error or
	/// any non-authoritative failure is AMBIGUOUS (the revoke may or may not have
	/// landed) and must force read-only reconciliation; only a definite session
	/// rejection is reported as such.
	static func classifyRevokeFailure(_ error: Error) -> ZagReplacementError {
		if let e = error as? ZagPortalError {
			switch e {
			case .sessionRejected: return .sessionRejected
			default: return .ambiguousRevoke
			}
		}
		return .ambiguousRevoke
	}

	/// Classifies a thrown portal error for the CSR step. A repeated 7460 or a
	/// hard limit is authoritative (do NOT assume the freed slot helped); a
	/// network/unknown error is an ambiguous submission to reconcile.
	static func classifySubmitFailure(_ error: Error) -> ZagReplacementError {
		if let e = error as? ZagPortalError {
			switch e {
			case .existingCertificateOrPendingRequest: return .repeatedConflict
			case .certificateLimitReached:             return .certificateLimitReached
			case .sessionRejected:                     return .sessionRejected
			default:                                   return .ambiguousSubmission
			}
		}
		return .ambiguousSubmission
	}

	/// Maps a fresh listing to the coordinator reconcile verdict for a halted
	/// revoke: is the halted target still present?
	static func reconcileVerdict(target: ZagReplacementTarget,
								 freshListing: [ZagRevocableCertificate]?)
		-> ZagCertificateReplacementCoordinator.ReconcileVerdict {
		guard let freshListing else { return .listingUnavailable }
		return freshListing.contains(where: { $0.id == target.id }) ? .targetStillPresent : .targetGone
	}
}

/// A live driver that owns the journal, consent and portal. Separated from the
/// stateless helpers so the helpers stay trivially testable; this type wires
/// them to real I/O. It is `actor` so the one-submission and write-ahead
/// guarantees hold under concurrency.
actor ZagCertificateReplacementDriver {
	private let portal: ZagReplacementPortal
	private let consent: ZagMutationConsentCoordinator
	private let activeGuard: ZagActiveCertificateGuard
	private let journal: ZagReplacementJournalStore
	private let team: String

	init(portal: ZagReplacementPortal, consent: ZagMutationConsentCoordinator,
		 activeGuard: ZagActiveCertificateGuard, journal: ZagReplacementJournalStore, team: String) {
		self.portal = portal
		self.consent = consent
		self.activeGuard = activeGuard
		self.journal = journal
		self.team = team
	}

	private var state: ZagCertificateReplacementState { journal.loadReplacementState() ?? .idle }
	private func persist(_ s: ZagCertificateReplacementState) { journal.saveReplacementState(s) }

	/// Call once on launch: an in-flight mutation whose outcome is unknown is
	/// moved to a non-advancing state (never "completed").
	func recoverOnLaunch() {
		persist(ZagCertificateReplacementCoordinator.recoverAfterInterruption(state))
	}

	/// Read-only inventory for the UI.
	func inventory() async throws -> [ZagRevocableCertificate] {
		do { return try await portal.revocableCertificates(team: team) }
		catch let e as ZagPortalError where e == .sessionRejected { throw ZagReplacementError.sessionRejected }
		catch { throw ZagReplacementError.network(reason: portal.lastFailureReason) }
	}

	/// Select the EXACT certificate; the coordinator rejects the active one.
	func select(_ cert: ZagRevocableCertificate) throws {
		let next = ZagCertificateReplacementCoordinator.reduce(state, .select(cert), guard: activeGuard)
		if case .abandoned(.protectedActiveCertificate) = next { persist(next); throw ZagReplacementError.targetNowActive }
		persist(next)
	}

	/// MUTATION 1 — revoke. Refreshes the listing, re-verifies the exact target,
	/// requires its own consent, writes `revoking` ahead of the network call, and
	/// on success STOPS at `revoked` (it never chains to the CSR).
	func confirmAndRevoke() async throws {
		guard case .selected(let target) = state else { throw ZagReplacementError.notSelectable }
		// Re-verify against a fresh read-only listing immediately before mutating.
		let fresh = try? await portal.revocableCertificates(team: team)
		let verified = ZagCertificateReplacementService.verifyTargetForRevoke(
			selected: target, freshListing: fresh, activeGuard: activeGuard)
		let cert: ZagRevocableCertificate
		switch verified {
		case .success(let c): cert = c
		case .failure(let e): throw e
		}
		// Separate, explicit authorization for THIS mutation only.
		consent.authorize([.revokeCertificate])
		guard consent.mayPerform(.revokeCertificate) else { throw ZagReplacementError.consentMissing }
		persist(ZagCertificateReplacementCoordinator.reduce(state, .confirmRevoke, guard: activeGuard))
		// Write-ahead: if we are killed here, launch recovery sees `revoking`.
		persist(ZagCertificateReplacementCoordinator.reduce(state, .revokeStarted, guard: activeGuard))
		do {
			try await portal.revokeCertificate(cert, guard: activeGuard, override: false, team: team)
			persist(ZagCertificateReplacementCoordinator.reduce(state, .revokeSucceeded, guard: activeGuard))
			consent.cancel()   // the revoke authorization is spent; the CSR needs its own.
			// STOP. No automatic CSR submission.
		} catch {
			let classified = ZagCertificateReplacementService.classifyRevokeFailure(error)
			// Any failure is ambiguous for a mutation: the revoke may or may not
			// have landed, so the flow halts and must be reconciled read-only
			// before any further mutation — never silently retried or advanced.
			persist(ZagCertificateReplacementCoordinator.reduce(state, .revokeAmbiguous, guard: activeGuard))
			consent.cancel()
			throw classified
		}
	}

	/// Read-only reconciliation after an ambiguous/interrupted revoke. Re-lists
	/// and moves the halted flow only as the listing proves (gone -> revoked,
	/// present -> selected). Never revokes or submits.
	func reconcileAfterAmbiguousRevoke() async throws {
		guard case .revokeHalted(let target, let reason) = state,
			  reason == .revokeAmbiguous || reason == .interruptedDuringRevoke else {
			throw ZagReplacementError.notSelectable
		}
		let fresh = try? await portal.revocableCertificates(team: team)
		let verdict = ZagCertificateReplacementService.reconcileVerdict(target: target, freshListing: fresh)
		persist(ZagCertificateReplacementCoordinator.reconcileHaltedRevoke(state, verdict: verdict))
	}

	/// MUTATION 2 — CSR. Requires a SECOND, separate authorization, reachable only
	/// from a proven-revoked state. Consumes and persists the authorization and
	/// the `submitting` write-ahead BEFORE transmission, and submits exactly once
	/// (no retry). A repeated 7460 is reported honestly, not treated as success.
	func authorizeAndSubmitCSR(_ request: ZagCertificateRequest) async throws -> ZagIssuedCertificate {
		guard case .revoked = state else { throw ZagReplacementError.notSelectable }
		persist(ZagCertificateReplacementCoordinator.reduce(state, .authorizeCSR, guard: activeGuard))
		// Second, independent consent — gathered now, consumed and persisted
		// before any byte leaves the device.
		consent.authorize([.submitCSR])
		guard consent.mayPerform(.submitCSR), ZagCertificateReplacementCoordinator.maySubmitCSR(state) else {
			throw ZagReplacementError.consentMissing
		}
		persist(ZagCertificateReplacementCoordinator.reduce(state, .csrStarted, guard: activeGuard))  // write-ahead: submitting
		do {
			let issued = try await portal.submitCertificateRequest(request, team: team)
			persist(ZagCertificateReplacementCoordinator.reduce(state, .csrSucceeded, guard: activeGuard))
			consent.cancel()
			return issued
		} catch {
			let classified = ZagCertificateReplacementService.classifySubmitFailure(error)
			switch classified {
			case .ambiguousSubmission:
				// Outcome unknown: leave the write-ahead as submitting so launch
				// recovery turns it into submissionUnconfirmed for reconciliation.
				persist(ZagCertificateReplacementCoordinator.recoverAfterInterruption(state))
			default:
				persist(ZagCertificateReplacementCoordinator.reduce(state, .csrRejected, guard: activeGuard))
			}
			consent.cancel()
			throw classified
		}
	}

	func currentState() -> ZagCertificateReplacementState { state }
}

/// The disabled portal: every operation refuses, so the gated UI entry point can
/// never reach the network until a live portal is explicitly provided.
struct ZagDisabledReplacementPortal: ZagReplacementPortal {
	func revocableCertificates(team: String) async throws -> [ZagRevocableCertificate] { throw ZagPortalError.livePortalDisabled }
	func revokeCertificate(_ certificate: ZagRevocableCertificate, guard activeGuard: ZagActiveCertificateGuard, override: Bool, team: String) async throws { throw ZagPortalError.livePortalDisabled }
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate { throw ZagPortalError.livePortalDisabled }
}

/// An in-memory journal for the gated preview; the live app backs this with the
/// Keychain-held secret store instead.
final class ZagInMemoryReplacementJournal: ZagReplacementJournalStore, @unchecked Sendable {
	private let lock = NSLock()
	private var value: ZagCertificateReplacementState?
	func loadReplacementState() -> ZagCertificateReplacementState? { lock.withLock { value } }
	func saveReplacementState(_ state: ZagCertificateReplacementState) { lock.withLock { value = state } }
}
