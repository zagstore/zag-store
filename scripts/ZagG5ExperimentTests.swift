import Foundation
import Security

// G5: the experiment's safeguards, offline (G5-EXPERIMENT-BUILD-PLAN.md §5.4,
// §5.5; G5-DIAGNOSTIC-LOGGING-SPEC.md §10). Run by
// scripts/test-zag-g5-experiment.sh, compiled with ZAG_G5_TESTS (never set in
// an app build).
//
// T1–T16 run the real provisioner and the real bridge portal adapter
// (`ZagIsideloadDeveloperPortal`, so its campaign gate and the
// `ZagCertificateBudget.consume` choke point run unchanged), with the bridge
// itself replaced below the adapter by a scripted transport that answers
// from the simulated portal and counts every certificate request that
// reaches it. Certificates and profiles come from a local test authority
// (trusted by nothing). Nothing contacts Apple or an anisette provider.
//
// A failed check is recorded and the suite continues, so the no-`consume`
// mutant run reports which tests fail; any failure exits non-zero.

let environment = ProcessInfo.processInfo.environment
let openssl = environment["ZAG_TEST_OPENSSL"]!
let authority = URL(fileURLWithPath: environment["ZAG_TEST_AUTHORITY"]!)
let work = URL(fileURLWithPath: environment["ZAG_TEST_WORK"]!)
let deviceUDID = "00000000-SIMULATED000000"

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: tool)
	process.arguments = arguments
	let pipe = Pipe()
	process.standardOutput = pipe
	process.standardError = pipe
	try! process.run()
	let output = pipe.fileHandleForReading.readDataToEndOfFile()
	process.waitUntilExit()
	return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

func file(_ data: Data, _ name: String) -> URL {
	let url = work.appendingPathComponent("\(UUID().uuidString)-\(name)")
	try! data.write(to: url)
	return url
}

final class OpenSSLIssuer: ZagSimulatedIssuer, @unchecked Sendable {
	func certificate(for request: ZagCertificateRequest, serialNumber: String) throws -> Data {
		let csr = file(request.data, "request.der"), cert = work.appendingPathComponent("cert-\(serialNumber).der")
		let result = run(openssl, ["x509", "-req", "-inform", "DER", "-in", csr.path,
			"-CA", authority.appendingPathComponent("ca.pem").path, "-CAkey", authority.appendingPathComponent("ca.key").path,
			"-set_serial", "0x\(serialNumber)", "-days", "365", "-outform", "DER", "-out", cert.path])
		guard result.status == 0 else { throw ZagPortalError.malformedResponse }
		return try Data(contentsOf: cert)
	}

	func profile(signing plist: Data) throws -> Data {
		let input = file(plist, "profile.plist"), output = work.appendingPathComponent("profile-\(UUID().uuidString).der")
		let result = run(openssl, ["cms", "-sign", "-nodetach", "-binary", "-outform", "DER",
			"-signer", authority.appendingPathComponent("ca.pem").path, "-inkey", authority.appendingPathComponent("ca.key").path,
			"-in", input.path, "-out", output.path])
		guard result.status == 0 else { throw ZagPortalError.malformedResponse }
		return try Data(contentsOf: output)
	}
}

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	func accountIDs() throws -> Set<UUID> { lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) } }
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil } }
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
	func pending(_ account: UUID, _ team: String) -> ZagPendingSigningKey? {
		lock.withLock { items["\(account).pendingSigningKey.\(team)"] }.flatMap { try? JSONDecoder().decode(ZagPendingSigningKey.self, from: $0) }
	}
}

/// Certificate requests that reached the transport (below the adapter).
final class RequestCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	func add() { lock.withLock { count += 1 } }
	var value: Int { lock.withLock { count } }
}

final class Box<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: T
	init(_ value: T) { stored = value }
	var value: T {
		get { lock.withLock { stored } }
		set { lock.withLock { stored = newValue } }
	}
}

func component(_ id: String, _ name: String) -> ZagProvisioningRequest.Component {
	.init(originalBundleIdentifier: id, name: name, entitlements: try! ZagEntitlementSet(["keychain-access-groups": ["ORIGTEAM01.\(id)"]]))
}

/// The bridge's JSON answers, from the simulated portal (the shapes
/// `ZagIsideloadDeveloperPortal` decodes).
func scriptedTransport(_ portal: ZagSimulatedDeveloperPortal, counter: RequestCounter) -> ZagIsideloadDeveloperPortal.Transport {
	{ _, json in
		guard let request = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
			  let op = request["op"] as? String, let team = request["team"] as? String else { return .failed(.invalidInput) }
		func appID(_ id: ZagRegisteredAppID) -> [String: Any] {
			var value: [String: Any] = ["identifier": id.identifier, "bundleIdentifier": id.bundleIdentifier]
			if let expires = id.expiresAt { value["expiresAt"] = expires.timeIntervalSince1970 }
			return value
		}
		func certificate(_ c: ZagDevelopmentCertificate, data: Data? = nil) -> [String: Any] {
			var value: [String: Any] = ["serialNumber": c.serialNumber, "name": c.name, "expiresAt": c.expiresAt.timeIntervalSince1970]
			if let machine = c.machineName { value["machineName"] = machine }
			if let data = data ?? c.data { value["data"] = data.base64EncodedString() }
			return value
		}
		func findAppID(_ identifier: Any?) async throws -> ZagRegisteredAppID {
			guard let found = try await portal.appIDs(team: team).first(where: { $0.identifier == identifier as? String }) else { throw ZagPortalError.malformedResponse }
			return found
		}
		do {
			let value: Any
			switch op {
			case "devices":
				value = try await portal.devices(team: team).map { ["udid": $0.udid, "name": $0.name] }
			case "registerDevice":
				let device = try await portal.registerDevice(udid: request["udid"] as! String, name: request["name"] as! String, team: team)
				value = ["udid": device.udid, "name": device.name]
			case "appIds":
				value = try await portal.appIDs(team: team).map(appID)
			case "registerAppId":
				value = appID(try await portal.registerAppID(bundleIdentifier: request["bundleIdentifier"] as! String, name: request["name"] as! String, team: team))
			case "appGroups":
				value = try await portal.appGroups(team: team).map { ["identifier": $0.identifier] }
			case "registerAppGroup":
				value = ["identifier": try await portal.registerAppGroup(request["identifier"] as! String, team: team).identifier]
			case "assignAppGroups":
				try await portal.assignAppGroups(request["groups"] as! [String], to: try await findAppID(request["appId"]), team: team)
				value = [String: Any]()
			case "certificates":
				value = try await portal.certificates(team: team).map { certificate($0) }
			case "submitCertificateRequest":
				counter.add()
				let issued = try await portal.submitCertificateRequest(ZagCertificateRequest(data: Data(base64Encoded: request["request"] as! String)!), team: team)
				value = certificate(issued.certificate, data: issued.data)
			case "profile":
				value = ["data": try await portal.profile(for: try await findAppID(request["appId"]), team: team).data.base64EncodedString()]
			default:
				return .failed(.invalidInput)
			}
			return .result(try JSONSerialization.data(withJSONObject: value))
		} catch let error as ZagPortalError {
			switch error {
			case .sessionRejected: return .failed(.sessionExpired)
			case .network: return .failed(.network)
			case .rateLimited: return .failed(.rateLimited)
			default: return .failed(.refused)
			}
		} catch {
			return .failed(.cancelled)
		}
	}
}

/// One campaign's device stores: the registry (survives reinstalls, like the
/// Keychain) and the container marker (deleting the app wipes it).
final class Device: @unchecked Sendable {
	let registry = MemoryCampaignRegistry()
	let marker = MemoryCampaignMarker()
	let appleTime = Box<Date?>(Date())
	let clock = Box(Date())
	var logger: ZagExperimentLogger

