import Foundation

// Offline unit test for ZagNativeSignInClassifier (the pure native-sign-in
// error/phase logic). The engine types it switches over are stubbed here with
// the exact cases of the real ones (ZagAppleAuthMachine.swift); the real-type
// compile is covered by scripts/test-zag-apple-bridge.sh, which compiles the
// classifier against the genuine declarations. This test validates the branch
// logic without the ZagAppleAuth xcframework or a device.

enum ZagAppleAuthSignInOutcome: Equatable {
	case authenticated
	case twoFactorRequired
	case rejected(code: Int)
	case httpError(status: Int)
	case transportFailed
	case notProvisioned
	case twoFactorRequiredAtCeiling
}

enum ZagAppleAuthError: Error, Equatable {
	case unavailable
	case notProvisioned
	case provisioningFailed(Int)
	case transportBlocked
	case malformedHeaders
	case keychain(OSStatus)
}

enum ZagDeveloperSessionOutcome: Equatable {
	case ok, expired, failed, transportFailed, noSession, notProvisioned
}

// The fields the classifier reads from the real report (ZagAppleAuthMachine.swift).
struct ZagAppleAuthSignInReport: Equatable {
	var outcome: ZagAppleAuthSignInOutcome
	var stage: String? = nil
	var requestCount: Int = 0
	var ec: Int? = nil
	var httpStatus: Int? = nil
	var appleMessage: String? = nil
	var developerOutcome: ZagDeveloperSessionOutcome? = nil
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
	if ok { print("ok  - \(what)") } else { failures += 1; print("FAIL- \(what)") }
}

@main
enum ZagNativeSignInClassifierTestMain {
	static func main() {
		// Success
		check(ZagNativeSignInClassifier.failure(outcome: .authenticated, developerOK: true) == nil,
			  "authenticated + developer session OK is not a failure")
		let noDev = ZagNativeSignInClassifier.failure(outcome: .authenticated, developerOK: false)
		check(noDev?.recovery == .retry && (noDev?.message.contains("developer session") ?? false),
			  "authenticated without developer session is a retryable failure")

		// Two-factor not completed
		let tf = ZagNativeSignInClassifier.failure(outcome: .twoFactorRequired, developerOK: false)
		check(tf?.recovery == .retry && (tf?.message.contains("Two-factor") ?? false), "2FA not completed → retry")
		check(ZagNativeSignInClassifier.failure(outcome: .twoFactorRequiredAtCeiling, developerOK: false)?.recovery == .retry,
			  "2FA at ceiling → retry")

		// Rejections
		let codeReject = ZagNativeSignInClassifier.failure(outcome: .rejected(code: -21669), developerOK: false)
		check(codeReject?.recovery == .checkCredentials && (codeReject?.message.contains("verification code") ?? false),
			  "known 2FA code rejection → check credentials, code message")
		let credReject = ZagNativeSignInClassifier.failure(outcome: .rejected(code: -99999), developerOK: false)
		check(credReject?.recovery == .checkCredentials && (credReject?.message.contains("did not accept") ?? false),
			  "other rejection → check credentials, generic message")

		// HTTP
		check(ZagNativeSignInClassifier.failure(outcome: .httpError(status: 429), developerOK: false)?.recovery == .waitAndRetry,
			  "HTTP 429 → wait and retry")
		let http503 = ZagNativeSignInClassifier.failure(outcome: .httpError(status: 503), developerOK: false)
		check(http503?.recovery == .waitAndRetry && (http503?.message.contains("503") ?? false), "HTTP 503 → wait, status shown")

		// Transport / provisioning
		check(ZagNativeSignInClassifier.failure(outcome: .transportFailed, developerOK: false)?.recovery == .retry,
			  "transport failure → retry")
		check(ZagNativeSignInClassifier.failure(outcome: .notProvisioned, developerOK: false)?.recovery == .provisionADI,
			  "not provisioned → provision ADI")

		// Thrown errors
		check(ZagNativeSignInClassifier.failure(error: .unavailable).recovery == .unsupportedBuild, "unavailable → unsupported build")
		check(ZagNativeSignInClassifier.failure(error: .notProvisioned).recovery == .provisionADI, "error notProvisioned → provision ADI")
		check(ZagNativeSignInClassifier.failure(error: .provisioningFailed(3)).recovery == .provisionADI, "provisioningFailed → provision ADI")
		check(ZagNativeSignInClassifier.failure(error: .transportBlocked).recovery == .retry, "transportBlocked → retry")
		check(ZagNativeSignInClassifier.failure(error: .keychain(-25300)).recovery == .retry, "keychain → retry")

		// Report-based classification: stage + ec surfaced, lookup vs SRP distinguished
		let lookup = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .rejected(code: -80045), stage: "lookup", requestCount: 1, ec: -80045), developerOK: false)
		check(lookup?.recovery == .deviceIdentity
			  && (lookup?.detail?.contains("-80045") ?? false) && (lookup?.detail?.contains("lookup") ?? false),
			  "lookup-stage rejection → device identity; detail carries stage + ec")
		let cred = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .rejected(code: -20101), stage: "srp-complete", requestCount: 3, ec: -20101), developerOK: false)
		check(cred?.recovery == .checkCredentials && (cred?.message.contains("Apple Account or password") ?? false),
			  "SRP-stage known credential ec → check credentials")
		let proto = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .rejected(code: -77777), stage: "srp-complete", requestCount: 3, ec: -77777, appleMessage: "could not complete"), developerOK: false)
		check(proto?.recovery == .deviceIdentity && (proto?.detail?.contains("could not complete") ?? false),
			  "SRP-stage unknown ec → device identity; sanitized message in detail")
		let code2fa = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .rejected(code: -21669), stage: "srp-complete", requestCount: 3, ec: -21669), developerOK: false)
		check(code2fa?.recovery == .checkCredentials && (code2fa?.message.contains("verification code") ?? false),
			  "2FA code rejection via report → check credentials")
		let httpR = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .httpError(status: 503), stage: "srp-init", requestCount: 2, httpStatus: 503), developerOK: false)
		check(httpR?.recovery == .waitAndRetry && (httpR?.detail?.contains("HTTP 503") ?? false),
			  "report httpError 503 → wait; detail shows HTTP status")
		let devFail = ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .authenticated, developerOutcome: .failed), developerOK: false)
		check(devFail?.recovery == .retry && (devFail?.detail?.contains("failed") ?? false),
			  "authenticated + developer session failed → retry; detail names developer outcome")
		check(ZagNativeSignInClassifier.failure(
			report: ZagAppleAuthSignInReport(outcome: .authenticated, developerOutcome: .ok), developerOK: true) == nil,
			  "authenticated + developer OK via report → not a failure")

		// Recovery text is always present and non-empty
		let all: [ZagNativeSignInFailure.Recovery] = [.retry, .checkCredentials, .provisionADI, .unsupportedBuild, .waitAndRetry, .deviceIdentity]
		for r in all {
			check(!ZagNativeSignInFailure(message: "x", recovery: r).recoveryText.isEmpty, "recovery text non-empty for \(r)")
		}

		// No message leaks a secret-ish placeholder (sanity: fixed strings only)
		check(ZagNativeSignInClassifier.twoFactorRejectionCodes.contains(-21669), "rejection code set populated")

		if failures == 0 { print("\nPASS: ZagNativeSignInClassifier — all checks passed") }
		else { print("\nFAIL: \(failures) check(s) failed"); exit(1) }
	}
}
