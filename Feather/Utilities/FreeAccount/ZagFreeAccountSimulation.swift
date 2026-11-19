#if DEBUG
import Foundation

// Debug builds only. A simulated Apple Account service and anisette source
// that drive the real `ZagFreeAccountAuthenticator`, so the sign-in screen can
// be exercised end to end. Nothing here contacts Apple or any server.

enum ZagFreeAccountSimulation {
	/// Only reserved, non-existent addresses are accepted (RFC 2606), so a
	/// real Apple Account can never "sign in" to the simulation.
	static let accountDomain = "@example.invalid"
	static let appleID = "tester\(accountDomain)"
	static let password = "zag-simulated-password"
	static let verificationCode = "123456"
	static let keychainService = "app.zagstore.free-account.simulation"
	static let sessionKey = "ZagStore.freeAccount.simulatedSession.v1"
	/// Multi-account simulation data lives under its own namespace.
	static let accountsNamespace = "ZagStore.accounts.simulated"

	/// Synthetic accounts: each address has its own Apple-side identity and
	/// teams. Any other reserved address behaves as `appleID`.
	struct Account: Sendable {
		let identifier: String
		let teams: [ZagDeveloperTeam]
	}

	static let accounts: [String: Account] = [
		appleID: Account(identifier: "SIMULATED0001", teams: [
			ZagDeveloperTeam(identifier: "SIMTEAM001", name: "Personal Team (Simulated)", kind: .personalFree)
		]),
		"second\(accountDomain)": Account(identifier: "SIMULATED0002", teams: [
			ZagDeveloperTeam(identifier: "SIMTEAM002", name: "Second Personal Team (Simulated)", kind: .personalFree)
		]),
		"paid\(accountDomain)": Account(identifier: "SIMULATED0003", teams: [
			ZagDeveloperTeam(identifier: "SIMPAID001", name: "Paid Individual (Simulated)", kind: .individualPaid),
			ZagDeveloperTeam(identifier: "SIMORG0001", name: "Organisation (Simulated)", kind: .organization)
		])
	]

	static func account(for appleID: String) -> Account {
		accounts[appleID.lowercased()] ?? accounts[Self.appleID]!
	}

	/// The multi-account directory wired to the simulation, under its own
	/// Keychain service and preferences namespace (never the real ones).
	static func makeDirectory(
		service: ZagSimulatedAuthenticationService,
		clock: ZagSimulationClock,
		secrets: ZagFreeAccountSecretStore = ZagKeychainFreeAccountSecretStore(service: keychainService),
		preferences: ZagPreferenceStore = ZagUserDefaultsPreferences(),
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		operationTimeout: TimeInterval = 8
	) -> ZagAccountDirectory {
		var configuration = ZagAccountDirectory.Configuration()
		configuration.namespace = accountsNamespace
		configuration.legacySessionKey = sessionKey
		configuration.authenticator = .init(operationTimeout: operationTimeout, twoFactorWindow: 600, maximumCodeAttempts: 3)
		return ZagAccountDirectory(
			service: service,
			anisette: ZagSimulatedAnisetteSource(service: service, clock: clock),
			secrets: secrets, preferences: preferences, diagnostics: diagnostics,
			configuration: configuration, now: { clock.now }
		)
	}

	enum Scenario: String, CaseIterable, Identifiable, Sendable {
		case signInSucceeds
		case trustedDeviceCode
		case accountLocked
		case rateLimited
		case networkFailure
		case noResponse
		case malformedResponse
		case anisetteUnavailable

		var id: String { rawValue }

		var title: String {
			switch self {
			case .signInSucceeds: return "Signs In Directly"
			case .trustedDeviceCode: return "Asks for Verification Code"
			case .accountLocked: return "Account Locked"
			case .rateLimited: return "Too Many Attempts"
			case .networkFailure: return "Network Failure"
			case .noResponse: return "No Response (Timeout)"
			case .malformedResponse: return "Malformed Response"
			case .anisetteUnavailable: return "Anisette Provider Unavailable"
			}
		}
	}

	/// The authenticator wired to the simulation, the real Keychain store
	/// (under a separate service) and a separate preferences key.
	static func makeAuthenticator(
		service: ZagSimulatedAuthenticationService,
		clock: ZagSimulationClock,
		secrets: ZagFreeAccountSecretStore = ZagKeychainFreeAccountSecretStore(service: keychainService),
		preferences: ZagPreferenceStore = ZagUserDefaultsPreferences(),
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		operationTimeout: TimeInterval = 8
	) -> ZagFreeAccountAuthenticator {
		ZagFreeAccountAuthenticator(
			service: service,
			anisette: ZagSimulatedAnisetteSource(service: service, clock: clock),
			secrets: secrets,
			sessions: ZagFreeAccountSessionStore(preferences: preferences, key: sessionKey),
			diagnostics: diagnostics,
			configuration: .init(operationTimeout: operationTimeout, twoFactorWindow: 600, maximumCodeAttempts: 3),
			now: { clock.now }
		)
	}
}