	init() { logger = Device.newLogger() }

	static func newLogger() -> ZagExperimentLogger {
		var key = [UInt8](repeating: 0, count: 32)
		_ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
		return ZagExperimentLogger(store: ZagMemoryExperimentLogStore(), runKey: Data(key), provider: "anisette.example.org")
	}

	static func constants(_ number: Int = 1, nonce: String = "0123456789abcdef0123456789abcdef", now: Date = Date()) -> ZagCampaignConstants {
		ZagCampaignConstants(
			campaignID: "G5-C\(number)", campaignNumber: number,
			notBefore: now.addingTimeInterval(-3_600), notAfter: now.addingTimeInterval(72 * 3_600),
			buildNonce: nonce, anisetteURL: "https://anisette.example.org", deviceSerialPolicy: "g3Fixed", deviceSerial: "TESTSERIAL01"
		)
	}

	/// A launch of the app: a new campaign object over the same stores, made
	/// the process-wide one (the provisioner's stop hooks use it).
	func launch(_ constants: ZagCampaignConstants = Device.constants()) -> (ZagLiveExperimentCampaign, ZagLiveExperimentCampaign.Durability) {
		let appleTime = appleTime, clock = clock
		let campaign = ZagLiveExperimentCampaign(constants: constants, registry: registry, marker: marker, logger: logger,
												 now: { clock.value }, authenticatedTime: { appleTime.value })
		ZagLiveExperiment.campaign = campaign
		ZagLiveExperiment.logger = logger
		return (campaign, campaign.launch())
	}

	/// E5 done: first launch, one delete-and-reinstall, second launch.
	func armed(_ constants: ZagCampaignConstants = Device.constants()) -> ZagLiveExperimentCampaign {
		_ = launch(constants)
		marker.wipe()
		let (campaign, result) = launch(constants)
		precondition(result == .armed, "arming failed: \(result)")
		return campaign
	}

	var registryValue: ZagCampaignRegistry? {
		registry.stored.flatMap { try? JSONDecoder().decode(ZagCampaignRegistry.self, from: $0) }
	}
}

/// One signed-in account with its own portal, adapter and provisioner.
struct Rig {
	let secrets: MemorySecrets
	let directory: ZagAccountDirectory
	let account: UUID
	let team: String
	let portal: ZagSimulatedDeveloperPortal
	let counter: RequestCounter
	let adapter: ZagIsideloadDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner
	let keys: ZagKeychainSigningKeys

	static func make(_ campaign: ZagLiveExperimentCampaign, appleID: String = SimulatedAccounts.tester,
					 secrets: MemorySecrets = MemorySecrets(), directory: ZagAccountDirectory? = nil,
					 keys: ZagKeychainSigningKeys? = nil, portal: ZagSimulatedDeveloperPortal? = nil) async -> Rig {
		let directory = directory ?? SimulatedAccounts.directory(now: { Date() }, secrets: secrets).directory
		let account = await SimulatedAccounts.signIn(appleID, to: directory)!
		let team = await directory.registry.account(account)!.teams[0].identifier
		let portal = portal ?? ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer())
		let counter = RequestCounter()
		let adapter = ZagIsideloadDeveloperPortal(account: account, secrets: secrets, campaign: campaign, transport: scriptedTransport(portal, counter: counter))
		let keys = keys ?? ZagKeychainSigningKeys(namespace: "ZagStore.test.g5.\(UUID().uuidString)")
		let provisioner = ZagFreeAccountProvisioner(portal: adapter, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: secrets, account: account)
		return Rig(secrets: secrets, directory: directory, account: account, team: team, portal: portal, counter: counter,
				   adapter: adapter, provisioner: provisioner, keys: keys)
	}

	/// The same account after a relaunch: new adapter and provisioner over
	/// the same Keychain items, with `campaign` (a new campaign object).
	func relaunched(_ campaign: ZagLiveExperimentCampaign) -> Rig {
		let adapter = ZagIsideloadDeveloperPortal(account: account, secrets: secrets, campaign: campaign, transport: scriptedTransport(portal, counter: counter))
		let provisioner = ZagFreeAccountProvisioner(portal: adapter, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: secrets, account: account)
		return Rig(secrets: secrets, directory: directory, account: account, team: team, portal: portal, counter: counter,
				   adapter: adapter, provisioner: provisioner, keys: keys)
	}

	var accountKey: String {
		let credential = try! JSONDecoder().decode(ZagSessionCredential.self, from: try! secrets.load(.session, account: account)!)
		return ZagAppleAccountRecord.accountKey(for: credential.accountIdentifier)
	}

	func request(_ app: String = "com.example.notes") -> ZagProvisioningRequest {
		ZagProvisioningRequest(accountID: account, team: team, deviceUDID: deviceUDID, deviceName: "Test iPhone",
							   app: component(app, "Notes"), extensions: [], installedFreeAccountApps: [])
	}

	func provision(_ app: String = "com.example.notes") async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		let authorization = try! await directory.authorize(ZagSigningScope(accountID: account, teamID: team))
		return await provisioner.provision(request(app), authorization: authorization)
	}

	/// Loses the stored signing identity (as after a reset), so the next
	/// provisioning must ask for a new certificate.
	func loseIdentity() { try? secrets.delete(.signingPrivateKey, account: account, team: team) }

	func cleanUp() { try? keys.deleteAll(account: account) }
}

func wait(_ timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
	let end = Date().addingTimeInterval(timeout)
	while Date() < end {
		if await condition() { return true }
		try? await Task.sleep(nanoseconds: 20_000_000)
	}
	return false
}

func events(_ logger: ZagExperimentLogger, _ name: String) -> [ZagLogEvent] {
	let (phase, event) = ZagLogSchema.split(name)
	return logger.events.filter { $0.phase == phase && $0.event == event }
}

func field(_ event: ZagLogEvent, _ name: String) -> String? {
	switch event.fields?[name] {
	case .string(let value)?: value
	case .bool(let value)?: String(value)
	case .int(let value)?: String(value)
	default: nil
	}
}

func budgetDecisions(_ logger: ZagExperimentLogger) -> [String] { events(logger, "cert.budget").compactMap { field($0, "decision") } }

func checkRefused(_ logger: ZagExperimentLogger, _ check: String) -> Bool {
	events(logger, "campaign.check").contains { field($0, "check") == check && field($0, "result") == "refuse" }
}

func halted(_ device: Device, _ id: String = "G5-C1") -> Bool { device.registryValue?.campaigns[id]?.state == .halted }

@main struct Tests {
	nonisolated(unsafe) static var passed = 0
	nonisolated(unsafe) static var failed: [String] = []

