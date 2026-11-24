import Foundation
import CryptoKit

// Crash-safe, idempotent state for a single native CSR submission, so repeated
// attempts cannot silently create orphaned keys or duplicate certificate
// requests. Mirrors the production ZagPendingSigningKey journal, in a light form
// the experiment harness can use without the full provisioner. The pure
// `ZagPendingCSRState` logic is host-tested; the Keychain store wraps it.

/// The persisted journal for one in-flight CSR. The key lives in the Keychain
/// (referenced by `keySlot`); `request` is the exact CSR bytes resubmitted on
/// retry (never regenerated, so no duplicate request). `submissionUnconfirmed`
/// marks that a request was sent but its outcome is unknown (a certificate may
/// have been issued whose response was lost) — nothing is resubmitted until the
/// team's certificate listing settles it.
struct ZagPendingCSRState: Codable, Equatable, Sendable {
	static let maximumAttempts = 3
	static let lifetime: TimeInterval = 86_400

	let keySlot: String?
	let request: Data
	let startedAt: Date
	var attempts: Int
	var submissionUnconfirmed: Bool
	var issuedSerial: String?
	// The last submission's recorded fault (for reconciliation). All optional so
	// an older journal decodes unchanged; the raw resultCode is a small integer,
	// the message is already redacted and bounded.
	var lastResultCode: Int? = nil
	var lastHTTPStatus: Int? = nil
	var lastMessage: String? = nil
	var lastClassification: String? = nil
	// The team the key + CSR were made for (binds an override to the right team).
	var team: String? = nil
	// Reconciliation evidence recorded by a read-only reconcile run (not-found).
	var reviewEvidence: ZagReconciliationEvidence? = nil
	// Set ONLY by a single-use operator override after reviewed evidence; consumed
	// (cleared) at the moment of the next submission.
	var retryableAfterReview: Bool? = nil

	func allowsRetry(at now: Date) -> Bool {
		attempts < Self.maximumAttempts && now >= startedAt && now.timeIntervalSince(startedAt) < Self.lifetime
	}

	/// SHA-256 of the pending CSR bytes — the binding an override is checked against.
	var csrFingerprint: String { ZagReconciliationEvidence.fingerprint(request) }

	/// What the orchestration should do next, given the current journal. Never
	/// generates a key or resubmits while an outcome is unconfirmed.
	enum NextStep: Equatable, Sendable {
		/// A certificate was already issued and verified for this key; reuse it.
		case reuseIssued(serial: String)
		/// A request was sent and its outcome is unknown; resolve via the team's
		/// certificate listing before doing anything else.
		case resolveUnconfirmed
		/// Safe to submit the stored request (reusing the same key and bytes).
		case submit
		/// An operator override authorised exactly one resubmission of the stored
		/// request; the override is consumed at submit time (single-use).
		case submitAfterReview
		/// The retry budget or lifetime is exhausted; stop and keep the key for review.
		case exhausted
	}

	func nextStep(at now: Date) -> NextStep {
		if let serial = issuedSerial { return .reuseIssued(serial: serial) }
		if retryableAfterReview == true { return .submitAfterReview }
		if submissionUnconfirmed { return .resolveUnconfirmed }
		return allowsRetry(at: now) ? .submit : .exhausted
	}
}

/// Evidence from a successful, complete read-only certificate listing that found
/// NO certificate for the pending key, recorded so a one-time operator override
/// can be bound to it. Carries the exact key/CSR/team/account it was gathered
/// for, and that the original submission verdict remains unknown.
struct ZagReconciliationEvidence: Codable, Equatable, Sendable {
	let teamID: String
	let keySlot: String?
	let csrSHA256: String
	let account: String
	let listingComplete: Bool
	let httpStatus: Int
	let certificateCountObserved: Int
	let matchingPublicKeyFound: Bool
	let originalVerdictUnknown: Bool
	let observedAt: Date

	static func fingerprint(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

/// A single-use, evidence-bound transition from `submissionUnconfirmed` to
/// `retryableAfterReview`. Never clears the journal automatically; a human runs
/// it after reviewing the evidence. The original CSR and key are untouched.
enum ZagReconciliationOverride {
	static let evidenceFreshness: TimeInterval = 3600   // evidence must be recent

	enum Rejection: String, Error, Equatable, Sendable {
		case journalNotUnconfirmed       // already issued / already overridden / resolved (replay guard)
		case noEvidence
		case evidenceIncomplete          // listing not a complete HTTP 200
		case matchFound                  // a certificate for the key WAS found — must recover, not retry
		case verdictNotUnknown           // original verdict is known; use the normal path
		case keyBindingMismatch
		case teamMismatch
		case accountMismatch
		case csrMismatch
		case evidenceStale
	}

	/// Validates the evidence against the journal + expected binding and, if
	/// valid, returns the journal transitioned to `retryableAfterReview`.
	static func apply(to state: ZagPendingCSRState, account: String, now: Date) -> Result<ZagPendingCSRState, Rejection> {
		guard state.issuedSerial == nil, state.retryableAfterReview != true, state.submissionUnconfirmed else {
			return .failure(.journalNotUnconfirmed)
		}
		guard let evidence = state.reviewEvidence else { return .failure(.noEvidence) }
		guard evidence.listingComplete, evidence.httpStatus == 200 else { return .failure(.evidenceIncomplete) }
		guard !evidence.matchingPublicKeyFound else { return .failure(.matchFound) }
		guard evidence.originalVerdictUnknown else { return .failure(.verdictNotUnknown) }
		guard evidence.keySlot == state.keySlot else { return .failure(.keyBindingMismatch) }
		guard evidence.account == account else { return .failure(.accountMismatch) }
		if let journalTeam = state.team { guard evidence.teamID == journalTeam else { return .failure(.teamMismatch) } }
		guard evidence.csrSHA256 == state.csrFingerprint else { return .failure(.csrMismatch) }
		guard now.timeIntervalSince(evidence.observedAt) >= 0,
			  now.timeIntervalSince(evidence.observedAt) <= evidenceFreshness else { return .failure(.evidenceStale) }
		var updated = state
		updated.submissionUnconfirmed = false
		updated.retryableAfterReview = true
		return .success(updated)
	}
}

/// Stores one `ZagPendingCSRState` per scope in the Keychain (this-device-only,
/// non-synchronized), beside the signing key it journals.
struct ZagPendingCSRStore {
	private let service = "app.zagstore.anisette.appleauth.pendingcsr.v1"

	func load(scope: String) -> ZagPendingCSRState? {
		var query = baseQuery(scope: scope)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
			  let data = out as? Data else { return nil }
		return try? JSONDecoder().decode(ZagPendingCSRState.self, from: data)
	}

	func save(_ state: ZagPendingCSRState, scope: String) throws {
		let data = try JSONEncoder().encode(state)
		var query = baseQuery(scope: scope)
		let attributes: [String: Any] = [kSecValueData as String: data]
		let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecItemNotFound {
			query[kSecValueData as String] = data
			query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			let add = SecItemAdd(query as CFDictionary, nil)
			guard add == errSecSuccess else { throw ZagAppleAuthError.keychain(add) }
		} else if status != errSecSuccess {
			throw ZagAppleAuthError.keychain(status)
		}
	}

	func delete(scope: String) {
		SecItemDelete(baseQuery(scope: scope) as CFDictionary)
	}

	private func baseQuery(scope: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: scope,
		 kSecAttrSynchronizable as String: false]
	}
}
