import Foundation

/// A development team the account belongs to. A free Apple Account has one
/// Personal Team; paid memberships work the same way without the free limits.
struct ZagDeveloperTeam: Codable, Equatable, Sendable {
	enum Kind: String, Codable, Sendable {
		/// Free provisioning: 7-day profiles and the limits in `ZagFreeAccountLimits`.
		case personalFree
		case individualPaid
		case organization
		/// Apple returned a team type Zag Store does not recognise; treated with
		/// the free limits, which are the strictest.
		case unknown
	}

	let identifier: String
	let name: String
	let kind: Kind

	var hasFreeLimits: Bool { kind == .personalFree || kind == .unknown }

	/// Team IDs are ten upper-case letters or digits.
	static func isValidIdentifier(_ value: String) -> Bool {
		value.count == 10 && value.unicodeScalars.allSatisfy {
			("A"..."Z").contains($0) || ("0"..."9").contains($0)
		}
	}
}

/// What Zag Store remembers about a signed-in account outside the Keychain.
/// It holds nothing that can be used to sign in: the session token is in
/// `ZagFreeAccountSecretStore` under `accountID`.
struct ZagFreeAccountSession: Codable, Equatable, Sendable {
	/// Local identifier for the Keychain items; not Apple's account ID.
	let accountID: UUID
	/// For display only, e.g. "p•••@gmail.com".
	let maskedAppleID: String
	let team: ZagDeveloperTeam
	let authenticatedAt: Date
	/// When Apple said the session token expires, if it said.
	let expiresAt: Date?

	func isExpired(at now: Date) -> Bool {
		guard let expiresAt else { return false }
		return expiresAt <= now
	}

	/// "person@example.com" → "p•••@example.com". Never shows more than the
	/// first character of the local part.
	static func mask(appleID: String) -> String {
		let trimmed = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let at = trimmed.firstIndex(of: "@"), at > trimmed.startIndex else {
			return trimmed.isEmpty ? "" : String(trimmed.prefix(1)) + "•••"
		}
		return String(trimmed[trimmed.startIndex]) + "•••" + trimmed[at...]
	}
}

enum ZagTwoFactorMethod: String, Codable, Equatable, Sendable {
	case trustedDevice
	case sms
}

/// Why signing in or using the account failed, in terms the user can act on.
struct ZagFreeAccountFailure: Codable, Equatable, Sendable {
	enum Kind: String, Codable, Sendable {
		case invalidCredentials
		case twoFactorRejected
		case accountLocked
		case rateLimited
		case network
		/// Anisette data could not be obtained, so Apple's sign-in cannot start.
		case anisetteUnavailable
		/// Apple answered with something Zag Store does not understand. Never
		/// retried automatically: the protocol may have changed.
		case unexpectedResponse
		case cancelled
		/// Sign-in is turned off in this build (live authentication not enabled).
		case unavailable
	}

	let kind: Kind
	let occurredAt: Date

	var message: String {
		switch kind {
		case .invalidCredentials: return "Your Apple Account email or password was not accepted."
		case .twoFactorRejected: return "The verification code was not accepted."
		case .accountLocked: return "Apple has locked or restricted this Apple Account."
		case .rateLimited: return "Apple is limiting sign-in attempts for now."
		case .network: return "Apple's servers could not be reached."
		case .anisetteUnavailable: return "Sign-in data from the anisette service is unavailable."
		case .unexpectedResponse: return "Apple returned a response Zag Store does not recognise."
		case .cancelled: return "Sign-in was cancelled."
		case .unavailable: return "Apple Account sign-in is not available in this version of Zag Store."
		}
	}

	var recovery: String {
		switch kind {
		case .invalidCredentials, .twoFactorRejected, .cancelled: return "Sign in again"
		case .accountLocked: return "Unlock your account at account.apple.com"
		case .rateLimited: return "Try again later"
		case .network, .anisetteUnavailable: return "Check your connection and try again"
		case .unexpectedResponse: return "Update Zag Store"
		case .unavailable: return "Use an imported certificate for now"
		}
	}

	/// Whether an automatic retry (with backoff) is sensible.
	var isTransient: Bool { kind == .network || kind == .anisetteUnavailable || kind == .rateLimited }
}

/// The account's sign-in state. Changes only through `applying(_:)`, which
/// rejects transitions that cannot happen (for example a verification code
/// with no sign-in in progress), so the UI cannot show a state the account
/// is not in.
enum ZagFreeAccountState: Codable, Equatable, Sendable {
	case signedOut
	case authenticating
	case awaitingTwoFactor(ZagTwoFactorMethod)
	case signedIn(ZagFreeAccountSession)
	case sessionExpired(ZagFreeAccountSession)
	case failed(ZagFreeAccountFailure)

	enum Event: Equatable, Sendable {
		case beginSignIn
		case twoFactorRequired(ZagTwoFactorMethod)
		case twoFactorSubmitted
		case authenticated(ZagFreeAccountSession)
		/// Apple rejected the stored session token (or it passed its expiry).
		case sessionRejected
		case failed(ZagFreeAccountFailure)
		case signOut
	}

	/// The next state, or nil when `event` cannot happen in this state.
	func applying(_ event: Event) -> ZagFreeAccountState? {
		switch (self, event) {
		case (_, .signOut):
			return .signedOut
		case (.signedOut, .beginSignIn), (.failed, .beginSignIn), (.sessionExpired, .beginSignIn):
			return .authenticating
		case (.authenticating, .twoFactorRequired(let method)):
			return .awaitingTwoFactor(method)
		case (.awaitingTwoFactor, .twoFactorSubmitted):
			return .authenticating
		case (.authenticating, .authenticated(let session)):
			return .signedIn(session)
		case (.signedIn(let session), .sessionRejected):
			return .sessionExpired(session)
		case (.authenticating, .failed(let failure)), (.awaitingTwoFactor, .failed(let failure)):
			return .failed(failure)
		default:
			return nil
		}
	}

	var session: ZagFreeAccountSession? {
		switch self {
		case .signedIn(let session), .sessionExpired(let session): return session
		default: return nil
		}
	}

	/// Only a signed-in session can provision or refresh.
	var canProvision: Bool {
		if case .signedIn = self { return true }
		return false
	}
}
