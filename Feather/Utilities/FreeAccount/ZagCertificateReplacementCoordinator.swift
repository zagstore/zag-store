import Foundation

// The native certificate-replacement state machine: the explicit, consent-gated
// path from "the free team is at its development-certificate allotment and none
// is reusable" to a freshly issued device-key certificate. It is PURE (no I/O,
// no token, never revokes or requests anything) and its state is Codable so the
// caller can persist a durable journal that survives interruption or app
// termination. The caller performs the two Apple mutations between the gates.
//
// Enforced invariants (each a test below):
//  * The user selects the EXACT certificate (by v1 id + serial); the active
//    Xcode certificate is rejected at selection (ZagActiveCertificateGuard).
//  * Revocation needs a SEPARATE explicit confirmation after selection.
//  * CSR submission needs a SECOND, separate authorization after revocation.
//  * No automatic retries and no chained mutations: every mutation step is a
//    distinct event; the reducer never advances two mutations from one input.
//  * A failed OR ambiguous revocation CANNOT advance to CSR submission.
//  * Interruption while a mutation was in flight resolves to a NON-advancing
//    state (revoke -> needs re-check; CSR -> unconfirmed for reconciliation),
//    never to "completed".

/// The durable replacement journal. Persist this (e.g. in the secret store);
/// on relaunch, `recoverAfterInterruption` maps any in-flight state to a safe one.
enum ZagCertificateReplacementState: Codable, Equatable, Sendable {
	case idle
	/// The user chose this exact certificate to replace (not the active one).
	case selected(target: ZagReplacementTarget)
	/// Separate explicit confirmation to revoke has been given.
	case revokeConfirmed(target: ZagReplacementTarget)
	/// Revoke request is in flight (written ahead for interruption detection).
	case revoking(target: ZagReplacementTarget)
	/// Revoke succeeded; the slot is free. CSR still needs its own authorization.
	case revoked(target: ZagReplacementTarget)
	/// Revoke failed or was ambiguous: a TERMINAL stop for this attempt. It can
	/// never advance to CSR submission.
	case revokeHalted(serial: String, reason: ZagReplacementHalt)
	/// A SECOND, separate authorization to submit the CSR has been given.
	case csrAuthorized(target: ZagReplacementTarget)
	/// CSR submission is in flight (written ahead).
	case submitting(target: ZagReplacementTarget)
	/// Replacement finished: the slot was freed and a new CSR was submitted.
	case completed(serial: String)
	/// The CSR submission outcome is unknown (interrupted in flight): hand to
	/// ZagCSRReconciliation; never treated as completed.
	case submissionUnconfirmed(serial: String)
	/// The user (or a guard) abandoned the flow.
	case abandoned(reason: ZagReplacementHalt)
}

/// The exact certificate to replace: the handles a later revoke needs, captured
/// at selection so the operation can never target a different certificate.
struct ZagReplacementTarget: Codable, Equatable, Sendable {
	let id: String             // /services/v1 revoke handle
	let serialNumber: String
	let sha1: String?
}

enum ZagReplacementHalt: String, Codable, Equatable, Sendable {
	case userCancelled
	case protectedActiveCertificate
	case revokeFailed
	case revokeAmbiguous
	case interruptedDuringRevoke
	case csrRejected
	case illegalTransition
}

/// Events the caller feeds the reducer. Mutation *results* (succeeded/failed/
/// ambiguous) are separate from the mutation *authorizations* (confirmRevoke,
/// authorizeCSR), so the UI gates each mutation independently.
enum ZagCertificateReplacementEvent: Equatable, Sendable {
	case select(ZagRevocableCertificate)
	case confirmRevoke              // separate explicit confirmation
	case revokeStarted
	case revokeSucceeded
	case revokeFailed
	case revokeAmbiguous
	case authorizeCSR              // second, separate authorization
	case csrStarted
	case csrSucceeded
	case csrRejected
	case cancel
}

