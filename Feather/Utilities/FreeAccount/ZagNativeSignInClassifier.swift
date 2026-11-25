import Foundation

// Pure, offline-testable classification for the native (Option B) sign-in.
// No SwiftUI and no engine side effects: every branch is a function of the
// engine's sanitized outcome, so scripts/test-zag-native-signin.sh exercises
// it without the ZagAppleAuth xcframework or a device. The engine's own Apple
// strings are never shown; each case maps to a fixed, secret-free message.

/// The user-facing phase of the native sign-in screen.
enum ZagNativeSignInPhase: Equatable, Sendable {
	case signedOut
	case authenticating
	case awaitingConsent
	case selectingPhone
	case awaitingCode
	case submitting
	case signedIn
	case failed
}

/// A meaningful, secret-free failure with a concrete recovery action. Produced
/// only from the engine's sanitized report/outcome — never from raw Apple
/// responses, and never carrying passwords, codes, tokens or device identifiers.
struct ZagNativeSignInFailure: Equatable, Sendable {
	enum Recovery: Equatable, Sendable {
		case retry                 // transient; try again
		case checkCredentials      // wrong Apple Account / password / code
		case provisionADI          // on-device ADI profile needed first
		case unsupportedBuild      // the native engine is not linked in this build
		case waitAndRetry          // Apple rate-limited or temporarily unavailable
	}
	let message: String
	let recovery: Recovery

	var recoveryText: String {
		switch recovery {
		case .retry:            return "Please try signing in again."
		case .checkCredentials: return "Check your Apple Account, password or code, then try again."
		case .provisionADI:     return "Complete on-device provisioning first, then sign in."
		case .unsupportedBuild: return "This build does not include the native sign-in engine."
		case .waitAndRetry:     return "Wait a moment and try again."
		}
	}
}

enum ZagNativeSignInClassifier {
	/// A GrandSlam outcome → a failure, or nil when authentication succeeded.
	/// `developerOK` is whether the developer-session exchange also succeeded;
	/// a signed-in account with no developer session is still a failure to use.
	static func failure(outcome: ZagAppleAuthSignInOutcome, developerOK: Bool) -> ZagNativeSignInFailure? {
		switch outcome {
		case .authenticated:
			return developerOK ? nil
				: ZagNativeSignInFailure(message: "Signed in, but a developer session could not be established.",
										 recovery: .retry)
		case .twoFactorRequired, .twoFactorRequiredAtCeiling:
			// The code gate was reached but no code was submitted (cancelled /
			// none provided). Not an error to hide — it needs another attempt.
			return ZagNativeSignInFailure(message: "Two-factor verification was not completed.", recovery: .retry)
		case .rejected(let code):
			if Self.twoFactorRejectionCodes.contains(code) {
				return ZagNativeSignInFailure(message: "The verification code was not accepted.", recovery: .checkCredentials)
			}
			return ZagNativeSignInFailure(message: "Apple did not accept the sign-in.", recovery: .checkCredentials)
		case .httpError(let status):
			if status == 429 { return ZagNativeSignInFailure(message: "Apple is rate-limiting sign-in.", recovery: .waitAndRetry) }
			return ZagNativeSignInFailure(message: "Apple's sign-in service is temporarily unavailable (HTTP \(status)).", recovery: .waitAndRetry)
		case .transportFailed:
			return ZagNativeSignInFailure(message: "Could not reach Apple. Check the network connection.", recovery: .retry)
		case .notProvisioned:
			return ZagNativeSignInFailure(message: "This iPhone has no on-device provisioning profile yet.", recovery: .provisionADI)
		}
	}

	/// A thrown engine error (not a GrandSlam outcome) → a failure.
	static func failure(error: ZagAppleAuthError) -> ZagNativeSignInFailure {
		switch error {
		case .unavailable:        return ZagNativeSignInFailure(message: "The native Apple engine is not linked in this build.", recovery: .unsupportedBuild)
		case .notProvisioned:     return ZagNativeSignInFailure(message: "This iPhone has no on-device provisioning profile yet.", recovery: .provisionADI)
		case .provisioningFailed: return ZagNativeSignInFailure(message: "On-device provisioning failed.", recovery: .provisionADI)
		case .transportBlocked:   return ZagNativeSignInFailure(message: "Could not reach Apple. Check the network connection.", recovery: .retry)
		case .malformedHeaders:   return ZagNativeSignInFailure(message: "The device identity headers were malformed.", recovery: .retry)
		case .keychain:           return ZagNativeSignInFailure(message: "Secure storage could not be read on this device.", recovery: .retry)
		}
	}

	/// Known GrandSlam `ec` codes for a rejected verification code (negative).
	static let twoFactorRejectionCodes: Set<Int> = [-21669, -22406, -28248]
}
