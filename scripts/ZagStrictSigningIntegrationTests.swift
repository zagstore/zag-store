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

final class OpenSSLIssuer: ZagSimulatedIssuer, @unchecked Sendable {
	/// Validity of the certificates issued from now on.
	var days = 365

	func certificate(for request: ZagCertificateRequest, serialNumber: String) throws -> Data {
		let csr = file(request.data, "request.der"), cert = work.appendingPathComponent("cert-\(serialNumber).der")
		let result = run(openssl, ["x509", "-req", "-inform", "DER", "-in", csr.path,
			"-CA", authority.appendingPathComponent("ca.pem").path, "-CAkey", authority.appendingPathComponent("ca.key").path,
			"-set_serial", "0x\(serialNumber)", "-days", "\(days)", "-outform", "DER", "-out", cert.path])
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
	/// Simulates an interruption between verifying a certificate and storing it.
	var failIdentitySaves = false
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		if failIdentitySaves && kind == .signingPrivateKey { throw ZagPortalError.network }
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil } }
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
	func identity(_ account: UUID, _ team: String) -> ZagSigningIdentity? {
		lock.withLock { items["\(account).signingPrivateKey.\(team)"] }.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}
	func pending(_ account: UUID, _ team: String) -> ZagPendingSigningKey? {
		lock.withLock { items["\(account).pendingSigningKey.\(team)"] }.flatMap { try? JSONDecoder().decode(ZagPendingSigningKey.self, from: $0) }
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
		await pendingKeys()
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
		check(identity.keyIsInKeychain && identity.keySlot != nil && (try? keys.key(account: account, team: team, slot: identity.keySlot)) != nil,
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
		try? keys.delete(account: account, team: team, slot: identity.keySlot)
		var permissive = adapter
		permissive.allowsKeyFiles = true
		do {
			_ = try permissive.sign(appAt: makeApp(extensions: []), with: result, identity: identity, authorization: authorization, now: Date())
			check(false, "missing key")
		} catch {
			check(error as? ZagFreeAccountSigningError == .keychainKeyMissing,
				  "Keychain keys: a missing key item fails clearly, with no fallback to a key file")
		}
		// Provisioning again does not reuse the identity whose key is gone: it
		// makes a new key and certificate.
		guard case .success(let renewed) = await provisioner.provision(request, authorization: authorization),
			  let replacement = secrets.identity(account, team) else { return check(false, "provisioning after a lost key") }
		check(renewed.changes.createdCertificate && replacement.serialNumber != identity.serialNumber
			  && replacement.keyIsInKeychain && (try? keys.key(account: account, team: team, slot: replacement.keySlot)) != nil,
			  "Keychain keys: an identity whose key is missing is not reused; a new key and certificate are made")

		// A certificate issued for another key (a wrong lookup, or a request in an
		// unexpected format answered for something else) is refused, and nothing
		// is stored.
		let wrongPortal = WrongKeyPortal(inner: ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer()))
		let wrongSecrets = MemorySecrets()
		let wrongProvisioner = ZagFreeAccountProvisioner(portal: wrongPortal, keys: ZagKeychainSigningKeyFactory(keys: keys), secrets: wrongSecrets, account: account)
		let wrongResult = await wrongProvisioner.provision(request, authorization: authorization)
		if case .failure(let failure) = wrongResult {
			check(failure.step == .certificate && wrongSecrets.identity(account, team) == nil,
				  "Keychain keys: a certificate that is not for this account's key is refused and nothing is stored")
		} else {
			check(false, "wrong-key certificate accepted")
		}

		// Removing the account removes its key items in the directory's namespace.
		let directoryKeys = ZagKeychainSigningKeys(namespace: ZagFreeAccountSimulation.accountsNamespace)
		_ = try? directoryKeys.create(account: account, team: team, commonName: "Removal test")
		defer { try? directoryKeys.deleteAll(account: account) }
		var ledger = ZagRefreshLedger()
		do {
			let plan = try await directory.removalPlan(for: account, ledger: ledger)
			try await directory.remove(plan.confirm(.forgetRecords), ledger: &ledger)
			check((try? directoryKeys.key(account: account, team: team)) == nil && secrets.identity(account, team) == nil,
				  "Keychain keys: removing the account removes its signing key items and identities")
		} catch {
			check(false, "account removal: \(error)")
		}
	}
}

