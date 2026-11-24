import Foundation

/// Errors surfaced by the developer portal (live or simulated). Typed so the
/// provisioner can react (re-auth, back off, stop) and so nothing leaks a
/// message that could contain request data.
enum ZagPortalError: Error, Equatable, Sendable {
	/// Apple no longer accepts the session; the user must sign in again.
	case sessionRejected
	case network
	case rateLimited
	case malformedResponse
	/// Another team owns this identifier.
	case identifierUnavailable(String)
	case deviceLimitReached
	case appIDLimitReached
	case certificateLimitReached
	/// Apple refused a CSR because the account already has a current development
	/// certificate OR an outstanding pending certificate request (resultCode
	/// 7460). This is an application-level conflict, NOT HTTP throttling and NOT a
	/// conclusively-established numeric certificate cap — the two are kept distinct.
	case existingCertificateOrPendingRequest
	case livePortalDisabled
}
