import Foundation

// The shared sign-in experiment, exercising the REAL Phase C integration:
// ZagOnDeviceAnisetteProvider generates fresh on-device anisette, then
// ZagAppleAuthMachine.signInExperiment performs at most one bounded GrandSlam
// SRP sign-in using the existing provisioned profile (no re-provisioning) — the
// same apple-auth client, not a parallel implementation. `live == false` runs
// the whole path with the transport refused (offline self-check, no Apple
// contact); `live == true` is the single authorised attempt.
//
// Output carries only classifications and counts: never a credential, session,
// token or anisette value.

enum ZagSignInExperimentRunner {
	/// The identity under test. `.iphone`/`device` is the provisioned baseline;
	/// `.mac`/`mac-experiment` is the consistent Mac identity (E2), in its own
	/// Keychain scope so the baseline profile is never touched.
	static func machine(platform: ZagAppleAuthPlatform, scope: String) -> ZagAppleAuthMachine {
		ZagAppleAuthMachine(scope: scope, platform: platform)
	}

	/// Provision a fresh identity (an authorised live step). Reports only
	/// sanitized stats — request count, per-request HTTP statuses, outcome,
	/// consistency, offline re-derivation and the untouched iPhone baseline —
	/// never an anisette value, credential or session.
	static func provision(platform: ZagAppleAuthPlatform, scope: String) async -> [String: Any] {
		var report: [String: Any] = ["mode": "provision", "platform": platform.rawValue, "scope": scope]
		let m = machine(platform: platform, scope: scope)
		do {
			let headers = try await m.anisetteHeaders(allowProvisioning: true)
			report["anisette_header_count"] = headers.count
			report["client_info_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(headers, platform: platform)
			report["result"] = "provisioned"
		} catch {
			report["result"] = "provision-failed"
		}
		report["request_count"] = await m.lastRequestCount
		report["http_statuses"] = await m.lastHTTPStatuses
		report["reached_apple"] = await m.lastReachedApple
		let trace = await m.lastHTTPTrace
		if !trace.isEmpty { report["http_trace"] = traceDicts(trace) }

		// Offline re-derivation: can the stored Mac profile make fresh headers
		// with the transport refused (no Apple contact)?
		if (report["result"] as? String) == "provisioned" {
			do {
				let off = try await m.anisetteHeaders(allowProvisioning: false)
				report["offline_header_count"] = off.count
				report["offline_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(off, platform: platform)
			} catch { report["offline_headers"] = "unavailable" }
		}

		// Condition 8: the original iPhone-labelled profile is unchanged — it
		// still derives its headers offline from the untouched `device` scope.
		let baseline = ZagAppleAuthMachine(scope: "device", platform: .iphone)
		do {
			let h = try await baseline.anisetteHeaders(allowProvisioning: false)
			report["iphone_baseline_header_count"] = h.count
			report["iphone_baseline_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(h, platform: .iphone)
		} catch { report["iphone_baseline"] = "error" }
		return report
	}

	static func run(live: Bool, platform: ZagAppleAuthPlatform = .iphone, scope: String = "device") async -> [String: Any] {
		var report: [String: Any] = ["mode": live ? "live" : "selfcheck", "platform": platform.rawValue, "scope": scope]
		let m = machine(platform: platform, scope: scope)

		// 1. Fresh anisette through the integrated on-device provider (offline),
		//    with the offline client-info/platform consistency assertion.
		let provider = ZagOnDeviceAnisetteProvider(machine: m, allowProvisioning: false)
		do {
			let anisette = try await provider.anisetteData()
			report["anisette_header_count"] = anisette.headers.count
			report["anisette_fresh"] = anisette.isFresh(at: Date())
			report["client_info_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(anisette.headers, platform: platform)
		} catch {
			report["anisette"] = anisetteLabel(error)
		}

		// 2. Load the test credentials (never logged). A live run requires them.
		let credential = ZagSignInCredentialStore().load()
		if credential == nil {
			report["credential"] = "absent"
			if live { report["result"] = "no-credential"; return report }
		} else {
			report["credential"] = "present"
		}
		// Self-check without credentials uses non-sent placeholders; the
		// transport is refused, so nothing leaves the device.
		let email = credential?.email ?? "selfcheck@invalid.local"
		let password = credential?.password ?? "selfcheck-not-sent"

		// 3. One bounded sign-in attempt.
		let machine = m
		do {
			let signIn = try await machine.signInExperiment(email: email, password: password, allowNetwork: live)
			report["outcome"] = describe(signIn.outcome)
			if let stage = signIn.stage { report["stage"] = stage }
			report["request_count"] = signIn.requestCount
			if let ec = signIn.ec { report["ec"] = ec }
			if let http = signIn.httpStatus { report["http_status"] = http }
			if let message = signIn.appleMessage { report["apple_message"] = message }
			if !signIn.httpTrace.isEmpty { report["http_trace"] = traceDicts(signIn.httpTrace) }
		} catch {
			report["outcome"] = "error"
		}

		// Condition 8: both profiles remain intact after the attempt — the
		// sign-in reads the profile read-only (no re-provision, no save), so
		// each scope still derives its headers offline, unchanged.
		do {
			let cur = try await m.anisetteHeaders(allowProvisioning: false)
			report["profile_intact_header_count"] = cur.count
		} catch { report["profile_intact"] = "unavailable" }
		if scope != "device" {
			let baseline = ZagAppleAuthMachine(scope: "device", platform: .iphone)
			do {
				let h = try await baseline.anisetteHeaders(allowProvisioning: false)
				report["iphone_baseline_header_count"] = h.count
				report["iphone_baseline_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(h, platform: .iphone)
			} catch { report["iphone_baseline"] = "error" }
		}
		report["result"] = "ran"
		return report
	}

	/// Renders the sanitized per-request trace as JSON-friendly dicts: stage,
	/// status, and allowlisted metadata (e.g. `retry-after` -> `retry_after`).
	static func traceDicts(_ trace: [ZagHTTPTraceEntry]) -> [[String: Any]] {
		trace.map { entry in
			var d: [String: Any] = ["stage": entry.stage, "status": entry.status]
			for (k, v) in entry.metadata { d[k.replacingOccurrences(of: "-", with: "_")] = v }
			return d
		}
	}

	static func describe(_ outcome: ZagAppleAuthSignInOutcome) -> String {
		switch outcome {
		case .authenticated: return "authenticated"
		case .twoFactorRequired: return "two-factor-required (not submitted)"
		case .rejected(let code): return "rejected(\(code))"
		case .httpError(let status): return "http-error(\(status))"
		case .transportFailed: return "transport-failed"
		case .notProvisioned: return "not-provisioned"
		}
	}

	private static func anisetteLabel(_ error: Error) -> String {
		guard let e = error as? ZagAnisetteError else { return "error" }
		switch e {
		case .liveProvidersDisabled: return "disabled"
		case .providerUnavailable: return "unavailable"
		case .invalidResponse: return "invalid"
		default: return "error"
		}
	}

	/// Writes the sanitized report and logs it (names/counts only).
	static func emit(_ report: [String: Any], name: String) {
		let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
		FileHandle.standardOutput.write(Data("ZAGSIGNIN ".utf8))
		FileHandle.standardOutput.write(data)
		FileHandle.standardOutput.write(Data("\n".utf8))
		let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
		try? data.write(to: out)
	}
}
