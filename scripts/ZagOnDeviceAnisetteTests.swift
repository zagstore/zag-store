import Foundation

// Phase C: the on-device apple-auth anisette provider and its broker wiring.
// Host tests — the ZagAppleAuth module is not linked here, so the provider's
// native path is compiled out and reports "not linked"; the header-shaping,
// validation, gating and broker-fallback logic is exercised directly. Nothing
// contacts Apple. The native path itself is validated on device.

@main
struct ZagOnDeviceAnisetteTests {
	static var failures = 0
	static func check(_ condition: Bool, _ name: String) {
		if condition { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
	}

	// A representative header set as apple-auth's aauth_client_headers emits it.
	static let sampleHeaders: [String: String] = [
		"X-Apple-I-MD": "AAAA....", "X-Apple-I-MD-M": "BBBB....", "X-Apple-I-MD-RINFO": "17106176",
		"X-Mme-Device-Id": "00000000-0000-0000-0000-000000000000",
		"X-MMe-Client-Info": "<iPhone15,2> <iPhone OS;17.4;21E219> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
		"X-Apple-I-Client-Time": "2026-11-23T22:00:00Z", "X-Apple-I-TimeZone": "UTC", "X-Apple-Locale": "en_US",
		"User-Agent": "akd/1.0 CFNetwork/1410", "Content-Type": "application/x-www-form-urlencoded"
	]

	static func main() async {
		// 1. Catalogue entry.
		let cat = ZagAnisetteProviderCatalogue.onDevice
		check(cat.kind == .onDevice && cat.identifier == "apple-auth-on-device" && cat.endpoint == nil
			  && cat.evaluation == .pending, "on-device catalogue entry is correct")

		// 2. Production gate: disabled without the experiment flag; factory returns nil.
		check(ZagAppleAuthADI.isEnabled == false, "ADI gate is off in a non-experiment build")
		check(ZagAnisetteProviderFactory.make(cat) == nil, "factory yields no provider in production")

		// 3. Header shaping: only X-Apple-*/X-Mme-* survive, and the result validates.
		let subset = ZagAppleAuthMachine.anisetteSubset(sampleHeaders)
		check(subset["User-Agent"] == nil && subset["Content-Type"] == nil, "non-anisette headers are dropped")
		check(subset["X-Apple-I-MD"] != nil && subset["X-Mme-Device-Id"] != nil
			  && subset["X-MMe-Client-Info"] != nil, "anisette headers are kept")
		do {
			let data = try ZagAnisetteData(validating: subset, obtainedAt: Date())
			check(data.isFresh(at: Date()), "derived anisette data validates and is fresh")
		} catch { check(false, "derived anisette data validates: \(error)") }

		// 4. Validation rejects a non-X-Apple/X-Mme header.
		do { _ = try ZagAnisetteData(validating: ["Bad": "x"], obtainedAt: Date()); check(false, "validator rejects bad header name") }
		catch { check(true, "validator rejects bad header name") }

		// 5. Provider on host (module not linked) reports live providers disabled.
		check(ZagAppleAuthMachine.isLinked == false, "ZagAppleAuth module is not linked in host tests")
		let provider = ZagOnDeviceAnisetteProvider()
		do { _ = try await provider.anisetteData(); check(false, "provider errors when module absent") }
		catch let e as ZagAnisetteError { check(e == .liveProvidersDisabled, "provider reports liveProvidersDisabled when unlinked") }
		catch { check(false, "provider error type: \(error)") }

		// 6. Broker with the on-device config falls back to the disabled provider
		//    while live is off, and reports liveProvidersDisabled.
		let settings = ZagAnisetteProviderSettings(choice: .custom(cat))
		let broker = ZagAnisetteBroker(settings: settings) { ZagAnisetteProviderFactory.make($0) }
		do { _ = try await broker.anisetteData(); check(false, "broker errors while live disabled") }
		catch let e as ZagAnisetteError { check(e == .liveProvidersDisabled, "broker falls back to disabled provider") }
		catch { check(false, "broker error type: \(error)") }

		// 7. GrandSlam status-code parsing (used to classify a sign-in rejection).
		check(ZagAppleAuthMachine.grandSlamCode("GrandSlam complete: Apple authentication rejected (code -22410)") == -22410, "parses -22410")
		check(ZagAppleAuthMachine.grandSlamCode("AKAuthenticationError -80045 bad anisette") == -80045, "parses -80045")
		check(ZagAppleAuthMachine.grandSlamCode("GrandSlam HTTP 503") == nil, "ec parser ignores positive HTTP status")
		check(ZagAppleAuthMachine.grandSlamCode("transport failure, no code") == nil, "nil when no ec present")
		check(ZagAppleAuthMachine.grandSlamHTTPStatus("GrandSlam HTTP 503") == 503, "parses HTTP 503")
		check(ZagAppleAuthMachine.grandSlamHTTPStatus("rejected (code -22410)") == nil, "no HTTP status when absent")
		check(ZagAppleAuthMachine.signInStage(requestCount: 2) == "srp-init"
			  && ZagAppleAuthMachine.signInStage(requestCount: 3) == "srp-complete"
			  && ZagAppleAuthMachine.signInStage(requestCount: 1) == "lookup", "maps request count to stage")

		// 9. Apple `em` extraction + sanitization.
		check(ZagAppleAuthMachine.grandSlamMessage("rejected (code -22410)") == nil, "em absent -> nil")
		check(ZagAppleAuthMachine.grandSlamMessage("code -22410 em=[") == nil, "em malformed (unterminated) -> nil")
		check(ZagAppleAuthMachine.grandSlamMessage("em=[]") == nil, "em empty -> nil")
		check(ZagAppleAuthMachine.grandSlamMessage("em=[This action could not be completed.]")
			  == "This action could not be completed.", "em plain passes through")
		// Sensitive values inside em are redacted.
		let sensitive = ZagAppleAuthMachine.grandSlamMessage("em=[problem for user@example.com now]") ?? ""
		check(!sensitive.contains("@example.com") && !sensitive.contains("user@"), "em redacts an email address")
		// Oversized em is length-bounded with an ellipsis.
		let big = "em=[" + String(repeating: "warn ", count: 100) + "]"
		let bounded = ZagAppleAuthMachine.grandSlamMessage(big, limit: 32) ?? ""
		check(bounded.count <= 33 && bounded.hasSuffix("…"), "em is length-bounded")
		// Control characters are stripped.
		check(!(ZagAppleAuthMachine.sanitizeAppleMessage("a\nb\tc").contains("\n")), "em strips control chars")

		// 7b. Platform / client-info consistency (E2 Mac-identity experiment).
		check(ZagAppleAuthPlatform.mac.clientInfoOS == "macOS"
			  && ZagAppleAuthPlatform.iphone.clientInfoOS == "iPhone OS", "platform OS tokens")
		let macHeaders = ["X-MMe-Client-Info": "<MacBookPro18,3> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"]
		check(ZagAppleAuthMachine.clientInfoConsistent(macHeaders, platform: .mac), "mac headers consistent with .mac")
		check(!ZagAppleAuthMachine.clientInfoConsistent(macHeaders, platform: .iphone), "mac headers inconsistent with .iphone")
		check(ZagAppleAuthMachine.clientInfoConsistent(sampleHeaders, platform: .iphone), "iphone sample consistent with .iphone")
		check(!ZagAppleAuthMachine.clientInfoConsistent(sampleHeaders, platform: .mac), "iphone sample inconsistent with .mac (the -22410 hybrid)")
		check(!ZagAppleAuthMachine.clientInfoConsistent([:], platform: .mac), "missing client-info -> inconsistent")

		// 7d. Legacy Mac identity (E3): client-info OS token, consistency matrix,
		//     header overrides and User-Agent, and shared Mac algorithm.
		check(ZagAppleAuthPlatform.macLegacy.clientInfoOS == "Mac OS X", "macLegacy OS token is 'Mac OS X'")
		check(ZagAppleAuthPlatform.macLegacy.rawValue == "mac-legacy", "macLegacy scope label")
		check(ZagAppleAuthPlatform.macLegacy.usesMacAlgorithm && ZagAppleAuthPlatform.mac.usesMacAlgorithm
			  && !ZagAppleAuthPlatform.iphone.usesMacAlgorithm, "macLegacy shares the Mac algorithm")
		let legacyHeaders = ["X-MMe-Client-Info": "<MacBookPro13,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"]
		check(ZagAppleAuthMachine.clientInfoConsistent(legacyHeaders, platform: .macLegacy), "legacy headers consistent with .macLegacy")
		check(!ZagAppleAuthMachine.clientInfoConsistent(legacyHeaders, platform: .mac), "legacy headers inconsistent with .mac (not 'macOS;')")
		check(!ZagAppleAuthMachine.clientInfoConsistent(legacyHeaders, platform: .iphone), "legacy headers inconsistent with .iphone")
		check(!ZagAppleAuthMachine.clientInfoConsistent(macHeaders, platform: .macLegacy), "mac 'macOS;' headers inconsistent with .macLegacy (the 503 token)")
		// Header overrides: only macLegacy supplies them; values match the
		// independently-confirmed working config; iPhone/Mac supply none.
		check(ZagAppleAuthPlatform.mac.headerOverrides == nil && ZagAppleAuthPlatform.iphone.headerOverrides == nil, "mac/iphone supply no overrides")
		let ov = ZagAppleAuthPlatform.macLegacy.headerOverrides ?? [:]
		check(ov["X-MMe-Client-Info"]?.contains("Mac OS X;") == true && ov["X-MMe-Client-Info"]?.contains("macOS;") == false, "macLegacy override carries the legacy client-info")
		check(ov["User-Agent"] == "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0", "macLegacy override carries the legacy User-Agent")

		// 7c. Safe HTTP diagnostic capture: header-value sanitizer + trace builder.
		check(ZagAppleAuthTransport.sanitizeHeaderValue(nil) == nil, "header value missing -> nil")
		check(ZagAppleAuthTransport.sanitizeHeaderValue("") == nil, "header value empty -> nil")
		check(ZagAppleAuthTransport.sanitizeHeaderValue("   ") == nil, "header value whitespace-only -> nil")
		check(ZagAppleAuthTransport.sanitizeHeaderValue("120") == "120", "numeric Retry-After passes through")
		check(ZagAppleAuthTransport.sanitizeHeaderValue("Wed, 21 Oct 2026 07:28:00 GMT") == "Wed, 21 Oct 2026 07:28:00 GMT", "HTTP-date Retry-After passes through")
		// Malformed: a CRLF-injecting value must not carry control chars through.
		let malformed = ZagAppleAuthTransport.sanitizeHeaderValue("30\r\nX-Injected: evil") ?? ""
		check(!malformed.contains("\r") && !malformed.contains("\n"), "malformed header value is de-controlled (no CRLF)")
		// Oversized: bounded with an ellipsis.
		let oversized = ZagAppleAuthTransport.sanitizeHeaderValue(String(repeating: "A", count: 500), limit: 32) ?? ""
		check(oversized.count <= 33 && oversized.hasSuffix("…"), "oversized header value is length-bounded")
		check(ZagAppleAuthTransport.allowedResponseHeaders == ["retry-after"], "only Retry-After is allowlisted")
		// Stage mapping + trace builder.
		check(ZagAppleAuthMachine.provisionStage(requestCount: 1) == "lookup"
			  && ZagAppleAuthMachine.provisionStage(requestCount: 2) == "start-provisioning"
			  && ZagAppleAuthMachine.provisionStage(requestCount: 3) == "finish-provisioning", "provision stage mapping")
		let rawTrace: [(status: Int, metadata: [String: String])] = [(200, [:]), (200, [:]), (503, ["retry-after": "120"])]
		let built = ZagAppleAuthMachine.httpTrace(rawTrace, stageFor: ZagAppleAuthMachine.signInStage)
		check(built.count == 3 && built[0].stage == "lookup" && built[1].stage == "srp-init"
			  && built[2].stage == "srp-complete" && built[2].status == 503
			  && built[2].metadata["retry-after"] == "120", "trace builder labels stages and keeps allowlisted metadata")

		// 7e. Phase 1 — precise classification of a post-completion ceiling
		//     refusal vs a genuine network error (never from HTTP 200 alone).
		check(ZagAppleAuthMachine.networkErrorOutcome(hitCeiling: true, all200: true) == .twoFactorRequiredAtCeiling,
			  "ceiling refusal after all-200 -> two-factor-required-at-ceiling")
		check(ZagAppleAuthMachine.networkErrorOutcome(hitCeiling: false, all200: true) == .transportFailed,
			  "network error without ceiling refusal -> transport-failed (not 2FA)")
		check(ZagAppleAuthMachine.networkErrorOutcome(hitCeiling: true, all200: false) == .transportFailed,
			  "ceiling refusal but a non-200 occurred -> transport-failed (not 2FA)")

		// 7f. Phase 2 — request classification, per-class ceilings, consent gate,
		//     controller cancellation, session-store round-trip.
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/grandslam/GsService2/lookup", method: "GET") == .authentication, "GsService2/lookup -> authentication")
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/grandslam/GsService2") == .authentication, "GsService2 SRP -> authentication")
		// Opaque URL-bag bases still classify as verification (consent-gated):
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/opaque-secondary", method: "GET") == .verificationInitiation, "post-auth config GET -> verification-initiation")
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/x/verify/phone", method: "PUT") == .verificationInitiation, "SMS delivery PUT -> verification-initiation")
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/opaque-trusteddevice", method: "GET") == .verificationInitiation, "trusted-device push -> verification-initiation")
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/x/verify/phone/securitycode") == .codeSubmission, "SMS securitycode -> code-submission")
		// Trusted-device submit is identified by the security-code request header:
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/opaque-validate", method: "GET", hasSecurityCodeHeader: true) == .codeSubmission, "validateCode w/ security-code header -> code-submission")
		// Regression: validateCode served UNDER /grandslam/GsService2 must still be
		// code-submission (the security-code header wins over the GsService2 path),
		// else it is mis-counted as authentication and exhausts that ceiling.
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/grandslam/GsService2/validate", method: "GET", hasSecurityCodeHeader: true) == .codeSubmission, "GsService2-hosted validateCode w/ header -> code-submission")
		check(ZagAppleAuthRequestClass.classify(url: "https://gsa.apple.com/auth/opaque-validate", method: "GET") == .verificationInitiation, "validate URL w/o header -> verification-initiation")
		check(ZagAppleAuthRequestClass.classify(url: "not-a-url") == .other, "non-https -> other")
		let pol = ZagTwoFactorPolicy()
		check(pol.consentToDeliver == false, "consent defaults to NOT granted")
		check(pol.authenticationCeiling == 5 && pol.verificationInitiationCeiling == 2 && pol.codeSubmissionCeiling == 1, "default per-class ceilings")
		check(pol.allows(.verificationInitiation, alreadyAccepted: 0) == false, "verification delivery refused without consent")
		var consented = pol; consented.consentToDeliver = true
		check(consented.allows(.verificationInitiation, alreadyAccepted: 0) == true, "verification delivery allowed after consent")
		check(consented.allows(.verificationInitiation, alreadyAccepted: 2) == false, "verification delivery refused past its ceiling")
		check(consented.allows(.codeSubmission, alreadyAccepted: 0) == true && consented.allows(.codeSubmission, alreadyAccepted: 1) == false, "code submission capped at 1")
		check(consented.allows(.authentication, alreadyAccepted: 4) == true && consented.allows(.authentication, alreadyAccepted: 5) == false, "authentication capped at 5")
		let denier = ZagDenyingTwoFactorController()
		check(denier.consentToDeliver() == false && denier.provideCode() == nil && denier.didCancel, "denying controller cancels cleanly, no code")
		let sessions = ZagAppleAuthSessionStore()
		try? sessions.delete(scope: "unit-test")
		check(sessions.hasSession(scope: "unit-test") == false, "no session before save")
		try? sessions.save(Data("opaque".utf8), scope: "unit-test")
		check(sessions.hasSession(scope: "unit-test") == true, "session present after save")
		try? sessions.delete(scope: "unit-test")
		check(sessions.hasSession(scope: "unit-test") == false, "session gone after delete")

		#if canImport(SwiftUI)
		let coord = ZagTwoFactorCoordinator()
		check(coord.didCancel == false, "coordinator not cancelled initially")
		coord.cancel()
		check(coord.didCancel == true, "coordinator cancelled after cancel()")
		check(coord.requestConsent() == false, "consent denied once cancelled")
		check(coord.provideCode() == nil, "no code provided once cancelled")
		let choices = ZagTwoFactorCoordinator.parseChoices("[{\"id\":42,\"display_number\":\"(•••) •••-1234\"}]")
		check(choices.count == 1 && choices.first?.id == 42, "phone choices parsed from JSON")
		#endif

		// 8. The gated sign-in experiment is inert when the module is unlinked.
		let signInMachine = ZagAppleAuthMachine()
		do { _ = try await signInMachine.signInExperiment(email: "test@example.com", password: "x", allowNetwork: false)
			 check(false, "sign-in errors when module absent") }
		catch let e as ZagAppleAuthError { check(e == .unavailable, "sign-in reports unavailable when unlinked") }
		catch { check(false, "sign-in error type: \(error)") }

		print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
		exit(failures == 0 ? 0 : 1)
	}
}
