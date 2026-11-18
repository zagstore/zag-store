import Foundation

@main struct Tests {
	static var passed = 0

	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static let day: TimeInterval = 86_400
	static let now = Date(timeIntervalSince1970: 1_795_000_000)
	static let team = "ABCDE12345"
	static let freeTeam = ZagDeveloperTeam(identifier: team, name: "Personal Team", kind: .personalFree)
	static let session = ZagFreeAccountSession(
		accountID: UUID(), maskedAppleID: "p•••@example.com", team: freeTeam, authenticatedAt: now, expiresAt: now + day
	)

	static func main() {
		signingMethods()
		accountState()
		bundleIdentifiers()
		appIDs()
		certificates()
		devicesAndSlots()
		entitlements()
		refreshPolicy()
		refreshLedger()
		redaction()
		secretStoreContract()
		print("SUCCESS: \(passed) free-account foundation checks passed")
	}

	static func signingMethods() {
		check(ZagSigningMethodAvailability.listedMethods() == [.importedCertificate, .byoc],
			  "free Apple Account is not listed until it can sign and install")
		check(ZagSigningMethodAvailability.listedMethods(freeAccountEnabled: true) == [.freeAppleAccount, .importedCertificate, .byoc],
			  "all three methods listed once enabled")
		let none = ZagSigningMethodAvailability.ImportedCertificates(total: 0, usable: 0, nearestExpiry: nil)
		let expired = ZagSigningMethodAvailability.ImportedCertificates(total: 2, usable: 0, nearestExpiry: nil)
		let two = ZagSigningMethodAvailability.ImportedCertificates(total: 3, usable: 2, nearestExpiry: nil)
		check(ZagSigningMethodAvailability.status(of: .importedCertificate, imported: none, freeAccount: .signedOut) == .actionRequired("Import a certificate"),
			  "no imported certificate asks for one")
		check(ZagSigningMethodAvailability.status(of: .importedCertificate, imported: expired, freeAccount: .signedOut) == .actionRequired("All certificates have expired or been revoked"),
			  "only unusable certificates is not ready")
		check(ZagSigningMethodAvailability.status(of: .importedCertificate, imported: two, freeAccount: .signedOut) == .ready(detail: "2 certificates"),
			  "usable certificates are counted")
		check(ZagSigningMethodAvailability.status(of: .byoc, imported: none, freeAccount: .signedOut) == .external("Signed on zagstore.app"),
			  "BYOC is external, not an in-app signer")
		check(!ZagSigningMethod.byoc.signsOnDevice && ZagSigningMethod.freeAppleAccount.signsOnDevice,
			  "free-account signing is on-device")
		check(ZagSigningMethodAvailability.status(of: .freeAppleAccount, imported: none, freeAccount: .signedIn(session)) == .ready(detail: "Personal Team"),
			  "signed-in free account is ready with its team")
		let failure = ZagFreeAccountFailure(kind: .accountLocked, occurredAt: now)
		check(ZagSigningMethodAvailability.status(of: .freeAppleAccount, imported: none, freeAccount: .failed(failure)) == .actionRequired(failure.recovery),
			  "failure shows its recovery action")
	}

