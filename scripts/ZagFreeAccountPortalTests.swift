import Foundation

// Phase 3 groundwork: provisioning against the simulated developer portal.
// Synthetic team, device, keys and profiles only; nothing contacts Apple.

final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Date(timeIntervalSince1970: 1_795_000_000)
	var now: Date { lock.withLock { value } }
	func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	var failSaves = false
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws {
		if failSaves { throw ZagKeychainFreeAccountSecretStore.StoreError.keychain(-34018) }
		lock.withLock { items["\(account).\(kind)"] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data? { lock.withLock { items["\(account).\(kind)"] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws { lock.withLock { items["\(account).\(kind)"] = nil } }
}

let team = "SIMTEAM001"
let udid = "00000000-SIMULATED000000"
let account = UUID()

func entitlements(_ values: [String: Any] = [:]) -> ZagEntitlementSet { try! ZagEntitlementSet(values) }

func request(
	app: String = "com.example.notes",
	extensions: [String] = [],
	appEntitlements: [String: Any] = [:],
	installed: Set<String> = []
) -> ZagProvisioningRequest {
	ZagProvisioningRequest(
		accountID: account,
		team: team,
		deviceUDID: udid,
		deviceName: "Test iPhone",
		app: .init(originalBundleIdentifier: app, name: "Notes", entitlements: entitlements(appEntitlements)),
		extensions: extensions.map { .init(originalBundleIdentifier: $0, name: "Extension", entitlements: entitlements()) },
		installedFreeAccountApps: installed
	)
}

struct Harness {
	let clock = TestClock()
	let secrets = MemorySecrets()
	let diagnostics = ZagFreeAccountDiagnostics()
	let portal: ZagSimulatedDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner

	init(timeout: TimeInterval = 30) {
		let clock = self.clock
		portal = ZagSimulatedDeveloperPortal(team: team, clock: { clock.now })
		provisioner = ZagFreeAccountProvisioner(
			portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
			diagnostics: diagnostics, operationTimeout: timeout, now: { clock.now }
		)
	}

	func run(_ request: ZagProvisioningRequest) async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		await provisioner.provision(request)
	}
}

extension Result where Failure == ZagProvisioningFailure {
	var failure: ZagProvisioningFailure? { if case .failure(let f) = self { return f } else { return nil } }
	var value: Success? { if case .success(let v) = self { return v } else { return nil } }
}

@main struct Tests {
	static var passed = 0
	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static func main() async {
		await firstProvisioning()
		await reuseAndRefresh()
		await limitsCheckedBeforeChanges()
		await certificates()
		await profileChecks()
		await failures()
		await liveDisabled()
		print("SUCCESS: \(passed) free-account provisioning checks passed")
	}

	static func firstProvisioning() async {
		let h = Harness()
		let result = await h.run(request(
			extensions: ["com.example.notes.widget"],
			appEntitlements: [
				"com.apple.security.application-groups": ["group.com.example.notes"],
				"keychain-access-groups": ["ORIGTEAM01.com.example.notes"],
				"aps-environment": "production",
				"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]
			]
		))
		guard let value = result.value else { return check(false, "first provisioning succeeds: \(String(describing: result.failure))") }
		check(value.app.bundleIdentifier == "com.example.notes.\(team)" && value.extensions.map(\.bundleIdentifier) == ["com.example.notes.\(team).widget"],
			  "the app and its extension get team-specific bundle IDs")
		check(value.changes.registeredDevice && value.changes.createdCertificate, "the device is registered and a certificate created")
		check(value.changes.registeredAppIDs == ["com.example.notes.\(team)", "com.example.notes.\(team).widget"], "an App ID is registered for the app and the extension")
		check(value.changes.registeredAppGroups == ["group.com.example.notes.\(team)"], "the app group is mapped for the team and registered")
		let granted = value.app.entitlements.dictionary
		check(granted["application-identifier"] as? String == "\(team).com.example.notes.\(team)", "the app is signed as the team's App ID")
		check(granted["com.apple.security.application-groups"] as? [String] == ["group.com.example.notes.\(team)"], "the app keeps its (mapped) app group")
		check(granted["keychain-access-groups"] as? [String] == ["\(team).com.example.notes"], "keychain groups move to the team")
		let rejected = Set(value.app.rejected.map(\.key))
		check(rejected == ["aps-environment", "com.apple.developer.networking.networkextension"],
			  "capabilities free teams lack are reported, not granted")
		check(value.expiresAt == h.clock.now + 7 * 86_400, "the profiles last 7 days")
		let stored = h.secrets.items["\(account).signingPrivateKey"].flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		check(stored?.serialNumber == value.certificateSerial && stored?.privateKey.count == 32, "the signing key is kept in the Keychain store with its certificate")
		check(h.secrets.items.count == 1, "nothing else is stored")
		let log = h.diagnostics.entries.map(\.message).joined(separator: "\n")
		check(!log.contains(udid) && !log.contains("SIMULATED-CERTIFICATE") && !log.contains(stored?.privateKey.base64EncodedString() ?? "-"),
			  "diagnostics hold no device ID, certificate or key")
	}

	static func reuseAndRefresh() async {
		let h = Harness()
		let first = await h.run(request()).value
		let before = await h.portal.mutations.count
		let second = await h.run(request()).value
		let after = await h.portal.mutations.count
		check(second != nil && before == after && second?.changes == ZagProvisioningResult.Changes(), "provisioning again changes nothing on the team")
		check(second?.certificateSerial == first?.certificateSerial, "the stored certificate is reused")

		h.clock.advance(8 * 86_400)
		let refreshed = await h.run(request()).value
		check(refreshed?.changes.registeredAppIDs == ["com.example.notes.\(team)"] && refreshed?.changes.createdCertificate == false,
			  "after 7 days the expired App ID is registered again; the certificate is reused")
		check(refreshed.map { $0.expiresAt > h.clock.now + 6 * 86_400 } == true, "a refresh issues a new 7-day profile")
	}

	static func limitsCheckedBeforeChanges() async {
		let full = Harness()
		let slots = await full.run(request(installed: ["a.\(team)", "b.\(team)", "c.\(team)"]))
		let slotCalls = await full.portal.calls
		check(slots.failure?.kind == .installSlotsFull(installed: ["a.\(team)", "b.\(team)", "c.\(team)"]) && slotCalls.isEmpty,
			  "three installed apps stop provisioning before Apple is asked")
		let refresh = await full.run(request(installed: ["com.example.notes.\(team)", "b.\(team)", "c.\(team)"]))
		check(refresh.value != nil, "refreshing an installed app needs no free slot")

		let devices = Harness()
		for index in 0..<3 { await devices.portal.seedDevice("OTHER-\(index)") }
		let deviceResult = await devices.run(request())
		let deviceMutations = await devices.portal.mutations
		check(deviceResult.failure?.kind == .deviceLimitReached && deviceMutations.isEmpty, "a fourth device is refused and nothing is created")

		let appIDs = Harness()
		for index in 0..<9 { await appIDs.portal.seedAppID("com.other.app\(index).\(team)", expiresAt: appIDs.clock.now + Double(index + 1) * 3_600) }
		let appIDResult = await appIDs.run(request(extensions: ["com.example.notes.widget"]))
		let appIDMutations = await appIDs.portal.mutations
		check(appIDResult.failure?.kind == .appIDCapacityExhausted(needed: 2, available: 1, nextSlotFreesAt: appIDs.clock.now + 3_600),
			  "App ID capacity is reported with when the next slot frees")
		check(appIDMutations == [.registerDevice], "no certificate or App ID is created when App IDs would run out")
		check(appIDs.secrets.items.isEmpty, "no signing key is created either")

		let taken = Harness()
		await taken.portal.setForeignIdentifiers(["com.example.notes.\(team)"])
		let takenResult = await taken.run(request())
		check(takenResult.failure?.kind == .identifierUnavailable("com.example.notes.\(team)"), "an identifier owned by another team is reported")

		let invalid = Harness()
		let bad = await invalid.run(request(app: "not a bundle id"))
		check(bad.failure?.kind == .invalidRequest && bad.failure?.step == .request, "an invalid bundle ID is refused locally")
	}

	static func certificates() async {
		let limit = Harness()
		await limit.portal.seedCertificate(serial: "AAAA", expiresAt: limit.clock.now + 200 * 86_400)
		await limit.portal.seedCertificate(serial: "BBBB", expiresAt: limit.clock.now + 100 * 86_400)
		let result = await limit.run(request())
		guard case .certificateMustBeRevoked(let candidates)? = result.failure?.kind else { return check(false, "certificate limit") }
		check(candidates.map(\.serialNumber) == ["BBBB", "AAAA"], "at the certificate limit the user is offered certificates to revoke, soonest-expiring first")
		let issued = await limit.portal.issuedCertificates.count
		check(issued == 2, "no certificate is revoked automatically")

		let expiring = Harness()
		_ = await expiring.run(request())
		expiring.clock.advance(360 * 86_400)
		let renewed = await expiring.run(request())
		check(renewed.value?.changes.createdCertificate == true, "a certificate with under 7 days left is replaced, not reused")

		let storage = Harness()
		storage.secrets.failSaves = true
		let stored = await storage.run(request())
		check(stored.failure?.kind == .keyStorage, "if the Keychain refuses the key, provisioning stops")
	}

	static func profileChecks() async {
		for (tamper, problem) in [
			(ZagSimulatedDeveloperPortal.ProfileTamper.wrongTeam, ZagProvisioningProfileCheck.Problem.wrongTeam),
			(.wrongBundle, .wrongBundleIdentifier),
			(.missingDevice, .deviceMissing),
			(.missingCertificate, .certificateMissing),
			(.expired, .expired),
			(.wrongApplicationIdentifier, .wrongApplicationIdentifier)
		] {
			let h = Harness()
			await h.portal.tamperProfiles(tamper)
			let result = await h.run(request())
			check(result.failure?.kind == .invalidProfile(problem) && result.failure?.step == .profiles, "a profile with \(problem.rawValue) is refused")
		}
	}

	static func failures() async {
		for (failure, kind, label) in [
			(ZagSimulatedDeveloperPortal.Failure.sessionRejected, ZagProvisioningFailure.Kind.sessionRejected, "a rejected session asks to sign in again"),
			(.network, .network, "a network failure is reported"),
			(.rateLimited, .rateLimited, "rate limiting is reported"),
			(.malformed, .unexpectedResponse, "a malformed response is reported")
		] {
			let h = Harness()
			await h.portal.fail(.appIDs, with: failure)
			let result = await h.run(request())
			check(result.failure?.kind == kind && result.failure?.step == .appIDs, label)
		}

		let slow = Harness(timeout: 0.3)
		await slow.portal.fail(.profile, with: .noResponse)
		let timedOut = await slow.run(request())
		check(timedOut.failure?.kind == .timedOut && timedOut.failure?.step == .profiles, "a portal call that does not answer times out")

		let cancelled = Harness()
		await cancelled.portal.fail(.certificates, with: .noResponse)
		let task = Task { await cancelled.run(request()) }
		try? await Task.sleep(nanoseconds: 200_000_000)
		task.cancel()
		let outcome = await task.value
		check(outcome.failure?.kind == .cancelled, "provisioning can be cancelled")
		let step = await cancelled.provisioner.currentStep
		check(step == nil, "the provisioner is idle after cancelling")
	}

	static func liveDisabled() async {
		let secrets = MemorySecrets()
		let provisioner = ZagFreeAccountProvisioner(secrets: secrets)
		let result = await provisioner.provision(request())
		check(result.failure?.kind == .unavailable && secrets.items.isEmpty, "the default build cannot provision and says it is unavailable")
		check(ZagLivePortal.isEnabled == false && ZagLiveAuthentication.isEnabled == false && ZagAnisetteLive.isEnabled == false,
			  "live portal, sign-in and anisette are all disabled")
	}
}
