import Foundation

// Shared by the free-account test suites: preferences in memory, and
// synthetic accounts (reserved @example.invalid addresses) signed in to a
// real ZagAccountDirectory through the simulated service. Nothing here
// contacts Apple.

final class TestPreferences: ZagPreferenceStore, @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]
	func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
	func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
	var keys: [String] { lock.withLock { Array(values.keys) } }
}

enum SimulatedAccounts {
	static let tester = ZagFreeAccountSimulation.appleID
	static let second = "second\(ZagFreeAccountSimulation.accountDomain)"
	static let paid = "paid\(ZagFreeAccountSimulation.accountDomain)"

	/// A directory whose simulated sessions and authorisations follow `now`.
	static func directory(
		now: @escaping @Sendable () -> Date,
		secrets: ZagFreeAccountSecretStore,
		preferences: TestPreferences = TestPreferences(),
		service existing: ZagSimulatedAuthenticationService? = nil,
		localState: ZagAccountLocalState? = nil
	) -> (directory: ZagAccountDirectory, service: ZagSimulatedAuthenticationService) {
		let clock = ZagSimulationClock(base: now)
		let service = existing ?? ZagSimulatedAuthenticationService(scenario: .signInSucceeds, latency: 0, clock: clock)
		return (ZagFreeAccountSimulation.makeDirectory(service: service, clock: clock, secrets: secrets, preferences: preferences, localState: localState), service)
	}

	/// Signs `appleID` in as a new (or known) account and adopts it.
	static func signIn(_ appleID: String, to directory: ZagAccountDirectory) async -> UUID? {
		let authenticator = await directory.newSignIn()
		_ = await authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		return try? await directory.adopt(authenticator)
	}
}
