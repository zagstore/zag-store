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
	func accountIDs() throws -> Set<UUID> { lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) } }
	var failSaves = false
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		if failSaves { throw ZagKeychainFreeAccountSecretStore.StoreError.keychain(-34018) }
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil } }
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
}

let team = "SIMTEAM001"
let udid = "00000000-SIMULATED000000"

func entitlements(_ values: [String: Any] = [:]) -> ZagEntitlementSet { try! ZagEntitlementSet(values) }

func request(
	app: String = "com.example.notes",
	extensions: [String] = [],
	appEntitlements: [String: Any] = [:],
	installed: Set<String> = []
) -> ZagProvisioningRequest {
	ZagProvisioningRequest(
		accountID: UUID(), // replaced with the harness's signed-in account
		team: team,
		deviceUDID: udid,
		deviceName: "Test iPhone",
		app: .init(originalBundleIdentifier: app, name: "Notes", entitlements: entitlements(appEntitlements)),
		extensions: extensions.map { .init(originalBundleIdentifier: $0, name: "Extension", entitlements: entitlements()) },
		installedFreeAccountApps: installed
	)
}

struct Harness {
	let clock: TestClock
	let secrets: MemorySecrets
	let diagnostics = ZagFreeAccountDiagnostics()
	let portal: ZagSimulatedDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner
	let directory: ZagAccountDirectory
	/// The simulated tester account, signed in to the directory.
	let account: UUID

	static func make(timeout: TimeInterval = 30) async -> Harness {
		let clock = TestClock(), secrets = MemorySecrets()
		let directory = SimulatedAccounts.directory(now: { clock.now }, secrets: secrets).directory
		let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		return Harness(clock: clock, secrets: secrets, directory: directory, account: account, timeout: timeout)
	}

	private init(clock: TestClock, secrets: MemorySecrets, directory: ZagAccountDirectory, account: UUID, timeout: TimeInterval) {
		self.clock = clock
		self.secrets = secrets
		self.directory = directory
		self.account = account
		portal = ZagSimulatedDeveloperPortal(team: team, clock: { clock.now })
		provisioner = ZagFreeAccountProvisioner(
			portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
			diagnostics: diagnostics, operationTimeout: timeout, account: account, now: { clock.now }
		)
	}

	var scope: ZagSigningScope { ZagSigningScope(accountID: account, teamID: team) }

	/// Authorised for this account (signing in again if the simulated session has lapsed).
	func authorization() async -> ZagSigningAuthorization {
		if let granted = try? await directory.authorize(scope) { return granted }
		let authenticator = await directory.authenticator(for: account)!
		_ = await authenticator.restore()
		_ = await authenticator.signIn(appleID: SimulatedAccounts.tester, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
		return try! await directory.authorize(scope)
	}

	func run(_ r: ZagProvisioningRequest) async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		let request = ZagProvisioningRequest(
			accountID: account, team: r.team, deviceUDID: r.deviceUDID, deviceName: r.deviceName,
			app: r.app, extensions: r.extensions, installedFreeAccountApps: r.installedFreeAccountApps
		)
		return await provisioner.provision(request, authorization: await authorization())
	}

	var storedIdentity: ZagSigningIdentity? {
		secrets.items["\(account).signingPrivateKey.\(team)"].flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
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
		await nativeCertificateInventory()
		await nativeInstallAndRestart()
		await nativeAppIDsAcrossAccounts()
		await firstProvisioning()
		await reuseAndRefresh()
		await limitsCheckedBeforeChanges()
		await certificates()
		await profileChecks()
		await failures()
		await liveDisabled()
		print("SUCCESS: \(passed) free-account provisioning checks passed")
	}

