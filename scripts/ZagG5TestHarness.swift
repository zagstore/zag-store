import Foundation
import Security

// Shared by the G5 experiment tests and the existing-account tests: the
// scripted bridge transport, the simulated device stores and the rigs (run by
// scripts/test-zag-g5-experiment.sh and scripts/test-zag-existing-account.sh,
// compiled with ZAG_G5_TESTS, never in an app build).

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
	let diagnostics: ZagFreeAccountDiagnostics

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
		let diagnostics = ZagFreeAccountDiagnostics()
		let provisioner = ZagFreeAccountProvisioner(portal: adapter, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: secrets, diagnostics: diagnostics, account: account)
		return Rig(secrets: secrets, directory: directory, account: account, team: team, portal: portal, counter: counter,
				   adapter: adapter, provisioner: provisioner, keys: keys, diagnostics: diagnostics)
	}

	/// The same account after a relaunch: new adapter and provisioner over
	/// the same Keychain items, with `campaign` (a new campaign object).
	func relaunched(_ campaign: ZagLiveExperimentCampaign) -> Rig {
		let adapter = ZagIsideloadDeveloperPortal(account: account, secrets: secrets, campaign: campaign, transport: scriptedTransport(portal, counter: counter))
		let diagnostics = ZagFreeAccountDiagnostics()
		let provisioner = ZagFreeAccountProvisioner(portal: adapter, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: secrets, diagnostics: diagnostics, account: account)
		return Rig(secrets: secrets, directory: directory, account: account, team: team, portal: portal, counter: counter,
				   adapter: adapter, provisioner: provisioner, keys: keys, diagnostics: diagnostics)
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

/// Each concurrent result, with its step and the provisioner's diagnostics.
func describe(_ results: [Result<ZagProvisioningResult, ZagProvisioningFailure>], _ rigs: [Rig]) -> String {
	zip(results, rigs).map { result, rig in
		switch result {
		case .success: "success"
		case .failure(let failure): "\(failure.kind)@\(failure.step) \(rig.diagnostics.entries.map(\.message))"
		}
	}.joined(separator: " | ")
}

func budgetDecisions(_ logger: ZagExperimentLogger) -> [String] { events(logger, "cert.budget").compactMap { field($0, "decision") } }

func checkRefused(_ logger: ZagExperimentLogger, _ check: String) -> Bool {
	events(logger, "campaign.check").contains { field($0, "check") == check && field($0, "result") == "refuse" }
}

func halted(_ device: Device, _ id: String = "G5-C1") -> Bool { device.registryValue?.campaigns[id]?.state == .halted }

/// T16's directory never signs in.
struct StubAnisette: ZagAnisetteSource {
	func anisetteData() async throws -> ZagAnisetteData { throw ZagAnisetteError.liveProvidersDisabled }
}
