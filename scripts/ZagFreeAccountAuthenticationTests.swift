import Foundation

// Phase 2 groundwork tests. Every service here is a simulation and every
// credential is synthetic; nothing contacts Apple or an anisette provider.

final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Date(timeIntervalSince1970: 1_795_000_000)
	var now: Date { lock.withLock { value } }
	func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class MemoryPreferences: ZagPreferenceStore {
	var values: [String: Data] = [:]
	func data(forKey key: String) -> Data? { values[key] }
	func set(_ data: Data?, forKey key: String) { values[key] = data }
}

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	var failDeletes = false
	var failSaves = false
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		if failSaves { throw ZagKeychainFreeAccountSecretStore.StoreError.keychain(-1) }
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		if failDeletes { throw ZagKeychainFreeAccountSecretStore.StoreError.keychain(-25300) }
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil }
	}
	func deleteAll(account: UUID) throws {
		if failDeletes { throw ZagKeychainFreeAccountSecretStore.StoreError.keychain(-25300) }
		lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } }
	}
	var all: String { lock.withLock { items.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") } }
}

struct FixedAnisette: ZagAnisetteSource {
	let clock: TestClock
	func anisetteData() async throws -> ZagAnisetteData {
		try ZagAnisetteData(validating: ["X-Apple-I-MD": "synthetic-otp", "X-Apple-I-MD-M": "synthetic-machine"], obtainedAt: clock.now)
	}
}

struct FailingAnisette: ZagAnisetteSource {
	let error: Error
	func anisetteData() async throws -> ZagAnisetteData { throw error }
}

struct SimulatedProvider: ZagAnisetteProvider {
	enum Behaviour: Sendable { case ok, fail, slow, stale, malformed }
	let configuration: ZagAnisetteProviderConfiguration
	let behaviour: Behaviour
	let clock: TestClock
	func anisetteData() async throws -> ZagAnisetteData {
		switch behaviour {
		case .ok: return try ZagAnisetteData(validating: ["X-Apple-I-MD": "otp-\(configuration.identifier)"], obtainedAt: clock.now)
		case .fail: throw ZagTransportError.offline
		case .slow:
			try await Task.sleep(nanoseconds: 2_000_000_000)
			return try ZagAnisetteData(validating: ["X-Apple-I-MD": "late"], obtainedAt: clock.now)
		case .stale: return try ZagAnisetteData(validating: ["X-Apple-I-MD": "old"], obtainedAt: clock.now - 3_600)
		case .malformed: return try ZagAnisetteData(validating: ["Authorization": "x"], obtainedAt: clock.now)
		}
	}
}

/// A scripted stand-in for Apple's authentication service.
actor SimulatedService: ZagAppleAuthenticationService {
	enum SignIn: Sendable {
		case authenticated
		case twoFactor(ZagTwoFactorChallenge)
		case error(ZagAuthenticationServiceError)
		case slow
	}

	static let password = "Synthetic-Pass-7Q!"
	static let token = "SYNTHETICTOKEN0123456789abcdefSYNTHETIC"
	static let accountIdentifier = "000123456789"

	var script: SignIn
	var session: @Sendable (Date) -> ZagAuthenticatedSession
	var validity: Result<Bool, ZagAuthenticationServiceError> = .success(true)
	let correctCode = "123456"
	private(set) var signInCalls = 0
	private(set) var submittedCodes: [String] = []
	private(set) var passwordSeenCorrectly = true
	private(set) var smsRequests = 0
	let clock: TestClock

	init(script: SignIn, clock: TestClock, session: @escaping @Sendable (Date) -> ZagAuthenticatedSession = SimulatedService.goodSession) {
		self.script = script
		self.clock = clock
		self.session = session
	}

	static let goodSession: @Sendable (Date) -> ZagAuthenticatedSession = { now in
		ZagAuthenticatedSession(
			credential: ZagSessionCredential(accountIdentifier: accountIdentifier, token: token, expiresAt: now + 30 * 86_400),
			teams: [
				ZagDeveloperTeam(identifier: "PAID000001", name: "Company", kind: .organization),
				ZagDeveloperTeam(identifier: "FREE000001", name: "Personal Team", kind: .personalFree)
			]
		)
	}

	func set(_ script: SignIn) { self.script = script }
	func setValidity(_ value: Result<Bool, ZagAuthenticationServiceError>) { validity = value }

	private func checkPassword(_ password: ZagEphemeralSecret) {
		let ok = (try? password.withBytes { Array($0) == Array(Self.password.utf8) }) ?? false
		passwordSeenCorrectly = passwordSeenCorrectly && ok
	}

	func signIn(appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		signInCalls += 1
		checkPassword(password)
		switch script {
		case .authenticated: return .authenticated(session(clock.now))
		case .twoFactor(let challenge): return .twoFactorRequired(challenge)
		case .error(let error): throw error
		case .slow:
			try await Task.sleep(nanoseconds: 5_000_000_000)
			return .authenticated(session(clock.now))
		}
	}

	func requestCode(by method: ZagTwoFactorMethod, anisette: ZagAnisetteData) async throws -> ZagTwoFactorChallenge {
		smsRequests += 1
		return ZagTwoFactorChallenge(method: .sms, codeLength: 6, maskedDestination: "•• •• 42", canRequestSMS: false)
	}

	func submitCode(_ code: String, challenge: ZagTwoFactorChallenge, appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		submittedCodes.append(code)
		checkPassword(password)
		if code == "999999" { try await Task.sleep(nanoseconds: 5_000_000_000) }
		guard code == correctCode else { throw ZagAuthenticationServiceError.twoFactorRejected }
		return .authenticated(session(clock.now))
	}

	func isValid(_ credential: ZagSessionCredential, anisette: ZagAnisetteData) async throws -> Bool {
		try validity.get()
	}
}

@main struct Tests {
	static var passed = 0
	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static let appleID = "synthetic.tester@example.invalid"
	static let deviceChallenge = ZagTwoFactorChallenge(method: .trustedDevice, codeLength: 6, maskedDestination: nil, canRequestSMS: true)

	struct Harness {
		let clock = TestClock()
		let preferences = MemoryPreferences()
		let secrets = MemorySecrets()
		let diagnostics = ZagFreeAccountDiagnostics()
		let service: SimulatedService
		let authenticator: ZagFreeAccountAuthenticator

		init(_ script: SimulatedService.SignIn, anisette: ZagAnisetteSource? = nil,
			 session: (@Sendable (Date) -> ZagAuthenticatedSession)? = nil, timeout: TimeInterval = 30) {
			let clock = self.clock
			service = SimulatedService(script: script, clock: clock, session: session ?? SimulatedService.goodSession)
			authenticator = ZagFreeAccountAuthenticator(
				service: service,
				anisette: anisette ?? FixedAnisette(clock: clock),
				secrets: secrets,
				sessions: ZagFreeAccountSessionStore(preferences: preferences),
				diagnostics: diagnostics,
				configuration: .init(operationTimeout: timeout, twoFactorWindow: 600, maximumCodeAttempts: 3),
				now: { clock.now }
			)
		}

		var storedSummary: ZagFreeAccountSession? { ZagFreeAccountSessionStore(preferences: preferences).load() }
	}

	static func main() async {
		await secretHandling()
		providerSettings()
		await anisetteBroker()
		transportPolicy()
		await signInWithoutTwoFactor()
		await twoFactorFlows()
		await malformedResponses()
		await unavailableAndFailures()
		await timeoutsAndCancellation()
		await restoreValidateAndSignOut()
		await liveDisabled()
		print("SUCCESS: \(passed) free-account authentication checks passed")
	}

	// MARK: -

	static func secretHandling() async {
		let secret = ZagEphemeralSecret(SimulatedService.password)
		check((try? secret.withBytes { Array($0) }) == Array(SimulatedService.password.utf8), "password bytes are readable during the operation")
		check("\(secret)" == "[secret]" && String(reflecting: secret) == "[secret]", "a password never prints its value")
		secret.wipe()
		check(secret.isWiped, "wiping marks the password gone")
		var threw = false
		do { _ = try secret.withBytes { _ in 0 } } catch { threw = (error as? ZagEphemeralSecret.SecretError) == .wiped }
		check(threw, "a wiped password cannot be read")
		secret.wipe()
		check(secret.isWiped, "wiping twice is harmless")
		check(!ZagFreeAccountSecretKind.allCases.contains { $0.rawValue.lowercased().contains("password") },
			  "there is still no Keychain slot for a password")
		let credential = ZagSessionCredential(accountIdentifier: "1", token: "t", expiresAt: Date())
		check("\(credential)" == "[session credential]", "a session credential never prints its token")
	}

	static func providerSettings() {
		check(ZagAnisetteProviderCatalogue.recommended.evaluation == .pending, "the recommended provider is marked pending evaluation")
		check(ZagAnisetteLive.isEnabled == false && ZagLiveAuthentication.isEnabled == false, "live providers and live sign-in are disabled")
		let custom = try? ZagAnisetteProviderConfiguration.custom("  https://Anisette.Example.org/v3/ ")
		check(custom?.endpoint?.absoluteString == "https://anisette.example.org/v3" && custom?.evaluation == .userSupplied,
			  "a custom provider URL is normalised and marked user-supplied")
		func refused(_ text: String, _ expected: ZagAnisetteProviderConfiguration.URLError) -> Bool {
			do { _ = try ZagAnisetteProviderConfiguration.custom(text); return false } catch { return (error as? ZagAnisetteProviderConfiguration.URLError) == expected }
		}
		check(refused("http://anisette.example.org", .notHTTPS), "plain HTTP providers are refused")
		check(refused("https://user:pw@anisette.example.org", .containsCredentials), "credentials in the URL are refused")
		check(refused("https://anisette.example.org/?key=1", .containsQueryOrFragment), "query strings are refused")
		check(refused("https://", .missingHost), "a URL without a host is refused")
		let preferences = MemoryPreferences()
		let store = ZagAnisetteSettingsStore(preferences: preferences)
		check(store.load() == ZagAnisetteProviderSettings(), "no saved settings means the recommended provider")
		var settings = ZagAnisetteProviderSettings(choice: .custom(custom!))
		try? store.save(settings)
		check(store.load() == settings, "the provider choice persists")
		check(settings.attemptOrder == [custom!], "a custom provider is used alone unless fallback is allowed")
		settings.allowFallbackToRecommended = true
		check(settings.attemptOrder == [custom!, ZagAnisetteProviderCatalogue.recommended], "fallback to the recommended provider only when allowed")
		preferences.values[ZagAnisetteSettingsStore.key] = Data("not json".utf8)
		check(store.load() == ZagAnisetteProviderSettings(), "corrupt settings fall back to the defaults")
		let rejected = ZagAnisetteProviderConfiguration(identifier: "x", name: "x", endpoint: nil, kind: .remote, evaluation: .rejected)
		check(ZagAnisetteProviderSettings(choice: .custom(rejected)).attemptOrder.isEmpty, "a rejected provider is never tried")
	}

	static func anisetteBroker() async {
		let clock = TestClock()
		func config(_ id: String) -> ZagAnisetteProviderConfiguration {
			ZagAnisetteProviderConfiguration(identifier: id, name: id, endpoint: nil, kind: .remote, evaluation: .approved)
		}
		do {
			_ = try ZagAnisetteData(validating: ["X-Apple-I-MD": "a\r\nInjected: 1"], obtainedAt: clock.now)
			check(false, "header injection refused")
		} catch { check((error as? ZagAnisetteData.ValidationError) == .badValue, "anisette values with line breaks are refused") }
		check((try? ZagAnisetteData(validating: [:], obtainedAt: clock.now)) == nil, "empty anisette data is refused")
		check((try? ZagAnisetteData(validating: ["X-Apple-I-MD": "a"], obtainedAt: clock.now))?.description == "[anisette: 1 headers]",
			  "anisette data never prints its values")

		let fallback = ZagAnisetteBroker(providers: [
			SimulatedProvider(configuration: config("down"), behaviour: .fail, clock: clock),
			SimulatedProvider(configuration: config("up"), behaviour: .ok, clock: clock)
		], timeout: 1, now: { clock.now })
		let data = try? await fallback.anisetteData()
		let health = await fallback.health
		check(data?.headers["X-Apple-I-MD"] == "otp-up" && health["down"]?.consecutiveFailures == 1 && health["up"]?.lastSuccess != nil,
			  "an unavailable provider is skipped for the next and recorded in health")
		for (behaviour, expected, label) in [
			(SimulatedProvider.Behaviour.slow, ZagAnisetteError.timedOut, "a provider that does not answer in time times out"),
			(.stale, .invalidResponse, "stale anisette data is refused"),
			(.malformed, .invalidResponse, "malformed anisette headers are refused"),
			(.fail, .providerUnavailable, "an unavailable provider reports unavailable")
		] {
			let broker = ZagAnisetteBroker(providers: [SimulatedProvider(configuration: config("p"), behaviour: behaviour, clock: clock)], timeout: 0.3, now: { clock.now })
			do { _ = try await broker.anisetteData(); check(false, label) } catch { check((error as? ZagAnisetteError) == expected, label) }
		}
		let disabled = ZagAnisetteBroker(settings: ZagAnisetteProviderSettings())
		do { _ = try await disabled.anisetteData(); check(false, "disabled") } catch {
			check((error as? ZagAnisetteError) == .liveProvidersDisabled, "with live providers disabled the broker returns nothing")
		}
	}

	static func transportPolicy() {
		let policy = ZagTransportPolicy(allowedHosts: ["anisette.example.org"])
		func error(_ request: ZagHTTPRequest) -> ZagTransportError? {
			do { try policy.validate(request); return nil } catch { return error as? ZagTransportError }
		}
		let good = ZagHTTPRequest(url: URL(string: "https://Anisette.example.org/v3")!)
		check(error(good) == nil, "an HTTPS request to an allowed host passes")
		check(error(ZagHTTPRequest(url: URL(string: "http://anisette.example.org")!)) == .insecureURL, "plain HTTP is refused")
		check(error(ZagHTTPRequest(url: URL(string: "https://u:p@anisette.example.org")!)) == .insecureURL, "URLs with credentials are refused")
		check(error(ZagHTTPRequest(url: URL(string: "https://evil.example.com")!)) == .hostNotAllowed("evil.example.com"), "hosts outside the allow-list are refused")
		var injected = good
		injected.headers = ["X-Test": "a\r\nEvil: 1"]
		check(error(injected) == .invalidHeader, "header injection is refused")
		var slow = good
		slow.timeout = 600
		check(error(slow) == .invalidTimeout, "unbounded timeouts are refused")
		check((try? policy.validate(url: URL(string: "https://other.example.org/redirect")!)) == nil, "redirects to other hosts are refused")
		check(ZagURLSessionTransport.map(URLError(.timedOut)) == .timedOut && ZagURLSessionTransport.map(URLError(.notConnectedToInternet)) == .offline
			  && ZagURLSessionTransport.map(URLError(.cancelled)) == .cancelled, "URL errors map to timeout, offline and cancelled")
	}

	static func signInWithoutTwoFactor() async {
		let h = Harness(.authenticated)
		let state = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		guard case .signedIn(let summary) = state else { return check(false, "signed in") }
		check(summary.team.kind == .personalFree && summary.team.identifier == "FREE000001", "the free Personal Team is preferred for signing")
		check(summary.maskedAppleID == "s•••@example.invalid", "only the masked Apple ID is kept")
		check(h.storedSummary == summary, "the non-secret summary is saved")
		let stored = h.secrets.items["\(summary.accountID).session"].flatMap { try? JSONDecoder().decode(ZagSessionCredential.self, from: $0) }
		check(stored?.token == SimulatedService.token && h.secrets.items.count == 1, "only the session credential is stored in the Keychain")
		check(!h.secrets.all.contains(SimulatedService.password) && !h.preferences.values.values.contains { String(decoding: $0, as: UTF8.self).contains(SimulatedService.password) },
			  "the password is stored nowhere")
		let seen = await h.service.passwordSeenCorrectly
		check(seen, "the service received the password intact during the operation")
		let again = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret("x"))
		let calls = await h.service.signInCalls
		check(again == state && calls == 1, "a second sign-in while signed in is ignored")
	}

	static func twoFactorFlows() async {
		let h = Harness(.twoFactor(deviceChallenge))
		let password = ZagEphemeralSecret(SimulatedService.password)
		var state = await h.authenticator.signIn(appleID: appleID, password: password)
		check(state == .awaitingTwoFactor(.trustedDevice), "a trusted-device code is requested")
		var prompt = await h.authenticator.twoFactorPrompt
		check(prompt?.codeLength == 6 && prompt?.alternativeAction == "Send Code by Text Message" && prompt?.isRetry == false,
			  "the prompt asks for 6 digits and offers a text message")
		check(!password.isWiped, "the password is kept while the code is awaited")
		state = await h.authenticator.submitCode("12a456")
		let sentAfterMalformed = await h.service.submittedCodes
		check(state == .awaitingTwoFactor(.trustedDevice) && sentAfterMalformed.isEmpty, "a malformed code is refused locally, never sent")
		state = await h.authenticator.submitCode("000 000")
		prompt = await h.authenticator.twoFactorPrompt
		check(state == .awaitingTwoFactor(.trustedDevice) && prompt?.isRetry == true && prompt?.attemptsRemaining == 2,
			  "a wrong code keeps the prompt open with attempts remaining")
		state = await h.authenticator.requestCodeBySMS()
		prompt = await h.authenticator.twoFactorPrompt
		let smsRequests = await h.service.smsRequests
		check(prompt?.message.contains("ending •• •• 42") == true && prompt?.alternativeAction == nil && smsRequests == 1,
			  "switching to SMS shows the masked number only")
		state = await h.authenticator.submitCode("123-456")
		guard case .signedIn = state else { return check(false, "2FA sign-in") }
		check(password.isWiped, "the password is wiped as soon as sign-in completes")
		let sent = await h.service.submittedCodes
		check(sent == ["000000", "123456"], "codes are sent normalised")

		let locked = Harness(.twoFactor(deviceChallenge))
		let lockedPassword = ZagEphemeralSecret(SimulatedService.password)
		_ = await locked.authenticator.signIn(appleID: appleID, password: lockedPassword)
		for _ in 0..<3 { state = await locked.authenticator.submitCode("111111") }
		guard case .failed(let failure) = state else { return check(false, "failed 2FA") }
		check(failure.kind == .twoFactorRejected && lockedPassword.isWiped && locked.storedSummary == nil,
			  "three wrong codes end the sign-in, wipe the password and store nothing")

		let late = Harness(.twoFactor(deviceChallenge))
		_ = await late.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		late.clock.advance(601)
		state = await late.authenticator.submitCode("123456")
		let lateCodes = await late.service.submittedCodes
		check(state.isFailure(.twoFactorRejected) && lateCodes.isEmpty, "a code after the verification window is refused")
	}

	static func malformedResponses() async {
		let cases: [(String, @Sendable (Date) -> ZagAuthenticatedSession)] = [
			("empty token", { now in .init(credential: .init(accountIdentifier: "1", token: "", expiresAt: now + 86_400), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree)]) }),
			("token with whitespace", { now in .init(credential: .init(accountIdentifier: "1", token: "a b", expiresAt: now + 86_400), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree)]) }),
			("already expired", { now in .init(credential: .init(accountIdentifier: "1", token: "t", expiresAt: now - 1), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree)]) }),
			("expiry years away", { now in .init(credential: .init(accountIdentifier: "1", token: "t", expiresAt: now + 3_650 * 86_400), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree)]) }),
			("no teams", { now in .init(credential: .init(accountIdentifier: "1", token: "t", expiresAt: now + 86_400), teams: []) }),
			("invalid team ID", { now in .init(credential: .init(accountIdentifier: "1", token: "t", expiresAt: now + 86_400), teams: [.init(identifier: "bad", name: "P", kind: .personalFree)]) }),
			("duplicate teams", { now in .init(credential: .init(accountIdentifier: "1", token: "t", expiresAt: now + 86_400), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree), .init(identifier: "FREE000001", name: "Q", kind: .personalFree)]) }),
			("empty account identifier", { now in .init(credential: .init(accountIdentifier: "", token: "t", expiresAt: now + 86_400), teams: [.init(identifier: "FREE000001", name: "P", kind: .personalFree)]) })
		]
		for (label, session) in cases {
			let h = Harness(.authenticated, session: session)
			let password = ZagEphemeralSecret(SimulatedService.password)
			let state = await h.authenticator.signIn(appleID: appleID, password: password)
			check(state.isFailure(.unexpectedResponse) && h.secrets.items.isEmpty && h.storedSummary == nil && password.isWiped,
				  "malformed response (\(label)) is rejected and nothing is stored")
		}
		let h = Harness(.authenticated)
		h.secrets.failSaves = true
		let state = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		check(state.isFailure(.unexpectedResponse) && h.storedSummary == nil, "a Keychain write failure leaves no half-stored session")
	}

	static func unavailableAndFailures() async {
		for (error, kind, label) in [
			(ZagAuthenticationServiceError.invalidCredentials, ZagFreeAccountFailure.Kind.invalidCredentials, "wrong password"),
			(.accountLocked, .accountLocked, "locked account"),
			(.rateLimited, .rateLimited, "rate limiting"),
			(.network, .network, "network failure"),
			(.malformedResponse, .unexpectedResponse, "malformed response")
		] {
			let h = Harness(.error(error))
			let password = ZagEphemeralSecret(SimulatedService.password)
			let state = await h.authenticator.signIn(appleID: appleID, password: password)
			check(state.isFailure(kind) && password.isWiped && h.secrets.items.isEmpty, "\(label) fails the sign-in with a clear reason and wipes the password")
		}
		let h = Harness(.authenticated, anisette: FailingAnisette(error: ZagAnisetteError.providerUnavailable))
		let state = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		let serviceCalls = await h.service.signInCalls
		check(state.isFailure(.anisetteUnavailable) && serviceCalls == 0, "an unavailable anisette provider stops sign-in before Apple is contacted")
		let retry = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		check(retry.isFailure(.anisetteUnavailable), "sign-in can be retried after a failure")
	}

	static func timeoutsAndCancellation() async {
		let slow = Harness(.slow, timeout: 0.3)
		let password = ZagEphemeralSecret(SimulatedService.password)
		let state = await slow.authenticator.signIn(appleID: appleID, password: password)
		check(state.isFailure(.network) && password.isWiped && slow.secrets.items.isEmpty, "a service that does not answer in time fails the sign-in")
		check(slow.diagnostics.entries.contains { $0.message.contains("network") }, "the timeout is recorded in diagnostics")

		let cancelled = Harness(.slow)
		let cancelledPassword = ZagEphemeralSecret(SimulatedService.password)
		let running = Task { await cancelled.authenticator.signIn(appleID: appleID, password: cancelledPassword) }
		try? await Task.sleep(nanoseconds: 200_000_000)
		await cancelled.authenticator.cancel()
		let outcome = await running.value
		check(outcome.isFailure(.cancelled) && cancelledPassword.isWiped && cancelled.secrets.items.isEmpty, "cancelling during sign-in stops it and stores nothing")

		let waiting = Harness(.twoFactor(deviceChallenge))
		let waitingPassword = ZagEphemeralSecret(SimulatedService.password)
		_ = await waiting.authenticator.signIn(appleID: appleID, password: waitingPassword)
		await waiting.authenticator.cancel()
		let afterCancel = await waiting.authenticator.state
		let promptAfterCancel = await waiting.authenticator.twoFactorPrompt
		check(afterCancel.isFailure(.cancelled) && waitingPassword.isWiped && promptAfterCancel == nil,
			  "cancelling at the code prompt ends the sign-in and wipes the password")

		let checking = Harness(.twoFactor(deviceChallenge))
		_ = await checking.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		let submit = Task { await checking.authenticator.submitCode("999999") }
		try? await Task.sleep(nanoseconds: 200_000_000)
		await checking.authenticator.cancel()
		let submitted = await submit.value
		check(submitted.isFailure(.cancelled) && checking.storedSummary == nil, "cancelling while a code is checked stores nothing")
	}

	static func restoreValidateAndSignOut() async {
		let h = Harness(.authenticated)
		_ = await h.authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(SimulatedService.password))
		let fresh = ZagFreeAccountAuthenticator(
			service: h.service, anisette: FixedAnisette(clock: h.clock), secrets: h.secrets,
			sessions: ZagFreeAccountSessionStore(preferences: h.preferences), now: { h.clock.now }
		)
		guard case .signedIn = await fresh.restore() else { return check(false, "restore") }
		check(true, "a stored session is restored at launch without contacting Apple")
		await h.service.setValidity(.failure(.network))
		var state = await fresh.validateStoredSession()
		guard case .signedIn = state else { return check(false, "network keeps session") }
		check(true, "a network failure while checking keeps the session")
		await h.service.setValidity(.success(false))
		state = await fresh.validateStoredSession()
		guard case .sessionExpired = state else { return check(false, "rejected session") }
		check(true, "a session Apple rejects becomes expired and asks to sign in again")

		h.clock.advance(31 * 86_400)
		guard case .sessionExpired = await fresh.restore() else { return check(false, "expired restore") }
		check(true, "a session past its expiry is restored as expired")

		h.secrets.failDeletes = true
		var threw = false
		do { try await fresh.signOut() } catch { threw = true }
		check(threw && h.storedSummary != nil, "if the Keychain refuses, sign-out reports it and does not pretend")
		h.secrets.failDeletes = false
		do { try await fresh.signOut() } catch { check(false, "sign-out") }
		let finalState = await fresh.state
		check(finalState == .signedOut && h.secrets.items.isEmpty && h.storedSummary == nil, "sign-out removes the credential and the summary")

		let orphan = Harness(.authenticated)
		try? ZagFreeAccountSessionStore(preferences: orphan.preferences).save(
			ZagFreeAccountSession(accountID: UUID(), maskedAppleID: "s•••@example.invalid",
								  team: .init(identifier: "FREE000001", name: "P", kind: .personalFree),
								  authenticatedAt: orphan.clock.now, expiresAt: nil))
		let orphanState = await orphan.authenticator.restore()
		check(orphanState == .signedOut && orphan.storedSummary == nil,
			  "a summary without its Keychain credential is cleared at launch")

		let diagnostics = h.diagnostics.entries.map(\.message).joined(separator: "\n")
		for secret in [SimulatedService.password, SimulatedService.token, SimulatedService.accountIdentifier, "synthetic.tester", "synthetic-otp"] {
			check(!diagnostics.contains(secret), "diagnostics never contain \(secret.prefix(3))…")
		}
		check(!diagnostics.isEmpty, "diagnostics record the sign-in steps")
	}

	static func liveDisabled() async {
		let clock = TestClock()
		let authenticator = ZagFreeAccountAuthenticator(
			anisette: ZagAnisetteBroker(settings: ZagAnisetteProviderSettings()),
			secrets: MemorySecrets(),
			sessions: ZagFreeAccountSessionStore(preferences: MemoryPreferences()),
			now: { clock.now }
		)
		let password = ZagEphemeralSecret(SimulatedService.password)
		let state = await authenticator.signIn(appleID: appleID, password: password)
		check(state.isFailure(.unavailable) && password.isWiped, "the default build cannot sign in and says sign-in is unavailable")
		let service = ZagDisabledAuthenticationService()
		do {
			_ = try await service.signIn(appleID: appleID, password: password, anisette: try ZagAnisetteData(validating: ["X-Apple-I-MD": "a"], obtainedAt: clock.now))
			check(false, "disabled")
		} catch { check((error as? ZagAuthenticationServiceError) == .liveAuthenticationDisabled, "the live service stub only refuses") }
	}
}

extension ZagFreeAccountState {
	func isFailure(_ kind: ZagFreeAccountFailure.Kind) -> Bool {
		if case .failed(let failure) = self { return failure.kind == kind }
		return false
	}
}
