import Foundation
import CryptoKit

// Policy for native certificate issuance and the (separate, consented)
// revocation branch. All types here are pure — no I/O, no token — so they are
// host-testable and used both by the orchestration and by synthetic-response
// tests. Nothing here ever sends a request or revokes a certificate.

// MARK: - Inferred capacity preflight (NOT the authoritative server limit)

/// A BEFORE-the-request heuristic from the discovered certificate count. It is
/// explicitly *inferred*: it can warn that a new CSR is likely to need a revoke,
/// but it never blocks and is never treated as authoritative. The only
/// authoritative capacity verdict is the server's `certificateLimitReached`
/// (`ZagPortalError.certificateLimitReached`) returned by `submitDevelopmentCSR`.
enum ZagCertificateCapPreflight: Equatable, Sendable {
	/// The observed count is below the inferred free-team cap.
	case withinInferredCap(count: Int, inferredCap: Int)
	/// The observed count meets or exceeds the inferred cap, so a new CSR MAY be
	/// refused by Apple. This is a heuristic warning only, not a hard limit.
	case inferredCapacityRisk(count: Int, inferredCap: Int)

	/// The commonly reported practical ceiling of development certificates on a
	/// free Personal Team. Inferred from community evidence, not from Apple; the
	/// authoritative answer only ever comes from the server at request time.
	static let inferredFreeTeamCap = 2

	static func evaluate(certificateCount: Int, inferredCap: Int = inferredFreeTeamCap) -> ZagCertificateCapPreflight {
		certificateCount >= inferredCap
			? .inferredCapacityRisk(count: certificateCount, inferredCap: inferredCap)
			: .withinInferredCap(count: certificateCount, inferredCap: inferredCap)
	}

	/// True when a new CSR is heuristically at risk of `certificateLimitReached`.
	/// Callers may warn, but must NOT block solely on this — only the server's
	/// response is authoritative.
	var isInferredRisk: Bool {
		if case .inferredCapacityRisk = self { return true }
		return false
	}

	var sanitized: [String: Any] {
		switch self {
		case let .withinInferredCap(count, cap):
			return ["cap_preflight": "within-inferred-cap", "count": count, "inferred_cap": cap, "authoritative": false]
		case let .inferredCapacityRisk(count, cap):
			return ["cap_preflight": "inferred-capacity-risk", "count": count, "inferred_cap": cap, "authoritative": false]
		}
	}
}

// MARK: - Revocable certificate + active-cert protection

/// A certificate that could be revoked, identified UNAMBIGUOUSLY by its
/// `/services/v1/` `id` (the revoke handle) as well as its serial and body
/// SHA-1 (for matching the active Xcode certificate).
struct ZagRevocableCertificate: Equatable, Sendable {
	/// The v1 JSON `data[].id` — the handle `DELETE /services/v1/certificates/<id>` needs.
	let id: String
	let serialNumber: String
	/// SHA-1 of the certificate DER, for identifying the active Xcode cert.
	let sha1: String?
	let name: String
	let machineName: String?
	let expiresAt: Date?
}

/// Protects the certificate currently used by Xcode for local signing. Legacy
/// certificates are classified as `unknownUsage` — NEVER "unused" — so the UI
/// must not present them as safe to revoke without evidence.
struct ZagActiveCertificateGuard: Sendable {
	/// SHA-1 fingerprint of the active Apple Development certificate (the one in
	/// the Mac login keychain that Xcode signs with).
	let activeSHA1: String?
	/// Its serial number, as a fallback identifier.
	let activeSerial: String?

	enum Usage: Equatable, Sendable {
		/// The active Xcode signing certificate — protected.
		case activeProtected
		/// Usage not established. Not known to be safe to revoke.
		case unknownUsage
	}

	func classify(_ cert: ZagRevocableCertificate) -> Usage {
		if let s = activeSHA1, let c = cert.sha1, c.caseInsensitiveCompare(s) == .orderedSame { return .activeProtected }
		if let s = activeSerial, cert.serialNumber.caseInsensitiveCompare(s) == .orderedSame { return .activeProtected }
		return .unknownUsage
	}

	/// Revocation is allowed for a non-active certificate, or for the active one
	/// ONLY with an explicit override. Capacity errors must never set the override.
	func mayRevoke(_ cert: ZagRevocableCertificate, explicitOverride: Bool) -> Bool {
		classify(cert) == .activeProtected ? explicitOverride : true
	}
}

