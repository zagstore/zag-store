import Foundation

// MARK: - Password

/// The Apple Account password for one sign-in operation. Its bytes live in a
/// buffer that is zeroed when the operation ends (success, failure, cancel or
/// timeout) and on deinit. It is not Codable and never printed.
///
/// Limit: the `String` the text field produced cannot be wiped by Swift; the
/// sign-in screen must drop its copy as soon as this object is created.
final class ZagEphemeralSecret: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
	enum SecretError: Error, Equatable { case wiped }

	private let lock = NSLock()
	private var buffer: UnsafeMutableRawBufferPointer?

	init(_ text: String) {
		let bytes = Array(text.utf8)
		let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
		storage.initializeMemory(as: UInt8.self, repeating: 0)
		storage.copyBytes(from: bytes)
		buffer = UnsafeMutableRawBufferPointer(rebasing: storage[0..<bytes.count])
		allocation = storage
	}

	private var allocation: UnsafeMutableRawBufferPointer?

	var isWiped: Bool { lock.withLock { buffer == nil } }

	func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
		try lock.withLock {
			guard let buffer else { throw SecretError.wiped }
			return try body(UnsafeRawBufferPointer(buffer))
		}
	}

	func wipe() {
		lock.withLock {
			guard let allocation else { return }
			if let base = allocation.baseAddress { _ = memset_s(base, allocation.count, 0, allocation.count) }
			allocation.deallocate()
			self.allocation = nil
			buffer = nil
		}
	}

	deinit { wipe() }

	var description: String { "[secret]" }
	var debugDescription: String { "[secret]" }
}

// MARK: - Two-factor authentication

/// A verification code Apple asked for.
struct ZagTwoFactorChallenge: Equatable, Sendable {
	let method: ZagTwoFactorMethod
	let codeLength: Int
	/// For SMS, the masked number Apple reports (e.g. "•• •• 12"). Never a full number.
	let maskedDestination: String?
	let canRequestSMS: Bool
}

/// What the verification-code sheet shows.
struct ZagTwoFactorPrompt: Equatable, Sendable {
	let title: String
	let message: String
	let codeLength: Int
	let alternativeAction: String?
	let isRetry: Bool
	let attemptsRemaining: Int

	init(challenge: ZagTwoFactorChallenge, failedAttempts: Int, maximumAttempts: Int) {
		title = "Verification Code"
		switch challenge.method {
		case .trustedDevice:
			message = "Enter the \(challenge.codeLength)-digit code shown on your other Apple devices."
		case .sms:
			let destination = challenge.maskedDestination.map { " ending \($0)" } ?? ""
			message = "Enter the \(challenge.codeLength)-digit code sent to your phone number\(destination)."
		}
		codeLength = challenge.codeLength
		alternativeAction = challenge.method == .trustedDevice && challenge.canRequestSMS ? "Send Code by Text Message" : nil
		isRetry = failedAttempts > 0
		attemptsRemaining = max(0, maximumAttempts - failedAttempts)
	}

	/// The code to send, or nil when the input is not exactly `length` digits
	/// (spaces and dashes are ignored). Invalid input is never sent to Apple.
	static func normalisedCode(_ input: String, length: Int) -> String? {
		let digits = input.filter { $0 != " " && $0 != "-" }
		guard digits.count == length, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
		return digits
	}
}

// MARK: - Sessions

/// The session secret kept in the Keychain (`ZagFreeAccountSecretKind.session`).
struct ZagSessionCredential: Codable, Equatable, Sendable, CustomStringConvertible {
	/// Apple's identifier for the account in this session.
	let accountIdentifier: String
	let token: String
	let expiresAt: Date

	var description: String { "[session credential]" }
}

/// What a successful sign-in returns, before Zag Store validates it.
struct ZagAuthenticatedSession: Sendable, CustomStringConvertible {
	let credential: ZagSessionCredential
	let teams: [ZagDeveloperTeam]

	var description: String { "[session: \(teams.count) teams]" }

	enum ValidationError: Error, Equatable {
		case badAccountIdentifier
		case badToken
		case badExpiry
		case noTeams
		case badTeam
	}