	static func nativeCertificateInventory() async {
		let fixture = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
		let certificate = ZagCertificateInspection(der: fixture)!
		actor Transport: ZagHTTPTransport {
			let fixture: Data
			let serial: String
			var requests: [ZagHTTPRequest] = []
			var inventoryStatus = 200

			init(fixture: Data, serial: String) {
				self.fixture = fixture
				self.serial = serial
			}

			func failInventory() { inventoryStatus = 429 }

			func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
				requests.append(request)
				let path = request.url.lastPathComponent
				let body: Data
				if path == "submitDevelopmentCSR.action" {
					body = try PropertyListSerialization.data(
						fromPropertyList: ["resultCode": 0, "certRequest": ["certificateId": "CERT1"]],
						format: .xml, options: 0
					)
				} else if path == "CERT1" {
					body = try JSONSerialization.data(withJSONObject: [
						"data": ["id": "CERT1", "attributes": ["certificateContent": fixture.base64EncodedString()]]
					])
				} else {
					body = try JSONSerialization.data(withJSONObject: [
						"data": [["id": "CERT1", "attributes": ["serialNumber": serial]]]
					])
				}
				return ZagHTTPResponse(statusCode: path == "certificates" ? inventoryStatus : 200, headers: [:], body: body)
			}
		}

