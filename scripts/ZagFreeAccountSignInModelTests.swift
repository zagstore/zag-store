import Foundation

// Sign-in screen state transitions: the model the debug screen binds to,
// driving the real authenticator against the debug simulation. Synthetic
// credentials only; nothing contacts Apple or an anisette provider.

final class MemoryPreferences: ZagPreferenceStore {
	var values: [String: Data] = [:]
	func data(forKey key: String) -> Data? { values[key] }
	func set(_ data: Data?, forKey key: String) { values[key] = data }
	var all: String { values.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") }
}

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	var failDeletes = false
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
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

@MainActor
final class Fixture {
	let clock = ZagSimulationClock()
	let preferences = MemoryPreferences()
	let secrets = MemorySecrets()
	let diagnostics = ZagFreeAccountDiagnostics()
	let service: ZagSimulatedAuthenticationService
	let model: ZagFreeAccountSignInModel

	init(_ scenario: ZagFreeAccountSimulation.Scenario, timeout: TimeInterval = 8) {
		service = ZagSimulatedAuthenticationService(scenario: scenario, latency: 0, clock: clock)
		model = ZagFreeAccountSignInModel(
			authenticator: ZagFreeAccountSimulation.makeAuthenticator(
				service: service, clock: clock, secrets: secrets, preferences: preferences,
				diagnostics: diagnostics, operationTimeout: timeout
			),
			diagnostics: diagnostics
		)
	}

	func enter(appleID: String = ZagFreeAccountSimulation.appleID, password: String = ZagFreeAccountSimulation.password) {
		model.appleID = appleID
		model.password = password
	}

	/// Neither preferences nor the Keychain hold a password or a code.
	var nothingSecretStored: Bool {
		let stored = preferences.all + "\n" + secrets.all
		return [ZagFreeAccountSimulation.password, "wrong-password", ZagFreeAccountSimulation.verificationCode, "111111"].allSatisfy { !stored.contains($0) }
	}
}

@main @MainActor struct Tests {
	static var passed = 0
	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static func main() async {
		await successfulSignIn()
		await incorrectCredentials()
		await twoFactorRetries()
		await cancellation()
		await sessionExpiry()
		await signOut()
		await otherFailures()
		print("SUCCESS: \(passed) sign-in screen state checks passed")
	}

	static func successfulSignIn() async {
		let f = Fixture(.signInSucceeds)
		await f.model.restore()
		check(f.model.phase == .signedOut && !f.model.canSubmitCredentials, "starts signed out; Sign In disabled until both fields are filled")
		f.enter()
		check(f.model.canSubmitCredentials, "Sign In enabled with an account and password")
		await f.model.signIn()
		check(f.model.password.isEmpty, "the password field is cleared on submit")
		guard case .signedIn(let session) = f.model.state else { return check(false, "signed in") }
		check(f.model.phase == .signedIn && !f.model.isBusy && f.model.prompt == nil, "signs in without a code when none is asked")
		check(session.maskedAppleID == "t•••@example.invalid" && session.team.kind == .personalFree, "shows the masked account and the Personal Team")
		check(f.preferences.values.keys.sorted() == [ZagFreeAccountSimulation.sessionKey], "simulated sessions use their own preferences key")
		check(f.secrets.items.count == 1 && f.nothingSecretStored, "only the session is stored; no password")
		check(!f.model.canSubmitCredentials, "Sign In is unavailable while signed in")
	}

	static func incorrectCredentials() async {
		let f = Fixture(.trustedDeviceCode)
		f.enter(password: "wrong-password")
		await f.model.signIn()
		check(f.model.failure?.kind == .invalidCredentials && f.model.password.isEmpty, "a wrong password fails with a clear reason and clears the field")
		check(f.model.failure?.message == "Your Apple Account email or password was not accepted.", "the failure message is the user-facing one")
		check(f.secrets.items.isEmpty && f.preferences.values.isEmpty, "a failed sign-in stores nothing")
		f.enter(appleID: "someone@icloud.com")
		await f.model.signIn()
		check(f.model.failure?.kind == .invalidCredentials, "the simulation refuses any real-looking Apple Account")
		f.enter()
		check(f.model.canSubmitCredentials, "Try Again is available after a failure")
		await f.model.signIn()
		check(f.model.phase == .awaitingCode, "retrying with the right password reaches the code prompt")
	}

