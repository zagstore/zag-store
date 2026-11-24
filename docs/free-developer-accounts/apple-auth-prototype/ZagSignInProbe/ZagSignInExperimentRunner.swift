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

		// The pre-existing profiles (device, mac-experiment) are unchanged — each
		// still derives its headers offline from its untouched scope.
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	/// Offline confirmation that the pre-existing profiles remain intact: each
	/// named scope (except the one under test) still derives consistent headers.
	static func preservationChecks(excluding scope: String) async -> [String: Any] {
		let preserved: [(scope: String, platform: ZagAppleAuthPlatform, key: String)] = [
			("device", .iphone, "iphone_baseline"),
			("mac-experiment", .mac, "mac_experiment")
		]
		var out: [String: Any] = [:]
		for p in preserved where p.scope != scope {
			let m = ZagAppleAuthMachine(scope: p.scope, platform: p.platform)
			do {
				let h = try await m.anisetteHeaders(allowProvisioning: false)
				out["\(p.key)_header_count"] = h.count
				out["\(p.key)_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(h, platform: p.platform)
			} catch { out[p.key] = "unavailable" }
		}
		return out
	}

	static func run(live: Bool, platform: ZagAppleAuthPlatform = .iphone, scope: String = "device", maxRequests: Int = 6) async -> [String: Any] {
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
			let signIn = try await machine.signInExperiment(email: email, password: password, allowNetwork: live, maxRequests: maxRequests)
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
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		report["result"] = "ran"
		return report
	}

	#if canImport(SwiftUI)
	/// The supervised, interactive 2FA run: fresh offline anisette, then one
	/// bounded interactive GrandSlam sign-in that completes the 2FA exchange under
	/// the coordinator's consent/phone/code gates and securely retains the session
	/// on success. Reports only sanitized outcomes — never a code, token or
	/// session. Preserves all three ADI profiles (read-only).
	static func runTwoFactor(platform: ZagAppleAuthPlatform, scope: String, coordinator: ZagTwoFactorCoordinator, allowNetwork: Bool = true, includeDeveloperSession: Bool = false) async -> [String: Any] {
		let label = includeDeveloperSession ? "login-devsession" : "2fa"
		var report: [String: Any] = ["mode": (allowNetwork ? "live-" : "selfcheck-") + label, "platform": platform.rawValue, "scope": scope]
		let m = machine(platform: platform, scope: scope)

		let provider = ZagOnDeviceAnisetteProvider(machine: m, allowProvisioning: false)
		do {
			let anisette = try await provider.anisetteData()
			report["anisette_header_count"] = anisette.headers.count
			report["client_info_consistent"] = ZagAppleAuthMachine.clientInfoConsistent(anisette.headers, platform: platform)
		} catch { report["anisette"] = anisetteLabel(error) }

		guard let credential = ZagSignInCredentialStore().load() else {
			report["credential"] = "absent"; report["result"] = "no-credential"; return report
		}
		report["credential"] = "present"

		do {
			let signIn = try await m.signInWith2FA(email: credential.email, password: credential.password, coordinator: coordinator, allowNetwork: allowNetwork, includeDeveloperSession: includeDeveloperSession)
			report["outcome"] = describe(signIn.outcome)
			if let dOut = signIn.developerOutcome { report["developer_outcome"] = describeDeveloper(dOut) }
			if let t = signIn.developerTokenPresent { report["developer_token_present"] = t }
			if let g = signIn.developerHasGSTokenHeader { report["developer_has_gs_token_header"] = g }
			if let d = signIn.developerExpiresInDays { report["developer_expires_in_days"] = d }
			if let stage = signIn.stage { report["stage"] = stage }
			report["request_count"] = signIn.requestCount
			if let ec = signIn.ec { report["ec"] = ec }
			if let http = signIn.httpStatus { report["http_status"] = http }
			if let message = signIn.appleMessage { report["apple_message"] = message }
			if !signIn.httpTrace.isEmpty { report["http_trace"] = traceDicts(signIn.httpTrace) }
			if let tf = signIn.twoFactorCompleted { report["two_factor_completed"] = tf }
			if let ss = signIn.sessionStored { report["session_stored"] = ss }
			if let byClass = signIn.acceptedByClass { report["accepted_by_class"] = byClass }
			if let refusals = signIn.refusals, !refusals.isEmpty { report["refusals"] = refusals }
		} catch { report["outcome"] = "error" }

		do { let cur = try await m.anisetteHeaders(allowProvisioning: false); report["profile_intact_header_count"] = cur.count }
		catch { report["profile_intact"] = "unavailable" }
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		report["result"] = "ran"
		return report
	}
	#endif

	/// The developer-session experiment: reuse the retained authenticated session
	/// (no GrandSlam login) to exchange one Xcode developer-services token.
	/// `allowNetwork` false is the offline preflight (transport refused). Reports
	/// only sanitized facts; preserves the session and all three ADI profiles.
	static func runDeveloperSession(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-devsession" : "selfcheck-devsession", "platform": platform.rawValue, "scope": scope]
		let m = machine(platform: platform, scope: scope)
		do {
			let ds = try await m.developerSession(allowNetwork: allowNetwork)
			report["outcome"] = describeDeveloper(ds.outcome)
			report["request_count"] = ds.requestCount
			report["token_present"] = ds.tokenPresent
			report["has_gs_token_header"] = ds.hasGSTokenHeader
			if let hc = ds.headerCount { report["developer_header_count"] = hc }
			if let d = ds.expiresInDays { report["expires_in_days"] = d }
			if let ec = ds.ec { report["ec"] = ec }
			if let http = ds.httpStatus { report["http_status"] = http }
			if let message = ds.appleMessage { report["apple_message"] = message }
			if !ds.httpTrace.isEmpty { report["http_trace"] = traceDicts(ds.httpTrace) }
		} catch { report["outcome"] = "error" }
		do { let cur = try await m.anisetteHeaders(allowProvisioning: false); report["profile_intact_header_count"] = cur.count }
		catch { report["profile_intact"] = "unavailable" }
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		report["result"] = "ran"
		return report
	}

	/// Read-only team discovery (Phase 4). Uses the PERSISTED developer token via
	/// the machine's local `developer_headers` bridge (no login, no token
	/// request); then exactly ONE request to developerservices2.apple.com — HTTPS,
	/// no redirect, no retry. Reports only sanitized counts; never a team id,
	/// token, header, cookie or response body. Mirrors the production
	/// `ZagNativeDeveloperPortal.teams()` using the same pure codec. When no token
	/// is persisted, or in self-check, it makes zero requests.
	static func runTeamDiscovery(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-teams" : "selfcheck-teams", "platform": platform.rawValue, "scope": scope]
		let m = ZagAppleAuthMachine(scope: scope, platform: platform)
		// Offline diagnostic: is a token actually in the store, and is it usable?
		// (Isolates a save failure from a bridge failure. No Apple contact.)
		let stored = ZagDeveloperTokenStore().load(scope: scope)
		report["token_in_store"] = (stored != nil)
		report["token_usable"] = (stored?.isUsable(at: Date()) ?? false)
		let headers = await m.developerHeaders()
		report["developer_token_persisted"] = (headers != nil)
		guard let headers else {
			report["result"] = "ran"; report["outcome"] = "no-developer-token-persisted"; report["request_count"] = 0
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		guard allowNetwork else {
			report["result"] = "ran"; report["outcome"] = "preflight-no-network"; report["request_count"] = 0
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		let budget = ZagRequestBudget(limit: 1)   // one aggregate request maximum, no retry
		do {
			guard budget.take() else { throw ZagPortalError.network }
			let dict = try await sendTeamDiscovery(headers: headers)
			let teams = (dict["teams"] as? [[String: Any]]) ?? []
			report["result"] = "ran"
			report["http_status"] = 200
			report["result_code"] = (dict["resultCode"] as? NSNumber)?.intValue ?? 0
			report["team_count"] = teams.count
			if let first = teams.first {
				report["membership_type"] = ((first["memberships"] as? [[String: Any]])?.first?["name"] as? String)
					?? (first["type"] as? String) ?? "unknown"
			}
			report["outcome"] = teams.isEmpty ? "no-teams" : "teams-discovered"
		} catch let e as ZagPortalError {
			report["result"] = "ran"; report["outcome"] = describePortalError(e)
		} catch {
			report["result"] = "ran"; report["outcome"] = "error"
		}
		report["request_count"] = budget.used
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	/// Sends exactly one team-discovery POST. Ephemeral session, no cookies/
	/// cache/credentials, redirects refused, pinned to the developer-services
	/// host. Parses with the shared `ZagDeveloperServicesProtocol`.
	private static func sendTeamDiscovery(headers: [String: String]) async throws -> [String: Any] {
		let url = try ZagDeveloperServicesProtocol.endpoint(.listTeams)
		guard url.host == ZagDeveloperServicesProtocol.host else { throw ZagPortalError.network }
		var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		req.httpMethod = "POST"
		req.httpShouldHandleCookies = false
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
		req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
		req.httpBody = try ZagDeveloperServicesProtocol.requestBody(teamID: nil)
		let config = URLSessionConfiguration.ephemeral
		config.httpCookieStorage = nil; config.httpShouldSetCookies = false
		config.urlCache = nil; config.urlCredentialStorage = nil; config.waitsForConnectivity = false
		let delegate = ZagNoRedirect()
		let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let (data, response) = try await session.data(for: req)
		guard let http = response as? HTTPURLResponse else { throw ZagPortalError.network }
		guard data.count <= (1 << 20) else { throw ZagPortalError.malformedResponse }
		return try ZagDeveloperServicesProtocol.parse(data, httpStatus: http.statusCode)
	}

	static func describePortalError(_ e: ZagPortalError) -> String {
		switch e {
		case .sessionRejected: return "session-rejected"
		case .network: return "network"
		case .rateLimited: return "rate-limited"
		case .malformedResponse: return "malformed-response"
		case .identifierUnavailable: return "identifier-unavailable"
		case .deviceLimitReached: return "device-limit"
		case .appIDLimitReached: return "app-id-limit"
		case .certificateLimitReached: return "certificate-limit"
		case .livePortalDisabled: return "portal-disabled"
		}
	}

	static func describeDeveloper(_ outcome: ZagDeveloperSessionOutcome) -> String {
		switch outcome {
		case .ok: return "developer-session (verified: token + GS header)"
		case .expired: return "expired"
		case .failed: return "failed"
		case .transportFailed: return "transport-failed"
		case .noSession: return "no-session"
		case .notProvisioned: return "not-provisioned"
		}
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
		case .twoFactorRequiredAtCeiling: return "two-factor-required (ceiling reached; SRP verified)"
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

/// Refuses every HTTP redirect: the one team-discovery request may not be
/// redirected off the pinned developer-services host.
final class ZagNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	func urlSession(_ session: URLSession, task: URLSessionTask,
					willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
					completionHandler: @escaping (URLRequest?) -> Void) {
		completionHandler(nil)
	}
}