	/// Strict checks before anything is stored: identifiers and tokens within
	/// bounds and without whitespace, an expiry between one minute and 400
	/// days away, at least one team, valid and unique team IDs.
	func validated(now: Date) throws -> ZagAuthenticatedSession {
		func plain(_ value: String, max: Int) -> Bool {
			!value.isEmpty && value.count <= max && !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 }
		}
		guard plain(credential.accountIdentifier, max: 128) else { throw ValidationError.badAccountIdentifier }
		guard plain(credential.token, max: 8192) else { throw ValidationError.badToken }
		let remaining = credential.expiresAt.timeIntervalSince(now)
		guard remaining >= 60, remaining <= 400 * 86_400 else { throw ValidationError.badExpiry }
		guard !teams.isEmpty else { throw ValidationError.noTeams }
		guard teams.allSatisfy({ ZagDeveloperTeam.isValidIdentifier($0.identifier) && !$0.name.isEmpty && $0.name.count <= 256 }),
			  Set(teams.map(\.identifier)).count == teams.count else { throw ValidationError.badTeam }
		return self
	}

	/// The team used for signing: a free Personal Team when there is one.
	var preferredTeam: ZagDeveloperTeam {
		teams.first { $0.kind == .personalFree } ?? teams[0]
	}
}

enum ZagSignInStep: Sendable {
	case twoFactorRequired(ZagTwoFactorChallenge)
	case authenticated(ZagAuthenticatedSession)
}

enum ZagAuthenticationServiceError: Error, Equatable, Sendable {
	case invalidCredentials
	case twoFactorRejected
	case accountLocked
	case rateLimited
	case network
	case malformedResponse
	case liveAuthenticationDisabled
}

