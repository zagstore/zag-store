import Foundation

// The legitimate native recovery decision for resultCode 7460 ("You already
// have a current iOS Development certificate or a pending certificate request").
// Apple conflates two situations in one code, and the PENDING-request half is
// not exposed by any read-only API. This resolver distinguishes them using the
// one thing that IS readable — the team's issued-certificate listing — and
// proposes only safe, explicit next steps. It is PURE: no I/O, no token, and it
// NEVER revokes or requests anything. It only decides.
//
// Rules:
//  * A certificate is reusable only when THIS device holds a key proven to match
//    it (`locallyHeldSerials`). Foreign certificates are counted, never reused.
//  * The active Xcode certificate is protected by `ZagActiveCertificateGuard`
//    and is never offered as a replacement candidate (a separate, explicit
//    authorization is required to touch it).
//  * An unavailable listing is "unknown", never "empty": it decides nothing.
//  * No numeric certificate cap is assumed. The decision follows from what the
//    listing actually shows plus the server's 7460, nothing inferred.

enum ZagCertificateConflictResolution {
	enum Resolution: Equatable, Sendable {
		/// A listed, still-valid certificate matches a key this device holds —
		/// reuse it; no new request and no revocation are needed.
		case recoverExisting(serial: String)
		/// No existing valid development certificate is listed, so the 7460 must be
		/// the PENDING-request arm. Route to Check Again / Abandon
		/// (`ZagCertificateRecoveryModel`); never a blind resubmit, never a revoke.
		case resolvePendingRequest
		/// Existing valid development certificate(s) are listed and none is
		/// reusable. To obtain a signable certificate the user must EXPLICITLY
		/// choose one of these to replace (revoke + re-request). Consent-gated;
		/// the active Xcode certificate is excluded from the candidates.
		case replacementRequired(candidates: [ZagRevocableCertificate])
		/// The only existing valid certificate(s) are the protected active Xcode
		/// certificate. Replacement needs a SEPARATE authorization to touch it;
		/// nothing is proposed here.
		case onlyActiveCertificatePresent
		/// The certificate listing could not be read. Decide nothing; preserve the
		/// unconfirmed state for review.
		case listingUnavailable
	}

	/// `certificates` is the team's issued-certificate listing as revocable
	/// candidates (nil = the read-only listing was unavailable — never empty).
	/// `locallyHeldSerials` are the serials of certificates whose private key this
	/// device holds and has proven to match.
	static func resolve(
		certificates: [ZagRevocableCertificate]?,
		locallyHeldSerials: Set<String>,
		activeGuard: ZagActiveCertificateGuard,
		now: Date
	) -> Resolution {
		guard let certificates else { return .listingUnavailable }
		let valid = certificates.filter { ($0.expiresAt ?? .distantPast) > now }
		// 1. Reuse a certificate we actually hold the key for.
		if let reuse = valid.first(where: { locallyHeldSerials.contains($0.serialNumber) }) {
			return .recoverExisting(serial: reuse.serialNumber)
		}
		// 2. No existing valid development certificate -> the conflict is the
		//    pending-request arm (a request whose outcome we cannot read).
		if valid.isEmpty { return .resolvePendingRequest }
		// 3. Existing valid certificate(s), none reusable -> replacement, with the
		//    active Xcode certificate protected and excluded.
		let nonActive: [ZagRevocableCertificate] = valid.filter { activeGuard.classify($0) != .activeProtected }
		let replaceable = nonActive.sorted { a, b in
			(a.expiresAt ?? .distantPast) < (b.expiresAt ?? .distantPast)   // soonest-expiring first
		}
		return replaceable.isEmpty ? .onlyActiveCertificatePresent : .replacementRequired(candidates: replaceable)
	}

	/// A user-facing explanation that NEVER leaks an identifier, serial, address
	/// or certificate name. The caller renders the specific candidates (masked).
	static func message(_ resolution: Resolution) -> String {
		switch resolution {
		case .recoverExisting:
			return "A development certificate this iPhone already has a key for is still valid; Zag Store will reuse it. Nothing new is requested and nothing is revoked."
		case .resolvePendingRequest:
			return "Apple reports an existing or pending development-certificate request, but this team lists no current certificate. An earlier request may still be outstanding — check again before requesting another. Nothing is revoked."
		case .replacementRequired(let candidates):
			return "This Apple Account already has \(candidates.count) development certificate\(candidates.count == 1 ? "" : "s") that this iPhone has no key for, and Apple will not issue another. To continue you must explicitly choose one to replace. Nothing is revoked until you do."
		case .onlyActiveCertificatePresent:
			return "The only existing development certificate is the one currently used for local signing, which Zag Store protects. Replacing it needs a separate, explicit authorization."
		case .listingUnavailable:
			return "The certificate list could not be read, so no decision was made. Nothing was requested or revoked."
		}
	}

	/// Whether the resolution can proceed without the user making a replacement
	/// decision (reuse or the pending-request flow); the others need explicit input.
	static func isAutonomouslyRecoverable(_ resolution: Resolution) -> Bool {
		switch resolution {
		case .recoverExisting, .resolvePendingRequest: return true
		case .replacementRequired, .onlyActiveCertificatePresent, .listingUnavailable: return false
		}
	}
}