extension Tests {
	/// L2: a new key stays pending until its certificate is issued, verified
	/// and stored; the working identity is untouched until then.
	static func pendingKeys() async {
		let secrets = MemorySecrets()
		let (directory, _) = SimulatedAccounts.directory(now: { Date() }, secrets: secrets)
		guard let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory) else { return check(false, "sign-in") }
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.test.\(UUID().uuidString)")
		defer { try? keys.deleteAll(account: account) }
		let factory = ZagKeychainSigningKeyFactory(keys: keys)
		let issuer = OpenSSLIssuer()
		issuer.days = 3
		let simulated = ZagSimulatedDeveloperPortal(team: team, issuer: issuer)
		// This test issues more certificates than Apple's limit of 2 allows.
		await simulated.setCertificateLimit(20)
		let portal = ScriptedCertificatePortal(inner: simulated)
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: factory, secrets: secrets, account: account)
		let authorization = try! await directory.authorize(ZagSigningScope(accountID: account, teamID: team))
		let request = ZagProvisioningRequest(
			accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
			app: component("com.example.notes", "Notes"), extensions: [], installedFreeAccountApps: []
		)
		func provision() async -> ZagProvisioningResult? {
			if case .success(let result) = await provisioner.provision(request, authorization: authorization) { return result }
			return nil
		}
		func works(_ identity: ZagSigningIdentity) -> Bool {
			if case .matches = factory.check(certificate: identity.certificate, privateKey: identity.privateKey, account: account, team: team, keySlot: identity.keySlot) { return true }
			return false
		}
		// A still-valid identity with under 7 days left: the next provisioning renews it.
		guard await provision() != nil, let first = secrets.identity(account, team) else { return check(false, "first identity") }
		issuer.days = 365

		// The request fails before Apple answers: the working identity is untouched.
		portal.failNext(2)
		let failed = await provision()
		check(failed == nil && secrets.identity(account, team) == first && works(first)
			  && secrets.pending(account, team).map { factory.hasKey(account: account, team: team, keySlot: $0.keySlot) } == true
			  && secrets.pending(account, team)?.attempts == 1,
			  "L2: an interrupted certificate request leaves the working identity and its key in use; the new key stays pending")
		_ = await provision()
		check(portal.submitted.count == 3 && portal.submitted[1] == portal.submitted[2] && secrets.pending(account, team)?.attempts == 2
			  && secrets.identity(account, team) == first,
			  "L2: a retry resubmits the same request with the same pending key")
		issuer.days = 3
		guard let renewed = await provision(), let second = secrets.identity(account, team) else { return check(false, "renewal") }
		check(renewed.changes.createdCertificate && portal.submitted[3] == portal.submitted[1] && second.serialNumber != first.serialNumber
			  && works(second) && !works(first) && (try? keys.slots(account: account, team: team)) == [second.keySlot] && secrets.pending(account, team) == nil,
			  "L2: on success the identity switches to the new key in one write; the old key is then removed")

		// Retries are bounded: after three attempts a new key and request are made.
		portal.failNext(4)
		for _ in 0..<4 { _ = await provision() }
		let attempts = Array(portal.submitted.suffix(4))
		check(attempts[0] == attempts[1] && attempts[1] == attempts[2] && attempts[3] != attempts[2]
			  && secrets.pending(account, team)?.attempts == 1 && secrets.identity(account, team) == second && works(second),
			  "L2: the same request is retried at most \(ZagPendingSigningKey.maximumAttempts) times, then replaced; the identity stays in use")
		check(Set((try? keys.slots(account: account, team: team)) ?? []) == Set([second.keySlot, secrets.pending(account, team)?.keySlot]),
			  "L2: the abandoned request's key is removed; only the key in use and the current request's key remain")

		// Interrupted after the certificate was verified: finished, not re-requested.
		issuer.days = 365
		secrets.failIdentitySaves = true
		let interrupted = await provision()
		let journal = secrets.pending(account, team)
		check(interrupted == nil && journal?.certificate != nil && secrets.identity(account, team) == second,
			  "L2: a certificate verified but not yet stored is kept in the journal; nothing is published")
		secrets.failIdentitySaves = false
		let before = portal.submitted.count
		guard let finished = await provision(), let third = secrets.identity(account, team) else { return check(false, "finish") }
		check(finished.changes.createdCertificate && portal.submitted.count == before && third.serialNumber == journal?.certificate?.serialNumber
			  && works(third) && secrets.pending(account, team) == nil && (try? keys.slots(account: account, team: team)) == [third.keySlot],
			  "L2: the next attempt publishes the journalled certificate without requesting another")

		// A lost response: Apple issued a certificate the app never received. (The
		// identity's key is removed first, so a new certificate is needed.)
		try? keys.delete(account: account, team: team, slot: third.keySlot)
		portal.loseNext(1)
		let issuedBeforeLoss = portal.issuedCount
		let lost = await provision()
		let afterLoss = portal.submitted.count
		check(lost == nil && secrets.pending(account, team)?.submissionUnconfirmed == true,
			  "recovery: a request whose response is lost is marked unconfirmed")
		guard let recovered = await provision(), let fourth = secrets.identity(account, team) else { return check(false, "after a lost response") }
		check(recovered.changes.createdCertificate && portal.submitted.count == afterLoss && works(fourth) && fourth.serialNumber != third.serialNumber
			  && secrets.pending(account, team) == nil && portal.issuedCount == issuedBeforeLoss + 1,
			  "recovery: the certificate issued for the lost response is found in the listing by its key and used; none is requested again")

		// The same, but the listing has no certificate data: the outcome cannot be
		// established, so nothing more is requested and nothing is revoked.
		try? keys.delete(account: account, team: team, slot: fourth.keySlot)
		portal.hidesCertificateData = true
		portal.loseNext(1)
		_ = await provision()
		let unresolvedFrom = portal.submitted.count, issuedBefore = portal.issuedCount
		for _ in 0..<3 {
			let result = await provisioner.provision(request, authorization: authorization)
			guard case .failure(let failure) = result, failure.kind == .certificateRequestUnresolved else { return check(false, "unresolved: \(result)") }
		}
		check(portal.submitted.count == unresolvedFrom && portal.issuedCount == issuedBefore && secrets.pending(account, team)?.submissionUnconfirmed == true,
			  "recovery: with no certificate data in the listing, provisioning stops (certificateRequestUnresolved) and requests nothing more, however often it is retried")
		// Only the user's decision starts a new request; nothing is revoked (the
		// portal interface has no revoke operation at all).
		await provisioner.abandonUnresolvedCertificateRequest(accountID: account, team: team)
		guard await provision() != nil, let fifth = secrets.identity(account, team) else { return check(false, "after abandoning") }
		check(portal.submitted.count == unresolvedFrom + 1 && works(fifth) && portal.submitted.last != portal.submitted[unresolvedFrom - 1],
			  "recovery: after the user abandons the unresolved request, one new request is made with a new key")

		// A refusal from Apple (rate limit) means nothing was issued: the next
		// attempt does not need the listing to proceed.
		try? keys.delete(account: account, team: team, slot: fifth.keySlot)
		portal.refuseNext(1)
		_ = await provision()
		check(secrets.pending(account, team)?.submissionUnconfirmed == false, "recovery: a request Apple refused is marked as not issued")
		let refusedAt = portal.submitted.count
		guard await provision() != nil, let sixth = secrets.identity(account, team) else { return check(false, "after a refusal") }
		check(portal.submitted.count == refusedAt + 1 && portal.submitted.last == portal.submitted[refusedAt - 1] && works(sixth),
			  "recovery: after a refusal the same request is sent again, even when the listing has no certificate data")
		portal.hidesCertificateData = false

		// The app stops while a request is out (the journal is written ahead).
		try? keys.delete(account: account, team: team, slot: sixth.keySlot)
		portal.failNext(1)
		_ = await provision()
		check(secrets.pending(account, team)?.submissionUnconfirmed == true, "recovery: a request is marked unconfirmed before it is sent")
		let crashAt = portal.submitted.count
		guard await provision() != nil, let latest = secrets.identity(account, team) else { return check(false, "after an unsent request") }
		check(portal.submitted.count == crashAt + 1 && portal.submitted.last == portal.submitted[crashAt - 1] && works(latest),
			  "recovery: when the full listing shows nothing was issued, the same request is sent once more")

		// Pending keys belong to one account and team.
		let other = UUID()
		defer { try? keys.deleteAll(account: other) }
		_ = try? keys.create(account: other, team: team, slot: "PENDING1", commonName: "Other")
		check((try? keys.slots(account: account, team: team)) == [latest.keySlot] && (try? keys.slots(account: other, team: team)) == ["PENDING1"]
			  && works(latest),
			  "L2: another account's key for the same team is separate and never touches this account's keys")
		try? keys.deleteAll(account: other)
		check((try? keys.slots(account: other, team: team))?.isEmpty == true && works(latest), "L2: removing an account removes all its keys, pending ones included")
	}
}

