import Foundation

// G4: Zag Store's authenticator, account directory and developer-portal
// interface driving the Rust bridge (AppleAuthCore/zag-apple-bridge), linked
// with its scripted test backend. The backend is mocked at the bridge's own
// boundary (outcomes such as "a code is required" or "the session expired"),
// never at the level of Apple's messages. Nothing contacts Apple.

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	private func key(_ kind: ZagFreeAccountSecretKind, _ account: UUID, _ team: String?) -> String { "\(account).\(kind)" + (team.map { ".\($0)" } ?? "") }
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items[key(kind, account, team)] = secret } }
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items[key(kind, account, team)] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items[key(kind, account, team)] = nil } }
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
	func accountIDs() throws -> Set<UUID> { lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) } }
	var allBytes: Data { lock.withLock { items.values.reduce(Data(), +) } }
}

nonisolated(unsafe) var passed = 0

func check(_ condition: Bool, _ name: String) {
	guard condition else {
		print("FAIL: \(name)")
		exit(1)
	}
	passed += 1
	print("PASS: \(name)")
}

let passwordOne = "bridge-test-password-one"
let passwordTwo = "bridge-test-password-two"
let deviceCode = "482913"
let smsCode = "730564"
let issuedCertificate = Data("TEST-CERTIFICATE-DER".utf8)

func team(_ id: String) -> [String: Any] { ["identifier": id, "name": "Personal Team", "kind": "personalFree"] }

let script: [String: Any] = ["accounts": [
	["email": "one@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC1", "teams": [team("BRTEAM0001")],
	 "issuedCertificate": issuedCertificate.base64EncodedString(), "listsCertificateContent": true,
	 "anisetteScope": ZagIsideloadBridge.anisetteScope(forAppleID: "one@bridge.invalid")],
	["email": "two@bridge.invalid", "password": passwordTwo, "accountIdentifier": "BRIDGEACC2", "teams": [team("BRTEAM0002")],
	 "anisetteScope": ZagIsideloadBridge.anisetteScope(forAppleID: "two@bridge.invalid")],
	["email": "codes@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC3", "twoFactor": "trustedDevice",
	 "code": deviceCode, "smsCode": smsCode, "teams": [team("BRTEAM0003")]],
	["email": "offline@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC4", "signInFailure": "network"],
	["email": "slow@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC5", "delayMilliseconds": 30_000],
	["email": "brief@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC6", "sessionLifetime": 1, "teams": [team("BRTEAM0006")]],
	["email": "flaky@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC7", "portalFailure": "network", "teams": [team("BRTEAM0007")]],
	["email": "teams@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC8",
	 "teams": [["identifier": "BRTEAM0008", "name": "Team A", "kind": "unknown"], ["identifier": "BRTEAM0009", "name": "Team B", "kind": "unknown"]]],
	["email": "oneteam@bridge.invalid", "password": passwordOne, "accountIdentifier": "BRIDGEACC9",
	 "teams": [["identifier": "BRTEAM0010", "name": "Team", "kind": "unknown"]]],
]]

func makeDirectory(secrets: MemorySecrets, diagnostics: ZagFreeAccountDiagnostics, localState: ZagAccountLocalState? = nil) -> ZagAccountDirectory {
	var configuration = ZagAccountDirectory.Configuration()
	configuration.localState = localState
	configuration.namespace = "ZagStore.bridge-test.\(UUID().uuidString)"
	configuration.authenticator = .init(operationTimeout: 5, twoFactorWindow: 600, maximumCodeAttempts: 3)
	configuration.makeService = { ZagIsideloadAuthenticationService() }
	return ZagAccountDirectory(
		anisette: ZagBridgeAnisetteSource(allowsTestBackend: true), secrets: secrets,
		preferences: TestPreferences(), diagnostics: diagnostics, configuration: configuration
	)
}

func signedInAccount(_ state: ZagFreeAccountState) -> UUID? {
	if case .signedIn(let session) = state { return session.accountID }
	return nil
}

func failure(_ state: ZagFreeAccountState) -> ZagFreeAccountFailure.Kind? {
	if case .failed(let failure) = state { return failure.kind }
	return nil
}

