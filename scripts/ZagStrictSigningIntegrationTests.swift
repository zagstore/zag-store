import Foundation
import Security

// Zag Store's free-account signing with the Zsign branch, in isolation (the
// submodule is not moved): a simulated account and portal provision an app
// with an extension and an app group, a local test authority (trusted by
// nothing, with an ordinary name) issues the certificate and profiles, and
// the adapter signs each component through a Security framework key, with
// no key data given to Zsign. Run by scripts/test-zag-zsign-branch.sh.

let environment = ProcessInfo.processInfo.environment
let openssl = environment["ZAG_TEST_OPENSSL"]!
let authority = URL(fileURLWithPath: environment["ZAG_TEST_AUTHORITY"]!)
let executable = URL(fileURLWithPath: environment["ZAG_TEST_EXECUTABLE"]!)
let work = URL(fileURLWithPath: environment["ZAG_TEST_WORK"]!)
let team = "SIMTEAM001"
let udid = "00000000-SIMULATED000000"

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

struct OpenSSLIssuer: ZagSimulatedIssuer {
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
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret } }
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil } }
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
	func identity(_ account: UUID, _ team: String) -> ZagSigningIdentity? {
		lock.withLock { items["\(account).signingPrivateKey.\(team)"] }.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}
}

func makeApp(extensions: [String] = ["Widget"]) -> URL {
	let app = work.appendingPathComponent("apps/\(UUID().uuidString)/Notes.app")
	func bundle(_ url: URL, _ identifier: String, _ name: String, package: String) {
		try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		let info: [String: Any] = [
			"CFBundleIdentifier": identifier, "CFBundleExecutable": name, "CFBundleName": name,
			"CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": package,
			"MinimumOSVersion": "16.4", "CFBundleSupportedPlatforms": ["iPhoneOS"]
		]
		try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
		try! FileManager.default.copyItem(at: executable, to: url.appendingPathComponent(name))
	}
	bundle(app, "com.example.notes", "Notes", package: "APPL")
	for name in extensions {
		bundle(app.appendingPathComponent("PlugIns/\(name).appex"), "com.example.notes.\(name.lowercased())", name, package: "XPC!")
	}
	return app
}

func signedEntitlements(_ binary: URL) -> [String: Any] {
	guard let blob = ZagCodeSignatureInspection.signatureBlobs(try! Data(contentsOf: binary))?.first?[5] else { return [:] }
	return (try? PropertyListSerialization.propertyList(from: blob.dropFirst(8), format: nil)) as? [String: Any] ?? [:]
}

func component(_ id: String, _ name: String, groups: [String] = []) -> ZagProvisioningRequest.Component {
	var entitlements: [String: Any] = ["keychain-access-groups": ["ORIGTEAM01.\(id)"]]
	if !groups.isEmpty { entitlements["com.apple.security.application-groups"] = groups }
	return .init(originalBundleIdentifier: id, name: name, entitlements: try! ZagEntitlementSet(entitlements))
}