	static func check(_ value: Bool, _ label: String) {
		if value {
			passed += 1
			print("PASS: \(label)")
		} else {
			failed.append(label)
			print("FAIL: \(label)")
		}
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		let only = environment["ZAG_G5_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
		func runs(_ group: String) -> Bool { only == nil || only!.split(separator: ",").contains(Substring(group)) }
		if runs("budget") { await budgetTests() }
		if runs("e5") { durabilityTests() }
		if runs("checks") { await campaignCheckTests() }
		if runs("logger") { await loggerTests() }
		print("RESULT: \(passed) passed, \(failed.count) failed")
		if !failed.isEmpty {
			for label in failed { print("FAILED: \(label)") }
			exit(1)
		}
		print("SUCCESS: G5 experiment safeguards (\(passed) checks)")
	}

	// MARK: - T1–T16 (plan §5.4)

	static func budgetTests() async {
		// T1: a normal first request.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			let result = await rig.provision()
			let record = device.registryValue?.campaigns["G5-C1"]
			check((try? result.get()) != nil, "T1: the first provisioning succeeds")
			check(rig.counter.value == 1, "T1: exactly one certificate request reached the portal")
			check(record?.state == .spent && record?.submissions == 1, "T1: the ledger is spent, with one submission")
			check(record?.accountKey == rig.accountKey, "T1: the account is pinned to the signed-in account")
			check(budgetDecisions(device.logger) == ["allow"], "L10/T1: cert.budget records one allow")
			check(events(device.logger, "campaign.state").contains { field($0, "from") == "armed" && field($0, "to") == "spent" && field($0, "reason") == "consume" },
				  "L10/T1: campaign.state armed → spent (consume)")
			check(events(device.logger, "cert.preflight").count == 1 && events(device.logger, "cert.preflight")[0].outcome == "ok",
				  "T1: E4 ran once before the first mutating call and found the account empty")

			// T2: a second provision after issuance.
			let reused = await rig.provision("com.example.second")
			check((try? reused.get()) != nil && rig.counter.value == 1, "T2: a second app reuses the certificate; no request")
			rig.loseIdentity()
			let again = await rig.provision("com.example.third")
			check((try? again.get()) == nil && rig.counter.value == 1, "T2: a new certificate request after issuance is refused; still one request")
			check(budgetDecisions(device.logger).last == "budgetSpent", "L10/T2: cert.budget records budgetSpent")
			check(halted(device), "T2: the refusal halts the campaign (stop rule certificateBudgetSpent)")

			// T8: relaunch.
			let (relaunched, launchResult) = device.launch()
			check(launchResult == .refused && checkRefused(device.logger, "C2"), "T8: a relaunch finds the campaign used up (C2)")
			let rig2 = rig.relaunched(relaunched)
			rig2.loseIdentity()
			_ = await rig2.provision("com.example.fourth")
			check(rig.counter.value == 1, "T8: after a relaunch a new request is refused; still one request")

			// T9: reinstall: container wiped, a new installation ID, preferences gone; same Keychain.
			let pinned = device.registryValue?.campaigns["G5-C1"]?.accountKey
			device.marker.wipe()
			device.logger = Device.newLogger()
			let (reinstalled, reinstallResult) = device.launch()
			let secrets = rig.secrets
			let fresh = await Rig.make(reinstalled, secrets: secrets, directory: SimulatedAccounts.directory(now: { Date() }, secrets: secrets).directory,
									   keys: rig.keys, portal: rig.portal)
			fresh.loseIdentity()
			_ = await fresh.provision("com.example.fifth")
			check(reinstallResult == .refused, "T9: the reinstalled app does not arm again")
			check(rig.counter.value + fresh.counter.value == 1, "T9: after a reinstall a new request is refused; still one request")
			check(halted(device) && device.registryValue?.campaigns["G5-C1"]?.accountKey == pinned, "T9: the halt and the account pin survive the reinstall")
			rig.cleanUp()
		}

		// T3: a definite refusal by Apple, then the production retry.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			await rig.portal.fail(.submitCertificateRequest, with: .rateLimited)
			let first = await rig.provision()
			let pending = rig.secrets.pending(rig.account, rig.team)
			check((try? first.get()) == nil && rig.counter.value == 1, "T3: Apple refuses the one request")
			check(pending?.submissionUnconfirmed == false && pending?.allowsRetry(at: Date()) == true,
				  "T3: production would retry (a definite refusal, attempts left)")
			await rig.portal.fail(.submitCertificateRequest, with: nil)
			_ = await rig.provision()
			check(rig.counter.value == 1, "T3: the retry is refused; one request in total")
			check(halted(device), "T3: the campaign is halted")
			rig.cleanUp()
		}