	static func accountState() {
		let start = ZagFreeAccountState.signedOut
		check(start.applying(.beginSignIn) == .authenticating, "sign-in starts from signed out")
		check(start.applying(.twoFactorSubmitted) == nil, "a code cannot be submitted without a sign-in")
		check(start.applying(.authenticated(session)) == nil, "cannot become signed in without authenticating")
		let waiting = ZagFreeAccountState.authenticating.applying(.twoFactorRequired(.trustedDevice))
		check(waiting == .awaitingTwoFactor(.trustedDevice), "two-factor challenge is recorded with its method")
		check(waiting?.applying(.twoFactorSubmitted) == .authenticating, "submitting a code resumes authentication")
		let signedIn = ZagFreeAccountState.authenticating.applying(.authenticated(session))
		check(signedIn?.canProvision == true, "only a signed-in session can provision")
		let expired = signedIn?.applying(.sessionRejected)
		check(expired == .sessionExpired(session) && expired?.canProvision == false, "a rejected session stops provisioning")
		check(expired?.session == session, "the expired session keeps its non-secret summary for re-sign-in")
		check(expired?.applying(.beginSignIn) == .authenticating, "expired session signs in again")
		check(signedIn?.applying(.signOut) == .signedOut && waiting?.applying(.signOut) == .signedOut, "sign out works from any state")
		let failure = ZagFreeAccountFailure(kind: .invalidCredentials, occurredAt: now)
		check(waiting?.applying(.failed(failure)) == .failed(failure), "a rejected code fails the sign-in")
		check(signedIn?.applying(.failed(failure)) == nil, "a signed-in account does not fail from a sign-in error")
		check(ZagFreeAccountFailure(kind: .network, occurredAt: now).isTransient && !failure.isTransient
			  && !ZagFreeAccountFailure(kind: .unexpectedResponse, occurredAt: now).isTransient,
			  "only network, anisette and rate-limit failures are retried automatically")
		check(ZagFreeAccountSession.mask(appleID: " person@example.com ") == "p•••@example.com", "Apple ID is masked to its first character")
		check(ZagFreeAccountSession.mask(appleID: "@example.com") == "@•••", "malformed Apple ID reveals nothing more")
		check(!session.isExpired(at: now) && session.isExpired(at: now + day), "session expiry is honoured")
		if let data = try? JSONEncoder().encode(ZagFreeAccountState.signedIn(session)),
		   let text = String(data: data, encoding: .utf8) {
			check(!text.contains("person@") && (try? JSONDecoder().decode(ZagFreeAccountState.self, from: data)) == .signedIn(session),
				  "persisted state round-trips without the Apple ID")
		} else {
			check(false, "state encodes")
		}
	}

	static func bundleIdentifiers() {
		check(ZagDeveloperTeam.isValidIdentifier(team) && !ZagDeveloperTeam.isValidIdentifier("abcde12345")
			  && !ZagDeveloperTeam.isValidIdentifier("ABC"), "team IDs are ten upper-case letters or digits")
		check(ZagBundleIdentifierMapping.mapped("com.example.app", team: team) == "com.example.app.\(team)", "bundle ID gets the team suffix")
		check(ZagBundleIdentifierMapping.mapped("com.example.app.\(team)", team: team) == "com.example.app.\(team)", "mapping is idempotent")
		check(ZagBundleIdentifierMapping.mapped("com..app", team: team) == nil
			  && ZagBundleIdentifierMapping.mapped("com.ex ample", team: team) == nil
			  && ZagBundleIdentifierMapping.mapped("com.example", team: "bad") == nil, "invalid IDs and teams are refused")
		check(ZagBundleIdentifierMapping.mappedExtension("com.example.app.widget", appOriginal: "com.example.app", team: team)
			  == "com.example.app.\(team).widget", "extension stays under its mapped app")
		check(ZagBundleIdentifierMapping.mappedExtension("com.other.share", appOriginal: "com.example.app", team: team)
			  == "com.other.share.\(team)", "foreign-prefix extension is mapped on its own")
		check(ZagBundleIdentifierMapping.mappedExtension("com.example.app.\(team).widget", appOriginal: "com.example.app", team: team)
			  == "com.example.app.\(team).widget", "extension mapping is idempotent")
		check(ZagBundleIdentifierMapping.mappedAppGroup("group.com.example", team: team) == "group.com.example.\(team)"
			  && ZagBundleIdentifierMapping.mappedAppGroup("com.example", team: team) == nil, "app groups must start with group.")
	}

