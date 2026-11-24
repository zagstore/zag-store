import Foundation

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

	func allowsRetry(at now: Date) -> Bool {
		attempts < Self.maximumAttempts && now >= startedAt && now.timeIntervalSince(startedAt) < Self.lifetime
	}

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
		/// The retry budget or lifetime is exhausted; stop and keep the key for review.
		case exhausted
	}

	func nextStep(at now: Date) -> NextStep {
		if let serial = issuedSerial { return .reuseIssued(serial: serial) }
		if submissionUnconfirmed { return .resolveUnconfirmed }
		return allowsRetry(at: now) ? .submit : .exhausted
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
