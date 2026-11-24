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