/// Apple Account authentication. Only simulations implement it in this
/// phase; the live implementation is written and enabled after the
/// supervised real-account test plan (docs/free-developer-accounts/PHASE2.md).
protocol ZagAppleAuthenticationService: Sendable {
	func signIn(appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep
	func requestCode(by method: ZagTwoFactorMethod, anisette: ZagAnisetteData) async throws -> ZagTwoFactorChallenge
	func submitCode(_ code: String, challenge: ZagTwoFactorChallenge, appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep
	/// false when Apple no longer accepts the session.
	func isValid(_ credential: ZagSessionCredential, anisette: ZagAnisetteData) async throws -> Bool
}

enum ZagLiveAuthentication {
	#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG
	/// G5 experiment build only (plan §3.2): live sign-in, bounded by the campaign.
	static let isEnabled = true
	#else
	/// Live Apple Account authentication is not implemented or enabled.
	static let isEnabled = false
	#endif
}

struct ZagDisabledAuthenticationService: ZagAppleAuthenticationService {
	func signIn(appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		throw ZagAuthenticationServiceError.liveAuthenticationDisabled
	}
	func requestCode(by method: ZagTwoFactorMethod, anisette: ZagAnisetteData) async throws -> ZagTwoFactorChallenge {
		throw ZagAuthenticationServiceError.liveAuthenticationDisabled
	}
	func submitCode(_ code: String, challenge: ZagTwoFactorChallenge, appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		throw ZagAuthenticationServiceError.liveAuthenticationDisabled
	}
	func isValid(_ credential: ZagSessionCredential, anisette: ZagAnisetteData) async throws -> Bool {
		throw ZagAuthenticationServiceError.liveAuthenticationDisabled
	}
}

// MARK: - Session summary and diagnostics

/// The non-secret session summary in preferences. The credential itself is in
/// the Keychain; both are written and removed together.
struct ZagFreeAccountSessionStore {
	static let key = "ZagStore.freeAccount.session.v1"
	let preferences: ZagPreferenceStore
	/// Simulated sessions use their own key so they never mix with real ones.
	/// With `accountKeyPrefix` this is only the single-account (v1) key.
	var key: String = ZagFreeAccountSessionStore.key
	/// Multi-account: each account's summary is stored under
	/// `<prefix><account ID>`, so accounts never share an entry.
	var accountKeyPrefix: String? = nil

	private func storageKey(_ account: UUID?) -> String? {
		guard let accountKeyPrefix else { return key }
		return account.map { accountKeyPrefix + $0.uuidString }
	}

	func load(account: UUID? = nil) -> ZagFreeAccountSession? {
		guard let storageKey = storageKey(account) else { return nil }
		guard let session = preferences.data(forKey: storageKey).flatMap({ try? JSONDecoder().decode(ZagFreeAccountSession.self, from: $0) }) else { return nil }
		// An entry filed under another account's key is never returned.
		if accountKeyPrefix != nil, session.accountID != account { return nil }
		return session
	}

	func save(_ session: ZagFreeAccountSession) throws {
		guard let storageKey = storageKey(session.accountID) else { return }
		preferences.set(try JSONEncoder().encode(session), forKey: storageKey)
	}

	func remove(account: UUID? = nil) {
		guard let storageKey = storageKey(account) else { return }
		preferences.set(nil, forKey: storageKey)
	}
}

/// The last 50 free-account events for Settings › Diagnostics. Every entry is
/// passed through `ZagSensitiveRedactor`; callers also never pass secrets.
final class ZagFreeAccountDiagnostics: @unchecked Sendable {
	struct Entry: Equatable, Sendable {
		let at: Date
		let message: String
	}

	private let lock = NSLock()
	private var storage: [Entry] = []
	private let capacity = 50

	func record(_ message: String, at date: Date = Date()) {
		let entry = Entry(at: date, message: ZagSensitiveRedactor.redact(message))
		lock.withLock {
			storage.append(entry)
			if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
		}
	}

	var entries: [Entry] { lock.withLock { storage } }
}

// MARK: - Authenticator

/// Runs sign-in, two-factor authentication, session restore and sign-out,
/// keeping `state` consistent with `ZagFreeAccountState.applying(_:)`.
///
/// - The password lives only as long as the sign-in operation, including the
///   wait for a verification code, and is wiped when it ends.
/// - Every network step has a deadline; `cancel()` stops the operation.
/// - A session is stored only after strict validation: credential in the
///   Keychain first, then the summary; a failed write leaves neither.
actor ZagFreeAccountAuthenticator {
	struct Configuration: Sendable {
		var operationTimeout: TimeInterval = 30
		/// How long a verification code may be awaited before the sign-in ends.
		var twoFactorWindow: TimeInterval = 600
		var maximumCodeAttempts = 3
	}

	private struct PendingSignIn {
		let accountID: UUID
		let appleID: String
		let password: ZagEphemeralSecret
		var challenge: ZagTwoFactorChallenge
		var failedAttempts: Int
		let startedAt: Date
	}

	private(set) var state: ZagFreeAccountState = .signedOut
	private(set) var twoFactorPrompt: ZagTwoFactorPrompt?

	private let service: ZagAppleAuthenticationService
	private let anisette: ZagAnisetteSource
	private let secrets: ZagFreeAccountSecretStore
	private let sessions: ZagFreeAccountSessionStore
	private let diagnostics: ZagFreeAccountDiagnostics
	private let configuration: Configuration
	private let now: @Sendable () -> Date
	private var pending: PendingSignIn?
	private var cancelInFlight: (@Sendable () -> Void)?
	private var busy = false
	/// The account this authenticator belongs to (multi-account), if any.
	/// Once bound it never signs in, stores or removes another account.
	private(set) var boundAccountID: UUID?
	/// Maps Apple's account identifier (and the address entered) to Zag
	/// Store's stable account ID, so the same Apple Account signing in again
	/// keeps its ID (and its assets). Nil: the sign-in is refused (an address
	/// not known for that account; aliases are never merged by guesswork).
	private let identify: (@Sendable (_ accountIdentifier: String, _ appleID: String) -> UUID?)?

	init(
		service: ZagAppleAuthenticationService = ZagDisabledAuthenticationService(),
		anisette: ZagAnisetteSource,
		secrets: ZagFreeAccountSecretStore,
		sessions: ZagFreeAccountSessionStore,
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		configuration: Configuration = Configuration(),
		account: UUID? = nil,
		identify: (@Sendable (_ accountIdentifier: String, _ appleID: String) -> UUID?)? = nil,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.boundAccountID = account
		self.identify = identify
		self.service = service
		self.anisette = anisette
		self.secrets = secrets
		self.sessions = sessions
		self.diagnostics = diagnostics
		self.configuration = configuration
		self.now = now
	}

	// MARK: Restore and sign-out

	/// At launch: signed in only with both a summary and its Keychain
	/// credential; expired when either has passed its expiry. No network.
	func restore() -> ZagFreeAccountState {
		guard let summary = sessions.load(account: boundAccountID) else {
			state = .signedOut
			return state
		}
		guard let data = try? secrets.load(.session, account: summary.accountID),
			  let credential = try? JSONDecoder().decode(ZagSessionCredential.self, from: data) else {
			// A summary without its credential is useless: clear it.
			sessions.remove(account: summary.accountID)
			diagnostics.record("Stored session incomplete; signed out", at: now())
			state = .signedOut
			return state
		}
		state = (summary.isExpired(at: now()) || credential.expiresAt <= now()) ? .sessionExpired(summary) : .signedIn(summary)
		return state
	}

	/// Removes this account's session from the Keychain and preferences. Its
	/// signing identities and refresh records stay (removing the account
	/// removes those), and no other account is touched. If the Keychain
	/// refuses, the error is thrown and the state is unchanged, so the user is
	/// never told they are signed out while a credential remains.
	func signOut() throws {
		cancelPending(reason: nil)
		let accountID = state.session?.accountID ?? sessions.load(account: boundAccountID)?.accountID ?? boundAccountID
		if let accountID {
			try secrets.delete(.session, account: accountID)
		}
		sessions.remove(account: accountID)
		state = state.applying(.signOut) ?? .signedOut
		twoFactorPrompt = nil
		diagnostics.record("Signed out", at: now())
	}

	// MARK: Sign-in

	/// Starts a sign-in. Ignored (returns the current state) while another
	/// operation runs or a code is awaited.
	@discardableResult
	func signIn(appleID: String, password: ZagEphemeralSecret) async -> ZagFreeAccountState {
		guard !busy, pending == nil, let next = state.applying(.beginSignIn) else {
			password.wipe()
			return state
		}
		let accountID = state.session?.accountID ?? boundAccountID ?? UUID()
		state = next
		busy = true
		defer { busy = false }
		diagnostics.record("Sign-in started for \(ZagFreeAccountSession.mask(appleID: appleID))", at: now())
		let pendingSignIn = PendingSignIn(
			accountID: accountID, appleID: appleID, password: password,
			challenge: ZagTwoFactorChallenge(method: .trustedDevice, codeLength: 6, maskedDestination: nil, canRequestSMS: false),
			failedAttempts: 0, startedAt: now()
		)
		let result = await run { anisette in
			try await self.service.signIn(appleID: appleID, password: password, anisette: anisette)
		}
		await handle(result, pending: pendingSignIn)
		return state
	}

	/// Sends a verification code. Malformed codes are refused locally.
	@discardableResult
	func submitCode(_ input: String) async -> ZagFreeAccountState {
		guard !busy, var pendingSignIn = pending, case .awaitingTwoFactor = state else { return state }
		guard now().timeIntervalSince(pendingSignIn.startedAt) <= configuration.twoFactorWindow else {
			fail(.twoFactorRejected, "Verification window expired")
			return state
		}
		guard let code = ZagTwoFactorPrompt.normalisedCode(input, length: pendingSignIn.challenge.codeLength) else {
			diagnostics.record("Verification code refused locally: wrong format", at: now())
			return state
		}
		guard let next = state.applying(.twoFactorSubmitted) else { return state }
		state = next
		busy = true
		defer { busy = false }
		let challenge = pendingSignIn.challenge
		let appleID = pendingSignIn.appleID
		let password = pendingSignIn.password
		let result = await run { anisette in
			try await self.service.submitCode(code, challenge: challenge, appleID: appleID, password: password, anisette: anisette)
		}
		// cancel() may have ended the sign-in while the code was checked.
		guard state == .authenticating else { return state }
		if case .failure(ZagAuthenticationServiceError.twoFactorRejected) = result {
			pendingSignIn.failedAttempts += 1
			guard pendingSignIn.failedAttempts < configuration.maximumCodeAttempts else {
				pending = pendingSignIn
				fail(.twoFactorRejected, "Verification code rejected; no attempts left")
				return state
			}
			pending = pendingSignIn
			state = state.applying(.twoFactorRequired(challenge.method)) ?? state
			twoFactorPrompt = ZagTwoFactorPrompt(
				challenge: challenge, failedAttempts: pendingSignIn.failedAttempts,
				maximumAttempts: configuration.maximumCodeAttempts
			)
			diagnostics.record("Verification code rejected (\(pendingSignIn.failedAttempts) of \(configuration.maximumCodeAttempts))", at: now())
			return state
		}
		await handle(result, pending: pendingSignIn)
		return state
	}

	/// Asks for the code by text message instead of a trusted device.
	@discardableResult
	func requestCodeBySMS() async -> ZagFreeAccountState {
		guard !busy, var pendingSignIn = pending, case .awaitingTwoFactor = state,
			  pendingSignIn.challenge.canRequestSMS else { return state }
		busy = true
		defer { busy = false }
		let result = await run { anisette in try await self.service.requestCode(by: .sms, anisette: anisette) }
		guard case .awaitingTwoFactor = state, pending != nil else { return state }
		switch result {
		case .success(let challenge):
			pendingSignIn.challenge = challenge
			pendingSignIn.failedAttempts = 0
			pending = pendingSignIn
			twoFactorPrompt = ZagTwoFactorPrompt(challenge: challenge, failedAttempts: 0, maximumAttempts: configuration.maximumCodeAttempts)
			diagnostics.record("Verification code requested by text message", at: now())
		case .failure(let error):
			failFrom(error)
		}
		return state
	}

	/// Cancels the running operation or the wait for a code.
	func cancel() {
		cancelInFlight?()
		cancelPending(reason: .cancelled)
	}

	/// Asks Apple whether the stored session still works. A rejected session
	/// becomes `sessionExpired`; a network problem leaves the state alone.
	@discardableResult
	func validateStoredSession() async -> ZagFreeAccountState {
		guard !busy, case .signedIn(let summary) = state,
			  let data = try? secrets.load(.session, account: summary.accountID),
			  let credential = try? JSONDecoder().decode(ZagSessionCredential.self, from: data) else { return state }
		busy = true
		defer { busy = false }
		let result = await run { anisette in try await self.service.isValid(credential, anisette: anisette) }
		switch result {
		case .success(false):
			state = state.applying(.sessionRejected) ?? state
			diagnostics.record("Stored session rejected; sign in again", at: now())
		case .success(true):
			diagnostics.record("Stored session valid", at: now())
		case .failure(let error):
			diagnostics.record("Session check failed: \(Self.failureKind(for: error).rawValue)", at: now())
		}
		return state
	}

	// MARK: Internals

	/// Fetches anisette and runs `operation`, both under the operation
	/// deadline, as a cancellable task.
	private func run<T: Sendable>(_ operation: @escaping @Sendable (ZagAnisetteData) async throws -> T) async -> Result<T, Error> {
		let anisette = self.anisette
		let timeout = configuration.operationTimeout
		let task = Task<Result<T, Error>, Never> {
			do {
				let value = try await ZagDeadline.run(seconds: timeout) {
					let data = try await anisette.anisetteData()
					try Task.checkCancellation()
					return try await operation(data)
				}
				return .success(value)
			} catch {
				return .failure(Task.isCancelled ? ZagTransportError.cancelled : error)
			}
		}
		cancelInFlight = { task.cancel() }
		let outcome = await withTaskCancellationHandler {
			await task.value
		} onCancel: {
			task.cancel()
		}
		cancelInFlight = nil
		return outcome
	}

	private func handle(_ result: Result<ZagSignInStep, Error>, pending pendingSignIn: PendingSignIn) async {
		// cancel() may have ended the operation while it ran.
		guard state == .authenticating else {
			pendingSignIn.password.wipe()
			return
		}
		switch result {
		case .success(.twoFactorRequired(let challenge)):
			var waiting = pendingSignIn
			waiting.challenge = challenge
			waiting.failedAttempts = 0
			pending = waiting
			state = state.applying(.twoFactorRequired(challenge.method)) ?? state
			twoFactorPrompt = ZagTwoFactorPrompt(challenge: challenge, failedAttempts: 0, maximumAttempts: configuration.maximumCodeAttempts)
			diagnostics.record("Verification code required (\(challenge.method.rawValue))", at: now())
		case .success(.authenticated(let session)):
			pending = nil
			twoFactorPrompt = nil
			pendingSignIn.password.wipe()
			complete(session, accountID: pendingSignIn.accountID, appleID: pendingSignIn.appleID)
		case .failure(let error):
			pending = pendingSignIn
			failFrom(error)
		}
	}

	private func complete(_ session: ZagAuthenticatedSession, accountID: UUID, appleID: String) {
		let validated: ZagAuthenticatedSession
		do {
			validated = try session.validated(now: now())
		} catch {
			fail(.unexpectedResponse, "Sign-in response rejected: \(error)")
			return
		}
		// The stable ID for this Apple Account. An authenticator bound to one
		// account refuses to become another.
		let resolvedID: UUID
		if let identify {
			guard let identified = identify(validated.credential.accountIdentifier, appleID) else {
				fail(.addressNotRecognised, "Sign-in reached a known Apple Account through an address not recorded for it; nothing stored")
				return
			}
			resolvedID = identified
		} else {
			resolvedID = accountID
		}
		if let boundAccountID, resolvedID != boundAccountID {
			fail(.differentAccount, "Sign-in was for a different Apple Account; nothing stored")
			return
		}
		let summary = ZagFreeAccountSession(
			accountID: resolvedID,
			maskedAppleID: ZagFreeAccountSession.mask(appleID: appleID),
			team: validated.preferredTeam,
			authenticatedAt: now(),
			expiresAt: validated.credential.expiresAt,
			otherTeams: validated.teams.filter { $0.identifier != validated.preferredTeam.identifier }
		)
		let accountID = resolvedID
		do {
			try secrets.save(try JSONEncoder().encode(validated.credential), kind: .session, account: accountID)
			do {
				try sessions.save(summary)
			} catch {
				try? secrets.delete(.session, account: accountID)
				throw error
			}
		} catch {
			fail(.unexpectedResponse, "Session could not be stored")
			return
		}
		state = state.applying(.authenticated(summary)) ?? state
		boundAccountID = accountID
		diagnostics.record("Signed in; team \(validated.preferredTeam.kind.rawValue)", at: now())
	}

	private func failFrom(_ error: Error) {
		fail(Self.failureKind(for: error), "Sign-in failed: \(Self.failureKind(for: error).rawValue)")
	}

	private func fail(_ kind: ZagFreeAccountFailure.Kind, _ note: String) {
		pending?.password.wipe()
		pending = nil
		twoFactorPrompt = nil
		let failure = ZagFreeAccountFailure(kind: kind, occurredAt: now())
		state = state.applying(.failed(failure)) ?? state
		diagnostics.record(note, at: now())
	}

	private func cancelPending(reason: ZagFreeAccountFailure.Kind?) {
		let active = pending != nil || state == .authenticating
		pending?.password.wipe()
		pending = nil
		twoFactorPrompt = nil
		if let reason, active {
			state = state.applying(.failed(ZagFreeAccountFailure(kind: reason, occurredAt: now()))) ?? state
			diagnostics.record("Sign-in cancelled", at: now())
		}
	}

	static func failureKind(for error: Error) -> ZagFreeAccountFailure.Kind {
		switch error {
		case let error as ZagAuthenticationServiceError:
			switch error {
			case .invalidCredentials: return .invalidCredentials
			case .twoFactorRejected: return .twoFactorRejected
			case .accountLocked: return .accountLocked
			case .rateLimited: return .rateLimited
			case .network: return .network
			case .malformedResponse: return .unexpectedResponse
			case .liveAuthenticationDisabled: return .unavailable
			}
		case let error as ZagAnisetteError:
			switch error {
			case .cancelled: return .cancelled
			case .liveProvidersDisabled: return .unavailable
			default: return .anisetteUnavailable
			}
		case ZagTransportError.cancelled, is CancellationError: return .cancelled
		case is ZagTransportError: return .network
		default: return .unexpectedResponse
		}
	}
}