		let transport = Transport(fixture: fixture, serial: certificate.serialNumber)
		let consent = ZagMutationConsentCoordinator()
		let portal = ZagNativeDeveloperPortal(
			transport: transport, headers: { ["X-Apple-GS-Token": "persisted-test-token"] }, consent: consent
		)
		do {
			let candidates = try await portal.revocableCertificates(team: team)
			check(candidates.map(\.id) == ["CERT1"] && candidates.first?.sha1 == nil,
				  "native inventory distinguishes metadata-only rows")
			let hydrated = try await portal.certificates(team: team)
			check(hydrated.first?.data == fixture, "native recovery loads verified DER from the individual certificate resource")
			let csr = ZagCertificateRequest(data: Data([1]))
			do {
				_ = try await portal.submitCertificateRequest(csr, team: team)
				check(false, "native CSR requires consent")
			} catch ZagNativePortalError.consentRequired(.submitCSR) {
				check(true, "native CSR requires consent")
			}
			consent.authorize([.submitCSR])
			let issued = try await portal.submitCertificateRequest(csr, team: team)
			check(issued.certificate.serialNumber == certificate.serialNumber && issued.data == fixture,
				  "native CSR resolves a response containing only the certificate ID")
			let requests = await transport.requests
			check(requests.map { $0.url.lastPathComponent } == ["certificates", "certificates", "CERT1", "submitDevelopmentCSR.action", "certificates", "CERT1"],
				  "production portal uses read-only details and submits exactly one CSR")
			check(requests.allSatisfy { $0.headers["X-Apple-GS-Token"] == "persisted-test-token" },
				  "production portal uses the injected session for each operation")
			let inventory = requests[0]
			let query = try JSONSerialization.jsonObject(with: inventory.body ?? Data()) as? [String: String]
			check(inventory.method == "POST" && inventory.headers["X-HTTP-Method-Override"] == "GET"
				  && inventory.headers["Accept"] == "application/vnd.api+json"
				  && query == ["urlEncodedQueryParams": "teamId=\(team)"], "Personal Team certificate request matches the v1 wire format")
			await transport.failInventory()
			do {
				_ = try await portal.submitCertificateRequest(csr, team: team)
				check(false, "failed read-back should surface an unconfirmed CSR")
			} catch let failure as ZagPortalOperationFailure {
				check(failure.underlying == .malformedResponse && failure.reason.contains("HTTP 429"),
					"a read-back 429 after CSR success retains the read-back status without classifying the CSR as refused")
			}
		} catch {
			check(false, "native inventory and CSR flow: \(error)")
		}
	}

	@MainActor
	static func nativeInstallAndRestart() async {
		enum Interruption: Error { case duringInstall }
		final class Signer: ZagAppSigning, @unchecked Sendable {
			private let lock = NSLock()
			private var staged: ZagProvisioningResult?
			var result: ZagProvisioningResult? { lock.withLock { staged } }

			func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity,
					  authorization: ZagSigningAuthorization, now: Date) throws -> ZagSignedAppRecord {
				guard identity.serialNumber == result.certificateSerial, authorization.scope.teamID == result.team,
					  result.app.entitlements.dictionary["application-identifier"] as? String == "\(result.team).\(result.app.bundleIdentifier)" else {
					throw ZagFreeAccountSigningError.identityMismatch
				}
				try Data(result.app.bundleIdentifier.utf8).write(to: app.appendingPathComponent("simulated-signature"))
				lock.withLock { staged = result }
				return .init(bundleIdentifier: result.app.bundleIdentifier,
					originalBundleIdentifier: result.app.originalBundleIdentifier, signedAt: now,
					profileExpiresAt: result.expiresAt, certificateExpiresAt: identity.expiresAt)
			}
		}
		actor Installer: ZagFreeAccountInstaller {
			let interrupted: Bool
			var installed: String?
			init(interrupted: Bool) { self.interrupted = interrupted }

			func install(signedApp: URL, bundleIdentifier: String) async throws {
				let signature = try String(contentsOf: signedApp.appendingPathComponent("simulated-signature"), encoding: .utf8)
				guard signature == bundleIdentifier else { throw ZagFreeAccountSigningError.verification("signature") }
				if interrupted { throw Interruption.duringInstall }
				installed = bundleIdentifier
			}

			func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
				guard installed == expectation.bundleIdentifier else { return .notInstalled }
				guard expectation.version == "1.2", expectation.build == "7",
					  expectation.teamIdentifier == team, !expectation.profileUUID.isEmpty else { return .mismatch("handoff") }
				return .verified(profileExpiresAt: expectation.profileExpiresAt, certificateExpiresAt: expectation.certificateExpiresAt)
			}
		}

		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let credentials = root.appendingPathComponent("rppairing.plist")
		let metadata = root.appendingPathComponent("rppairing-device.plist")
		let device = ZagPairedDeviceIdentity(name: "Test iPhone", model: "iPhone", udid: "0000ABCD-0123456789ABCDEF")!
		do {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			func writeHost(_ byte: UInt8) throws {
				try PropertyListSerialization.data(fromPropertyList: [
					"identifier": "Zag Store", "public_key": Data(repeating: byte, count: 32),
					"private_key": Data(repeating: 2, count: 32)
				], format: .xml, options: 0).write(to: credentials)
			}
			try writeHost(1)
			let migration = ZagSavedPairing(credentials: credentials, metadata: metadata)
			check(migration.hasCredentials && migration.restore(cleanupPending: false) == nil,
				  "legacy credentials allow identity migration without pairing again")
			try migration.save(device)
			let restarted = ZagSavedPairing(credentials: credentials, metadata: metadata)
			check(restarted.restore(cleanupPending: false) == device && restarted.restore(cleanupPending: true) == nil,
				  "a restarted core restores the saved device and respects pending cleanup")
			try writeHost(3)
			check(restarted.restore(cleanupPending: false) == nil, "a replaced host key invalidates stale device metadata")
			try writeHost(1)
			let restored = restarted.restore(cleanupPending: false)!
			let harness = await Harness.make()
			let authorization = await harness.authorization()
			let component = request().app
			var request = ZagProvisioningRequest(accountID: harness.account, team: team, deviceUDID: restored.udid,
				deviceName: restored.name, app: component, extensions: [], installedFreeAccountApps: [])
			try PropertyListSerialization.data(fromPropertyList: [
				"CFBundleShortVersionString": "1.2", "CFBundleVersion": "7"
			], format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
			let signer = Signer()
			do {
				_ = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
					provisioner: harness.provisioner, secrets: harness.secrets, signer: signer, installer: Installer(interrupted: true),
					verifyTarget: {}, now: { harness.clock.now })
				check(false, "interrupted installer must report its failure")
			} catch let failure as ZagStagedSigningFailure where failure.phase == .installation && failure.underlying is Interruption {
				check(true, "the production pipeline surfaces a simulated installation interruption")
			}
			guard let result = signer.result else { return check(false, "signing produced a provisioning result") }
			request.reusableProfiles = [result.app.profile]
			let newProvisioner = ZagFreeAccountProvisioner(portal: harness.portal, keys: ZagSimulatedSigningKeyFactory(),
				secrets: harness.secrets, account: harness.account, now: { harness.clock.now })
			let verification = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
				provisioner: newProvisioner, secrets: harness.secrets, signer: signer, installer: Installer(interrupted: false),
				verifyTarget: {}, now: { harness.clock.now })
			let calls = await harness.portal.calls
			check(calls.filter { $0 == .registerDevice }.count == 1 && calls.filter { $0 == .registerAppID }.count == 1
				  && calls.filter { $0 == .submitCertificateRequest }.count == 1 && calls.filter { $0 == .profile }.count == 1,
				  "resumed pipeline reuses the device, App ID, certificate and valid profile")
			check(verification == .verified(profileExpiresAt: result.app.profile.expiresAt,
				certificateExpiresAt: harness.storedIdentity!.expiresAt),
				  "resumed pipeline signs, installs and independently verifies the intended app")
		} catch {
			check(false, "native signing restart and installation: \(error)")
		}
	}

	static func firstProvisioning() async {
		let h = await Harness.make()
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
		let stored = h.storedIdentity
		check(stored?.serialNumber == value.certificateSerial && stored?.privateKey.count == 32, "the signing key is kept in the Keychain store with its certificate")
		check(Set(h.secrets.items.keys) == ["\(h.account).session", "\(h.account).accountRecord", "\(h.account).signingPrivateKey.\(team)"],
			  "besides the session and the ownership record, only the team's signing identity is stored (no request left pending)")
		let log = h.diagnostics.entries.map(\.message).joined(separator: "\n")
		check(!log.contains(udid) && !log.contains("SIMULATED-CERTIFICATE") && !log.contains(stored?.privateKey.base64EncodedString() ?? "-"),
			  "diagnostics hold no device ID, certificate or key")
	}

	static func reuseAndRefresh() async {
		let h = await Harness.make()
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
		let full = await Harness.make()
		let slots = await full.run(request(installed: ["a.\(team)", "b.\(team)", "c.\(team)"]))
		let slotCalls = await full.portal.calls
		check(slots.failure?.kind == .installSlotsFull(installed: ["a.\(team)", "b.\(team)", "c.\(team)"]) && slotCalls.isEmpty,
			  "three installed apps stop provisioning before Apple is asked")
		let refresh = await full.run(request(installed: ["com.example.notes.\(team)", "b.\(team)", "c.\(team)"]))
		check(refresh.value != nil, "refreshing an installed app needs no free slot")

		let devices = await Harness.make()
		for index in 0..<3 { await devices.portal.seedDevice("OTHER-\(index)") }
		let deviceResult = await devices.run(request())
		let deviceMutations = await devices.portal.mutations
		check(deviceResult.failure?.kind == .deviceLimitReached && deviceMutations.isEmpty, "a fourth device is refused and nothing is created")

		let appIDs = await Harness.make()
		for index in 0..<9 { await appIDs.portal.seedAppID("com.other.app\(index).\(team)", expiresAt: appIDs.clock.now + Double(index + 1) * 3_600) }
		let appIDResult = await appIDs.run(request(extensions: ["com.example.notes.widget"]))
		let appIDMutations = await appIDs.portal.mutations
		check(appIDResult.failure?.kind == .appIDCapacityExhausted(needed: 2, available: 1, nextSlotFreesAt: appIDs.clock.now + 3_600),
			  "App ID capacity is reported with when the next slot frees")
		check(appIDMutations == [.registerDevice], "no certificate or App ID is created when App IDs would run out")
		check(appIDs.storedIdentity == nil, "no signing key is created either")

		let taken = await Harness.make()
		await taken.portal.setForeignIdentifiers(["com.example.notes.\(team)"])
		let takenResult = await taken.run(request())
		check(takenResult.failure?.kind == .identifierUnavailable("com.example.notes.\(team)"), "an identifier owned by another team is reported")

		let invalid = await Harness.make()
		let bad = await invalid.run(request(app: "not a bundle id"))
		check(bad.failure?.kind == .invalidRequest && bad.failure?.step == .request, "an invalid bundle ID is refused locally")
	}

	static func certificates() async {
		let limit = await Harness.make()
		await limit.portal.seedCertificate(serial: "AAAA", expiresAt: limit.clock.now + 200 * 86_400)
		await limit.portal.seedCertificate(serial: "BBBB", expiresAt: limit.clock.now + 100 * 86_400)
		let result = await limit.run(request())
		guard case .certificateMustBeRevoked(let candidates)? = result.failure?.kind else { return check(false, "certificate limit") }
		check(candidates.map(\.serialNumber) == ["BBBB", "AAAA"], "at the certificate limit the user is offered certificates to revoke, soonest-expiring first")
		let issued = await limit.portal.issuedCertificates.count
		check(issued == 2, "no certificate is revoked automatically")

		let conflict = await Harness.make()
		await conflict.portal.seedCertificate(serial: "16EED9", expiresAt: conflict.clock.now + 100 * 86_400)
		await conflict.portal.fail(.submitCertificateRequest, with: .certificateConflict)
		let refused = await conflict.run(request())
		guard case .certificateMustBeRevoked(let listed)? = refused.failure?.kind else {
			return check(false, "Apple 7460 must surface as a certificate conflict")
		}
		let pending = try! conflict.secrets.load(.pendingSigningKey, account: conflict.account, team: team)
			.map { try JSONDecoder().decode(ZagPendingSigningKey.self, from: $0) }
		check(listed.map(\.serialNumber) == ["16EED9"] && pending?.submissionUnconfirmed == false,
			  "Apple 7460 preserves the key and records explicit refusal")
		conflict.clock.advance(ZagPendingSigningKey.lifetime + 1)
		await conflict.portal.fail(.submitCertificateRequest, with: nil)
		let resumed = await conflict.run(request())
		let published = try! conflict.secrets.load(.signingPrivateKey, account: conflict.account, team: team)
			.map { try JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		check(resumed.value?.changes.createdCertificate == true && published?.privateKey == pending?.privateKey,
			  "signing resumes with the preserved key after Apple allows issuance")

		let ambiguous = await Harness.make()
		await ambiguous.portal.fail(.submitCertificateRequest, with: .network)
		let lost = await ambiguous.run(request())
		await ambiguous.portal.fail(.submitCertificateRequest, with: nil)
		let retry = await ambiguous.run(request())
		let calls = await ambiguous.portal.calls
		check(lost.failure?.kind == .certificateRequestUnresolved && retry.failure?.kind == .certificateRequestUnresolved
			  && calls.filter { $0 == .submitCertificateRequest }.count == 1,
			  "an ambiguous CSR with no inventory match stays pending and does not resubmit")
		let abandoned = await ambiguous.provisioner.abandonUnresolvedCertificateRequest(accountID: ambiguous.account, team: team)
		let afterAbandon = await ambiguous.run(request())
		check(abandoned == .abandoned && afterAbandon.value?.changes.createdCertificate == true,
			  "explicit abandonment allows a fresh request and resumes provisioning")

		let expiring = await Harness.make()
		_ = await expiring.run(request())
		expiring.clock.advance(360 * 86_400)
		let renewed = await expiring.run(request())
		check(renewed.value?.changes.createdCertificate == true, "a certificate with under 7 days left is replaced, not reused")

		let storage = await Harness.make()
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
			let h = await Harness.make()
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
			let h = await Harness.make()
			await h.portal.fail(.appIDs, with: failure)
			let result = await h.run(request())
			check(result.failure?.kind == kind && result.failure?.step == .appIDs, label)
		}

		let slow = await Harness.make(timeout: 0.3)
		await slow.portal.fail(.profile, with: .noResponse)
		let timedOut = await slow.run(request())
		check(timedOut.failure?.kind == .timedOut && timedOut.failure?.step == .profiles, "a portal call that does not answer times out")

		let cancelled = await Harness.make()
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
		let h = await Harness.make()
		let clock = h.clock
		let provisioner = ZagFreeAccountProvisioner(secrets: h.secrets, now: { clock.now })
		let request = ZagProvisioningRequest(accountID: h.account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
											 app: .init(originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: entitlements()),
											 extensions: [], installedFreeAccountApps: [])
		let result = await provisioner.provision(request, authorization: await h.authorization())
		check(result.failure?.kind == .unavailable && h.storedIdentity == nil, "the default build cannot provision and says it is unavailable")
		check(ZagLivePortal.isEnabled == false && ZagLiveAuthentication.isEnabled == false && ZagAnisetteLive.isEnabled == false,
			  "live portal, sign-in and anisette are all disabled")
	}
}