/// Records each certificate request; fails the next ones before Apple would
/// see them (`failNext`), or after the certificate is issued (`loseNext`, the
/// response is lost).
final class ScriptedCertificatePortal: ZagDeveloperPortalService, @unchecked Sendable {
	let inner: ZagDeveloperPortalService
	private let lock = NSLock()
	private var failures = 0, losses = 0, refusals = 0
	private(set) var submitted: [Data] = []
	/// Certificates Apple issued (including those whose response was lost).
	private(set) var issuedCount = 0
	/// The listing leaves out every certificate's data (as a portal might).
	var hidesCertificateData = false
	init(inner: ZagDeveloperPortalService) { self.inner = inner }
	func failNext(_ count: Int) { lock.withLock { failures = count } }
	func loseNext(_ count: Int) { lock.withLock { losses = count } }
	func refuseNext(_ count: Int) { lock.withLock { refusals = count } }
	func devices(team: String) async throws -> [ZagRegisteredDevice] { try await inner.devices(team: team) }
	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice { try await inner.registerDevice(udid: udid, name: name, team: team) }
	func appIDs(team: String) async throws -> [ZagRegisteredAppID] { try await inner.appIDs(team: team) }
	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID { try await inner.registerAppID(bundleIdentifier: bundleIdentifier, name: name, team: team) }
	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] { try await inner.appGroups(team: team) }
	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup { try await inner.registerAppGroup(identifier, team: team) }
	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws { try await inner.assignAppGroups(groups, to: appID, team: team) }
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		let listed = try await inner.certificates(team: team)
		guard hidesCertificateData else { return listed }
		return listed.map { var certificate = $0; certificate.data = nil; return certificate }
	}
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		let (fail, lose, refuse): (Bool, Bool, Bool) = lock.withLock {
			submitted.append(request.data)
			if refusals > 0 { refusals -= 1; return (false, false, true) }
			if failures > 0 { failures -= 1; return (true, false, false) }
			if losses > 0 { losses -= 1; return (false, true, false) }
			return (false, false, false)
		}
		if refuse { throw ZagPortalError.rateLimited }
		if fail { throw ZagPortalError.network }
		let issued = try await inner.submitCertificateRequest(request, team: team)
		lock.withLock { issuedCount += 1 }
		if lose { throw ZagPortalError.network }
		return issued
	}
	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile { try await inner.profile(for: appID, team: team) }
}

/// Answers every certificate request with a certificate for a different key.
struct WrongKeyPortal: ZagDeveloperPortalService {
	let inner: ZagDeveloperPortalService
	func devices(team: String) async throws -> [ZagRegisteredDevice] { try await inner.devices(team: team) }
	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice { try await inner.registerDevice(udid: udid, name: name, team: team) }
	func appIDs(team: String) async throws -> [ZagRegisteredAppID] { try await inner.appIDs(team: team) }
	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID { try await inner.registerAppID(bundleIdentifier: bundleIdentifier, name: name, team: team) }
	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] { try await inner.appGroups(team: team) }
	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup { try await inner.registerAppGroup(identifier, team: team) }
	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws { try await inner.assignAppGroups(groups, to: appID, team: team) }
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] { try await inner.certificates(team: team) }
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		let other = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
		let substitute = try ZagCertificateSigningRequest.make(commonName: "Someone Else", privateKey: other)
		return try await inner.submitCertificateRequest(ZagCertificateRequest(data: substitute), team: team)
	}
	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile { try await inner.profile(for: appID, team: team) }
}
