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

		// End-to-end: the profiles the real signed app embeds are exactly what a
		// device reports back through RPPairing misagent, so feed those real
		// artifacts straight into the installed-profile check. This crosses the
		// sign -> install -> verify boundary with the issued certificate and the
		// CMS-signed profiles produced above; the only step that cannot run
		// offline is the device transport itself (a real iPhone).
		guard let appProfile = try? Certificate.decode(profileData: result.app.profile.data),
			  let widgetProfile = try? Certificate.decode(profileData: result.extensions[0].profile.data) else {
			return check(false, "end-to-end: the embedded app and extension profiles decode")
		}
		let installed = [result.app.profile.data, result.extensions[0].profile.data]
		func expectation(profileExpiresAt: Date, bundleIdentifier: String = result.app.bundleIdentifier) -> ZagInstallExpectation {
			ZagInstallExpectation(
				bundleIdentifier: bundleIdentifier, profileUUID: appProfile.UUID,
				profileExpiresAt: profileExpiresAt, certificateExpiresAt: appProfile.ExpirationDate,
				signerCommonName: nil, teamIdentifier: team, extensionProfileUUIDs: [widgetProfile.UUID])
		}
		if case .verified = ZagInstalledProfileCheck.verify(expectation(profileExpiresAt: appProfile.ExpirationDate), installedProfiles: installed) {
			check(true, "end-to-end: the profiles the device reports verify against the certificate and profiles that were signed and embedded")
		} else {
			check(false, "end-to-end: installed-profile verification of the real signed artifact")
		}
		if case .unverifiable = ZagInstalledProfileCheck.verify(expectation(profileExpiresAt: appProfile.ExpirationDate), installedProfiles: []) {
			check(true, "end-to-end: an app whose profile the device does not report is not a successful install")
		} else {
			check(false, "end-to-end: a missing installed profile must be unverifiable")
		}
		if case .mismatch = ZagInstalledProfileCheck.verify(expectation(profileExpiresAt: appProfile.ExpirationDate.addingTimeInterval(86_400)), installedProfiles: installed) {
			check(true, "end-to-end: a profile whose expiry differs from what was embedded is a mismatch, not a success")
		} else {
			check(false, "end-to-end: an expiry that differs from the embedded profile must be a mismatch")
		}

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
		await overlappingCertificateRequests()
		await cancelledWhileQueued()
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

		// Apple explicitly refuses the request: the working identity is untouched.
		portal.refuseNext(2)
		let failed = await provision()
		check(failed == nil && secrets.identity(account, team) == first && works(first)
			  && secrets.pending(account, team).map { factory.hasKey(account: account, team: team, keySlot: $0.keySlot) } == true
			  && secrets.pending(account, team)?.attempts == 1,
			  "L2: a refused certificate request leaves the working identity and its key in use; the new key stays pending")
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
		portal.refuseNext(4)
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

		// Check Again, the user's action: it reads the listing only. With
		// certificate data listed, a lost response's certificate is recovered.
		portal.hidesCertificateData = false
		try? keys.delete(account: account, team: team, slot: fifth.keySlot)
		portal.loseNext(1)
		_ = await provision()
		let beforeCheck = portal.submitted.count
		let checked = await provisioner.checkUnresolvedCertificateRequest(accountID: account, team: team, authorization: authorization)
		guard case .recovered(let recoveredSerial, _) = checked, let byCheck = secrets.identity(account, team) else { return check(false, "check again: \(checked)") }
		check(portal.submitted.count == beforeCheck && byCheck.serialNumber == recoveredSerial && works(byCheck) && secrets.pending(account, team) == nil,
			  "recovery: Check Again finds the certificate of a lost response by its key and uses it, sending nothing")
		let nothing = await provisioner.checkUnresolvedCertificateRequest(accountID: account, team: team, authorization: authorization)
		check(nothing == .nothingPending && portal.submitted.count == beforeCheck, "recovery: Check Again with nothing unresolved changes nothing")
		// Even a complete listing cannot resolve a submission with no match.
		try? keys.delete(account: account, team: team, slot: byCheck.keySlot)
		portal.failNext(1)
		_ = await provision()
		let beforeNotIssued = portal.submitted.count
		let settled = await provisioner.checkUnresolvedCertificateRequest(accountID: account, team: team, authorization: authorization)
		check(settled == .unresolved && portal.submitted.count == beforeNotIssued && secrets.pending(account, team)?.submissionUnconfirmed == true,
			  "recovery: Check Again preserves the pending key when even the full listing cannot establish issuance")
		_ = await provisioner.abandonUnresolvedCertificateRequest(accountID: account, team: team)
		guard await provision() != nil, let resent = secrets.identity(account, team) else { return check(false, "after not issued") }
		check(portal.submitted.count == beforeNotIssued + 1 && portal.submitted.last != portal.submitted[beforeNotIssued - 1] && works(resent),
			  "recovery: after explicit abandonment, signing sends one new request")
		portal.hidesCertificateData = true

		// A refusal from Apple (rate limit) means nothing was issued: the next
		// attempt does not need the listing to proceed.
		try? keys.delete(account: account, team: team, slot: resent.keySlot)
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
		let blocked = await provision()
		check(blocked == nil && portal.submitted.count == crashAt, "recovery: an interrupted request is not automatically repeated")
		_ = await provisioner.abandonUnresolvedCertificateRequest(accountID: account, team: team)
		guard await provision() != nil, let latest = secrets.identity(account, team) else { return check(false, "after an abandoned request") }
		check(portal.submitted.count == crashAt + 1 && portal.submitted.last != portal.submitted[crashAt - 1] && works(latest),
			  "recovery: explicitly abandoning the interrupted request lets the user start fresh")

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
/// response is lost or unreadable). `holdNext` pauses the next request before
/// or after Apple issues its certificate, until `release`.
final class ScriptedCertificatePortal: ZagDeveloperPortalService, @unchecked Sendable {
	enum HoldPoint { case beforeIssue, afterIssue }
	let inner: ZagDeveloperPortalService
	private let lock = NSLock()
	private var failures = 0, losses = 0, refusals = 0
	private var lossError: Error = ZagPortalError.network
	private var holdPoint: HoldPoint?
	private var held: CheckedContinuation<Void, Never>?
	private(set) var submitted: [Data] = []
	/// Certificates Apple issued (including those whose response was lost).
	private(set) var issuedCount = 0
	/// The listing leaves out every certificate's data (as a portal might).
	var hidesCertificateData = false
	init(inner: ZagDeveloperPortalService) { self.inner = inner }
	func failNext(_ count: Int) { lock.withLock { failures = count } }
	func loseNext(_ count: Int, with error: Error = ZagPortalError.network) { lock.withLock { losses = count; lossError = error } }
	func holdNext(_ point: HoldPoint) { lock.withLock { holdPoint = point } }
	var isHolding: Bool { lock.withLock { held != nil } }
	func release() {
		let waiting: CheckedContinuation<Void, Never>? = lock.withLock { defer { held = nil }; return held }
		waiting?.resume()
	}
	private func hold() async { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
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
		let (fail, lose, refuse, point): (Bool, Bool, Bool, HoldPoint?) = lock.withLock {
			submitted.append(request.data)
			defer { holdPoint = nil }
			let point = holdPoint
			if refusals > 0 { refusals -= 1; return (false, false, true, point) }
			if failures > 0 { failures -= 1; return (true, false, false, point) }
			if losses > 0 { losses -= 1; return (false, true, false, point) }
			return (false, false, false, point)
		}
		if point == .beforeIssue { await hold() }
		if refuse { throw ZagPortalError.rateLimited }
		if fail { throw ZagPortalError.network }
		let issued = try await inner.submitCertificateRequest(request, team: team)
		lock.withLock { issuedCount += 1 }
		if point == .afterIssue { await hold() }
		if lose { throw lock.withLock { lossError } }
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

extension Tests {
	/// G4: overlapping certificate operations for one account and team, and
	/// responses that do not say whether Apple issued a certificate. Apple must
	/// never be asked twice for the same request while its outcome is open,
	/// whatever runs at the same time.
	static func overlappingCertificateRequests() async {
		let secrets = MemorySecrets()
		let (directory, _) = SimulatedAccounts.directory(now: { Date() }, secrets: secrets)
		guard let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory) else { return check(false, "sign-in") }
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.test.\(UUID().uuidString)")
		defer { try? keys.deleteAll(account: account) }
		let factory = ZagKeychainSigningKeyFactory(keys: keys)
		let simulated = ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer())
		await simulated.setCertificateLimit(20)
		let portal = ScriptedCertificatePortal(inner: simulated)
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: factory, secrets: secrets, account: account)
		let authorization = try! await directory.authorize(ZagSigningScope(accountID: account, teamID: team))
		let request = ZagProvisioningRequest(
			accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
			app: component("com.example.notes", "Notes"), extensions: [], installedFreeAccountApps: []
		)
		func kind(of result: Result<ZagProvisioningResult, ZagProvisioningFailure>) -> ZagProvisioningFailure.Kind? {
			if case .failure(let failure) = result { return failure.kind }
			return nil
		}
		@Sendable func provision() async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
			await provisioner.provision(request, authorization: authorization)
		}
		func works(_ identity: ZagSigningIdentity?) -> Bool {
			guard let identity else { return false }
			if case .matches = factory.check(certificate: identity.certificate, privateKey: identity.privateKey, account: account, team: team, keySlot: identity.keySlot) { return true }
			return false
		}
		func waitUntilHeld() async -> Bool {
			for _ in 0..<500 where !portal.isHolding { try? await Task.sleep(nanoseconds: 10_000_000) }
			return portal.isHolding
		}
		/// The team needs a new certificate: the key in use is gone.
		func loseKeyInUse() {
			if let identity = secrets.identity(account, team) { try? keys.delete(account: account, team: team, slot: identity.keySlot) }
		}

		// Two signings of the same team at once, with a listing that includes
		// certificate content: the second must not settle the first one's
		// request from its own listing and send it again.
		portal.holdNext(.beforeIssue)
		let first = Task { await provision() }
		guard await waitUntilHeld() else { return check(false, "overlap: first request held") }
		let second = Task { await provision() }
		try? await Task.sleep(nanoseconds: 400_000_000)
		let whileHeld = portal.submitted.count
		portal.release()
		let outcomes = [await first.value, await second.value]
		let identity = secrets.identity(account, team)
		check(whileHeld == 1, "overlap: while one certificate request is out, a second signing of the team sends none (sent \(whileHeld))")
		check(portal.submitted.count == 1 && portal.issuedCount == 1 && works(identity)
			  && outcomes.allSatisfy { if case .success = $0 { return true }; return false },
			  "overlap: both signings succeed with the one certificate issued; Apple was asked once")

		// Cancelled while the request is out, after Apple issued the certificate.
		loseKeyInUse()
		let sentBefore = portal.submitted.count, issuedBefore = portal.issuedCount
		portal.holdNext(.afterIssue)
		let cancelled = Task { await provision() }
		guard await waitUntilHeld() else { return check(false, "cancel: request held") }
		cancelled.cancel()
		portal.release()
		let cancelledResult = await cancelled.value
		check(kind(of: cancelledResult) == .cancelled && secrets.pending(account, team)?.submissionUnconfirmed == true,
			  "cancel: cancelling while a request is out leaves it unconfirmed, not 'not issued'")
		guard case .success = await provision() else { return check(false, "cancel: recovery") }
		check(portal.submitted.count == sentBefore + 1 && portal.issuedCount == issuedBefore + 1 && works(secrets.identity(account, team)),
			  "cancel: the certificate Apple issued meanwhile is found and used; the request is not sent again")

		// Responses that do not say what happened: each leaves the request
		// unconfirmed, and with no certificate content listed, nothing is sent
		// again however often signing is retried.
		let ambiguous: [(String, Error)] = [
			("an unreadable response", ZagPortalError.malformedResponse),
			("a timeout", ZagTransportError.timedOut),
			("a dropped connection", ZagPortalError.network),
			("a cancelled transport", ZagTransportError.cancelled),
		]
		for (name, error) in ambiguous {
			loseKeyInUse()
			portal.loseNext(1, with: error)
			_ = await provision()
			let sent = portal.submitted.count, issued = portal.issuedCount
			check(secrets.pending(account, team)?.submissionUnconfirmed == true, "ambiguous: after \(name), the request is unconfirmed")
			portal.hidesCertificateData = true
			var stopped = 0
			for _ in 0..<3 where kind(of: await provision()) == .certificateRequestUnresolved { stopped += 1 }
			portal.hidesCertificateData = false
			check(stopped == 3 && portal.submitted.count == sent, "ambiguous: after \(name), unresolved signing stops and sends nothing more")
			guard case .success = await provision() else { return check(false, "ambiguous: \(name) recovery") }
			check(portal.submitted.count == sent && portal.issuedCount == issued && works(secrets.identity(account, team)),
				  "ambiguous: after \(name), the issued certificate is recovered from the listing; Apple was asked once")
		}

		// Check Again while a retry after a definite rejection is out.
		loseKeyInUse()
		portal.refuseNext(1)
		_ = await provision()
		guard secrets.pending(account, team)?.submissionUnconfirmed == false else { return check(false, "check race: setup") }
		let sentBeforeRace = portal.submitted.count, issuedBeforeRace = portal.issuedCount
		portal.holdNext(.beforeIssue)
		portal.loseNext(1)
		let retry = Task { await provision() }
		guard await waitUntilHeld() else { return check(false, "check race: retry held") }
		let checkAgain = Task { await provisioner.checkUnresolvedCertificateRequest(accountID: account, team: team, authorization: authorization) }
		try? await Task.sleep(nanoseconds: 300_000_000)
		portal.release()
		_ = await retry.value
		let checked = await checkAgain.value
		if case .recovered = checked {
			check(true, "check race: Check Again waits for the request out and then recovers its certificate")
		} else {
			check(false, "check race: Check Again waits for the request out and then recovers its certificate (got \(checked))")
		}
		_ = await provision()
		check(portal.submitted.count == sentBeforeRace + 1 && portal.issuedCount == issuedBeforeRace + 1 && works(secrets.identity(account, team)),
			  "check race: the retried request was sent once, and nothing is sent again afterwards")

		// Abandon and the unresolved-request view while a request is out.
		loseKeyInUse()
		portal.holdNext(.beforeIssue)
		let running = Task { await provision() }
		guard await waitUntilHeld() else { return check(false, "abandon race: held") }
		let shown = Task { await provisioner.unresolvedCertificateRequest(accountID: account, team: team) }
		let abandoned = Task { await provisioner.abandonUnresolvedCertificateRequest(accountID: account, team: team) }
		try? await Task.sleep(nanoseconds: 300_000_000)
		let keyWhileHeld = secrets.pending(account, team).map { factory.hasKey(account: account, team: team, keySlot: $0.keySlot) }
		portal.release()
		let ran = await running.value
		check(keyWhileHeld == true, "abandon race: Abandon does not remove a request's key while that request is out")
		if case .success = ran, await shown.value == nil, await abandoned.value == .nothingPending, works(secrets.identity(account, team)) {
			check(true, "abandon race: the request completes; a request in progress is neither shown as unresolved nor abandoned")
		} else {
			check(false, "abandon race: the request completes; a request in progress is neither shown as unresolved nor abandoned")
		}
	}
}

