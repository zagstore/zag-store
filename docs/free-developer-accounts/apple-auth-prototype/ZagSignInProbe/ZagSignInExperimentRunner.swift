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
	static func run(live: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": live ? "live" : "selfcheck"]

		// 1. Fresh anisette through the integrated on-device provider (offline).
		let provider = ZagOnDeviceAnisetteProvider(allowProvisioning: false)
		do {
			let anisette = try await provider.anisetteData()
			report["anisette_header_count"] = anisette.headers.count
			report["anisette_fresh"] = anisette.isFresh(at: Date())
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
		let machine = ZagAppleAuthMachine()
		do {
			let signIn = try await machine.signInExperiment(email: email, password: password, allowNetwork: live)
			report["outcome"] = describe(signIn.outcome)
			if let stage = signIn.stage { report["stage"] = stage }
			report["request_count"] = signIn.requestCount
		} catch {
			report["outcome"] = "error"
		}
		report["result"] = "ran"
		return report
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