	static func appIDs() {
		let ids = ["a.\(team)", "a.\(team).w"]
		let unknown = ZagAppIDPlan.make(bundleIdentifiers: ids + ids, registered: nil, now: now)
		check(unknown.outcome == .register(ids) && unknown.capacity.source == .unknown,
			  "unsynced capacity is unknown, not a count; duplicates are asked once")
		let registered = (0..<8).map { ZagRegisteredAppID(identifier: "X\($0)", bundleIdentifier: "b\($0)", expiresAt: now + Double($0 + 1) * day) }
			+ [ZagRegisteredAppID(identifier: "OLD", bundleIdentifier: "old", expiresAt: now - 1)]
		let fits = ZagAppIDPlan.make(bundleIdentifiers: ids, registered: registered, now: now)
		check(fits.outcome == .register(ids) && fits.capacity.used == 8 && fits.capacity.available == 2,
			  "expired App IDs free their slot; two new IDs fit in two slots")
		check(fits.capacity.nextSlotFreesAt == now + day, "next slot is the earliest active expiry")
		let full = ZagAppIDPlan.make(bundleIdentifiers: ids + ["c"], registered: registered, now: now)
		check(full.outcome == .capacityExhausted(needed: 3, available: 2, nextSlotFreesAt: now + day),
			  "too many new IDs is reported with when a slot frees; nothing revoked")
		let reuse = ZagAppIDPlan.make(bundleIdentifiers: ["b0", "b1"], registered: registered, now: now)
		check(reuse.outcome == .reuseAll, "refresh reuses existing App IDs and needs no slot")
		let partial = ZagAppIDPlan.make(bundleIdentifiers: ["b0", "new"], registered: registered, now: now)
		check(partial.outcome == .register(["new"]), "only missing App IDs are registered")
	}

	static func certificates() {
		let mine = ZagDevelopmentCertificate(serialNumber: "A1", name: "iPhone Developer", machineName: "Zag Store", expiresAt: now + 300 * day)
		let soon = ZagDevelopmentCertificate(serialNumber: "B2", name: "iPhone Developer", machineName: "Zag Store", expiresAt: now + 2 * day)
		let other = ZagDevelopmentCertificate(serialNumber: "C3", name: "iPhone Developer", machineName: "Mac", expiresAt: now + 200 * day)
		let gone = ZagDevelopmentCertificate(serialNumber: "D4", name: "iPhone Developer", machineName: nil, expiresAt: now - day)
		check(ZagCertificatePlan.make(remote: [other, mine], localKeySerials: ["A1"], limit: 2, now: now) == .reuse(serialNumber: "A1"),
			  "a valid certificate with its key on this device is reused")
		check(ZagCertificatePlan.make(remote: [other], localKeySerials: [], limit: 2, now: now) == .create,
			  "a certificate whose key is elsewhere is not reused; one is created when allowed")
		check(ZagCertificatePlan.make(remote: [soon], localKeySerials: ["B2"], limit: nil, now: now) == .create,
			  "a certificate expiring before a new profile would is not reused")
		check(ZagCertificatePlan.make(remote: [other, soon], localKeySerials: [], limit: 2, now: now)
			  == .userMustRevoke(candidates: [soon, other]), "at the limit the user chooses what to revoke")
		check(ZagCertificatePlan.make(remote: [other, gone], localKeySerials: [], limit: 2, now: now) == .create,
			  "expired certificates do not count against the limit")
		check(ZagCertificatePlan.make(remote: [other, soon, mine], localKeySerials: [], limit: nil, now: now) == .create,
			  "with an unknown limit Apple decides; nothing is revoked")
	}

	static func devicesAndSlots() {
		check(ZagDeviceRegistrationPlan.make(udid: "00008110-ABC", registeredUDIDs: ["00008110-abc"]) == .alreadyRegistered,
			  "a registered device is not registered again (UDID case ignored)")
		check(ZagDeviceRegistrationPlan.make(udid: "new", registeredUDIDs: ["a", "b"]) == .register, "a new device is registered")
		check(ZagDeviceRegistrationPlan.make(udid: "new", registeredUDIDs: ["a", "b", "c"]) == .limitReached(registered: 3),
			  "device limit is reported, not worked around")
		check(ZagInstallSlotPlan.make(installing: "a", installedFreeAccountApps: ["a", "b", "c"]) == .replacesInstalledApp,
			  "refreshing an installed app needs no slot")
		check(ZagInstallSlotPlan.make(installing: "d", installedFreeAccountApps: ["a", "b"]) == .fits(remainingAfterInstall: 0),
			  "the third app fits and uses the last slot")
		check(ZagInstallSlotPlan.make(installing: "d", installedFreeAccountApps: ["c", "a", "b"]) == .full(installed: ["a", "b", "c"]),
			  "a fourth app is refused with the installed list")
	}