@main struct Tests {
	static var passed = 0
	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		let secrets = MemorySecrets()
		let (directory, _) = SimulatedAccounts.directory(now: { Date() }, secrets: secrets)
		let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory)!
		let scope = ZagSigningScope(accountID: account, teamID: team)
		let portal = ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer())
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: ZagSecuritySigningKeyFactory(), secrets: secrets, account: account)
		let authorization = try! await directory.authorize(scope)
		let group = "group.com.example.notes"
		let request = ZagProvisioningRequest(
			accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
			app: component("com.example.notes", "Notes", groups: [group]),
			extensions: [component("com.example.notes.widget", "Widget", groups: [group])],
			installedFreeAccountApps: []
		)
		guard case .success(let result) = await provisioner.provision(request, authorization: authorization),
			  let identity = secrets.identity(account, team) else { return check(false, "provisioning") }
		check(result.extensions.count == 1, "the simulated portal provisions the app and its extension, each with its own profile")

		// The key as a Security framework key, as the Keychain would hold it;
		// Zsign only ever receives DigestInfo blocks to sign.
		let key = SecKeyCreateWithData(identity.privateKey as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)!
		var calls = 0
		let signer: (Data) -> Data? = { digestInfo in calls += 1; return ZagKeychainSigningKeys.signer(key)(digestInfo) }
		let intermediate = try! Data(contentsOf: authority.appendingPathComponent("ca.der"))
		let adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), workRoot: work, gate: .simulationOnly)

		let app = makeApp()
		do {
			let record = try adapter.signComponents(appAt: app, with: result, identity: identity, signer: signer, authorization: authorization,
													now: Date(), extraIntermediates: [intermediate])
			check(record.owner?.scope == scope && record.owner?.certificateSerial == identity.serialNumber, "the signed app is recorded for its own account and team")
		} catch {
			return check(false, "signing: \(error)")
		}
		check(calls >= 2, "every signature came from the Security framework key (no key data given to Zsign)")
		let widget = app.appendingPathComponent("PlugIns/Widget.appex")
		let main = run("/usr/bin/codesign", ["-dvvv", app.path]).output, ext = run("/usr/bin/codesign", ["-dvvv", widget.path]).output
		check(main.contains("Identifier=\(result.app.bundleIdentifier)") && ext.contains("Identifier=\(result.extensions[0].bundleIdentifier)")
			  && main.contains("TeamIdentifier=\(team)") && ext.contains("TeamIdentifier=\(team)"),
			  "codesign reads the team's bundle IDs for the app and the extension")
		let appEntitlements = signedEntitlements(app.appendingPathComponent("Notes")), extEntitlements = signedEntitlements(widget.appendingPathComponent("Widget"))
		check(appEntitlements["application-identifier"] as? String == "\(team).\(result.app.bundleIdentifier)"
			  && extEntitlements["application-identifier"] as? String == "\(team).\(result.extensions[0].bundleIdentifier)",
			  "the app and the extension each carry their own App ID")
		check((extEntitlements["com.apple.security.application-groups"] as? [String])?.isEmpty == false
			  && extEntitlements["com.apple.security.application-groups"] as? [String] == appEntitlements["com.apple.security.application-groups"] as? [String],
			  "the app and the extension share the team's app group")
		check((try? Data(contentsOf: widget.appendingPathComponent("embedded.mobileprovision"))) == result.extensions[0].profile.data,
			  "the extension embeds its own profile")
		var components: [String: (provision: Data, entitlements: Data)] = [:]
		components[""] = (result.app.profile.data, try! PropertyListSerialization.data(fromPropertyList: result.app.entitlements.dictionary, format: .xml, options: 0))
		components["PlugIns/Widget.appex"] = (result.extensions[0].profile.data,
											  try! PropertyListSerialization.data(fromPropertyList: result.extensions[0].entitlements.dictionary, format: .xml, options: 0))
		check(Zsign.verifyComponents(appPath: app.path, certificate: identity.certificate, components: components) == nil, "the result verifies independently")

		// Refusals.
		func refused(_ app: URL, _ label: String, gate: ZagFreeAccountSigningGate = .simulationOnly, intermediates: [Data] = [intermediate],
					 signer: @escaping (Data) -> Data? = signer, matches: (Error) -> Bool) {
			let adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), workRoot: work, gate: gate)
			do {
				_ = try adapter.signComponents(appAt: app, with: result, identity: identity, signer: signer, authorization: authorization,
											   now: Date(), extraIntermediates: intermediates)
				check(false, label)
			} catch {
				check(matches(error), label)
			}
		}
		refused(makeApp(), "the production gate is closed", gate: .production) { $0 as? ZagFreeAccountSigningError == .disabled }
		refused(makeApp(extensions: []), "an app missing its provisioned extension is refused") {
			$0 as? ZagFreeAccountSigningError == .extensionsNeedPerBundleSigning(["com.example.notes.widget"])
		}
		refused(makeApp(extensions: ["Widget", "Share"]), "an extension that was not provisioned is refused") {
			$0 as? ZagFreeAccountSigningError == .extensionsNeedPerBundleSigning(["com.example.notes.share"])
		}
		refused(makeApp(), "a certificate whose issuer is not trusted is refused", intermediates: []) {
			if case .signer(let message)? = $0 as? ZagFreeAccountSigningError { return message.contains("not issued by a supported Apple") }
			return false
		}
		refused(makeApp(), "a key that refuses to sign fails the signing", signer: { _ in nil }) {
			if case .signer? = $0 as? ZagFreeAccountSigningError { return true }
			return false
		}
		let other = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
		refused(makeApp(), "signatures from another account's key are caught before success", signer: ZagKeychainSigningKeys.signer(other)) {
			if case .signer(let message)? = $0 as? ZagFreeAccountSigningError { return message.contains("did not verify") }
			return false
		}
		await keychainHeldKeys(intermediate: intermediate)
		print("SUCCESS: \(passed) strict signing integration checks passed")
	}

	/// The supervised experiment's path: the provisioner makes the key as a
	/// Keychain key item, stores an identity without key bytes, and the
	/// adapter signs through the key reference only.
	static func keychainHeldKeys(intermediate: Data) async {
		let secrets = MemorySecrets()
		let (directory, _) = SimulatedAccounts.directory(now: { Date() }, secrets: secrets)
		guard let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory) else { return check(false, "sign-in") }
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.test.\(UUID().uuidString)")
		defer { try? keys.deleteAll(account: account) }
		let portal = ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer())
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: secrets, account: account)
		let authorization = try! await directory.authorize(ZagSigningScope(accountID: account, teamID: team))
		let request = ZagProvisioningRequest(
			accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
			app: component("com.example.notes", "Notes"), extensions: [], installedFreeAccountApps: []
		)
		guard case .success(let result) = await provisioner.provision(request, authorization: authorization),
			  let identity = secrets.identity(account, team) else { return check(false, "provisioning with a Keychain key") }
		check(identity.keyIsInKeychain && (try? keys.key(account: account, team: team)) != nil,
			  "Keychain keys: the stored identity carries no key bytes; the key is a Keychain key item for this account and team")

		var adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), workRoot: work, gate: .simulationOnly)
		adapter.keychainKeys = keys
		adapter.testIntermediates = [intermediate]
		let before = Set((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [])
		let app = makeApp(extensions: [])
		do {
			let record = try adapter.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: Date())
			check(record.owner?.scope.accountID == account && record.owner?.certificateSerial == identity.serialNumber,
				  "Keychain keys: the app is signed and recorded for its own account and team")
		} catch {
			return check(false, "Keychain signing: \(error)")
		}
		let after = Set((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [])
		check(after.subtracting(before).allSatisfy { !$0.hasPrefix("zag-free-account-signing-") },
			  "Keychain keys: no key staging folder or key file is created")
		let components: [String: (provision: Data, entitlements: Data)] = [
			"": (result.app.profile.data, try! PropertyListSerialization.data(fromPropertyList: result.app.entitlements.dictionary, format: .xml, options: 0))
		]
		check(Zsign.verifyComponents(appPath: app.path, certificate: identity.certificate, components: components) == nil,
			  "Keychain keys: the signed app verifies independently against the issued certificate")

		// Another account's identity and key do not sign this account's app.
		guard let other = await SimulatedAccounts.signIn(SimulatedAccounts.second, to: directory) else { return check(false, "second account") }
		defer { try? keys.deleteAll(account: other) }
		guard let otherAuthorization = try? await directory.authorize(ZagSigningScope(accountID: other, teamID: "SIMTEAM002")) else {
			return check(false, "second account authorisation")
		}
		do {
			_ = try adapter.sign(appAt: makeApp(extensions: []), with: result, identity: identity, authorization: otherAuthorization, now: Date())
			check(false, "cross-account signing")
		} catch {
			check(error as? ZagFreeAccountSigningError == .notAuthorized && (try? keys.key(account: other, team: team)) == nil,
				  "Keychain keys: another account's authorisation cannot sign this account's app, and it has no key item for this team")
		}
		// A missing key item is a clear failure, never a fallback to key files.
		try? keys.delete(account: account, team: team)
		var permissive = adapter
		permissive.allowsKeyFiles = true
		do {
			_ = try permissive.sign(appAt: makeApp(extensions: []), with: result, identity: identity, authorization: authorization, now: Date())
			check(false, "missing key")
		} catch {
			check(error as? ZagFreeAccountSigningError == .keychainKeyMissing,
				  "Keychain keys: a missing key item fails clearly, with no fallback to a key file")
		}
	}
}
