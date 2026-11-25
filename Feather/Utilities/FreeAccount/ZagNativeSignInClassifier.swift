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
		case deviceIdentity        // Apple rejected the device identity before credentials
	}
	let message: String
	let recovery: Recovery
	/// A sanitized, stage-specific diagnostic (stage, Apple `ec`, HTTP status and
	/// Apple's already-sanitized `em` message). Never a credential, token, session
	/// value or device identifier. Shown to the owner as secondary detail so a
	/// live failure yields evidence rather than a bare message.
	var detail: String? = nil

	var recoveryText: String {
		switch recovery {
		case .retry:            return "Please try signing in again."
		case .checkCredentials: return "Check your Apple Account, password or code, then try again."
		case .provisionADI:     return "Complete on-device provisioning first, then sign in."
		case .unsupportedBuild: return "This build does not include the native sign-in engine."
		case .waitAndRetry:     return "Wait a moment and try again."
		case .deviceIdentity:   return "Apple did not accept this device's identity. Re-provision on-device ADI, then try again."
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

	/// Known GrandSlam `ec` codes for a genuine credential rejection (wrong
	/// Apple Account or password) — Apple validated the SRP proof and refused it.
	static let credentialRejectionCodes: Set<Int> = [-20101, -22406, -20751]

	/// A full classification from the sanitized sign-in report. Uses the stage,
	/// `ec`, HTTP status and Apple message to distinguish a genuine credential
	/// rejection from a device-identity / provisioning / protocol / transport
	/// failure, and attaches a sanitized, stage-specific diagnostic. `nil` when
	/// authentication and the developer session both succeeded.
	static func failure(report: ZagAppleAuthSignInReport, developerOK: Bool) -> ZagNativeSignInFailure? {
		let detail = diagnostic(stage: report.stage, ec: report.ec, http: report.httpStatus,
								message: report.appleMessage, requestCount: report.requestCount,
								refusals: report.refusals ?? [])
		switch report.outcome {
		case .authenticated:
			guard !developerOK else { return nil }
			let devDetail = report.developerOutcome.map { "developer session: \($0)" } ?? detail
			return ZagNativeSignInFailure(message: "Signed in, but a developer session could not be established.",
										  recovery: .retry, detail: devDetail)
		case .rejected(let code):
			if twoFactorRejectionCodes.contains(code) {
				return ZagNativeSignInFailure(message: "The verification code was not accepted.", recovery: .checkCredentials, detail: detail)
			}
			// A rejection at the account-lookup stage (request 1), before any SRP
			// password proof, is a device-identity / client-info problem, not a
			// credential one. A rejection at the SRP stages with a known
			// credential `ec` is genuine; otherwise it is identity/protocol.
			let atLookup = report.stage == "lookup" || report.requestCount <= 1
			if atLookup {
				return ZagNativeSignInFailure(message: "Apple rejected this device before any password was checked (account-lookup stage).",
											  recovery: .deviceIdentity, detail: detail)
			}
			if credentialRejectionCodes.contains(code) {
				return ZagNativeSignInFailure(message: "Apple did not accept the Apple Account or password.", recovery: .checkCredentials, detail: detail)
			}
			return ZagNativeSignInFailure(message: "Apple rejected the sign-in at the \(report.stage ?? "SRP") stage.", recovery: .deviceIdentity, detail: detail)
		case .twoFactorRequired, .twoFactorRequiredAtCeiling:
			return ZagNativeSignInFailure(message: "Two-factor verification was not completed.", recovery: .retry, detail: detail)
		case .httpError(let status):
			if status == 429 { return ZagNativeSignInFailure(message: "Apple is rate-limiting sign-in.", recovery: .waitAndRetry, detail: detail) }
			return ZagNativeSignInFailure(message: "Apple's sign-in service returned HTTP \(status).", recovery: .waitAndRetry, detail: detail)
		case .transportFailed:
			return ZagNativeSignInFailure(message: "Could not reach Apple. Check the network connection.", recovery: .retry, detail: detail)
		case .notProvisioned:
			return ZagNativeSignInFailure(message: "This iPhone has no on-device provisioning profile yet.", recovery: .provisionADI, detail: detail)
		}
	}

	/// A sanitized, human-readable one-line diagnostic. Contains only the stage,
	/// Apple `ec`, HTTP status, Apple's pre-sanitized message and — when a request
	/// was refused before it left the device — the refusal's class and reason
	/// (e.g. `verificationInitiation/no-consent`, `transport/method-put`). No
	/// secrets: the refusal record is only a class name and a fixed reason string.
	static func diagnostic(stage: String?, ec: Int?, http: Int?, message: String?, requestCount: Int,
						   refusals: [[String: String]] = []) -> String? {
		var parts: [String] = []
		if let stage { parts.append("stage \(stage)") } else { parts.append("request \(requestCount)") }
		if let ec { parts.append("Apple ec \(ec)") }
		if let http { parts.append("HTTP \(http)") }
		if let message, !message.isEmpty { parts.append(message) }
		if let r = refusals.first, let cls = r["class"], let reason = r["reason"] {
			parts.append("refused: \(cls)/\(reason)")
		}
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}