		// T4: cancelled before the send, while waiting in `exclusively`.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			await rig.portal.fail(.certificates, with: .noResponse)
			let holder = Task { await rig.provision() }
			let started = await wait { await !rig.portal.calls.isEmpty }
			let waiter = Task { await rig.provision() }
			let queued = await wait { await rig.provisioner.waitingOperations == 1 }
			waiter.cancel()
			let cancelled = await waiter.value
			holder.cancel()
			_ = await holder.value
			check(started && queued, "T4: one provisioning holds the scope and another waits for it")
			if case .failure(let failure) = cancelled { check(failure.kind == .cancelled, "T4: the waiting provisioning is cancelled") }
			else { check(false, "T4: the waiting provisioning is cancelled") }
			check(rig.counter.value == 0 && device.registryValue?.campaigns["G5-C1"]?.state == .armed && device.registryValue?.campaigns["G5-C1"]?.submissions == 0,
				  "T4: nothing was sent and the budget is not consumed")
			await rig.portal.fail(.certificates, with: nil)
			let later = await rig.provision()
			check((try? later.get()) != nil && rig.counter.value == 1 && device.registryValue?.campaigns["G5-C1"]?.state == .spent,
				  "T4: a later request is allowed once")
			rig.cleanUp()
		}

		// T5: cancelled after consume, before the bridge returns.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			await rig.portal.fail(.submitCertificateRequest, with: .noResponse)
			let task = Task { await rig.provision() }
			let consumed = await wait { device.registryValue?.campaigns["G5-C1"]?.submissions == 1 }
			_ = await wait { rig.counter.value == 1 }
			task.cancel()
			_ = await task.value
			let record = device.registryValue?.campaigns["G5-C1"]
			check(consumed && record?.submissions == 1, "T5: the budget was consumed before the request was sent")
			check(rig.secrets.pending(rig.account, rig.team)?.submissionUnconfirmed == true, "T5: the journal leaves the request unresolved")
			check(record?.state == .halted, "T5: the halt is set")
			await rig.portal.fail(.submitCertificateRequest, with: nil)
			_ = await rig.provision()
			check(rig.counter.value == 1, "T5: later requests are refused; one request in total")
			rig.cleanUp()
		}

		// T6: lost response, Check Again → notIssued, then signing again.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			await rig.portal.fail(.submitCertificateRequest, with: .network)
			_ = await rig.provision()
			let authorization = try! await rig.directory.authorize(ZagSigningScope(accountID: rig.account, teamID: rig.team))
			let outcome = await rig.provisioner.checkUnresolvedCertificateRequest(accountID: rig.account, team: rig.team, authorization: authorization)
			check(outcome == .notIssued, "T6: Check Again (a read, allowed while halted) settles the request as not issued")
			check(events(device.logger, "cert.recovery").contains { field($0, "result") == "notIssued" }, "T6: cert.recovery records notIssued")
			await rig.portal.fail(.submitCertificateRequest, with: nil)
			_ = await rig.provision()
			check(rig.counter.value == 1, "T6: the re-request is refused; one request in total")
			rig.cleanUp()
		}

		// T7: unresolved, abandon (forced past E3), new key and request.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			await rig.portal.fail(.submitCertificateRequest, with: .network)
			_ = await rig.provision()
			let refused = await rig.provisioner.abandonUnresolvedCertificateRequest(accountID: rig.account, team: rig.team)
			check(refused == .checkFailed(.unavailable) && rig.secrets.pending(rig.account, rig.team) != nil,
				  "E3: Abandon is refused by the model during a campaign; the request is kept")
			ZagLiveExperiment.testAllowsAbandon = true
			let abandoned = await rig.provisioner.abandonUnresolvedCertificateRequest(accountID: rig.account, team: rig.team)
			ZagLiveExperiment.testAllowsAbandon = false
			await rig.portal.fail(.submitCertificateRequest, with: nil)
			_ = await rig.provision()
			check(abandoned == .abandoned && rig.counter.value == 1, "T7: after a forced abandon the new key's request is refused; one request in total")
			rig.cleanUp()
		}

		// T10: account switch.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			_ = await rig.provision()
			try? await rig.directory.signOut(rig.account)
			let second = await Rig.make(campaign, appleID: SimulatedAccounts.second, secrets: rig.secrets, directory: rig.directory)
			_ = await second.provision()
			check(rig.counter.value == 1 && second.counter.value == 0, "T10: the second account sends nothing; one request in total")
			check(budgetDecisions(device.logger).last == "accountMismatch" || events(device.logger, "campaign.accountPin").contains { field($0, "result") == "mismatch" },
				  "T10: refused as experimentAccountMismatch")
			check(halted(device), "T10: the halt is set")
			rig.cleanUp(); second.cleanUp()
		}

		// T12: concurrent provisions: two accounts, and two independent
		// provisioners on one account (no shared exclusivity between them).
		do {
			let device = Device(), campaign = device.armed()
			let first = await Rig.make(campaign)
			let second = await Rig.make(campaign, appleID: SimulatedAccounts.second, secrets: first.secrets, directory: first.directory)
			async let a = first.provision()
			async let b = second.provision()
			let results = await [a, b]
			check(first.counter.value + second.counter.value <= 1, "T12: two accounts at once: at most one request (\(first.counter.value + second.counter.value))")
			let firstCalls = await first.portal.calls, secondCalls = await second.portal.calls
			let kinds = results.map { result -> String in
				switch result { case .success: "success"; case .failure(let failure): "\(failure.kind)" }
			}
			// When the loser reaches the budget, its account-pin refusal halts
			// the campaign, so the winner's later steps may be refused too (E2).
			// Never more than one success.
			let reachedBudget = budgetDecisions(device.logger).count
			check(results.filter { (try? $0.get()) != nil }.count <= 1 && (reachedBudget < 2 || halted(device)),
				  "T12: two accounts at once: at most one succeeds; a second budget attempt halts \(kinds) (budget attempts \(reachedBudget); portal calls \(firstCalls.count)/\(secondCalls.count))")
			first.cleanUp(); second.cleanUp()
		}
		do {
			let device = Device(), campaign = device.armed()
			let first = await Rig.make(campaign)
			let twin = first.relaunched(campaign)
			async let a = first.provision()
			async let b = twin.provision("com.example.twin")
			_ = await [a, b]
			// Safety only: under load both may stop before sending (fail-closed);
			// T1 covers the single request going through.
			check(first.counter.value <= 1, "T12: two provisioners on one account at once: at most one request (\(first.counter.value))")
			first.cleanUp()
		}

		// T13: a new campaign in the same Keychain; the account already has a certificate.
		do {
			let device = Device()
			_ = device.armed(Device.constants(1))
			let campaign = device.armed(Device.constants(2, nonce: "fedcba9876543210fedcba9876543210"))
			let rig = await Rig.make(campaign)
			await rig.portal.seedCertificate(serial: "0A0B0C0D0E0F1011", expiresAt: Date().addingTimeInterval(86_400 * 300))
			_ = await rig.provision()
			check(rig.counter.value == 0, "T13: E4 refuses before consume; nothing sent")
			check(checkRefused(device.logger, "C8") && halted(device, "G5-C2"), "T13: C8 refuses and halts the new campaign")
			check(budgetDecisions(device.logger).isEmpty, "T13: consume was never reached")
			rig.cleanUp()
		}

		// T14: halted: every live operation is refused except the certificate
		// list, sign-out and the inventory.
		do {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			campaign.halt(.ownerUnrecognised)
			for operation in [ZagLiveOperation.signIn, .portalRead, .portalMutate, .submitCertificate, .sign, .install] {
				check((try? campaign.authorize(operation)) == nil, "T14: halted: \(operation.rawValue) is refused")
			}
			for operation in [ZagLiveOperation.certificateList, .signOut, .inventory] {
				check((try? campaign.authorize(operation)) != nil, "T14: halted: \(operation.rawValue) is allowed")
			}
			check((try? await rig.adapter.certificates(team: rig.team)) != nil, "T14: halted: the certificate list can be read (recovery)")
			check((try? await rig.adapter.devices(team: rig.team)) == nil, "T14: halted: the device list is refused")
			check((try? await rig.adapter.submitCertificateRequest(ZagCertificateRequest(data: Data([1])), team: rig.team)) == nil && rig.counter.value == 0,
				  "T14: halted: a certificate request is refused before the portal")
			check((try? await rig.directory.orphanedItems()) != nil, "T14: halted: the inventory works")
			check((try? await rig.directory.signOut(rig.account)) != nil, "T14: halted: sign-out works")
			let allowed = (0..<5).allSatisfy { _ in (try? campaign.authorize(.portalRead)) == nil }
			check(allowed && halted(device), "T14/E2: nothing leaves halted")
			rig.cleanUp()
		}

		// T15: the ledger write fails during consume.
		for (label, breakStore) in [("the write fails", { (r: MemoryCampaignRegistry) in r.failWrites = true }),
									("the read-back differs", { (r: MemoryCampaignRegistry) in r.corruptReadBack = true })] {
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			// Break the store at the consume step only: E4 does not write.
			await rig.portal.fail(.submitCertificateRequest, with: nil)
			let before = device.registry.writes
			breakStore(device.registry)
			_ = await rig.provision()
			check(rig.counter.value == 0, "T15: \(label): the request is refused; nothing sent")
			if label == "the write fails" { check(device.registry.writes == before, "T15: \(label): nothing was stored") }
			check((try? campaign.authorize(.portalRead)) == nil, "T15: \(label): this process refuses every further live operation")
			rig.cleanUp()
		}

		// T16: Stored Account Data "Remove All" leaves the registry alone (the
		// real Keychain, test services only).
		do {
			let service = "ZagStore.test.g5.\(UUID().uuidString)"
			let registry = ZagKeychainCampaignRegistryStore(service: service + ".registry")
			let stored = try! ZagCampaignRegistry(highestCampaignNumber: 1, campaigns: [
				"G5-C1": .init(state: .spent, buildNonce: "0123456789abcdef0123456789abcdef", submissions: 1, accountKey: "k", probeLaunches: 1, haltRule: nil)
			]).encoded()
			let written = (try? registry.write(stored)) != nil
			let secrets = ZagKeychainFreeAccountSecretStore(service: service + ".accounts")
			try? secrets.save(Data("orphan".utf8), kind: .session, account: UUID(), team: nil)
			var configuration = ZagAccountDirectory.Configuration()
			configuration.namespace = service
			let directory = ZagAccountDirectory(anisette: StubAnisette(), secrets: secrets, preferences: TestPreferences(), configuration: configuration)
			let orphans = try? await directory.orphanedItems()
			var removal: ZagOrphanRemoval?
			if let orphans { removal = try? await directory.removeOrphanedItems(orphans) }
			let after = (try? await directory.orphanedItems())?.accounts.count
			check(written && orphans?.accounts.isEmpty == false && removal != nil && after == 0, "T16: Remove All removed the orphaned account items")
			check((try? registry.read()) == stored, "T16: the campaign registry is untouched by Remove All")
			SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".registry"] as CFDictionary)
			SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".accounts"] as CFDictionary)
		}
	}

	// MARK: - E5 and the state machine

	static func durabilityTests() {
		let device = Device()
		let (_, first) = device.launch()
		check(first == .probeWritten && device.registryValue?.campaigns["G5-C1"]?.state == .probing && device.marker.read() != nil,
			  "E5 row 1: first launch writes the probe and the marker; not armed")
		let (_, second) = device.launch()
		check(second == .stillProbing && device.registryValue?.campaigns["G5-C1"]?.state == .probing, "E5 row 2: a relaunch without reinstalling stays probing")
		device.marker.wipe()
		let (armed, third) = device.launch()
		check(third == .armed && armed.state == .armed, "E5 row 3: after deleting and reinstalling (registry present, marker absent) it arms")
		check(events(device.logger, "campaign.durability").map { field($0, "result") ?? "" } == ["probeWritten", "stillProbing", "armed"],
			  "E5: campaign.durability records each launch")

		let lost = Device()
		_ = lost.launch()
		lost.registry.wipe(); lost.marker.wipe()
		let (_, again) = lost.launch()
		check(again == .probeWritten && lost.registryValue?.campaigns["G5-C1"]?.state == .probing,
			  "E5 row 4: Keychain lost with the app deleted looks like a first launch and never arms")

		// Exhaustive: from probing, only "probe present, marker absent" arms.
		for registryPresent in [true, false] {
			for markerPresent in [true, false] {
				let d = Device()
				_ = d.launch()
				if !registryPresent { d.registry.wipe() }
				if !markerPresent { d.marker.wipe() }
				let (_, result) = d.launch()
				check((result == .armed) == (registryPresent && !markerPresent),
					  "E5 table: registry \(registryPresent ? "present" : "absent"), marker \(markerPresent ? "present" : "absent") → \(result.rawValue)")
			}
		}

		let unconfigured = Device()
		var placeholder = Device.constants()
		placeholder = ZagCampaignConstants.compiled
		let (_, compiled) = unconfigured.launch(placeholder)
		check(!ZagCampaignConstants.compiled.isAuthorisable && compiled == .unconfigured && unconfigured.registry.stored == nil,
			  "The compiled placeholder constants authorise nothing and write nothing")
		for broken in [
			{ (c: inout ZagCampaignConstants) in c.campaignNumber = 0 },
			{ c in c.buildNonce = String(repeating: "0", count: 32) },
			{ c in c.notAfter = c.notBefore.addingTimeInterval(8 * 86_400) },
			{ c in c.anisetteURL = "http://anisette.example.org" },
			{ c in c.deviceSerialPolicy = "unset" },
			{ c in c.campaignID = "G5-C9" },
		] as [(inout ZagCampaignConstants) -> Void] {
			var c = Device.constants()
			broken(&c)
			check(!c.isAuthorisable, "Constants refused: \(c.campaignID) #\(c.campaignNumber) window \(Int(c.notAfter.timeIntervalSince(c.notBefore) / 3600))h \(c.anisetteURL) \(c.deviceSerialPolicy)")
		}

		// The one writer's transition table (E2: nothing leaves halted).
		typealias R = ZagCampaignRegistry.Record
		func r(_ state: ZagCampaignState, _ submissions: Int = 0, key: String? = nil, nonce: String = "n") -> R {
			R(state: state, buildNonce: nonce, submissions: submissions, accountKey: key, probeLaunches: 1, haltRule: nil)
		}
		let allowed: [(R?, R?, Bool, String)] = [
			(nil, r(.probing), true, "none → probing"),
			(nil, r(.armed), false, "none → armed"),
			(nil, r(.halted), true, "none → halted"),
			(r(.probing), r(.armed), true, "probing → armed"),
			(r(.armed), r(.spent, 1, key: "k"), true, "armed → spent with one submission"),
			(r(.armed), r(.spent, 0), false, "armed → spent without a submission"),
			(r(.spent, 1, key: "k"), r(.closed, 1, key: "k"), true, "spent → closed"),
			(r(.spent, 1, key: "k"), r(.armed, 1, key: "k"), false, "spent → armed"),
			(r(.spent, 1, key: "k"), r(.probing, 1, key: "k"), false, "spent → probing"),
			(r(.closed, 1), r(.armed, 1), false, "closed → armed"),
			(r(.halted), r(.armed), false, "halted → armed"),
			(r(.halted), r(.probing), false, "halted → probing"),
			(r(.halted), nil, false, "halted → removed"),
			(r(.armed), nil, false, "armed → removed"),
			(r(.armed, key: "a"), r(.spent, 1, key: "b"), false, "a changed pin"),
			(r(.armed), r(.armed, nonce: "m"), false, "a changed nonce"),
			(r(.spent, 1, key: "k"), r(.halted, 1, key: "k"), true, "spent → halted"),
			(r(.armed, 0), r(.armed, 1), false, "a submission without spending"),
		]
		for (old, new, expected, label) in allowed {
			check(ZagLiveExperimentCampaign.allowed(old, new) == expected, "State machine: \(label) is \(expected ? "allowed" : "refused")")
		}
	}

	// MARK: - C1–C8 (plan §5.5; L11)

	static func campaignCheckTests() async {
		func haltFollows(_ device: Device, _ check: String) -> Bool {
			let log = device.logger.events
			guard let refuse = log.firstIndex(where: { $0.phase == "campaign" && $0.event == "check" && field($0, "check") == check && field($0, "result") == "refuse" }) else { return false }
			return log[refuse...].contains { $0.phase == "campaign" && $0.event == "state" && field($0, "to") == "halted" }
		}

		// C1: another build claiming the same campaign.
		do {
			let device = Device()
			_ = device.armed()
			let (_, result) = device.launch(Device.constants(1, nonce: "ffffffffffffffffffffffffffffffff"))
			check(result == .refused && checkRefused(device.logger, "C1") && haltFollows(device, "C1"), "C1: a different build nonce is refused and halts (L11)")
		}
		// C2: single use.
		do {
			let device = Device(), campaign = device.armed()
			try? campaign.verifyAccountState(certificates: 0, appIDs: 0, devices: 0)
			try? await ZagCertificateBudget.consume(campaign: campaign, accountKey: "k", recheckCertificates: { 0 })
			let (_, result) = device.launch()
			check(result == .refused && checkRefused(device.logger, "C2") && haltFollows(device, "C2"), "C2: a spent campaign never runs again (L11)")
			let (_, closedAgain) = device.launch()
			check(closedAgain == .refused, "C2: and stays refused")
		}
		// C3: monotonic campaign numbers.
		do {
			let device = Device()
			_ = device.armed(Device.constants(3, nonce: "33333333333333333333333333333333"))
			let (_, older) = device.launch(Device.constants(2, nonce: "22222222222222222222222222222222"))
			check(older == .refused && checkRefused(device.logger, "C3"), "C3: an older campaign after a newer one armed is refused")
			check(device.registryValue?.campaigns["G5-C2"] == nil, "C3: the older campaign never gets a record")
			let (_, same) = device.launch(Device.constants(3, nonce: "33333333333333333333333333333333"))
			check(same == .armed, "C3: the same campaign and build resumes")
		}
		// C4: device clock outside the window.
		for (label, offset) in [("before", -2.0 * 3_600), ("after", 80.0 * 3_600)] {
			let device = Device()
			let now = Date()
			device.clock.value = now.addingTimeInterval(offset)
			let (_, result) = device.launch(Device.constants(now: now))
			check(result == .refused && checkRefused(device.logger, "C4") && device.registry.stored == nil,
				  "C4: the device clock \(label) the window is refused; nothing written")
			check(events(device.logger, "campaign.window").contains { field($0, "deviceClock") == label }, "C4: campaign.window records \(label)")
		}
		// C5: authenticated time.
		for (label, apple, pass) in [
			("inside", Date().addingTimeInterval(60), true),
			("not yet checked", nil, false),
			("before the window", Date().addingTimeInterval(-2 * 3_600), false),
			("after the window", Date().addingTimeInterval(80 * 3_600), false),
			("11 minutes from the device clock", Date().addingTimeInterval(11 * 60), false),
			("9 minutes from the device clock", Date().addingTimeInterval(9 * 60), true),
		] as [(String, Date?, Bool)] {
			let device = Device()
			device.appleTime.value = apple
			let campaign = device.armed()
			let allowed = (try? campaign.authorize(.portalRead)) != nil
			check(allowed == pass, "C5: Apple time \(label): \(pass ? "allowed" : "refused")")
			if !pass { check(checkRefused(device.logger, "C5") && haltFollows(device, "C5"), "C5: \(label) refuses and halts (L11)") }
		}
		do {
			let device = Device()
			device.appleTime.value = nil
			let campaign = device.armed()
			check((try? campaign.authorize(.signIn)) != nil, "C5: sign-in itself may run before any Apple response")
		}
		// C6: the account pin.
		do {
			let device = Device(), campaign = device.armed()
			try? campaign.checkAccount("first")
			check(!halted(device), "C6: nothing is pinned before the first submission")
			try? campaign.verifyAccountState(certificates: 0, appIDs: 0, devices: 0)
			try? await ZagCertificateBudget.consume(campaign: campaign, accountKey: "first", recheckCertificates: { 0 })
			check((try? campaign.checkAccount("first")) != nil, "C6: the pinned account matches")
			var refused: ZagLiveExperimentRefusal?
			do { try campaign.checkAccount("second") } catch { refused = error as? ZagLiveExperimentRefusal }
			check(refused == .accountMismatch && checkRefused(device.logger, "C6") && haltFollows(device, "C6"), "C6: another account is refused and halts (L11)")
		}
		// C7: the container says armed but the registry is gone.
		do {
			let device = Device()
			_ = device.armed()
			device.registry.wipe()
			let (_, result) = device.launch()
			check(result == .refused, "C7: Keychain lost without deleting the app: the launch is refused (\(result.rawValue))")
			check(checkRefused(device.logger, "C7"), "C7: campaign.check records C7 refuse")
			check(halted(device), "C7: the registry is rewritten halted (\(String(describing: device.registryValue?.campaigns["G5-C1"]?.state)))")
		}
		do {
			let device = Device()
			_ = device.launch()
			device.registry.wipe()
			let (_, result) = device.launch()
			check(result == .refused && halted(device), "C7: a probing marker without its registry record is the same loss: halted (\(result.rawValue))")
		}
		// C8: account state.
		do {
			let device = Device(), campaign = device.armed()
			var refused = false
			do { try campaign.verifyAccountState(certificates: 0, appIDs: 0, devices: 1) } catch { refused = true }
			check(refused && checkRefused(device.logger, "C8") && haltFollows(device, "C8"), "C8: a device already on the account refuses and halts (L11)")
		}
		do {
			let device = Device(), campaign = device.armed()
			try? campaign.verifyAccountState(certificates: 0, appIDs: 0, devices: 0)
			var refused = false
			do { try await ZagCertificateBudget.consume(campaign: campaign, accountKey: "k", recheckCertificates: { 1 }) } catch { refused = true }
			check(refused && device.registryValue?.campaigns["G5-C1"]?.submissions == 0 && halted(device), "C8: a certificate appearing before consume refuses it")
		}
		do {
			let device = Device(), campaign = device.armed()
			check((try? campaign.authorize(.portalMutate)) == nil, "C8: a mutating call before the E4 check is refused")
		}
	}

	// MARK: - Logger and report (logging spec §10)

	static func sample(_ format: ZagLogFormat) -> ZagLogValue {
		switch format {
		case .oneOf(let members): members.contains("true") ? .bool(true) : members.contains("false") ? .bool(false) : .string(members.sorted()[0])
		case .int(let range): .int(range.lowerBound)
		case .bool: .bool(true)
		case .sha8: .string("1234abcd")
		case .ref8: .string("abcd1234")
		case .campaign: .string("G5-C1")
		case .host: .string("gsa.apple.com")
		case .template: .string("/grandslam/GsService2")
		case .list(let members): .list([members.sorted()[0]])
		}
	}

	static func header(_ logger: ZagExperimentLogger) -> ZagExperimentReport.Header {
		ZagExperimentReport.Header(
			campaignID: "G5-C1", installID8: logger.installID8, branchSHA8: "0123abcd", bridgeLibSHA8: "4567ef01", zsignSHA8: "89abcdef", ipaSHA8: "fedcba98",
			startedAtUTC: Date(), iOS: "18.1", device: "iPhone 15 Pro Max", gates: ["G1": true, "G2": true, "G3": true, "G4": false, "G5": false, "G6": true],
			providerHost: "anisette.example.org", serialPolicy: "g3Fixed", conditions: ["ZAG_APPLE_BRIDGE", "ZAG_LIVE_EXPERIMENT", "ZAG_ZSIGN_STRICT"]
		)
	}

	static func loggerTests() async {
		let provider = "anisette.example.org"

		// L1: every event round-trips; bad fields are rejected at record time.
		do {
			let logger = Device.newLogger()
			for name in ZagLogSchema.events.keys.sorted() where name != "logger.rejected" {
				let fields = ZagLogSchema.events[name]!.mapValues(sample)
				logger.record(name, fields: fields)
				let stored = logger.events.last!
				let line = try! JSONEncoder().encode(stored)
				let back = try! JSONDecoder().decode(ZagLogEvent.self, from: line)
				check(back == stored && "\(stored.phase).\(stored.event)" == name, "L1: \(name) round-trips")
			}
			for (label, name, fields) in [
				("an unknown field", "campaign.check", ["check": ZagLogValue.string("C1"), "result": .string("pass"), "note": .string("x")]),
				("a wrong type", "campaign.check", ["check": .int(1)]),
				("an out-of-range integer", "auth.twoFactor.submit", ["attemptsRemaining": .int(4)]),
				("a value outside its enum", "campaign.check", ["check": .string("C9")]),
				("an unknown event", "auth.password", [:]),
			] as [(String, String, [String: ZagLogValue])] {
				logger.record(name, fields: fields)
				let last = logger.events.last!
				check(last.phase == "logger" && last.event == "rejected", "L1: \(label) is rejected and replaced by logger.rejected")
			}
		}

		// L2: the leak corpus.
		do {
			let secrets = [
				"Zag-L2-Pa55word!", "482913", "1234567890123", "00008110-001A2B3C4D5E6F70", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
				"F2LXK0ABCDEF", "QURJLXBi-ZmFrZS1hZGktc3RhdGUtZm9yLXRlc3Rz", "-----BEGIN PRIVATE KEY-----", "X-Apple-I-MD: AAAAABQAAAAQ",
				"l2.tester@example.invalid", "+44 7700 900123", "L2TEAM9999", "SIMTEAM001", SimulatedAccounts.tester, deviceUDID,
			]
			let device = Device(), campaign = device.armed()
			let rig = await Rig.make(campaign)
			_ = await rig.provision()
			let logger = device.logger
			for secret in secrets {
				for (name, formats) in ZagLogSchema.events {
					for (key, format) in formats {
						if case .oneOf(let members) = format, members.contains(secret) { continue }
						logger.record(name, fields: [key: .string(secret)])
					}
				}
				logger.recordPolicyDecisions(try! JSONSerialization.data(withJSONObject: [[
					"host": secret.contains("@") ? secret : "\(secret).example.com", "path": "/grandslam/GsService2?token=\(secret)",
					"method": "POST", "scheme": "https", "allowed": false, "reason": "hostNotAllowed",
				]]))
			}
			let report = ZagExperimentReport(header: header(logger), events: logger.events, privateKeyExportCalls: logger.privateKeyExportCalls)
			for contentRules in [true, false] {
				guard case .success(let files) = report.export(provider: provider, contentRules: contentRules) else {
					check(false, "L2: the corpus run exports (content rules \(contentRules ? "on" : "off"))"); continue
				}
				let text = String(decoding: files.json, as: UTF8.self) + files.markdown
				let leaked = (secrets + [rig.accountKey, String(rig.accountKey.prefix(16))]).filter { text.contains($0) }
				check(leaked.isEmpty, "L2: no planted secret, account key or identifier in the export (content rules \(contentRules ? "on" : "off")) \(leaked)")
			}
			rig.cleanUp()
		}

		// L3: the false-positive corpus.
		do {
			let logger = Device.newLogger()
			logger.record("net.response", durationMs: 0, fields: ["status": .int(100)])
			logger.record("net.response", durationMs: 123_450, fields: ["status": .int(599)])
			logger.record("net.response", durationMs: 600_000, fields: ["status": .int(200)])
			logger.record("cert.preflight", fields: ["certificateCount": .int(0), "zagAppIDCount": .int(500), "registeredDeviceCount": .int(500)])
			logger.record("cert.verify", fields: ["possessionMatch": .bool(true), "certRef": .string("12345678"), "expiresInDays": .int(400)])
			logger.record("profile.fetch", fields: ["profileRef": .string("abcdef01"), "sizeBucket": .string("1–10 KB")])
			logger.record("cert.key", fields: ["extractableAttributeRequested": .bool(false), "privateKeyExportCalls": .int(0), "keyFileWritten": .bool(false)])
			let longest = String(repeating: "x", count: 15) + "." + String(repeating: "y", count: 15) + "." + String(repeating: "z", count: 22) + ".apple.com"
			logger.recordPolicyDecisions(try! JSONSerialization.data(withJSONObject: [[
				"host": longest, "path": "/x", "method": "GET", "scheme": "https", "allowed": false, "reason": "hostNotAllowed",
			]]))
			var events = logger.events
			events[0].t = 999_999
			check(longest.count == 64 && events.allSatisfy { $0.phase != "logger" }, "L3: every boundary value is accepted at record time")
			check(events.contains { field($0, "host") == longest }, "L3: the longest allowed blocked .apple.com host is kept verbatim")
			let report = ZagExperimentReport(header: header(logger), events: events, privateKeyExportCalls: 0)
			if case .success = report.export(provider: provider) { check(true, "L3: the boundary corpus passes export validation unchanged") }
			else { check(false, "L3: the boundary corpus passes export validation unchanged") }
		}

		// L4: each §7.1 format and each content rule blocks a crafted report,
		// naming the rule and never the value.
		do {
			let logger = Device.newLogger()
			logger.record("campaign.check", fields: ["check": .string("C1"), "result": .string("pass")])
			let good = logger.events[0]
			let crafted: [(String, (inout ZagLogEvent) -> Void)] = [
				("enum", { $0.fields = ["check": .string("SECRETVALUE"), "result": .string("pass")] }),
				("int", { $0.seq = 2_001 }),
				("bool", { $0.phase = "cert"; $0.event = "verify"; $0.fields = ["possessionMatch": .string("SECRETVALUE")] }),
				("sha8", { $0.phase = "build"; $0.event = "identity"; $0.fields = ["branchSHA8": .string("SECRETVALUE")] }),
				("ref8", { $0.phase = "cert"; $0.event = "verify"; $0.fields = ["certRef": .string("ABCDEF12")] }),
				("campaign", { $0.phase = "build"; $0.event = "identity"; $0.fields = ["campaignID": .string("G5-SECRETVALUE")] }),
				("host", { $0.phase = "net"; $0.event = "request"; $0.fields = ["host": .string("SECRETVALUE@evil.example")] }),
				("template", { $0.phase = "net"; $0.event = "request"; $0.fields = ["pathTemplate": .string("/SECRETVALUE")] }),
				("list", { $0.phase = "profile"; $0.event = "check"; $0.fields = ["entitlementNames": .list(["get-task-allow", "application-identifier"])] }),
				("unknown field", { $0.fields = ["SECRETVALUE": .string("C1")] }),
				("failure", { $0.failure = "SECRETVALUE" }),
				("durationMs", { $0.durationMs = 123_456 }),
			]
			for (label, change) in crafted {
				var event = good
				change(&event)
				let result = ZagExperimentReport.validate([event], provider: provider)
				if case .blocked(let rule) = result {
					check(rule.hasPrefix("schema:") && !rule.contains("SECRETVALUE"), "L4: §7.1 \(label) blocks the export (\(rule)) without the value")
				} else {
					check(false, "L4: §7.1 \(label) blocks the export")
				}
				let report = ZagExperimentReport(header: header(logger), events: [event], privateKeyExportCalls: 0)
				if case .failure(.blocked(let rule)) = report.export(provider: provider) { check(!rule.contains("SECRETVALUE"), "L4: \(label): export blocked, value not shown") }
				else { check(false, "L4: \(label): export blocked") }
			}
			for (rule, value) in [
				("R1", "a@b"), ("R2", "-----BEGIN CERTIFICATE"), ("R3", "x-apple-i-md"), ("R3", "X-Mme-Device-Id"),
				("R4", "deadbeefdeadbeef"), ("R5", "QUJDREVGR0hJSktMTU5PUFFSUzEy"), ("R6", "00008110-001A2B3C4D5E6F70"),
				("R7", "password"), ("R7", "dsid"), ("R7", "udid"), ("R7", "token"), ("R7", "adi"),
			] {
				check(ZagExperimentReport.contentRule(value) == rule, "L4: \(rule) blocks \(rule == "R6" ? "a UDID shape" : "its pattern")")
			}
			for keyName in ZagLogSchema.events.values.flatMap(\.keys) {
				check(ZagExperimentReport.contentRule(keyName) == nil, "L4: the declared key name \(keyName) passes R1–R7")
			}
			let blockedHost = ZagLogSchema.recordedHost("deadbeefdeadbeef01.apple.com", provider: provider)
			check(blockedHost == "appleUnusual", "L4/§4.4: a blocked .apple.com host with a 16+ hex label is classed, not kept")
			check(ZagLogSchema.recordedHost("evil.example", provider: provider) == "nonApple", "§4.4: a blocked non-Apple host is classed")
			check(ZagLogSchema.template("/grandslam/GsService2/lookup") == "/grandslam/GsService2/lookup" && ZagLogSchema.template("/services/QH65B2/ios/addDevice.action") == "/services/QH65B2/{op}.action"
				  && ZagLogSchema.template("/services/QH65B2/ios/revokeDevelopmentCert.action") == "unlisted" && ZagLogSchema.template("/secret/path") == "unlisted",
				  "§4.4: paths become templates; anything else is unlisted")
		}

		// L5: mapping totality (the switches have no default; checked statically
		// by the script), and every mapped value is a declared failure.
		do {
			let kinds: [ZagProvisioningFailure.Kind] = [.invalidRequest, .notAuthorized, .installSlotsFull(installed: []), .deviceLimitReached,
				.appIDCapacityExhausted(needed: 1, available: 0, nextSlotFreesAt: nil), .identifierUnavailable("x"), .certificateMustBeRevoked(candidates: []),
				.certificateRequestUnresolved, .keyStorage, .sessionRejected, .network, .rateLimited, .unexpectedResponse, .timedOut, .cancelled, .unavailable]
			let portal: [ZagPortalError] = [.sessionRejected, .network, .rateLimited, .malformedResponse, .identifierUnavailable("x"), .deviceLimitReached,
				.appIDLimitReached, .certificateLimitReached, .livePortalDisabled]
			let bridge: [ZagBridgeFailure] = [.disabled, .notConfigured, .network, .rejected, .twoFactorRejected, .refused, .rateLimited,
				.sessionExpired, .malformed, .cancelled, .busy, .invalidInput, .notSignedIn, .unsupported]
			let auth: [ZagAuthenticationServiceError] = [.invalidCredentials, .twoFactorRejected, .accountLocked, .rateLimited, .network, .malformedResponse, .liveAuthenticationDisabled]
			let anisette: [ZagAnisetteError] = [.providerUnavailable, .invalidResponse, .timedOut, .cancelled, .liveProvidersDisabled]
			let account: [ZagFreeAccountFailure.Kind] = [.invalidCredentials, .twoFactorRejected, .accountLocked, .rateLimited, .network, .anisetteUnavailable,
				.unexpectedResponse, .cancelled, .differentAccount, .unavailable, .addressNotRecognised]
			let refusals: [ZagLiveExperimentRefusal] = [.notArmed, .halted, .certificateBudgetSpent, .accountMismatch, .ledgerWriteFailed, .check("C1"), .abandonRefused]
			let mapped = kinds.map(ZagExperimentFailureMap.failure) + portal.map(ZagExperimentFailureMap.failure) + bridge.map(ZagExperimentFailureMap.failure)
				+ auth.map(ZagExperimentFailureMap.failure) + anisette.map(ZagExperimentFailureMap.failure) + account.map(ZagExperimentFailureMap.failure)
				+ refusals.map(ZagExperimentFailureMap.failure)
			check(mapped.allSatisfy(ZagLogSchema.failures.contains), "L5: every error kind maps into the closed failure enum (\(mapped.count) kinds)")
		}

		// L6: ref tokens.
		do {
			let a = Device.newLogger(), b = Device.newLogger()
			check(a.ref("team", "SIMTEAM001") == a.ref("team", "SIMTEAM001") && a.ref("team", "SIMTEAM001") != a.ref("device", "SIMTEAM001"),
				  "L6: the same value gives the same token within an installation (per kind)")
			check(a.ref("team", "SIMTEAM001") != b.ref("team", "SIMTEAM001"), "L6: different installations give different tokens")
			check(a.installID8 != b.installID8 && a.ref("team", "x").count == 8, "L6: tokens and installation IDs are 8 hex characters, per installation")
		}

		// L8: the read-back classes and verdicts.
		do {
			check(ZagExperimentReadback.classify(.verified(profileExpiresAt: Date(), certificateExpiresAt: Date()), readSucceeded: true) == .verified,
				  "L8: verified only when the device's profiles were read")
			check(ZagExperimentReadback.classify(.mismatch("profile team"), readSucceeded: true) == .mismatch, "L8: mismatch")
			check(ZagExperimentReadback.classify(.unverifiable("the app's profile is not among the device's installed profiles"), readSucceeded: true) == .notVerified,
				  "L8: read, but the profile is absent: notVerified")
			check(ZagExperimentReadback.classify(.unverifiable("installed; the device's profiles could not be read"), readSucceeded: false) == .unavailable,
				  "L8: nothing read: unavailable")
			struct ReadFailed: Error {}
			let expectation = ZagInstallExpectation(bundleIdentifier: "com.zagstore.livetest.hello", profileUUID: "U",
													profileExpiresAt: Date(), certificateExpiresAt: Date(), signerCommonName: nil, teamIdentifier: "T")
			check(ZagExperimentReadback.classify(read: .failure(ReadFailed()), expectation: expectation) == .unavailable, "L8: a failed read is unavailable")
			check(ZagExperimentReadback.classify(read: .success([]), expectation: expectation) == .notVerified, "L8: an empty list is notVerified")

			func run(preflight: String, install: String, launched: Bool = true, stop: Bool = false) -> ZagExperimentReport.Verdict {
				let logger = Device.newLogger()
				logger.record("readback.preflight", fields: ["result": .string(preflight)])
				logger.record("cert.budget", fields: ["submissionsBefore": .int(0), "ledgerState": .string("armed"), "decision": .string("allow")])
				logger.record("cert.submit", fields: ["result": .string("issued")])
				logger.record("install.launch", fields: ["confirmedByOwner": .bool(launched)])
				logger.record("install.verify", fields: ["result": .string(install), "attempt": .int(2)])
				if stop { logger.stop(.readbackPreflight, haltSet: true) }
				return ZagExperimentReport(header: header(logger), events: logger.events, privateKeyExportCalls: 0).verdict
			}
			check(run(preflight: "verified", install: "verified") == .pass, "L8: verified + verified + launched is PASS")
			check(run(preflight: "verified", install: "unavailable") == .incomplete, "L8: install unavailable on an otherwise passing run is INCOMPLETE, never PASS")
			check(run(preflight: "verified", install: "notVerified") != .pass && run(preflight: "verified", install: "mismatch") != .pass,
				  "L8: notVerified and mismatch are never PASS")
			check(run(preflight: "unavailable", install: "verified", stop: true) == .safeStop, "L8: P3 unavailable is a stop")
		}

		// L9: key handling: the counter (the mutant raises it) fails the verdict.
		do {
			let logger = Device.newLogger()
			logger.record("cert.budget", fields: ["submissionsBefore": .int(0), "ledgerState": .string("armed"), "decision": .string("allow")])
			check(ZagExperimentReport(header: header(logger), events: logger.events, privateKeyExportCalls: logger.privateKeyExportCalls).verdict != .safetyFailure,
				  "L9: no export call: no safety failure")
			logger.notePrivateKeyExport()
			check(ZagExperimentReport(header: header(logger), events: logger.events, privateKeyExportCalls: logger.privateKeyExportCalls).verdict == .safetyFailure,
				  "L9: an export call (the mutant) makes the run a SAFETY FAILURE")
			let keyFile = work.appendingPathComponent("g5-keyscan-\(UUID().uuidString)")
			try! FileManager.default.createDirectory(at: keyFile, withIntermediateDirectories: true)
			let before = ZagExperimentKeyFileScan.keyFiles(in: [keyFile])
			try! Data("-----BEGIN PRIVATE KEY-----\nMIIE\n".utf8).write(to: keyFile.appendingPathComponent("k.pem"))
			try! Data([0x30, 0x82, 0x04, 0xa4, 0x02, 0x01, 0x00, 0x02, 0x82, 0x01, 0x01, 0x00]).write(to: keyFile.appendingPathComponent("k.der"))
			try! Data("not a key".utf8).write(to: keyFile.appendingPathComponent("note.txt"))
			let after = ZagExperimentKeyFileScan.keyFiles(in: [keyFile])
			check(before.isEmpty && after.subtracting(before).count == 2, "L9: the key-file scan finds PEM and PKCS #1 files written during signing")
		}

		// L10 is part of T1/T2; L11 of the C-check tests. The report never
		// carries nonces, account keys or times other than the start hour.
		do {
			let device = Device(), campaign = device.armed()
			try? campaign.verifyAccountState(certificates: 0, appIDs: 0, devices: 0)
			try? await ZagCertificateBudget.consume(campaign: campaign, accountKey: "ACCOUNTKEYVALUE0123456789abcdef", recheckCertificates: { 0 })
			_ = device.launch(Device.constants(1, nonce: "ffffffffffffffffffffffffffffffff"))
			let report = ZagExperimentReport(header: header(device.logger), events: device.logger.events, privateKeyExportCalls: 0)
			if case .success(let files) = report.export(provider: provider) {
				let text = String(decoding: files.json, as: UTF8.self) + files.markdown
				let iso = ISO8601DateFormatter().string(from: Date()).prefix(13)
				check(!text.contains("0123456789abcdef0123456789abcdef") && !text.contains("ffffffffffffffffffffffffffffffff") && !text.contains("ACCOUNTKEYVALUE"),
					  "L11: the export holds no nonce and no account key")
				let json = String(decoding: files.json, as: UTF8.self)
				check(json.components(separatedBy: String(iso)).count - 1 == 1 && files.markdown.components(separatedBy: String(iso)).count - 1 == 1,
					  "L11: the only timestamp is the header's start hour (once in each file)")
				check(ZagExperimentReport.markdown(fromJSON: files.json) == files.markdown, "§7.2: the Markdown regenerates byte for byte from the JSON")
			} else {
				check(false, "L11: the campaign-check run exports")
			}
		}
	}
}

/// T16's directory never signs in.
struct StubAnisette: ZagAnisetteSource {
	func anisetteData() async throws -> ZagAnisetteData { throw ZagAnisetteError.liveProvidersDisabled }
}
