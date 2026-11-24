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
			let dict = try await sendQH65B2(.listTeams, teamID: nil, headers: headers)
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

	/// Read-only DEVICE discovery (item 2): teams -> listDevices, at most TWO
	/// read-only requests, to determine whether this device is ALREADY registered
	/// before any addDevice mutation is ever designed. Reports device_count and,
	/// when ZAG_EXPECT_UDID is set, whether that UDID is present (a bool only) —
	/// never a team id, UDID, token or body. No mutation. Zero requests with no
	/// token or in self-check.
	static func runDeviceDiscovery(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-devices" : "selfcheck-devices", "platform": platform.rawValue, "scope": scope]
		let m = ZagAppleAuthMachine(scope: scope, platform: platform)
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
		let budget = ZagRequestBudget(limit: 2)   // teams + listDevices, read-only, no retry
		do {
			guard budget.take() else { throw ZagPortalError.network }
			let teamsDict = try await sendQH65B2(.listTeams, teamID: nil, headers: headers)
			guard let teamID = ((teamsDict["teams"] as? [[String: Any]])?.first)?["teamId"] as? String else {
				report["result"] = "ran"; report["outcome"] = "no-teams"; report["request_count"] = budget.used
				for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
				return report
			}
			guard budget.take() else { throw ZagPortalError.network }
			let devDict = try await sendQH65B2(.listDevices, teamID: teamID, headers: headers)
			let devices = (devDict["devices"] as? [[String: Any]]) ?? []
			report["result"] = "ran"
			report["http_status"] = 200
			report["result_code"] = (devDict["resultCode"] as? NSNumber)?.intValue ?? 0
			report["device_count"] = devices.count
			// Whether THIS device is already registered (bool only; UDID not logged).
			if let expect = ProcessInfo.processInfo.environment["ZAG_EXPECT_UDID"]?.lowercased(), !expect.isEmpty {
				let present = devices.contains { ($0["deviceNumber"] as? String)?.lowercased() == expect }
				report["expected_udid_registered"] = present
			}
			report["outcome"] = "devices-discovered"
		} catch let e as ZagPortalError {
			report["result"] = "ran"; report["outcome"] = describePortalError(e)
		} catch {
			report["result"] = "ran"; report["outcome"] = "error"
		}
		report["request_count"] = budget.used
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	/// A stable account identity for the experiment's signing key, so retries
	/// address the same Keychain key (no orphaned keys).
	static let experimentCSRAccount = UUID(uuidString: "0E5A0000-0000-4000-8000-000000000001")!

	/// NATIVE CERTIFICATE ISSUANCE (prepared; not run live until authorized).
	/// teams -> certificates (cap preflight) -> submitDevelopmentCSR for a NEW,
	/// non-extractable Keychain key. The CSR is sent only when `allowMutation`
	/// (the consent coordinator authorised `.submitCSR`). Idempotent via
	/// `ZagPendingCSRStore`: a stored request/key is reused, an unconfirmed
	/// submission is resolved against the listing (never blindly resubmitted),
	/// and `certificateLimitReached` stops immediately, preserving the key, with
	/// no revocation. Sanitized report only — no serials, keys, team ids or UDIDs.
	static func runCertificateIssuance(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool, allowMutation: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-csr" : "selfcheck-csr", "platform": platform.rawValue, "scope": scope, "mutation_authorized": allowMutation]
		let m = ZagAppleAuthMachine(scope: scope, platform: platform)
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
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.experiment.csr")
		let factory = ZagKeychainSigningKeyFactory(keys: keys)
		let store = ZagPendingCSRStore()
		let budget = ZagRequestBudget(limit: 3)   // teams + certificates + CSR, no retry
		let now = Date()
		report["result"] = "ran"
		do {
			guard budget.take() else { throw ZagPortalError.network }
			let teamsDict = try await sendQH65B2(.listTeams, teamID: nil, headers: headers)
			guard let teamID = ((teamsDict["teams"] as? [[String: Any]])?.first)?["teamId"] as? String else {
				report["outcome"] = "no-teams"; report["request_count"] = budget.used
				for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
				return report
			}
			guard budget.take() else { throw ZagPortalError.network }
			let (certBody, certStatus) = try await sendV1(path: "certificates", methodOverride: "GET",
														  body: try ZagDeveloperServicesV1.listCertificatesBody(teamID: teamID), headers: headers)
			let existing = try ZagDeveloperServicesV1.parseList(certBody, httpStatus: certStatus)
				.compactMap { ZagDeveloperServicesProtocol.parseCertificate($0) }
			let cap = ZagCertificateCapPreflight.evaluate(certificateCount: existing.count)
			for (k, v) in cap.sanitized { report[k] = v }

			// Resolve or recover any journalled attempt against the live listing.
			var pending = store.load(scope: scope)
			if let p = pending, p.issuedSerial == nil, factory.hasKey(account: experimentCSRAccount, team: teamID, keySlot: p.keySlot) {
				for parsed in existing {
					if let der = parsed.der,
					   case .matches(let serial, _) = factory.check(certificate: der, privateKey: Data(), account: experimentCSRAccount, team: teamID, keySlot: p.keySlot) {
						var done = p; done.issuedSerial = serial; done.submissionUnconfirmed = false
						try? store.save(done, scope: scope); pending = done; break
					}
				}
			}
			// Create a fresh non-extractable key + CSR only when nothing is journalled.
			if pending == nil {
				let made = try factory.makePendingKey(commonName: "Zag Store Development", account: experimentCSRAccount, team: teamID)
				var state = ZagPendingCSRState(keySlot: made.keySlot, request: made.request.data, startedAt: now, attempts: 0, submissionUnconfirmed: false, issuedSerial: nil)
				state.team = teamID   // binds a future operator override to this exact team
				try store.save(state, scope: scope); pending = state
			}
			var state = pending!
			report["pending_key_present"] = factory.hasKey(account: experimentCSRAccount, team: teamID, keySlot: state.keySlot)

			switch state.nextStep(at: now) {
			case .reuseIssued:
				report["outcome"] = "certificate-already-issued"; report["public_key_match"] = true
			case .resolveUnconfirmed:
				report["outcome"] = "submission-unconfirmed-unresolved"   // not found in listing; never resubmit here
			case .exhausted:
				report["outcome"] = "retry-budget-exhausted"              // key preserved for review
			case .submit, .submitAfterReview:
				guard allowMutation else { report["outcome"] = "consent-required"; break }
				// Single-use operator override: CONSUME retryableAfterReview BEFORE
				// sending, persisted first, so a crash cannot reuse it (no replay).
				if state.retryableAfterReview == true {
					state.retryableAfterReview = false
					report["override_consumed"] = true
					try store.save(state, scope: scope)
				}
				guard budget.take() else { throw ZagPortalError.network }
				state.attempts += 1; state.submissionUnconfirmed = true; try store.save(state, scope: scope)
				let (csrBody, csrStatus) = try await qh65b2Body(.submitCSR, teamID: teamID, headers: headers,
					parameters: ["csrContent": ZagDeveloperServicesProtocol.pem(state.request),
								 "machineName": "Zag Store", "machineId": UUID().uuidString.uppercased()])
				if let fault = ZagDeveloperServicesProtocol.fault(body: csrBody, httpStatus: csrStatus) {
					// Record the EXACT sanitized fault and KEEP submissionUnconfirmed
					// (item 3). Clear any stale review evidence so a FRESH reconcile is
					// required before another override (item 10). No revoke (item 9),
					// no resubmit, no key regeneration here.
					state.lastResultCode = fault.resultCode
					state.lastHTTPStatus = fault.httpStatus
					state.lastMessage = fault.message.isEmpty ? nil : fault.message
					state.lastClassification = fault.classification.rawValue
					state.reviewEvidence = nil
					try? store.save(state, scope: scope)
					for (k, v) in fault.sanitized { report[k] = v }
					report["outcome"] = "csr-rejected-" + fault.classification.rawValue
					if fault.classification == .certificateLimitReached {
						report["cap_preflight_was_inferred_risk"] = cap.isInferredRisk
						report["revoke_candidate_count"] = existing.count   // listed only; never auto-revoked
					}
				} else if let dict = (try? PropertyListSerialization.propertyList(from: csrBody, format: nil)) as? [String: Any],
						  let row = (dict["certRequest"] as? [String: Any]) ?? (dict["certificate"] as? [String: Any]),
						  let parsed = ZagDeveloperServicesProtocol.parseCertificate(row), let der = parsed.der {
					let teamAssoc = derContainsASCII(der, teamID)
					if case .matches(let serial, let expiresAt) = factory.check(certificate: der, privateKey: Data(), account: experimentCSRAccount, team: teamID, keySlot: state.keySlot) {
						let notExpired = expiresAt > now
						let valid = notExpired && teamAssoc
						state.issuedSerial = serial; state.submissionUnconfirmed = false; try store.save(state, scope: scope)
						report["public_key_match"] = true
						report["not_expired"] = notExpired
						report["team_association"] = teamAssoc
						report["cert_valid"] = valid
						report["cert_expires_in_days"] = Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.towardZero))
						report["outcome"] = valid ? "certificate-issued" : "certificate-issued-validation-failed"
					} else {
						// A cert came back but does not match our key: never silently
						// adopt it; keep unconfirmed for explicit review.
						report["public_key_match"] = false; report["outcome"] = "certificate-key-mismatch"
					}
				} else {
					// 2xx + resultCode 0 but no parsable certRequest: ambiguous; keep unconfirmed.
					report["outcome"] = "csr-response-unparsed"
				}
			}
		} catch let e as ZagPortalError {
			report["outcome"] = describePortalError(e)
		} catch {
			report["outcome"] = "error"
		}
		report["request_count"] = budget.used
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	/// Whether the certificate DER contains the team identifier as ASCII (the
	/// free-team "Apple Development" subject carries OU=<teamID>). A cheap,
	/// on-device team-association check that needs no X.509 subject parser.
	private static func derContainsASCII(_ der: Data, _ ascii: String) -> Bool {
		let needle = Array(ascii.utf8)
		guard !needle.isEmpty, der.count >= needle.count else { return false }
		let hay = Array(der)
		for i in 0...(hay.count - needle.count) where Array(hay[i..<i+needle.count]) == needle { return true }
		return false
	}

	/// Read-only CERTIFICATE discovery (item 4): teams -> certificates via the
	/// `/services/v1/` JSON API (POST + X-HTTP-Method-Override: GET). At most TWO
	/// read-only requests. Reports cert_count and the nearest expiry in coarse
	/// days — never a serial, team id, token or body. No mutation. Confirms the
	/// current certificate count against the free-team limit before any CSR is
	/// ever submitted. Zero requests with no token or in self-check.
	static func runCertificateDiscovery(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-certs" : "selfcheck-certs", "platform": platform.rawValue, "scope": scope]
		let m = ZagAppleAuthMachine(scope: scope, platform: platform)
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
		let budget = ZagRequestBudget(limit: 2)   // teams + certificates, read-only, no retry
		do {
			guard budget.take() else { throw ZagPortalError.network }
			let teamsDict = try await sendQH65B2(.listTeams, teamID: nil, headers: headers)
			guard let teamID = ((teamsDict["teams"] as? [[String: Any]])?.first)?["teamId"] as? String else {
				report["result"] = "ran"; report["outcome"] = "no-teams"; report["request_count"] = budget.used
				for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
				return report
			}
			guard budget.take() else { throw ZagPortalError.network }
			let (body, status) = try await sendV1(path: "certificates", methodOverride: "GET",
												  body: try ZagDeveloperServicesV1.listCertificatesBody(teamID: teamID), headers: headers)
			let rows = try ZagDeveloperServicesV1.parseList(body, httpStatus: status)
			let certs = rows.compactMap { ZagDeveloperServicesProtocol.parseCertificate($0) }
			report["result"] = "ran"
			report["http_status"] = status
			report["certificate_count"] = certs.count
			// Nearest expiry in coarse days (no serials, no exact dates).
			let now = Date()
			if let soonest = certs.compactMap({ $0.expiresAt }).min() {
				report["nearest_cert_expires_in_days"] = Int((soonest.timeIntervalSince(now) / 86_400).rounded(.towardZero))
			}
			report["outcome"] = "certificates-discovered"
		} catch let e as ZagPortalError {
			report["result"] = "ran"; report["outcome"] = describePortalError(e)
		} catch {
			report["result"] = "ran"; report["outcome"] = "error"
		}
		report["request_count"] = budget.used
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	/// Sends one `/services/v1/` JSON POST (read-only via X-HTTP-Method-Override).
	/// Ephemeral session, no cookies/cache/credentials, redirects refused, pinned
	/// to the developer-services host. Returns the body and HTTP status for the
	/// shared `ZagDeveloperServicesV1` parser.
	private static func sendV1(path: String, methodOverride: String, body: Data, headers: [String: String]) async throws -> (Data, Int) {
		let url = try ZagDeveloperServicesV1.endpoint(path)
		guard url.host == ZagDeveloperServicesV1.host else { throw ZagPortalError.network }
		var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		req.httpMethod = "POST"
		req.httpShouldHandleCookies = false
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		for (k, v) in ZagDeveloperServicesV1.headers(methodOverride: methodOverride) { req.setValue(v, forHTTPHeaderField: k) }
		req.httpBody = body
		let config = URLSessionConfiguration.ephemeral
		config.httpCookieStorage = nil; config.httpShouldSetCookies = false
		config.urlCache = nil; config.urlCredentialStorage = nil; config.waitsForConnectivity = false
		let delegate = ZagNoRedirect()
		let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let (data, response) = try await session.data(for: req)
		guard let http = response as? HTTPURLResponse else { throw ZagPortalError.network }
		return (data, http.statusCode)
	}

	/// Sends one QH65B2 plist POST (any read-only action). Ephemeral session, no
	/// cookies/cache/credentials, redirects refused, pinned to the developer-
	/// services host. Parses with the shared `ZagDeveloperServicesProtocol`.
	/// OFFLINE single-use operator override. After a human has reviewed the
	/// recorded reconciliation evidence, this transitions the journal from
	/// `submissionUnconfirmed` to `retryableAfterReview`. It contacts no one,
	/// submits no CSR and touches no key. The evidence must be a complete
	/// read-only listing that found no matching certificate, bound to this exact
	/// key/CSR/team/account, verdict-unknown, and recent. Never auto-applied, and
	/// it never clears the journal — it only enables exactly one later resubmit.
	static func runReconciliationOverride(platform: ZagAppleAuthPlatform, scope: String) async -> [String: Any] {
		var report: [String: Any] = ["mode": "operator-csr-override", "platform": platform.rawValue, "scope": scope, "request_count": 0]
		let store = ZagPendingCSRStore()
		guard let state = store.load(scope: scope) else {
			report["result"] = "ran"; report["outcome"] = "nothing-pending"
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		report["journal_submission_unconfirmed"] = state.submissionUnconfirmed
		report["journal_retryable_after_review"] = (state.retryableAfterReview == true)
		report["has_evidence"] = (state.reviewEvidence != nil)
		if let e = state.reviewEvidence {
			report["evidence_listing_complete"] = e.listingComplete
			report["evidence_match_found"] = e.matchingPublicKeyFound
			report["evidence_cert_count"] = e.certificateCountObserved
			report["evidence_verdict_unknown"] = e.originalVerdictUnknown
			report["evidence_age_seconds"] = Int(Date().timeIntervalSince(e.observedAt))
		}
		switch ZagReconciliationOverride.apply(to: state, account: experimentCSRAccount.uuidString, now: Date()) {
		case .success(let updated):
			try? store.save(updated, scope: scope)
			report["result"] = "ran"; report["outcome"] = "override-applied"
			report["transition"] = "submissionUnconfirmed->retryableAfterReview"
		case .failure(let rejection):
			report["result"] = "ran"; report["outcome"] = "override-rejected"
			report["rejection"] = rejection.rawValue
		}
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
	}

	private static func sendQH65B2(_ action: ZagDeveloperServicesAction, teamID: String?, headers: [String: String], parameters: [String: Any] = [:]) async throws -> [String: Any] {
		let (data, status) = try await qh65b2Body(action, teamID: teamID, headers: headers, parameters: parameters)
		return try ZagDeveloperServicesProtocol.parse(data, httpStatus: status)
	}

	/// The QH65B2 plist transport: one POST, returning the raw body + HTTP status
	/// WITHOUT classifying the resultCode, so the caller can capture the exact
	/// (sanitized) fault. Ephemeral session, no cookies/cache/credentials,
	/// redirects refused, pinned to the developer-services host.
	private static func qh65b2Body(_ action: ZagDeveloperServicesAction, teamID: String?, headers: [String: String], parameters: [String: Any] = [:]) async throws -> (Data, Int) {
		let url = try ZagDeveloperServicesProtocol.endpoint(action)
		guard url.host == ZagDeveloperServicesProtocol.host else { throw ZagPortalError.network }
		var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		req.httpMethod = "POST"
		req.httpShouldHandleCookies = false
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
		req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
		req.httpBody = try ZagDeveloperServicesProtocol.requestBody(teamID: teamID, parameters: parameters)
		let config = URLSessionConfiguration.ephemeral
		config.httpCookieStorage = nil; config.httpShouldSetCookies = false
		config.urlCache = nil; config.urlCredentialStorage = nil; config.waitsForConnectivity = false
		let delegate = ZagNoRedirect()
		let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let (data, response) = try await session.data(for: req)
		guard let http = response as? HTTPURLResponse else { throw ZagPortalError.network }
		guard data.count <= (1 << 20) else { throw ZagPortalError.malformedResponse }
		return (data, http.statusCode)
	}

	/// READ-ONLY reconciliation of an unconfirmed CSR (no CSR, no revoke, no key
	/// creation). Fetches a FRESH certificate listing, looks for the pending
	/// key's certificate, and applies `ZagCSRReconciliation` using the recorded
	/// submit verdict. A "not found" listing never by itself clears the flag.
	static func runCSRReconcile(platform: ZagAppleAuthPlatform, scope: String, allowNetwork: Bool) async -> [String: Any] {
		var report: [String: Any] = ["mode": allowNetwork ? "live-csr-reconcile" : "selfcheck-csr-reconcile", "platform": platform.rawValue, "scope": scope]
		let m = ZagAppleAuthMachine(scope: scope, platform: platform)
		let store = ZagPendingCSRStore()
		guard let state = store.load(scope: scope) else {
			report["result"] = "ran"; report["outcome"] = "nothing-pending"; report["request_count"] = 0
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		report["journal_submission_unconfirmed"] = state.submissionUnconfirmed
		if let c = state.lastClassification { report["journal_last_classification"] = c }
		if let rc = state.lastResultCode { report["journal_last_result_code"] = rc }
		let verdict = ZagCSRReconciliation.verdict(for: state.lastClassification.flatMap { ZagDeveloperServicesFault.Classification(rawValue: $0) })
		report["submit_verdict"] = "\(verdict)"
		let headers = await m.developerHeaders()
		report["developer_token_persisted"] = (headers != nil)
		guard state.submissionUnconfirmed else {
			report["result"] = "ran"; report["outcome"] = "not-unconfirmed"; report["request_count"] = 0
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		guard let headers, allowNetwork else {
			// Cannot fetch a listing: the listing is unavailable -> preserve.
			let decision = ZagCSRReconciliation.decide(match: .listingUnavailable, submit: verdict)
			report["result"] = "ran"; report["decision"] = "\(decision)"
			report["outcome"] = headers == nil ? "no-developer-token-persisted" : "preflight-no-network"
			report["request_count"] = 0
			for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
			return report
		}
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.experiment.csr")
		let factory = ZagKeychainSigningKeyFactory(keys: keys)
		let budget = ZagRequestBudget(limit: 2)
		report["result"] = "ran"
		do {
			guard budget.take() else { throw ZagPortalError.network }
			let teamsDict = try await sendQH65B2(.listTeams, teamID: nil, headers: headers)
			guard let teamID = ((teamsDict["teams"] as? [[String: Any]])?.first)?["teamId"] as? String else {
				report["outcome"] = "no-teams"; report["request_count"] = budget.used
				for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
				return report
			}
			guard budget.take() else { throw ZagPortalError.network }
			let (certBody, certStatus) = try await sendV1(path: "certificates", methodOverride: "GET",
														  body: try ZagDeveloperServicesV1.listCertificatesBody(teamID: teamID), headers: headers)
			let rows = try ZagDeveloperServicesV1.parseList(certBody, httpStatus: certStatus)
			var match = ZagCSRReconciliation.ListingMatch.notFound
			if factory.hasKey(account: experimentCSRAccount, team: teamID, keySlot: state.keySlot) {
				for row in rows {
					if let der = ZagDeveloperServicesProtocol.parseCertificate(row)?.der,
					   case .matches(let serial, _) = factory.check(certificate: der, privateKey: Data(), account: experimentCSRAccount, team: teamID, keySlot: state.keySlot) {
						match = .found(serial: serial); break
					}
				}
			}
			let decision = ZagCSRReconciliation.decide(match: match, submit: verdict)
			let matchFound: Bool = { if case .found = match { return true }; return false }()
			report["listing_match"] = matchFound ? "found" : "not-found"
			report["decision"] = "\(decision)"
			// Evidence from this complete read-only listing, recorded so a one-time
			// operator override can later be bound to it (never auto-applied).
			let evidence = ZagReconciliationEvidence(
				teamID: teamID, keySlot: state.keySlot, csrSHA256: state.csrFingerprint,
				account: experimentCSRAccount.uuidString, listingComplete: true, httpStatus: 200,
				certificateCountObserved: rows.count, matchingPublicKeyFound: matchFound,
				originalVerdictUnknown: (verdict == .none || verdict == .ambiguous), observedAt: Date())
			var updated = state
			switch decision {
			case .recover(let serial):
				updated.issuedSerial = serial; updated.submissionUnconfirmed = false; try? store.save(updated, scope: scope)
				report["outcome"] = "recovered-issued-certificate"
			case .retryable:
				updated.submissionUnconfirmed = false; updated.reviewEvidence = evidence; try? store.save(updated, scope: scope)
				report["outcome"] = "cleared-retryable"
			case .preserveForReview:
				updated.reviewEvidence = evidence; try? store.save(updated, scope: scope)   // records evidence for operator override
				report["outcome"] = "preserved-needs-review"
				report["override_available"] = true
			case .preserveUnconfirmed:
				report["outcome"] = "preserved-unconfirmed"
			}
			report["http_status"] = 200
		} catch let e as ZagPortalError {
			report["outcome"] = describePortalError(e)
		} catch {
			report["outcome"] = "error"
		}
		report["request_count"] = budget.used
		for (k, v) in await preservationChecks(excluding: scope) { report[k] = v }
		return report
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