@main
struct ZagAppleBridgeTests {
	static func main() async {
		// Gates first: nothing in this build can go live.
		check(!ZagIsideloadBridge.liveCompiled, "gate: the linked bridge has no network access (built without `live`)")
		check(!ZagIsideloadBridge.configureLive(anisetteURL: URL(string: "https://anisette.invalid")!, deviceSerial: "C02ZAGTEST01"),
			  "gate: configuring the live backend is refused while the live switches are off")
		do {
			_ = try await ZagBridgeAnisetteSource().anisetteData()
			check(false, "gate: anisette")
		} catch {
			check(error as? ZagAnisetteError == .liveProvidersDisabled, "gate: the bridge's anisette step refuses unless live anisette is enabled")
		}
		let unconfigured = ZagIsideloadAuthenticationService()
		do {
			_ = try await unconfigured.signIn(appleID: "one@bridge.invalid", password: ZagEphemeralSecret(passwordOne),
											  anisette: ZagAnisetteData(managedByBridgeAt: Date()))
			check(false, "gate: unconfigured")
		} catch {
			check(error as? ZagAuthenticationServiceError == .liveAuthenticationDisabled,
				  "gate: before a backend is configured, sign-in fails as disabled")
		}

		let json = try! JSONSerialization.data(withJSONObject: script)
		check(ZagIsideloadBridge.configureMock(json), "the scripted test backend is configured")

		let secrets = MemorySecrets()
		let diagnostics = ZagFreeAccountDiagnostics()
		let directory = makeDirectory(secrets: secrets, diagnostics: diagnostics)

		// Sign-in without a code; the session is stored, the password is not.
		let first = await directory.newSignIn()
		let firstState = await first.signIn(appleID: "one@bridge.invalid", password: ZagEphemeralSecret(passwordOne))
		guard let accountOne = signedInAccount(firstState) else { return check(false, "sign-in: \(firstState)") }
		_ = try? await directory.adopt(first)
		let storedOne = (try? secrets.load(.session, account: accountOne)).flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSessionCredential.self, from: $0) }
		check(storedOne?.accountIdentifier == "BRIDGEACC1", "sign-in: the session credential is stored for its own account")
		if case .signedIn(let session) = firstState {
			check(session.team.identifier == "BRTEAM0001" && session.team.kind == .personalFree, "sign-in: the Personal Team is selected")
		}

		// Anisette state is kept per Apple Account: the scripted backend refuses a
		// sign-in whose anisette scope is not that account's own.
		check(storedOne != nil, "anisette: the account signs in with its own anisette scope")
		let scopeOne = ZagIsideloadBridge.anisetteScope(forAppleID: "one@bridge.invalid")
		check(scopeOne == ZagIsideloadBridge.anisetteScope(forAppleID: " One@Bridge.INVALID\n")
			  && scopeOne != ZagIsideloadBridge.anisetteScope(forAppleID: "two@bridge.invalid"),
			  "anisette: one scope per Apple Account (case and spaces ignored), different for another account")
		check(scopeOne.count == 33 && scopeOne.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && !scopeOne.contains("bridge"),
			  "anisette: the scope is a hash, never the address")
		let scoped = await directory.newSignIn()
		let scopedState = await scoped.signIn(appleID: "two@bridge.invalid", password: ZagEphemeralSecret(passwordTwo))
		check(signedInAccount(scopedState) != nil && signedInAccount(scopedState) != accountOne,
			  "anisette: a second account signs in with its own, different anisette scope")

		// Wrong password and network failure.
		let wrong = await directory.newSignIn()
		check(failure(await wrong.signIn(appleID: "one@bridge.invalid", password: ZagEphemeralSecret("not-the-password"))) == .invalidCredentials,
			  "failure: a wrong password is reported as invalid credentials")
		let offline = await directory.newSignIn()
		check(failure(await offline.signIn(appleID: "offline@bridge.invalid", password: ZagEphemeralSecret(passwordOne))) == .network,
			  "failure: a network failure is reported as such")

		// The Personal Team is never guessed among several unidentified teams.
		let ambiguous = await directory.newSignIn()
		check(failure(await ambiguous.signIn(appleID: "teams@bridge.invalid", password: ZagEphemeralSecret(passwordOne))) == .unexpectedResponse,
			  "fail closed: with several teams of unknown kind, sign-in stops instead of choosing one")
		let single = await directory.newSignIn()
		if case .signedIn(let session) = await single.signIn(appleID: "oneteam@bridge.invalid", password: ZagEphemeralSecret(passwordOne)) {
			check(session.team.kind == .unknown && session.team.hasFreeLimits, "fail closed: a single unidentified team gets the free (strictest) limits")
		} else {
			check(false, "single unknown team")
		}

		// Two-factor: a wrong code, a switch to SMS, then the right code.
		let codes = await directory.newSignIn()
		check(await codes.signIn(appleID: "codes@bridge.invalid", password: ZagEphemeralSecret(passwordOne)) == .awaitingTwoFactor(.trustedDevice),
			  "2FA: a trusted-device code is requested")
		check(await codes.twoFactorPrompt?.alternativeAction != nil, "2FA: a text message can be requested instead")
		let afterWrongCode = await codes.submitCode("000000")
		let retryPrompt = await codes.twoFactorPrompt
		check(afterWrongCode == .awaitingTwoFactor(.trustedDevice) && retryPrompt?.isRetry == true,
			  "2FA: a wrong code keeps the sign-in waiting, marked as a retry")
		_ = await codes.requestCodeBySMS()
		let smsPrompt = await codes.twoFactorPrompt
		check(smsPrompt?.message.contains("ending •• •• 12") == true, "2FA: the SMS prompt shows only the last two digits")
		let codesState = await codes.submitCode(smsCode)
		check(signedInAccount(codesState) != nil, "2FA: the SMS code completes the sign-in")

		// Two wrong codes end the conversation on the backend's side.
		let refused = await directory.newSignIn()
		_ = await refused.signIn(appleID: "codes@bridge.invalid", password: ZagEphemeralSecret(passwordOne))
		_ = await refused.submitCode("000000")
		let refusedState = await refused.submitCode("111111")
		check(refusedState == .awaitingTwoFactor(.trustedDevice) || failure(refusedState) == .twoFactorRejected,
			  "2FA: repeated wrong codes are refused, never accepted")
		let afterRefusal = await refused.submitCode(deviceCode)
		check(signedInAccount(afterRefusal) == nil, "2FA: a code after the backend ended the sign-in does not sign in")

		// Cancellation while waiting for Apple, then the same authenticator is usable.
		let slow = await directory.newSignIn()
		let pendingSlow = Task { await slow.signIn(appleID: "slow@bridge.invalid", password: ZagEphemeralSecret(passwordOne)) }
		try? await Task.sleep(nanoseconds: 150_000_000)
		await slow.cancel()
		let slowState = await pendingSlow.value
		check(signedInAccount(slowState) == nil && slowState != .authenticating, "cancel: a running sign-in ends at once when cancelled")
		let reused = await slow.signIn(appleID: "two@bridge.invalid", password: ZagEphemeralSecret(passwordTwo))
		check(signedInAccount(reused) != nil, "cancel: the authenticator signs in normally afterwards")

		// Cancellation at the code prompt: a new sign-in replaces the abandoned one.
		let abandoned = await directory.newSignIn()
		_ = await abandoned.signIn(appleID: "codes@bridge.invalid", password: ZagEphemeralSecret(passwordOne))
		await abandoned.cancel()
		check(await abandoned.signIn(appleID: "codes@bridge.invalid", password: ZagEphemeralSecret(passwordOne)) == .awaitingTwoFactor(.trustedDevice),
			  "cancel: after cancelling at the code prompt, a new sign-in starts cleanly")
		check(signedInAccount(await abandoned.submitCode(deviceCode)) != nil, "cancel: and completes")

		// The deadline cancels the bridge operation too.
		var quick = ZagAccountDirectory.Configuration()
		quick.namespace = "ZagStore.bridge-test.\(UUID().uuidString)"
		quick.authenticator = .init(operationTimeout: 0.3, twoFactorWindow: 600, maximumCodeAttempts: 3)
		quick.makeService = { ZagIsideloadAuthenticationService() }
		let quickDirectory = ZagAccountDirectory(anisette: ZagBridgeAnisetteSource(allowsTestBackend: true), secrets: MemorySecrets(),
												 preferences: TestPreferences(), configuration: quick)
		let timed = await quickDirectory.newSignIn()
		let started = Date()
		let timedState = await timed.signIn(appleID: "slow@bridge.invalid", password: ZagEphemeralSecret(passwordOne))
		check(signedInAccount(timedState) == nil && Date().timeIntervalSince(started) < 3, "deadline: a sign-in that does not answer is stopped")

		// Expired sessions.
		let service = ZagIsideloadAuthenticationService()
		let anisette = ZagAnisetteData(managedByBridgeAt: Date())
		guard case .authenticated(let brief) = try! await service.signIn(appleID: "brief@bridge.invalid", password: ZagEphemeralSecret(passwordOne), anisette: anisette) else {
			return check(false, "brief session")
		}
		check(try! await service.isValid(brief.credential, anisette: anisette), "session: a fresh session is valid")
		try? await Task.sleep(nanoseconds: 1_200_000_000)
		check(try! await service.isValid(brief.credential, anisette: anisette) == false, "session: an expired session is reported invalid, not as an error")
		let forged = ZagSessionCredential(accountIdentifier: "BRIDGEACC6", token: "forged-token", expiresAt: Date().addingTimeInterval(3600))
		check(try! await ZagIsideloadAuthenticationService().isValid(forged, anisette: anisette) == false, "session: an unknown token is not accepted")

		// Developer portal, per account.
		let portalOne = ZagIsideloadDeveloperPortal(account: accountOne, secrets: secrets)
		let registered = try? await portalOne.registerDevice(udid: "00000000-PLACEHOLDER0000", name: "Test iPhone", team: "BRTEAM0001")
		check(registered?.name == "Test iPhone", "portal: a device is registered for the account's team")
		check((try? await portalOne.devices(team: "BRTEAM0001"))?.count == 1, "portal: the account lists its device")
		let appID = try? await portalOne.registerAppID(bundleIdentifier: "com.example.bridge.notes", name: "Notes", team: "BRTEAM0001")
		check(appID?.bundleIdentifier == "com.example.bridge.notes" && appID?.expiresAt != nil, "portal: an App ID is registered, with its expiry")
		let issued = try? await portalOne.submitCertificateRequest(ZagCertificateRequest(data: Data("CSR".utf8)), team: "BRTEAM0001")
		check(issued?.data == issuedCertificate, "portal: an issued certificate is returned with its DER data")
		let listed = try? await portalOne.certificates(team: "BRTEAM0001")
		check(listed?.count == 1, "portal: the certificate is listed")
		check(listed?.first?.data == issuedCertificate,
			  "portal: a listing that includes certificate content passes it on, so a lost issue response can be recognised by key")
		do {
			_ = try await portalOne.profile(for: appID!, team: "BRTEAM0001")
			check(false, "portal: profile")
		} catch {
			check(error as? ZagPortalError == .malformedResponse, "portal: a missing or unreadable profile is refused, never used")
		}
		do {
			_ = try await portalOne.devices(team: "BRTEAM0002")
			check(false, "portal: other team")
		} catch {
			check(error as? ZagPortalError == .malformedResponse, "portal: another account's team is refused")
		}

		// Account switching: each account has its own portal state, and a slot
		// bound to one account refuses another account's credential.
		let second = await directory.newSignIn()
		guard let accountTwo = signedInAccount(await second.signIn(appleID: "two@bridge.invalid", password: ZagEphemeralSecret(passwordTwo))) else {
			return check(false, "second account")
		}
		_ = try? await directory.adopt(second)
		check(accountTwo != accountOne, "accounts: the second Apple Account is a separate account")
		let portalTwo = ZagIsideloadDeveloperPortal(account: accountTwo, secrets: secrets)
		check((try? await portalTwo.devices(team: "BRTEAM0002"))?.isEmpty == true, "accounts: the second account does not see the first account's device")
		let swapped = MemorySecrets()
		try? swapped.save(try! secrets.load(.session, account: accountOne)!, kind: .session, account: accountOne)
		let swappedPortal = ZagIsideloadDeveloperPortal(account: accountOne, secrets: swapped)
		_ = try? await swappedPortal.devices(team: "BRTEAM0001")
		try? swapped.save(try! secrets.load(.session, account: accountTwo)!, kind: .session, account: accountOne)
		do {
			_ = try await swappedPortal.devices(team: "BRTEAM0002")
			check(false, "accounts: swapped credential")
		} catch {
			check(error as? ZagPortalError == .malformedResponse, "accounts: a portal bound to one account refuses another account's session")
		}

		// Portal failures.
		let flaky = await directory.newSignIn()
		guard let flakyAccount = signedInAccount(await flaky.signIn(appleID: "flaky@bridge.invalid", password: ZagEphemeralSecret(passwordOne))) else {
			return check(false, "flaky sign-in")
		}
		do {
			_ = try await ZagIsideloadDeveloperPortal(account: flakyAccount, secrets: secrets).devices(team: "BRTEAM0007")
			check(false, "portal network")
		} catch {
			check(error as? ZagPortalError == .network, "portal: a network failure is reported as such")
		}
		do {
			_ = try await ZagIsideloadDeveloperPortal(account: UUID(), secrets: secrets).devices(team: "BRTEAM0001")
			check(false, "portal: no session")
		} catch {
			check(error as? ZagPortalError == .sessionRejected, "portal: an account without a stored session must sign in again")
		}

		await anisetteStateFollowsTheAccount()

		// Secrets and diagnostics.
		let everything = secrets.allBytes
		for secret in [passwordOne, passwordTwo, deviceCode, smsCode] {
			check(everything.range(of: Data(secret.utf8)) == nil, "secrets: no password or code is stored (\(secret.prefix(6))…)")
		}
		let log = diagnostics.entries.map(\.message).joined(separator: "\n")
		let tokens = [storedOne?.token ?? "?", "mock-session"]
		check(!diagnostics.entries.isEmpty, "diagnostics: events were recorded")
		for secret in [passwordOne, passwordTwo, deviceCode, smsCode] + tokens {
			check(!log.contains(secret), "diagnostics: no password, code or token appears (\(secret.prefix(6))…)")
		}
		check(!log.contains("one@bridge.invalid") && !log.contains("codes@bridge.invalid"), "diagnostics: Apple Account addresses are masked")
		check(String(describing: brief.credential).contains("[session credential]") && !String(describing: brief).contains(brief.credential.token),
			  "diagnostics: credentials describe themselves without the token")

		print("SUCCESS: \(passed) Apple bridge integration checks passed")
	}

	/// The bridge's anisette Keychain items (named `<scope>/<key>`, as the live
	/// storage names them) are each account's local state: recorded at sign-in,
	/// removed with the account, and listed when no account owns them. A test
	/// service keeps this apart from the app's own items.
	static func anisetteStateFollowsTheAccount() async {
		let service = "ZagStore.anisette.bridge-test.\(UUID().uuidString)"
		let state = ZagBridgeAnisetteLocalState(service: service)
		func plant(_ name: String) {
			SecItemAdd([
				kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
				kSecAttrAccount as String: name, kSecValueData as String: Data("opaque".utf8),
			] as CFDictionary, nil)
		}
		defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
		let scopeTwo = ZagIsideloadBridge.anisetteScope(forAppleID: "two@bridge.invalid")
		let stray = "a" + String(repeating: "0", count: 32)
		plant("\(scopeTwo)/adi.pb"); plant("\(scopeTwo)/device.json"); plant("\(stray)/adi.pb")

		let secrets = MemorySecrets()
		let directory = makeDirectory(secrets: secrets, diagnostics: ZagFreeAccountDiagnostics(), localState: state)
		let signIn = await directory.newSignIn()
		guard let account = signedInAccount(await signIn.signIn(appleID: "two@bridge.invalid", password: ZagEphemeralSecret(passwordTwo))),
			  (try? await directory.adopt(signIn)) != nil else { return check(false, "anisette state: sign-in") }
		check((try? ZagAccountKeyIndex.record(of: account, in: secrets))??.localStateScopes == [scopeTwo],
			  "anisette state: the account's anisette scope is recorded with it at sign-in")
		check((try? await directory.orphanedItems())?.localStateScopes == [stray],
			  "anisette state: state no account's record names is listed as orphaned; the account's own is not")

		var ledger = ZagRefreshLedger()
		guard let plan = try? await directory.removalPlan(for: account, ledger: ledger),
			  (try? await directory.remove(plan.confirm(.forgetRecords), ledger: &ledger)) != nil else { return check(false, "anisette state: removal") }
		check((try? state.scopes()) == [stray], "anisette state: removing the account removes its anisette items, and only those")
		let result = try? await directory.removeOrphanedItems(ZagOrphanedAccountItems(accounts: [], localStateScopes: [stray]))
		check(result?.removedLocalState == [stray] && (try? state.scopes())?.isEmpty == true,
			  "anisette state: confirmed cleanup removes orphaned anisette state")
		check(!ZagIsideloadBridge.isValidAnisetteScope("../x") && (try? state.remove(scope: "")) == nil,
			  "anisette state: an invalid scope is refused before anything is deleted")
		check((ZagAppleAccountsFeature.configuration().localState as? ZagBridgeAnisetteLocalState)?.service == ZagBridgeAnisetteKeychain.service,
			  "anisette state: with the bridge, the production directory removes and lists the bridge's anisette state")
	}
}