	static func twoFactorRetries() async {
		let f = Fixture(.trustedDeviceCode)
		f.enter()
		await f.model.signIn()
		check(f.model.phase == .awaitingCode && f.model.prompt?.codeLength == 6, "a 6-digit verification code is requested")
		check(f.model.prompt?.alternativeAction == "Send Code by Text Message" && f.model.prompt?.isRetry == false, "the prompt offers a text message instead")
		f.model.code = "12"
		check(!f.model.canSubmitCode, "Verify is disabled until the code is complete")
		await f.model.submitCode()
		check(f.model.notice == "Enter the 6-digit code." && f.model.phase == .awaitingCode && f.model.code.isEmpty, "an incomplete code is refused locally")
		f.model.code = "111111"
		await f.model.submitCode()
		check(f.model.prompt?.isRetry == true && f.model.prompt?.attemptsRemaining == 2 && f.model.code.isEmpty && f.model.notice == nil,
			  "a wrong code keeps the prompt open with 2 attempts left and clears the field")
		await f.model.requestCodeBySMS()
		check(f.model.prompt?.message.contains("•• •• 00") == true && f.model.prompt?.alternativeAction == nil, "the text-message code shows a masked number only")
		f.model.code = "123 456"
		check(f.model.canSubmitCode, "spaces in the code are accepted")
		await f.model.submitCode()
		check(f.model.phase == .signedIn && f.model.prompt == nil && f.model.code.isEmpty, "the right code signs in and closes the prompt")
		check(f.nothingSecretStored, "codes are never stored")

		let g = Fixture(.trustedDeviceCode)
		g.enter()
		await g.model.signIn()
		for _ in 0..<3 {
			g.model.code = "111111"
			await g.model.submitCode()
		}
		check(g.model.failure?.kind == .twoFactorRejected && g.model.prompt == nil, "three wrong codes end the sign-in")
	}

	static func cancellation() async {
		let f = Fixture(.trustedDeviceCode)
		f.enter()
		await f.model.signIn()
		f.model.code = "12"
		await f.model.cancel()
		check(f.model.failure?.kind == .cancelled && f.model.prompt == nil && f.model.code.isEmpty, "Cancel at the code prompt ends the sign-in")
		check(f.secrets.items.isEmpty && f.preferences.values.isEmpty, "a cancelled sign-in stores nothing")

		let g = Fixture(.noResponse)
		g.enter()
		let running = Task { await g.model.signIn() }
		try? await Task.sleep(nanoseconds: 200_000_000)
		check(g.model.isBusy, "the screen shows progress while signing in")
		await g.model.cancel()
		await running.value
		check(g.model.failure?.kind == .cancelled && !g.model.isBusy, "Cancel during sign-in stops it")

		let h = Fixture(.noResponse, timeout: 0.3)
		h.enter()
		await h.model.signIn()
		check(h.model.failure?.kind == .network && !h.model.isBusy, "no response within the timeout fails as a network problem")
	}

	static func sessionExpiry() async {
		let f = Fixture(.signInSucceeds)
		f.enter()
		await f.model.signIn()
		await f.model.checkSession()
		check(f.model.phase == .signedIn, "a valid session stays signed in when checked")
		await f.service.setRejectsSessions(true)
		await f.model.checkSession()
		check(f.model.phase == .expired && f.model.state.session != nil, "a revoked session shows as expired, keeping the account shown")

		let g = Fixture(.signInSucceeds)
		g.enter()
		await g.model.signIn()
		g.clock.advance(31 * 86_400)
		await g.model.restore()
		check(g.model.phase == .expired, "a session past its 30-day expiry is expired after relaunch")
		g.enter()
		check(g.model.canSubmitCredentials, "an expired session can sign in again")
		await g.model.signIn()
		check(g.model.phase == .signedIn && g.secrets.items.count == 1, "signing in again replaces the expired session")
	}

	static func signOut() async {
		let f = Fixture(.signInSucceeds)
		f.enter()
		await f.model.signIn()
		f.secrets.failDeletes = true
		await f.model.signOut()
		check(f.model.phase == .signedIn && f.model.notice == "Sign-out could not remove the stored session. Try again.",
			  "a failed sign-out says so and stays signed in")
		f.secrets.failDeletes = false
		await f.model.signOut()
		check(f.model.phase == .signedOut && f.model.notice == nil && f.secrets.items.isEmpty && f.preferences.values.isEmpty,
			  "sign-out removes the session from the Keychain and preferences")
		await f.model.restore()
		check(f.model.phase == .signedOut, "after sign-out a relaunch stays signed out")
		let log = f.diagnostics.entries.map(\.message).joined(separator: "\n")
		check(!log.contains(ZagFreeAccountSimulation.password) && !log.contains("simulated-session") && !log.contains("tester@"),
			  "diagnostics hold no password, token or full account")
	}

	static func otherFailures() async {
		for (scenario, kind) in [
			(ZagFreeAccountSimulation.Scenario.accountLocked, ZagFreeAccountFailure.Kind.accountLocked),
			(.rateLimited, .rateLimited),
			(.networkFailure, .network),
			(.malformedResponse, .unexpectedResponse),
			(.anisetteUnavailable, .anisetteUnavailable)
		] {
			let f = Fixture(scenario)
			f.enter()
			await f.model.signIn()
			check(f.model.failure?.kind == kind && f.secrets.items.isEmpty, "\(scenario.title) shows its own failure and stores nothing")
		}
	}
}