	static func entitlements() {
		let bundle = "com.example.app.\(team)"
		let profile: [String: Any] = [
			"application-identifier": "\(team).\(bundle)",
			"com.apple.developer.team-identifier": team,
			"get-task-allow": true,
			"keychain-access-groups": ["\(team).*"],
			"com.apple.security.application-groups": ["group.com.example.\(team)"]
		]
		let requested: [String: Any] = [
			"application-identifier": "ZZZZZ99999.com.example.app",
			"com.apple.developer.team-identifier": "ZZZZZ99999",
			"keychain-access-groups": ["ZZZZZ99999.com.example.shared"],
			"com.apple.security.application-groups": ["group.com.example"],
			"aps-environment": "production",
			"com.apple.developer.icloud-services": ["CloudKit"]
		]
		let result = ZagFreeAccountEntitlements.resolve(requested: requested, profile: profile, team: team, bundleIdentifier: bundle)
		let granted = result.entitlements as NSDictionary
		check(granted["application-identifier"] as? String == "\(team).\(bundle)", "app identifier is the team's, not the original developer's")
		check(granted["com.apple.developer.team-identifier"] as? String == team, "team identifier is rewritten")
		check(granted["keychain-access-groups"] as? [String] == ["\(team).com.example.shared"], "keychain group is retargeted to the team")
		check(granted["com.apple.security.application-groups"] as? [String] == ["group.com.example.\(team)"], "app group is mapped and allowed by the profile")
		check(granted["get-task-allow"] as? Bool == true, "get-task-allow comes from the profile")
		check(granted["aps-environment"] == nil && granted["com.apple.developer.icloud-services"] == nil, "capabilities missing from the profile are not granted")
		check(result.rejected.map(\.key) == ["aps-environment", "com.apple.developer.icloud-services"]
			  && result.rejected.allSatisfy { $0.reason == .notInProfile }, "every left-out entitlement is reported")
		let wrong = ZagFreeAccountEntitlements.resolve(
			requested: ["com.apple.security.application-groups": ["group.other"]], profile: profile, team: team, bundleIdentifier: bundle
		)
		check(wrong.rejected == [.init(key: "com.apple.security.application-groups", reason: .valueNotAllowed)]
			  && wrong.entitlements["com.apple.security.application-groups"] == nil, "an app group not on the profile is refused")
		let bare = ZagFreeAccountEntitlements.resolve(requested: [:], profile: profile, team: team, bundleIdentifier: bundle)
		check(bare.entitlements["keychain-access-groups"] as? [String] == ["\(team).\(bundle)"] && bare.rejected.isEmpty,
			  "an app without keychain groups gets its own default group")
		let mismatch = ZagFreeAccountEntitlements.resolve(requested: [:], profile: profile, team: team, bundleIdentifier: "com.other.\(team)")
		check(mismatch.entitlements["application-identifier"] == nil
			  && mismatch.rejected.contains(.init(key: "application-identifier", reason: .valueNotAllowed)),
			  "a profile for another App ID is detected")
		check(ZagFreeAccountEntitlements.retargetKeychainGroup("com.example.shared", team: team) == "\(team).com.example.shared",
			  "an unprefixed keychain group gets the team prefix")
	}