final class WaitBox<T>: @unchecked Sendable {
	let lock = NSLock()
	var value: T?
}

extension Tests {
	/// G4 closeout, issue 2: an operation waiting for its account and team's
	/// turn can be cancelled. It returns at once, sends nothing, leaves no
	/// waiter behind, and the operations queued after it still run.
	static func cancelledWhileQueued() async {
		let secrets = MemorySecrets()
		let (directory, _) = SimulatedAccounts.directory(now: { Date() }, secrets: secrets)
		guard let account = await SimulatedAccounts.signIn(SimulatedAccounts.tester, to: directory) else { return check(false, "sign-in") }
		let keys = ZagKeychainSigningKeys(namespace: "ZagStore.test.\(UUID().uuidString)")
		defer { try? keys.deleteAll(account: account) }
		let factory = ZagKeychainSigningKeyFactory(keys: keys)
		let simulated = ZagSimulatedDeveloperPortal(team: team, issuer: OpenSSLIssuer())
		await simulated.setCertificateLimit(20)
		let portal = ScriptedCertificatePortal(inner: simulated)
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: factory, secrets: secrets, account: account)
		let authorization = try! await directory.authorize(ZagSigningScope(accountID: account, teamID: team))
		let request = ZagProvisioningRequest(
			accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
			app: component("com.example.notes", "Notes"), extensions: [], installedFreeAccountApps: []
		)
		@Sendable func provision() async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
			await provisioner.provision(request, authorization: authorization)
		}
		func kind(of result: Result<ZagProvisioningResult, ZagProvisioningFailure>?) -> ZagProvisioningFailure.Kind? {
			if case .failure(let failure)? = result { return failure.kind }
			return nil
		}
		func succeeded(_ result: Result<ZagProvisioningResult, ZagProvisioningFailure>?) -> Bool {
			if case .success? = result { return true }
			return false
		}
		/// The task's value if it finishes within `seconds`.
		func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
			let done = WaitBox<T>()
			Task { let value = await task.value; done.lock.withLock { done.value = value } }
			for _ in 0..<Int(seconds * 100) {
				if let value = done.lock.withLock({ done.value }) { return value }
				try? await Task.sleep(nanoseconds: 10_000_000)
			}
			return done.lock.withLock { done.value }
		}
		func waiting(_ count: Int) async -> Bool {
			for _ in 0..<300 where await provisioner.waitingOperations != count { try? await Task.sleep(nanoseconds: 10_000_000) }
			return await provisioner.waitingOperations == count
		}
		func loseKeyInUse() {
			if let identity = secrets.identity(account, team) { try? keys.delete(account: account, team: team, slot: identity.keySlot) }
		}

		// One signing holds the team while its certificate request is out.
		portal.holdNext(.beforeIssue)
		let holder = Task { await provision() }
		for _ in 0..<500 where !portal.isHolding { try? await Task.sleep(nanoseconds: 10_000_000) }
		guard portal.isHolding else { return check(false, "queue: holder") }

		// Three more wait; the first of them is cancelled while it waits.
		let cancelled = Task { await provision() }
		guard await waiting(1) else { return check(false, "queue: first waiter") }
		let second = Task { await provision() }, third = Task { await provision() }
		guard await waiting(3) else { return check(false, "queue: three waiters") }
		cancelled.cancel()
		let early = await value(of: cancelled, within: 2)
		check(kind(of: early) == .cancelled && portal.isHolding,
			  "queue: an operation cancelled while waiting for its team returns at once as cancelled, while the other still runs")
		check(await waiting(2), "queue: the cancelled operation leaves no waiter behind")

		// Another account's scope is never held up by this team's queue.
		let otherScope = Task { await provisioner.unresolvedCertificateRequest(accountID: UUID(), team: team) }
		check(await value(of: otherScope, within: 2) != nil, "queue: another account and team's operation does not wait for this one")

		portal.release()
		let results = [await value(of: holder, within: 10), await value(of: second, within: 10), await value(of: third, within: 10)]
		check(results.allSatisfy(succeeded), "queue: after the cancellation, the holder and every operation queued behind it complete")
		check(portal.submitted.count == 1 && portal.issuedCount == 1,
			  "queue: Apple was asked for one certificate; the cancelled operation sent nothing")
		check(await provisioner.waitingOperations == 0, "queue: no continuation is left waiting")

		// Cancelled before it waits: nothing runs and the team stays usable.
		let before = portal.submitted.count
		let precancelled = Task { () -> Result<ZagProvisioningResult, ZagProvisioningFailure> in
			withUnsafeCurrentTask { $0?.cancel() }
			return await provision()
		}
		check(kind(of: await value(of: precancelled, within: 2)) == .cancelled && portal.submitted.count == before,
			  "queue: an operation cancelled before it starts sends nothing")
		check(succeeded(await value(of: Task { await provision() }, within: 10)) && portal.submitted.count == before,
			  "queue: the next signing proceeds normally and reuses the certificate")

		// Many cancellations racing the queue: no lost wake-up, no extra request.
		portal.holdNext(.beforeIssue)
		loseKeyInUse()
		let racing = Task { await provision() }
		for _ in 0..<500 where !portal.isHolding { try? await Task.sleep(nanoseconds: 10_000_000) }
		let crowd = (0..<24).map { _ in Task { await provision() } }
		try? await Task.sleep(nanoseconds: 50_000_000)
		for (index, task) in crowd.enumerated() where index % 2 == 0 { task.cancel() }
		portal.release()
		var completed = 0, cancelledCount = 0
		for task in [racing] + crowd {
			let result = await value(of: task, within: 15)
			if succeeded(result) { completed += 1 } else if kind(of: result) == .cancelled { cancelledCount += 1 }
		}
		let leftWaiting = await provisioner.waitingOperations
		check(completed + cancelledCount == 25 && completed >= 13 && portal.submitted.count == before + 1 && leftWaiting == 0,
			  "queue: with half of 24 waiting operations cancelled, every operation ends, one request is sent, and no waiter is left (\(completed) done, \(cancelledCount) cancelled)")
	}
}