/// Simulated time, so session expiry can be shown without waiting 30 days.
final class ZagSimulationClock: @unchecked Sendable {
	private let lock = NSLock()
	private var offset: TimeInterval = 0
	private let base: @Sendable () -> Date

	init(base: @escaping @Sendable () -> Date = { Date() }) {
		self.base = base
	}

	var now: Date { lock.withLock { base() + offset } }
	func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

/// Synthetic anisette headers; fails when the scenario asks it to.
struct ZagSimulatedAnisetteSource: ZagAnisetteSource {
	let service: ZagSimulatedAuthenticationService
	let clock: ZagSimulationClock

	func anisetteData() async throws -> ZagAnisetteData {
		if await service.scenario == .anisetteUnavailable { throw ZagAnisetteError.providerUnavailable }
		return try ZagAnisetteData(validating: ["X-Apple-I-MD": "simulated", "X-Apple-I-MD-M": "simulated"], obtainedAt: clock.now)
	}
}

/// A scripted stand-in for Apple's sign-in service.
actor ZagSimulatedAuthenticationService: ZagAppleAuthenticationService {
	private(set) var scenario: ZagFreeAccountSimulation.Scenario
	/// When true, the stored session is reported as no longer accepted.
	private(set) var rejectsSessions = false
	/// Apple-side identifiers whose sessions are no longer accepted.
	private(set) var rejectedAccounts: Set<String> = []
	private let latency: UInt64
	private let clock: ZagSimulationClock

	init(scenario: ZagFreeAccountSimulation.Scenario = .trustedDeviceCode, latency: TimeInterval = 0.8, clock: ZagSimulationClock) {
		self.scenario = scenario
		self.latency = UInt64(max(0, latency) * 1_000_000_000)
		self.clock = clock
	}

	func setScenario(_ scenario: ZagFreeAccountSimulation.Scenario) {
		self.scenario = scenario
		rejectsSessions = false
	}

	func setRejectsSessions(_ value: Bool) { rejectsSessions = value }

	/// Rejects one simulated account's sessions only.
	func setRejectsSessions(_ value: Bool, forAppleID appleID: String) {
		let identifier = ZagFreeAccountSimulation.account(for: appleID).identifier
		if value { rejectedAccounts.insert(identifier) } else { rejectedAccounts.remove(identifier) }
	}

	private func pause() async throws {
		if latency > 0 { try await Task.sleep(nanoseconds: latency) }
	}

	private func session(_ appleID: String) -> ZagAuthenticatedSession {
		let account = ZagFreeAccountSimulation.account(for: appleID)
		return ZagAuthenticatedSession(
			credential: ZagSessionCredential(
				accountIdentifier: account.identifier,
				token: "simulated-session-\(UUID().uuidString)",
				expiresAt: clock.now + 30 * 86_400
			),
			teams: account.teams
		)
	}

	private func passwordMatches(_ password: ZagEphemeralSecret) -> Bool {
		(try? password.withBytes { Array($0) == Array(ZagFreeAccountSimulation.password.utf8) }) ?? false
	}

	func signIn(appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		try await pause()
		guard appleID.lowercased().hasSuffix(ZagFreeAccountSimulation.accountDomain), passwordMatches(password) else {
			throw ZagAuthenticationServiceError.invalidCredentials
		}
		switch scenario {
		case .signInSucceeds: return .authenticated(session(appleID))
		case .trustedDeviceCode:
			return .twoFactorRequired(ZagTwoFactorChallenge(method: .trustedDevice, codeLength: 6, maskedDestination: nil, canRequestSMS: true))
		case .accountLocked: throw ZagAuthenticationServiceError.accountLocked
		case .rateLimited: throw ZagAuthenticationServiceError.rateLimited
		case .networkFailure: throw ZagAuthenticationServiceError.network
		case .noResponse:
			try await Task.sleep(nanoseconds: 120_000_000_000)
			throw ZagAuthenticationServiceError.network
		case .malformedResponse:
			return .authenticated(ZagAuthenticatedSession(
				credential: ZagSessionCredential(accountIdentifier: "SIMULATED0001", token: "", expiresAt: clock.now - 1),
				teams: []
			))
		case .anisetteUnavailable: throw ZagAuthenticationServiceError.network
		}
	}

	func requestCode(by method: ZagTwoFactorMethod, anisette: ZagAnisetteData) async throws -> ZagTwoFactorChallenge {
		try await pause()
		return ZagTwoFactorChallenge(method: .sms, codeLength: 6, maskedDestination: "•• •• 00", canRequestSMS: false)
	}

	func submitCode(_ code: String, challenge: ZagTwoFactorChallenge, appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		try await pause()
		guard passwordMatches(password) else { throw ZagAuthenticationServiceError.invalidCredentials }
		guard code == ZagFreeAccountSimulation.verificationCode else { throw ZagAuthenticationServiceError.twoFactorRejected }
		return .authenticated(session(appleID))
	}

	func isValid(_ credential: ZagSessionCredential, anisette: ZagAnisetteData) async throws -> Bool {
		try await pause()
		return !rejectsSessions && !rejectedAccounts.contains(credential.accountIdentifier)
	}
}
#endif