	static func record(_ id: String, signed: Date, expires: Date, certificate: Date? = nil) -> ZagSignedAppRecord {
		ZagSignedAppRecord(
			bundleIdentifier: id, originalBundleIdentifier: id, signedAt: signed,
			profileExpiresAt: expires, certificateExpiresAt: certificate ?? expires + 300 * day
		)
	}

	static func refreshPolicy() {
		let app = record("a", signed: now, expires: now + 7 * day)
		let urgencies = (0...7).map { app.urgency(at: now + Double($0) * day + 3_600) }
		check(urgencies == [.normal, .normal, .normal, .eligible, .recommended, .urgent, .urgent, .expired],
			  "days 1-3 normal, 4 eligible, 5 recommended, 6-7 urgent, then expired")
		let cut = record("b", signed: now, expires: now + 7 * day, certificate: now + day)
		check(cut.expiresAt == now + day && cut.urgency(at: now) == .urgent, "certificate expiry before the profile's is what counts")
		let short = record("c", signed: now, expires: now + 2 * day)
		check(short.urgency(at: now + 3_600) == .normal && short.urgency(at: now + 1.5 * day) == .urgent,
			  "a shorter profile scales its thresholds instead of starting urgent")
		let year = record("d", signed: now, expires: now + 365 * day)
		check(year.urgency(at: now + 300 * day) == .normal && year.urgency(at: now + 362 * day) == .recommended,
			  "a long profile uses the same time-left thresholds")
		check(app.recommendedRefreshDate() == now + 4 * day, "recommended date is three days before expiry")
		check(app.reminderDates(after: now) == [now + 4 * day, now + 5 * day], "reminders at recommended and urgent")
		check(app.reminderDates(after: now + 4.5 * day) == [now + 5 * day], "past reminders are not scheduled")
	}

	static func refreshLedger() {
		var ledger = ZagRefreshLedger()
		let app = record("a", signed: now, expires: now + 7 * day)
		ledger.record(app)
		check(ledger.begin("missing", at: now, userInitiated: true) == .unknownApp, "unknown apps are not refreshed")
		check(ledger.begin("a", at: now, userInitiated: true) == .started, "refresh starts")
		check(ledger.begin("a", at: now, userInitiated: true) == .alreadyRunning, "overlapping refresh of the same app is refused")
		var threw = false
		do { try ledger.finishSucceeded("a", installedProfileExpiresAt: now + 7 * day, installedCertificateExpiresAt: now + 300 * day, at: now) }
		catch { threw = (error as? ZagRefreshLedger.FinishError) == .notVerified }
		check(threw && ledger.records["a"]?.lastFailure?.reason == .notVerified && ledger.records["a"]?.lastSuccessfulRefresh == nil,
			  "an unchanged expiry is a failure, never reported as success")
		check(ledger.begin("a", at: now + 30, userInitiated: false) == .backingOff(until: now + 60), "automatic retry backs off after a failure")
		check(ledger.begin("a", at: now + 30, userInitiated: true) == .started, "a person asking skips the backoff")
		do {
			try ledger.finishSucceeded("a", installedProfileExpiresAt: now + 9 * day, installedCertificateExpiresAt: now + 300 * day, at: now + 2 * day)
			check(ledger.records["a"]?.expiresAt == now + 9 * day && ledger.records["a"]?.consecutiveFailures == 0
				  && ledger.records["a"]?.lastSuccessfulRefresh == now + 2 * day, "a verified later expiry is recorded as success")
		} catch {
			check(false, "verified refresh succeeds")
		}
		var thrown: ZagRefreshLedger.FinishError?
		do { try ledger.finishSucceeded("a", installedProfileExpiresAt: now + 20 * day, installedCertificateExpiresAt: now + 20 * day, at: now) }
		catch { thrown = error as? ZagRefreshLedger.FinishError }
		check(thrown == .notRunning, "a result for a refresh that is not running is refused")

		_ = ledger.begin("a", at: now, userInitiated: true)
		ledger.finishFailed("a", reason: .signedOut, at: now)
		check(ledger.begin("a", at: now + 30 * day, userInitiated: false) == .backingOff(until: .distantFuture),
			  "failures that need the user are not retried automatically")
		ledger.resolve(.signedOut)
		check(ledger.begin("a", at: now, userInitiated: false) == .started, "signing in again re-enables automatic refresh")
		if let data = try? JSONEncoder().encode(ledger), var restored = try? JSONDecoder().decode(ZagRefreshLedger.self, from: data) {
			restored.recoverAfterLaunch(at: now + 60)
			check(restored.running.isEmpty && restored.records["a"]?.lastFailure?.reason == .interrupted,
				  "a refresh running at relaunch is recorded as interrupted, not done")
		} else {
			check(false, "ledger persists")
		}

		var all = ZagRefreshLedger()
		all.record(record("fresh", signed: now, expires: now + 7 * day))
		all.record(record("soon", signed: now - 5 * day, expires: now + 2 * day - 1))
		all.record(record("gone", signed: now - 8 * day, expires: now - day))
		all.record(record("mid", signed: now - 4 * day, expires: now + 3 * day))
		check(all.refreshAllOrder(at: now) == ["gone", "soon", "mid"], "Refresh All: expired first, then most urgent; fresh apps skipped")
		check(all.refreshAllOrder(at: now, minimum: .normal).last == "fresh", "Refresh All can include every app")
		check(ZagRefreshLedger.backoff(afterFailures: 0) == 0 && ZagRefreshLedger.backoff(afterFailures: 3) == 240
			  && ZagRefreshLedger.backoff(afterFailures: 50) == 6 * 3_600, "backoff doubles from a minute up to six hours")
	}