// MARK: - Revocation codec (synthetic-tested; no auto-revoke)

/// Pure codec for certificate revocation via the `/services/v1/` JSON API
/// (`DELETE /services/v1/certificates/<id>`, sent as POST + X-HTTP-Method-
/// Override: DELETE). Building a request requires an explicit `id`, so a
/// capacity error — which carries no `id` decision — cannot trigger one.
enum ZagCertificateRevocation {
	/// Builds revocation candidates from a `/services/v1/certificates` `data[]`
	/// listing: the v1 `id` plus the parsed certificate and a DER SHA-1.
	static func candidates(from rows: [[String: Any]]) -> [ZagRevocableCertificate] {
		rows.compactMap { row in
			guard let id = row["id"] as? String, let parsed = ZagDeveloperServicesProtocol.parseCertificate(row) else { return nil }
			let sha1 = parsed.der.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
			return ZagRevocableCertificate(id: id, serialNumber: parsed.serialNumber, sha1: sha1,
										   name: parsed.name, machineName: parsed.machineName, expiresAt: parsed.expiresAt)
		}
	}

	static func endpointPath(id: String) -> String { "certificates/\(id)" }
	static let methodOverride = "DELETE"

	/// Interprets a revoke response. A 2xx (optionally with no body, or an empty
	/// `data`) is success; `errors`/4xx/5xx map to a typed `ZagPortalError`.
	static func parse(_ body: Data, httpStatus: Int) throws -> Bool {
		guard (200..<300).contains(httpStatus) else {
			throw httpStatus == 401 || httpStatus == 403 ? ZagPortalError.sessionRejected
				: httpStatus == 429 ? ZagPortalError.rateLimited : ZagPortalError.network
		}
		if body.isEmpty { return true }
		guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return true }
		if let errors = obj["errors"] as? [[String: Any]], !errors.isEmpty { throw ZagPortalError.malformedResponse }
		return true
	}
}

// MARK: - Reconciling an unconfirmed CSR submission

/// Decides what to do with a journal whose last submission is unconfirmed, from
/// a FRESH certificate listing and the recorded submit verdict. The rule that
/// matters: a "no matching certificate" listing does NOT by itself clear the
/// unconfirmed flag — only an authoritative rejection makes the journal
/// retryable; anything ambiguous is preserved for explicit review.
enum ZagCSRReconciliation {
	/// Looking for the pending key's certificate in a fresh listing.
	enum ListingMatch: Equatable, Sendable {
		case found(serial: String)
		case notFound
		case listingUnavailable
	}

	/// What the recorded submit response established.
	enum SubmitVerdict: Equatable, Sendable {
		/// The server definitively refused and created nothing (cap, device/App-ID
		/// limit, session rejected, identifier unavailable, confirmed HTTP-429 throttle).
		case authoritativeRejection
		/// An unknown/ambiguous resultCode: the outcome is genuinely unknown.
		case ambiguous
		/// A transport failure or incomplete response.
		case transportIncomplete
		/// No submit verdict is recorded (e.g. an older journal).
		case none
	}

	enum Decision: Equatable, Sendable {
		/// A matching certificate was found: verify key/team/validity, then recover.
		case recover(serial: String)
		/// Safe to allow ONE resubmit of the same key+CSR (clears unconfirmed).
		case retryable
		/// Keep unconfirmed; a human must review before anything else.
		case preserveForReview
		/// Keep unconfirmed; the listing or transport was inconclusive.
		case preserveUnconfirmed
	}

	static func decide(match: ListingMatch, submit: SubmitVerdict) -> Decision {
		switch match {
		case .found(let serial): return .recover(serial: serial)
		case .listingUnavailable: return .preserveUnconfirmed
		case .notFound:
			switch submit {
			case .authoritativeRejection: return .retryable
			case .transportIncomplete:    return .preserveUnconfirmed
			case .ambiguous, .none:       return .preserveForReview
			}
		}
	}

	/// Maps a recorded fault classification to a submit verdict.
	static func verdict(for classification: ZagDeveloperServicesFault.Classification?) -> SubmitVerdict {
		guard let classification else { return .none }
		switch classification {
		case .sessionRejected, .deviceLimitReached, .appIDLimitReached,
			 .certificateLimitReached, .identifierUnavailable, .confirmedRateLimit:
			return .authoritativeRejection
		case .ambiguousRejection, .malformed:
			return .ambiguous
		case .network:
			return .transportIncomplete
		}
	}
}