enum ZagCertificateReplacementCoordinator {
	/// Applies one event to the current state under the active-cert guard.
	/// Returns the next state; an illegal transition leaves a terminal
	/// `abandoned(.illegalTransition)` rather than silently ignoring it, so a
	/// misuse can never leave the journal in a misleading intermediate state.
	static func reduce(_ state: ZagCertificateReplacementState,
					   _ event: ZagCertificateReplacementEvent,
					   guard activeGuard: ZagActiveCertificateGuard) -> ZagCertificateReplacementState {
		switch (state, event) {
		// Selection — reject the protected active certificate outright.
		case (.idle, .select(let cert)):
			if activeGuard.classify(cert) == .activeProtected {
				return .abandoned(reason: .protectedActiveCertificate)
			}
			return .selected(target: ZagReplacementTarget(id: cert.id, serialNumber: cert.serialNumber, sha1: cert.sha1))

		// Revocation — a distinct confirmation, then start, then a result.
		case (.selected(let t), .confirmRevoke):      return .revokeConfirmed(target: t)
		case (.revokeConfirmed(let t), .revokeStarted): return .revoking(target: t)
		case (.revoking(let t), .revokeSucceeded):    return .revoked(target: t)
		case (.revoking(let t), .revokeFailed):       return .revokeHalted(serial: t.serialNumber, reason: .revokeFailed)
		case (.revoking(let t), .revokeAmbiguous):    return .revokeHalted(serial: t.serialNumber, reason: .revokeAmbiguous)

		// CSR — a SECOND authorization, only reachable from a succeeded revoke.
		case (.revoked(let t), .authorizeCSR):        return .csrAuthorized(target: t)
		case (.csrAuthorized(let t), .csrStarted):    return .submitting(target: t)
		case (.submitting(let t), .csrSucceeded):     return .completed(serial: t.serialNumber)
		case (.submitting(let t), .csrRejected):      return .abandoned(reason: .csrRejected)

		// Cancellation is allowed from any non-terminal state.
		case (.idle, .cancel), (.selected, .cancel), (.revokeConfirmed, .cancel),
			 (.revoked, .cancel), (.csrAuthorized, .cancel):
			return .abandoned(reason: .userCancelled)

		// Terminal states accept nothing further; everything else is illegal.
		case (.completed, _), (.abandoned, _), (.revokeHalted, _), (.submissionUnconfirmed, _):
			return state
		default:
			return .abandoned(reason: .illegalTransition)
		}
	}

	/// Maps a state loaded from disk after an interruption to a safe one. An
	/// in-flight mutation whose outcome is unknown must NEVER resume as if it
	/// succeeded: a revoke in flight becomes a halt that needs an out-of-band
	/// re-check; a CSR in flight becomes `submissionUnconfirmed` for reconciliation.
	static func recoverAfterInterruption(_ state: ZagCertificateReplacementState) -> ZagCertificateReplacementState {
		switch state {
		case .revoking(let t):   return .revokeHalted(serial: t.serialNumber, reason: .interruptedDuringRevoke)
		case .submitting(let t): return .submissionUnconfirmed(serial: t.serialNumber)
		default:                 return state
		}
	}

	/// Whether the flow may submit the CSR now. True ONLY in `csrAuthorized`
	/// (a succeeded revoke plus a separate CSR authorization). A halted/ambiguous
	/// revoke is never true here.
	static func maySubmitCSR(_ state: ZagCertificateReplacementState) -> Bool {
		if case .csrAuthorized = state { return true }
		return false
	}

	/// Whether the flow may send the revoke now. True ONLY in `revokeConfirmed`.
	static func mayRevoke(_ state: ZagCertificateReplacementState) -> Bool {
		if case .revokeConfirmed = state { return true }
		return false
	}

	static func isTerminal(_ state: ZagCertificateReplacementState) -> Bool {
		switch state {
		case .completed, .abandoned, .revokeHalted, .submissionUnconfirmed: return true
		default: return false
		}
	}
}