	static func redaction() {
		let samples: [(String, String)] = [
			("signing in person@example.com", "person@example.com"),
			("X-Apple-I-MD: AAAAABQAAAAQabcdefgh12345678==", "AAAAABQAAAAQ"),
			("X-Apple-GS-Token: c2VjcmV0", "c2VjcmV0"),
			("Cookie: myacinfo=DAWTKNV2abcdef", "DAWTKNV2"),
			("dsid=1234567890 ok", "1234567890"),
			("\"password\": \"hunter22\"", "hunter22"),
			("<key>GsIdmsToken</key><string>MDAwMDE=</string>", "MDAwMDE="),
			("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----", "MIIEpAIBAAKCAQEA"),
			("token 0123456789abcdef0123456789abcdef01", "0123456789abcdef0123456789abcdef01")
		]
		for (input, secret) in samples {
			let output = ZagSensitiveRedactor.redact(input)
			check(!output.contains(secret), "redacted: \(output)")
		}
		let ordinary = "Installed com.example.app.ABCDE12345 (Build 4) in 2.3 s"
		check(ZagSensitiveRedactor.redact(ordinary) == ordinary, "ordinary diagnostics are left readable")
	}

	/// The contract every secret store must meet, checked against an in-memory
	/// store; the Keychain store is checked on the simulator by
	/// test-zag-free-account-keychain.sh.
	static func secretStoreContract() {
		final class MemoryStore: ZagFreeAccountSecretStore, @unchecked Sendable {
			var items: [String: Data] = [:]
			func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws { items["\(account)\(kind)"] = secret }
			func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data? { items["\(account)\(kind)"] }
			func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws { items["\(account)\(kind)"] = nil }
		}
		let store = MemoryStore()
		let a = UUID(), b = UUID()
		try? store.save(Data("one".utf8), kind: .session, account: a)
		try? store.save(Data("two".utf8), kind: .signingPrivateKey, account: a)
		try? store.save(Data("three".utf8), kind: .session, account: b)
		try? store.deleteAll(account: a)
		check(store.items.count == 1 && (try? store.load(.session, account: b)) == Data("three".utf8),
			  "signing out deletes every secret of that account only")
		check(!ZagFreeAccountSecretKind.allCases.map(\.rawValue).contains { $0.lowercased().contains("password") },
			  "the Apple Account password is never a stored secret")
	}
}
