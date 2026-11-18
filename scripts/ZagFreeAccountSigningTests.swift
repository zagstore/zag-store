import Foundation
import Security

// Free-account signing end to end, without Apple: Security-framework keys
// and certificate requests, a throwaway local test authority (never Apple's)
// issuing certificates and signed profiles to the simulated portal, Zag
// Store's profile parser, the real Zsign signer on a real arm64 iOS
// executable, and the 7-day install and refresh lifecycle on a stand-in
// device. Run by test-zag-free-account-signing.sh.

let environment = ProcessInfo.processInfo.environment
let openssl = environment["ZAG_TEST_OPENSSL"]!
/// Self-generated and trusted by nothing. Its subject name matches Apple's
/// WWDR G3 intermediate only so that Zsign's issuer check takes its normal
/// signing path; `otherAuthority` has a plainly different name.
let recognisedAuthority = URL(fileURLWithPath: environment["ZAG_TEST_AUTHORITY"]!)
let otherAuthority = URL(fileURLWithPath: environment["ZAG_TEST_OTHER_AUTHORITY"]!)
let executable = URL(fileURLWithPath: environment["ZAG_TEST_EXECUTABLE"]!)
let work = URL(fileURLWithPath: environment["ZAG_TEST_WORK"]!)
let team = "SIMTEAM001"
let udid = "00000000-SIMULATED000000"
let account = UUID()

@discardableResult
func run(_ tool: String, _ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data, error: String) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: tool)
	process.arguments = arguments
	let out = Pipe(), err = Pipe(), stdin = Pipe()
	process.standardOutput = out
	process.standardError = err
	process.standardInput = stdin
	try! process.run()
	if let input { stdin.fileHandleForWriting.write(input) }
	try? stdin.fileHandleForWriting.close()
	let output = out.fileHandleForReading.readDataToEndOfFile()
	let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
	process.waitUntilExit()
	return (process.terminationStatus, output, error)
}

func temporaryFile(_ data: Data, _ name: String) -> URL {
	let url = work.appendingPathComponent("tmp-\(UUID().uuidString)-\(name)")
	try! data.write(to: url)
	return url
}

/// A local test authority standing in for Apple's: it signs certificates for
/// requests and wraps profiles in CMS, using OpenSSL and a throwaway key.
struct OpenSSLIssuer: ZagSimulatedIssuer {
	var days = 365
	var authority = recognisedAuthority

	func certificate(for request: ZagCertificateRequest, serialNumber: String) throws -> Data {
		let csr = temporaryFile(request.data, "request.der"), cert = work.appendingPathComponent("cert-\(serialNumber).der")
		defer { try? FileManager.default.removeItem(at: csr) }
		let result = run(openssl, ["x509", "-req", "-inform", "DER", "-in", csr.path,
			"-CA", authority.appendingPathComponent("ca.pem").path, "-CAkey", authority.appendingPathComponent("ca.key").path,
			"-set_serial", "0x\(serialNumber)", "-days", "\(days)", "-outform", "DER", "-out", cert.path])
		guard result.status == 0 else { throw ZagPortalError.malformedResponse }
		return try Data(contentsOf: cert)
	}

	func profile(signing plist: Data) throws -> Data {
		let input = temporaryFile(plist, "profile.plist"), output = work.appendingPathComponent("profile-\(UUID().uuidString).der")
		defer { try? FileManager.default.removeItem(at: input) }
		let result = run(openssl, ["cms", "-sign", "-nodetach", "-binary", "-outform", "DER",
			"-signer", authority.appendingPathComponent("ca.pem").path, "-inkey", authority.appendingPathComponent("ca.key").path,
			"-in", input.path, "-out", output.path])
		guard result.status == 0 else { throw ZagPortalError.malformedResponse }
		return try Data(contentsOf: output)
	}
}

final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Date()
	var now: Date { lock.withLock { value } }
	func advance(days: Double) { lock.withLock { value += days * 86_400 } }
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

final class RecordingSigner: ZagCodeSigner, @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	var calls: Int { lock.withLock { count } }
	func sign(app: URL, profile: URL, privateKey: URL, entitlements: URL, bundleIdentifier: String) throws {
		lock.withLock { count += 1 }
		let mode = (try? FileManager.default.attributesOfItem(atPath: privateKey.path)[.posixPermissions] as? Int) ?? -1
		let folder = (try? FileManager.default.attributesOfItem(atPath: privateKey.deletingLastPathComponent().path)[.posixPermissions] as? Int) ?? -1
		guard mode == 0o600, folder == 0o700 else { throw ZagSignerFailure(message: "key file permissions \(String(mode, radix: 8)) / \(String(folder, radix: 8))") }
		try ZagZsignCodeSigner().sign(app: app, profile: profile, privateKey: privateKey, entitlements: entitlements, bundleIdentifier: bundleIdentifier)
	}
}

/// Stands in for the RPPairing installer and a device-side read-back: it
/// "installs" by copying, then reports the installed profile, as a verifier
/// that can read the device's profiles would. `unverifiable` stands for the
/// current RPPairing core, which cannot read the expiry back.
actor TestDevice: ZagFreeAccountInstaller {
	enum Failure: Error { case installFailed }
	let root = work.appendingPathComponent("device-\(UUID().uuidString)")
	private(set) var installs = 0
	var failNext = false
	var reportOldExpiryNext: Date?
	var unverifiable = false
	func setFailNext() { failNext = true }
	func setReportOldExpiryNext(_ date: Date) { reportOldExpiryNext = date }
	func setUnverifiable(_ value: Bool) { unverifiable = value }

	func install(signedApp: URL, bundleIdentifier: String) async throws {
		if failNext { failNext = false; throw Failure.installFailed }
		let destination = root.appendingPathComponent("\(bundleIdentifier).app")
		try? FileManager.default.removeItem(at: destination)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: signedApp, to: destination)
		installs += 1
	}

	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		if unverifiable { return .unverifiable("expiry read-back is not available") }
		let installed = root.appendingPathComponent("\(expectation.bundleIdentifier).app/embedded.mobileprovision")
		guard let data = try? Data(contentsOf: installed), let profile = try? Certificate.decode(profileData: data) else { return .notInstalled }
		guard profile.UUID == expectation.profileUUID else { return .mismatch("profile") }
		let certificate = (profile.DeveloperCertificates ?? []).compactMap { ZagCertificateInspection(der: $0)?.expiresAt }.min()!
		if let old = reportOldExpiryNext { reportOldExpiryNext = nil; return .verified(profileExpiresAt: old, certificateExpiresAt: certificate) }
		return .verified(profileExpiresAt: profile.ExpirationDate, certificateExpiresAt: certificate)
	}
}

let device = ZagTargetDevice(udid: udid, name: "Test iPhone")

func makeApp(bundleIdentifier: String = "com.example.notes", extensions: [String] = []) -> URL {
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
	bundle(app, bundleIdentifier, "Notes", package: "APPL")
	for name in extensions {
		bundle(app.appendingPathComponent("PlugIns/\(name).appex"), "\(bundleIdentifier).\(name.lowercased())", name, package: "XPC!")
	}
	return app
}

func codesignInfo(_ path: URL) -> String {
	run("/usr/bin/codesign", ["-dvvv", path.path]).error
}

/// The entitlements blob (slot 5) of an executable's signature, as iOS reads it.
func signedEntitlements(_ executable: URL) -> [String: Any] {
	guard let blob = ZagCodeSignatureInspection.signatureBlobs(try! Data(contentsOf: executable))?.first?[5] else { return [:] }
	return (try? PropertyListSerialization.propertyList(from: blob.dropFirst(8), format: nil)) as? [String: Any] ?? [:]
}

func request(installed: Set<String> = [], app: String = "com.example.notes") -> ZagProvisioningRequest {
	ZagProvisioningRequest(
		accountID: account, team: team, deviceUDID: udid, deviceName: "Test iPhone",
		app: .init(originalBundleIdentifier: app, name: "Notes", entitlements: try! ZagEntitlementSet([
			"keychain-access-groups": ["ORIGTEAM01.\(app)"],
			"aps-environment": "production"
		])),
		extensions: [],
		installedFreeAccountApps: installed
	)
}

func component(_ app: String = "com.example.notes") -> ZagProvisioningRequest.Component {
	request(app: app).app
}

/// One simulated account (and team) signed in to a real account directory,
/// with its own portal, provisioner and lifecycle. Several can share a
/// directory, Keychain store and device.
struct Harness {
	let clock: TestClock
	let secrets: MemorySecrets
	let directory: ZagAccountDirectory
	let service: ZagSimulatedAuthenticationService
	let appleID: String
	let account: UUID
	let team: String
	let diagnostics = ZagFreeAccountDiagnostics()
	let signer: RecordingSigner
	let device: TestDevice
	let staging: URL
	let portal: ZagSimulatedDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner
	let lifecycle: ZagFreeAccountLifecycle
	var adapter: ZagFreeAccountSigningAdapter { lifecycle.adapter }

	static func make(issuer: OpenSSLIssuer = OpenSSLIssuer()) async -> Harness {
		let clock = TestClock(), secrets = MemorySecrets()
		let (directory, service) = SimulatedAccounts.directory(now: { clock.now }, secrets: secrets)
		return await make(SimulatedAccounts.tester, team: "SIMTEAM001", clock: clock, secrets: secrets, directory: directory, service: service,
						  signer: RecordingSigner(), device: TestDevice(), issuer: issuer)
	}

	/// Another account (or team) on the same directory, Keychain and device.
	func adding(_ appleID: String, team: String, issuer: OpenSSLIssuer = OpenSSLIssuer()) async -> Harness {
		await Harness.make(appleID, team: team, clock: clock, secrets: secrets, directory: directory, service: service, signer: signer, device: device, issuer: issuer)
	}

	static func make(
		_ appleID: String, team: String, clock: TestClock, secrets: MemorySecrets, directory: ZagAccountDirectory,
		service: ZagSimulatedAuthenticationService, signer: RecordingSigner, device: TestDevice, issuer: OpenSSLIssuer
	) async -> Harness {
		let account: UUID
		if let known = await directory.registry.accounts.first(where: { $0.teams.contains { $0.identifier == team } })?.id {
			account = known
		} else {
			account = await SimulatedAccounts.signIn(appleID, to: directory)!
		}
		let staging = work.appendingPathComponent("staging-\(UUID().uuidString)")
		try! FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		let portal = ZagSimulatedDeveloperPortal(team: team, clock: { clock.now }, issuer: issuer)
		let provisioner = ZagFreeAccountProvisioner(
			portal: portal, keys: ZagSecuritySigningKeyFactory(), secrets: secrets,
			account: account, now: { clock.now }
		)
		let lifecycle = ZagFreeAccountLifecycle(
			directory: directory,
			provisioner: provisioner,
			adapter: ZagFreeAccountSigningAdapter(signer: signer, workRoot: staging, gate: .simulationOnly),
			installer: device,
			secrets: secrets
		)
		return Harness(clock: clock, secrets: secrets, directory: directory, service: service, appleID: appleID, account: account, team: team,
					   signer: signer, device: device, staging: staging, portal: portal, provisioner: provisioner, lifecycle: lifecycle)
	}

	var scope: ZagSigningScope { ZagSigningScope(accountID: account, teamID: team) }
	var identity: ZagSigningIdentity? { secrets.identity(account, team) }
	var bundle: String { "com.example.notes.\(team)" }
	func authorization() async -> ZagSigningAuthorization { try! await directory.authorize(scope) }

	func provision(_ r: ZagProvisioningRequest) async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		let mine = ZagProvisioningRequest(accountID: account, team: team, deviceUDID: r.deviceUDID, deviceName: r.deviceName,
										  app: r.app, extensions: r.extensions, installedFreeAccountApps: r.installedFreeAccountApps)
		return await provisioner.provision(mine, authorization: await authorization())
	}

	/// Signs in to this account again (after its session expired or was rejected).
	func signInAgain() async {
		let authenticator = await directory.authenticator(for: account)!
		_ = await authenticator.signIn(appleID: appleID, password: ZagEphemeralSecret(ZagFreeAccountSimulation.password))
	}

	var stagingIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? ["?"]).isEmpty }
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
		keysAndRequests()
		certificatesAndProfiles()
		await signing()
		await extensionsAndGuards()
		await lifecycle()
		await lifecycleFailures()
		await multipleAccounts()
		await profileReadBack()
		print("SUCCESS: \(passed) free-account signing and lifecycle checks passed")
	}

	// MARK: Installed-profile read-back

	/// What the device reports (its installed profiles) against what was
	/// installed. Only an exact match is verified.
	static func profileReadBack() async {
		let h = await Harness.make()
		guard let result = await h.provision(request()).value else { return check(false, "provision for read-back") }
		guard let other = await h.provision(request(app: "com.example.other")).value else { return check(false, "second provision") }
		let profile = result.app.profile
		let expectation = ZagInstallExpectation(bundleIdentifier: result.app.bundleIdentifier, profileUUID: profile.uuid, profileExpiresAt: profile.expiresAt,
												certificateExpiresAt: profile.expiresAt.addingTimeInterval(86_400 * 300), signerCommonName: nil, teamIdentifier: team)
		let verdict = ZagInstalledProfileCheck.verify(expectation, installedProfiles: [other.app.profile.data, profile.data])
		check(verdict == .verified(profileExpiresAt: profile.expiresAt, certificateExpiresAt: expectation.certificateExpiresAt),
			  "the app's own profile on the device, with the expected team, App ID and expiry, is verified")
		check(ZagInstalledProfileCheck.verify(expectation, installedProfiles: [other.app.profile.data]) == .unverifiable("the app's profile is not among the device's installed profiles"),
			  "without the app's own profile on the device, nothing is verified (another app's profile does not count)")
		check(ZagInstalledProfileCheck.verify(expectation, installedProfiles: []) != .verified(profileExpiresAt: profile.expiresAt, certificateExpiresAt: expectation.certificateExpiresAt)
			  && ZagInstalledProfileCheck.verify(expectation, installedProfiles: [Data("junk".utf8)]) == .unverifiable("the app's profile is not among the device's installed profiles"),
			  "an empty or unreadable profile list is never success")
		var later = expectation
		later = ZagInstallExpectation(bundleIdentifier: later.bundleIdentifier, profileUUID: later.profileUUID, profileExpiresAt: later.profileExpiresAt.addingTimeInterval(86_400),
									  certificateExpiresAt: later.certificateExpiresAt, signerCommonName: nil, teamIdentifier: team)
		check(ZagInstalledProfileCheck.verify(later, installedProfiles: [profile.data]) == .mismatch("profile expiry"), "a different expiry on the device is a mismatch")
		let wrongTeam = ZagInstallExpectation(bundleIdentifier: expectation.bundleIdentifier, profileUUID: profile.uuid, profileExpiresAt: profile.expiresAt,
											  certificateExpiresAt: expectation.certificateExpiresAt, signerCommonName: nil, teamIdentifier: "OTHERTEAM1")
		check(ZagInstalledProfileCheck.verify(wrongTeam, installedProfiles: [profile.data]) == .mismatch("profile team"), "a profile for another team is a mismatch")
		let wrongApp = ZagInstallExpectation(bundleIdentifier: "com.example.elsewhere", profileUUID: profile.uuid, profileExpiresAt: profile.expiresAt,
											 certificateExpiresAt: expectation.certificateExpiresAt, signerCommonName: nil, teamIdentifier: team)
		check(ZagInstalledProfileCheck.verify(wrongApp, installedProfiles: [profile.data]) == .mismatch("profile App ID"), "a profile for another App ID is a mismatch")
		var withExtension = expectation
		withExtension.extensionProfileUUIDs = ["00000000-0000-0000-0000-000000000000"]
		check(ZagInstalledProfileCheck.verify(withExtension, installedProfiles: [profile.data]) == .unverifiable("an extension's profile is not among the device's installed profiles"),
			  "a missing extension profile is never success")
		withExtension.extensionProfileUUIDs = [other.app.profile.uuid]
		check(ZagInstalledProfileCheck.verify(withExtension, installedProfiles: [profile.data, other.app.profile.data]) != .mismatch("extension profile team"),
			  "extension profiles of the same team are accepted")
	}

	// MARK: Keys and certificate requests

	static func keysAndRequests() {
		let factory = ZagSecuritySigningKeyFactory()
		let (key, request) = try! factory.makeKey(commonName: "Zag Store")
		let secKey = SecKeyCreateWithData(key as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)
		check(secKey.map { SecKeyGetBlockSize($0) * 8 } == 2048, "the signing key is RSA 2048, exported as PKCS #1")
		let publicKey = secKey.flatMap(SecKeyCopyPublicKey).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
		guard case .success(let contents) = ZagCertificateSigningRequest.validate(request.data) else { return check(false, "request validates") }
		check(contents.commonName == "Zag Store" && contents.publicKey == publicKey && contents.keySizeInBits == 2048,
			  "the request validates and carries the key's public half and the common name")

		let file = temporaryFile(request.data, "request.der")
		let verified = run(openssl, ["req", "-inform", "DER", "-in", file.path, "-verify", "-noout", "-subject"])
		check(verified.status == 0 && verified.error.contains("verify OK") || String(data: verified.output, encoding: .utf8)!.contains("CN") && verified.status == 0,
			  "OpenSSL independently verifies the request's signature")
		let text = String(data: run(openssl, ["req", "-inform", "DER", "-in", file.path, "-noout", "-text"]).output, encoding: .utf8) ?? ""
		check(text.contains("sha256WithRSAEncryption") && text.contains("Public-Key: (2048 bit)") && text.contains("CN") && text.contains("Zag Store"),
			  "OpenSSL reads a SHA-256 RSA 2048 request for CN=Zag Store")
		check(request.data.range(of: key.suffix(64)) == nil && request.data.range(of: key.prefix(64)) == nil, "the request contains no private-key material")

		let (otherKey, otherRequest) = try! factory.makeKey(commonName: "Zag Store")
		check(otherKey != key && otherRequest.data != request.data, "every key is new")

		var badSignature = request.data
		badSignature[badSignature.count - 5] ^= 0xFF
		check(ZagCertificateSigningRequest.validate(badSignature) == .failure(.badSignature), "a request with a damaged signature is refused")
		var badBody = request.data
		if let range = badBody.range(of: Data("Zag Store".utf8)) { badBody[range.lowerBound] = UInt8(ascii: "X") }
		check(ZagCertificateSigningRequest.validate(badBody) == .failure(.badSignature), "a request changed after signing is refused")
		check(ZagCertificateSigningRequest.validate(request.data.prefix(40)) == .failure(.malformed), "a truncated request is refused")
		let small = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024] as CFDictionary, nil)!
		let smallRequest = try! ZagCertificateSigningRequest.make(commonName: "Zag Store", privateKey: small)
		check(ZagCertificateSigningRequest.validate(smallRequest) == .failure(.keyTooSmall), "a key under 2048 bits is refused")
	}

	// MARK: Certificates and profiles

	static func certificatesAndProfiles() {
		let factory = ZagSecuritySigningKeyFactory()
		let (key, request) = try! factory.makeKey(commonName: "Zag Store")
		let certificate = try! OpenSSLIssuer().certificate(for: request, serialNumber: "0A1B2C3D4E5F6071")
		guard case .matches(let serial, let expiresAt) = factory.check(certificate: certificate, privateKey: key) else {
			return check(false, "certificate matches key")
		}
		check(serial == "0A1B2C3D4E5F6071" && abs(expiresAt.timeIntervalSinceNow - 365 * 86_400) < 3_600,
			  "an issued certificate is matched to its key, with its serial and expiry")
		let (otherKey, _) = try! factory.makeKey(commonName: "Zag Store")
		check(factory.check(certificate: certificate, privateKey: otherKey) == .mismatch, "a certificate for another key is refused")
		check(factory.check(certificate: Data("not a certificate".utf8), privateKey: key) == .mismatch, "an unreadable certificate is refused")
		let late = try! OpenSSLIssuer(days: 9_500).certificate(for: request, serialNumber: "01")
		let lateYear = ZagCertificateInspection(der: late).map { Calendar(identifier: .gregorian).component(.year, from: $0.expiresAt) }
		check(lateYear.map { $0 >= 2050 } == true, "expiry dates after 2049 (GeneralizedTime) are read")
		check(ZagCertificateInspection(der: certificate)?.commonName == "Zag Store", "the certificate's common name is read")

		let plist: [String: Any] = [
			"AppIDName": "Notes", "ApplicationIdentifierPrefix": [team], "CreationDate": Date(), "Platform": ["iOS"],
			"DeveloperCertificates": [certificate], "DER-Encoded-Profile": Data([0x30, 0x00]),
			"Entitlements": ["application-identifier": "\(team).com.example.notes.\(team)", "get-task-allow": true],
			"ExpirationDate": Date(timeIntervalSinceNow: 7 * 86_400), "Name": "Notes", "ProvisionedDevices": [udid],
			"TeamIdentifier": [team], "TeamName": "Simulated Team", "TimeToLive": 7, "UUID": "8C6F0D7E-0000-4000-8000-000000000001", "Version": 1
		]
		let data = try! OpenSSLIssuer().profile(signing: try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
		let profile = try? ZagIssuedProfile(profileData: data)
		check(profile?.teamIdentifier == team && profile?.bundleIdentifier == "com.example.notes.\(team)" && profile?.deviceUDIDs == [udid]
			  && profile?.certificateSerials == [serial] && profile?.uuid == "8C6F0D7E-0000-4000-8000-000000000001",
			  "a signed profile is read with Zag Store's parser: team, bundle, device and certificate")
		let decoded = try? Certificate.decode(profileData: data)
		check(decoded?.UUID == profile?.uuid && decoded?.ExpirationDate == profile?.expiresAt, "the free-account reading agrees with the app's profile parser")
		check((try? ZagIssuedProfile(profileData: Data("garbage".utf8))) == nil && (try? Certificate.decode(profileData: Data("garbage".utf8)))??.UUID == nil,
			  "an unreadable profile is refused")
	}

	// MARK: Signing with Zsign

	static func signing() async {
		let h = await Harness.make()
		guard let result = await h.provision(request()).value else { return check(false, "provisioning with real keys") }
		guard let identity = h.identity else { return check(false, "identity stored") }
		let auth = await h.authorization()
		check(identity.serialNumber == result.certificateSerial && result.changes.createdCertificate,
			  "provisioning makes a key, gets a certificate for it and stores the identity")
		let issued = await h.portal.issuedCertificates.count
		check(issued == 1, "one certificate request was sent")

		let app = makeApp()
		let record: ZagSignedAppRecord
		do { record = try h.adapter.sign(appAt: app, with: result, identity: identity, authorization: auth, now: h.clock.now) } catch {
			return check(false, "signing failed: \(error)")
		}
		check(h.signer.calls == 1, "the app is signed once, by Zsign")
		check(ZagFreeAccountSigningAdapter.bundleIdentifier(of: app) == "com.example.notes.\(team)", "the signed app carries the team's bundle ID")
		let embedded = try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
		check(embedded == result.app.profile.data, "the profile issued for this App ID is embedded")
		let info = codesignInfo(app)
		check(info.contains("Identifier=com.example.notes.\(team)") && info.contains("TeamIdentifier=\(team)"),
			  "codesign reads the team's identifier and team from the signature")
		let blobs = ZagCodeSignatureInspection.signatureBlobs(try! Data(contentsOf: app.appendingPathComponent("Notes")))?.first ?? [:]
		let cms = temporaryFile(blobs[ZagCodeSignatureInspection.cmsSlot]?.dropFirst(8) ?? Data(), "cms.der")
		let directory = temporaryFile(blobs[ZagCodeSignatureInspection.codeDirectorySlot] ?? Data(), "cd.bin")
		let signerFile = work.appendingPathComponent("signer-\(UUID().uuidString).pem")
		let verify = run(openssl, ["cms", "-verify", "-binary", "-inform", "DER", "-in", cms.path, "-content", directory.path,
								   "-noverify", "-signer", signerFile.path, "-out", "/dev/null"])
		let signerDER = run(openssl, ["x509", "-in", signerFile.path, "-outform", "DER"]).output
		check(verify.status == 0 && verify.error.contains("Verification successful"), "OpenSSL verifies the CMS signature over the code directory")
		check(!signerDER.isEmpty && signerDER == identity.certificate, "the signer is the certificate issued for the on-device key")
		let signed = signedEntitlements(app.appendingPathComponent("Notes"))
		check(signed["application-identifier"] as? String == "\(team).com.example.notes.\(team)"
			  && signed["keychain-access-groups"] as? [String] == ["\(team).com.example.notes"]
			  && signed["aps-environment"] == nil && signed["get-task-allow"] as? Bool == true,
			  "the signed entitlements are the resolved ones (team App ID and keychain group, no push)")
		check(record.profileExpiresAt == result.app.profile.expiresAt && record.certificateExpiresAt == identity.expiresAt
			  && abs(record.profileExpiresAt.timeIntervalSince(h.clock.now) - 7 * 86_400) < 1,
			  "the signing record carries the 7-day profile expiry")
		check(h.stagingIsEmpty, "no key, profile or entitlements file is left behind")
		let log = h.diagnostics.entries.map(\.message).joined(separator: "\n")
		check(!log.contains(identity.privateKey.base64EncodedString().prefix(40)) && !log.contains(udid), "diagnostics hold no key or device ID")
	}

	// MARK: Extensions and adapter guards

	static func extensionsAndGuards() async {
		let h = await Harness.make()
		guard let result = await h.provision(request()).value, let identity = h.identity else { return check(false, "provision") }
		let auth = await h.authorization()

		let withExtension = makeApp(extensions: ["Widget"])
		do {
			_ = try h.adapter.sign(appAt: withExtension, with: result, identity: identity, authorization: auth, now: h.clock.now)
			check(false, "apps with extensions are refused")
		} catch {
			check(error as? ZagFreeAccountSigningError == .extensionsNeedPerBundleSigning(["PlugIns/Widget.appex"]) && h.signer.calls == 0,
				  "an app with an extension is refused before signing (Zsign cannot sign it per App ID)")
		}

		// The evidence for that refusal: Zsign, as the app calls it, signs the
		// extension with the main app's entitlements and embeds no profile in it.
		let evidence = makeApp(extensions: ["Widget"])
		let profile = temporaryFile(result.app.profile.data, "main.mobileprovision")
		let keyFile = temporaryFile(identity.privateKey, "key")
		let entitlements = temporaryFile(try! PropertyListSerialization.data(fromPropertyList: result.app.entitlements.dictionary, format: .xml, options: 0), "e.plist")
		try? ZagZsignCodeSigner().sign(app: evidence, profile: profile, privateKey: keyFile, entitlements: entitlements, bundleIdentifier: result.app.bundleIdentifier)
		try? FileManager.default.removeItem(at: keyFile)
		let appex = evidence.appendingPathComponent("PlugIns/Widget.appex")
		let appexEntitlements = signedEntitlements(appex.appendingPathComponent("Widget"))
		check(appexEntitlements["application-identifier"] as? String == "\(team).com.example.notes.\(team)"
			  && !FileManager.default.fileExists(atPath: appex.appendingPathComponent("embedded.mobileprovision").path),
			  "evidence: Zsign gives an extension the main app's App ID and no profile of its own")

		let other = ZagSigningIdentity(serialNumber: "DEADBEEF", certificate: identity.certificate, privateKey: identity.privateKey, expiresAt: identity.expiresAt)
		do {
			_ = try h.adapter.sign(appAt: makeApp(), with: result, identity: other, authorization: auth, now: h.clock.now)
			check(false, "identity mismatch")
		} catch {
			check(error as? ZagFreeAccountSigningError == .identityMismatch && h.signer.calls == 0, "an identity that is not the profiles' certificate is refused")
		}
		do {
			_ = try h.adapter.sign(appAt: makeApp(bundleIdentifier: "com.example.other"), with: result, identity: identity, authorization: auth, now: h.clock.now)
			check(false, "bundle mismatch")
		} catch {
			check(error as? ZagFreeAccountSigningError == .bundleMismatch(expected: "com.example.notes", found: "com.example.other") && h.signer.calls == 0,
				  "an app that is not the provisioned one is refused")
		}

		let broken = makeApp()
		try! Data("not a Mach-O".utf8).write(to: broken.appendingPathComponent("Notes"))
		do {
			_ = try h.adapter.sign(appAt: broken, with: result, identity: identity, authorization: auth, now: h.clock.now)
			check(false, "broken executable")
		} catch {
			if case .signer? = error as? ZagFreeAccountSigningError { check(true, "a signing failure from Zsign is reported") } else { check(false, "signer error: \(error)") }
		}
		check(h.stagingIsEmpty, "the key file is removed after a failed signing too")

		// Zsign says "Signed OK" for a certificate whose issuer it does not
		// recognise, but makes no CMS signature; the adapter must catch that.
		let unrecognised = await Harness.make(issuer: OpenSSLIssuer(authority: otherAuthority))
		guard let otherResult = await unrecognised.provision(request()).value, let otherIdentity = unrecognised.identity else {
			return check(false, "provision with the other authority")
		}
		do {
			_ = try unrecognised.adapter.sign(appAt: makeApp(), with: otherResult, identity: otherIdentity, authorization: await unrecognised.authorization(), now: unrecognised.clock.now)
			check(false, "unsigned result accepted")
		} catch {
			check(error as? ZagFreeAccountSigningError == .verification("no signature") && unrecognised.stagingIsEmpty,
				  "a result Zsign reports as signed but that has no CMS signature is refused")
		}
	}

	// MARK: Lifecycle

	static func lifecycle() async {
		let h = await Harness.make()
		var ledger = ZagRefreshLedger()
		let bundle = "com.example.notes.\(team)"
		let start = h.clock.now

		guard case .installed(let first) = await h.lifecycle.install(app: component(), scope: nil, device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now) else {
			return check(false, "first install")
		}
		let installs = await h.device.installs
		check(installs == 1 && ledger.records[bundle] == first, "the signed app is installed and recorded from the device's read-back")
		check(abs(first.expiresAt.timeIntervalSince(start) - 7 * 86_400) < 1 && first.urgency(at: h.clock.now) == .normal, "a new install has 7 days and needs nothing")
		check(first.reminderDates(after: h.clock.now).count == 2, "reminders are scheduled for the recommended and urgent windows")

		h.clock.advance(days: 3.5)
		check(first.urgency(at: h.clock.now) == .eligible && ledger.refreshAllOrder(at: h.clock.now) == [bundle], "on day 4 a refresh is allowed")
		h.clock.advance(days: 1)
		check(first.urgency(at: h.clock.now) == .recommended, "on day 5 a refresh is recommended")

		let certificatesBefore = await h.portal.issuedCertificates.count
		let mutationsBefore = await h.portal.mutations.count
		guard case .installed(let refreshed) = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: false) else {
			return check(false, "refresh")
		}
		let certificatesAfter = await h.portal.issuedCertificates.count
		let mutationsAfter = await h.portal.mutations.count
		check(certificatesAfter == certificatesBefore && mutationsAfter == mutationsBefore,
			  "a refresh within 7 days reuses the certificate and App ID (no new request, nothing created)")
		check(abs(refreshed.expiresAt.timeIntervalSince(h.clock.now) - 7 * 86_400) < 1 && refreshed.lastSuccessfulRefresh == h.clock.now,
			  "the refresh is verified from the device: a new 7-day expiry")
		check(refreshed.urgency(at: h.clock.now) == .normal && ledger.running.isEmpty, "after the refresh the app needs nothing")

		h.clock.advance(days: 8)
		check(ledger.records[bundle]?.urgency(at: h.clock.now) == .expired && ledger.refreshAllOrder(at: h.clock.now) == [bundle],
			  "8 days later the app has expired and is first in Refresh All")
		guard case .installed(let revived) = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true) else {
			return check(false, "refresh after expiry")
		}
		let calls = await h.portal.calls
		check(calls.filter { $0 == .registerAppID }.count == 2 && revived.expiresAt > h.clock.now + 6 * 86_400,
			  "an expired app is brought back: its lapsed App ID is registered again")
		check(h.stagingIsEmpty && h.signer.calls == 3, "three signings, nothing left on disk")
	}

	static func lifecycleFailures() async {
		let h = await Harness.make()
		var ledger = ZagRefreshLedger()
		let bundle = "com.example.notes.\(team)"
		guard case .installed = await h.lifecycle.install(app: component(), scope: nil, device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now) else { return check(false, "install") }

		h.clock.advance(days: 4.5)
		let old = ledger.records[bundle]!.profileExpiresAt
		await h.device.setReportOldExpiryNext(old)
		let stale = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(stale == .failed(.notVerified) && ledger.records[bundle]?.lastFailure?.reason == .notVerified && ledger.records[bundle]?.profileExpiresAt == old,
			  "a refresh the device does not confirm is recorded as not verified, not as done")

		await h.device.setFailNext()
		let failed = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(failed == .failed(.installFailed), "an installation failure is recorded")
		let automatic = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: false)
		if case .notStarted(.backingOff) = automatic { check(true, "automatic refreshes back off after failures") } else { check(false, "backoff: \(automatic)") }

		await h.portal.fail(.appIDs, with: .sessionRejected)
		let signedOut = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		let held = ledger.begin(bundle, at: h.clock.now + 86_400, userInitiated: false)
		check(signedOut == .failed(.signedOut) && held == .backingOff(until: .distantFuture), "an expired session stops automatic refreshes until the user signs in")
		ledger.resolve(.signedOut, account: h.account)
		await h.portal.fail(.appIDs, with: nil)

		let signings = h.signer.calls
		await h.portal.tamperProfiles(.missingDevice)
		let tampered = await h.lifecycle.refresh(bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(tampered == .failed(.signingFailed) && h.signer.calls == signings, "a profile without this device is never used to sign")
		await h.portal.tamperProfiles(nil)

		for other in ["a.\(team)", "b.\(team)"] {
			ledger.record(ZagSignedAppRecord(bundleIdentifier: other, originalBundleIdentifier: other, signedAt: h.clock.now,
											 profileExpiresAt: h.clock.now + 86_400, certificateExpiresAt: h.clock.now + 86_400))
		}
		let full = await h.lifecycle.install(app: component("com.example.fourth"), scope: nil, device: device, appAt: makeApp(bundleIdentifier: "com.example.fourth"), ledger: &ledger, now: h.clock.now)
		check(full == .failed(.installSlots) && h.signer.calls == signings, "a fourth app is refused before anything is signed")

		let limited = await Harness.make()
		await limited.portal.seedCertificate(serial: "AAAA", expiresAt: limited.clock.now + 100 * 86_400)
		await limited.portal.seedCertificate(serial: "BBBB", expiresAt: limited.clock.now + 200 * 86_400)
		var other = ZagRefreshLedger()
		let refused = await limited.lifecycle.install(app: component(), scope: nil, device: device, appAt: makeApp(), ledger: &other, now: limited.clock.now)
		let remaining = await limited.portal.issuedCertificates.map(\.serialNumber)
		check(refused == .failed(.signingFailed) && remaining == ["AAAA", "BBBB"] && limited.signer.calls == 0,
			  "at the certificate limit nothing is revoked and nothing is signed")

		let disabled = ZagFreeAccountLifecycle(
			directory: limited.directory,
			provisioner: ZagFreeAccountProvisioner(secrets: MemorySecrets(), now: { limited.clock.now }),
			adapter: ZagFreeAccountSigningAdapter(signer: limited.signer, workRoot: limited.staging),
			installer: limited.device, secrets: MemorySecrets()
		)
		var none = ZagRefreshLedger()
		let unavailable = await disabled.install(app: component(), scope: nil, device: device, appAt: makeApp(), ledger: &none, now: limited.clock.now)
		check(unavailable == .failed(.signedOut) && limited.signer.calls == 0 && ZagLivePortal.isEnabled == false && ZagLiveAuthentication.isEnabled == false && ZagAnisetteLive.isEnabled == false,
			  "the default build cannot provision or sign: live portal, sign-in and anisette are off")
		check(ZagFreeAccountSigning.isEnabled == false && ZagFreeAccountSigningGate.production.isOpen == false, "the production signing gate is closed")
		let gated = await Harness.make()
		guard let result = await gated.provision(request()).value, let identity = gated.identity else { return check(false, "provision for the gate") }
		let closed = ZagFreeAccountSigningAdapter(signer: gated.signer, workRoot: gated.staging)
		do {
			_ = try closed.sign(appAt: makeApp(), with: result, identity: identity, authorization: await gated.authorization(), now: gated.clock.now)
			check(false, "closed gate signed")
		} catch {
			check(error as? ZagFreeAccountSigningError == .disabled && gated.signer.calls == 0, "the production adapter refuses to sign while the gate is closed")
		}
	}

	// MARK: Several accounts on one device

	static func multipleAccounts() async {
		let free1 = await Harness.make()
		let free2 = await free1.adding(SimulatedAccounts.second, team: "SIMTEAM002")
		let paid = await free1.adding(SimulatedAccounts.paid, team: "SIMPAID001")
		let org = await free1.adding(SimulatedAccounts.paid, team: "SIMORG0001")
		let accounts = await free1.directory.registry.accounts
		check(accounts.count == 3 && Set([free1.account, free2.account, paid.account]).count == 3 && org.account == paid.account,
			  "three accounts are signed in at once; the paid account's two teams share one account")
		check(accounts.first { $0.id == paid.account }?.teams.map(\.kind) == [.individualPaid, .organization], "a paid account lists all its teams")
		var ledger = ZagRefreshLedger()
		let now = free1.clock.now

		// Each account and team signs with its own certificate and key.
		guard case .installed(let a) = await free1.lifecycle.install(app: component(), scope: nil, device: device, appAt: makeApp(), ledger: &ledger, now: now),
			  case .installed(let b) = await free2.lifecycle.install(app: component(), scope: free2.scope, device: device, appAt: makeApp(), ledger: &ledger, now: now),
			  case .installed(let c) = await paid.lifecycle.install(app: component(), scope: paid.scope, device: device, appAt: makeApp(), ledger: &ledger, now: now),
			  case .installed(let d) = await org.lifecycle.install(app: component(), scope: org.scope, device: device, appAt: makeApp(), ledger: &ledger, now: now) else {
			return check(false, "install with each account")
		}
		check(a.owner?.scope == free1.scope && b.owner?.scope == free2.scope && c.owner?.scope == paid.scope && d.owner?.scope == org.scope,
			  "each installed app records the account and team that signed it (the default for the first)")
		let serials = [a, b, c, d].compactMap { $0.owner?.certificateSerial }
		check(Set(serials).count == 4 && serials == [free1, free2, paid, org].compactMap { $0.identity?.serialNumber },
			  "each account and team has its own certificate, stored under its own Keychain item")
		check(a.expiryVerified == true && c.owner?.teamKind == .individualPaid, "installs are verified from the device and keep the team kind")
		check(ledger.freeAppLimitApps == [free1.bundle, free2.bundle], "only free teams' apps count towards the 3-app limit, across accounts")

		// iOS's limit is per device: a third free app from either account fits, a fourth does not.
		guard case .installed = await free1.lifecycle.install(app: component("com.example.third"), scope: nil, device: device, appAt: makeApp(bundleIdentifier: "com.example.third"), ledger: &ledger, now: now) else {
			return check(false, "third free app")
		}
		let signings = free1.signer.calls
		let fourth = await free2.lifecycle.install(app: component("com.example.fourth"), scope: free2.scope, device: device, appAt: makeApp(bundleIdentifier: "com.example.fourth"), ledger: &ledger, now: now)
		check(fourth == .failed(.installSlots) && free1.signer.calls == signings, "a second account cannot get round the device's 3 free-app limit")
		guard case .installed = await paid.lifecycle.install(app: component("com.example.fifth"), scope: paid.scope, device: device, appAt: makeApp(bundleIdentifier: "com.example.fifth"), ledger: &ledger, now: now) else {
			return check(false, "paid app beyond 3")
		}
		check(true, "a paid team's app is not held to the free 3-app limit")

		// A provisioner works only for its own account.
		let crossed = await free1.lifecycle.install(app: component("com.example.cross"), scope: free2.scope, device: device, appAt: makeApp(bundleIdentifier: "com.example.cross"), ledger: &ledger, now: now)
		check(crossed == .failed(.signedOut) && free1.signer.calls == signings + 1, "one account's provisioner refuses to provision for another")

		// Refreshes go to the app's own account and team.
		free1.clock.advance(days: 4.5)
		let later = free1.clock.now
		let route = await free1.directory.route(free2.bundle, ledger: ledger)
		check(route == .refresh(try! await free1.directory.authorize(free2.scope)), "an app's refresh is routed to the account and team that signed it")
		guard case .installed(let refreshedB) = await free2.lifecycle.refresh(free2.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: later, userInitiated: true) else {
			return check(false, "refresh second account")
		}
		check(refreshedB.owner?.scope == free2.scope && refreshedB.owner?.certificateSerial == b.owner?.certificateSerial,
			  "a refresh keeps the owner and reuses its certificate")

		// Signing out one account leaves the others signed in and its assets kept.
		try! await free1.directory.signOut(free2.account)
		let blocked = await free1.directory.route(free2.bundle, ledger: ledger)
		let free1Route = await free1.directory.route(free1.bundle, ledger: ledger)
		if case .refresh(let granted) = free1Route { check(granted.scope == free1.scope && blocked == .blocked(.signedOut), "signing out one account blocks only its own refreshes") }
		else { check(false, "first account still routes") }
		let afterSignOut = await free2.lifecycle.refresh(free2.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: later, userInitiated: true)
		check(afterSignOut == .failed(.signedOut) && ledger.records[free2.bundle]?.owner?.scope == free2.scope,
			  "a signed-out account's app is not refreshed and is never given to another account")
		check(free2.identity != nil && free1.identity != nil, "signing out keeps every account's signing identity")
		let calls = free1.signer.calls
		let explicit = await free2.lifecycle.install(app: component("com.example.notes"), scope: free2.scope, device: device, appAt: makeApp(), ledger: &ledger, now: later)
		check(explicit == .failed(.signedOut) && free1.signer.calls == calls, "a signed-out account cannot sign, even when chosen explicitly")
		try! await free1.directory.setDefault(free2.scope)
		let viaDefault = await free1.lifecycle.install(app: component("com.example.default"), scope: nil, device: device, appAt: makeApp(bundleIdentifier: "com.example.default"), ledger: &ledger, now: later)
		check(viaDefault == .failed(.signedOut) && free1.signer.calls == calls, "a signed-out default account is not replaced by another one")
		try! await free1.directory.setDefault(free1.scope)

		ledger.resolve(.signedOut, account: free1.account)
		check(ledger.records[free2.bundle]?.lastFailure?.reason == .signedOut, "resolving one account's sign-in leaves another's failures")
		await free2.signInAgain()
		ledger.resolve(.signedOut, account: free2.account)
		free1.clock.advance(days: 1)
		let again = await free2.lifecycle.refresh(free2.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: free1.clock.now, userInitiated: false)
		guard case .installed = again else { return check(false, "refresh after signing in again: \(again)") }
		check(true, "after signing in again the account's apps refresh automatically")

		// A failure in one account does not affect another.
		await free2.portal.fail(.appIDs, with: .network)
		free1.clock.advance(days: 1)
		let failing = await free2.lifecycle.refresh(free2.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: free1.clock.now, userInitiated: true)
		let fine = await free1.lifecycle.refresh(free1.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: free1.clock.now, userInitiated: true)
		if case .installed = fine { check(failing == .failed(.network), "one account's portal failure leaves the others working") } else { check(false, "isolation: \(fine)") }
		await free2.portal.fail(.appIDs, with: nil)

		// The device cannot report the expiry: installed, but never a successful refresh.
		await free1.device.setUnverifiable(true)
		free1.clock.advance(days: 1)
		let unverified = await free1.lifecycle.refresh(free1.bundle, app: component(), device: device, appAt: makeApp(), ledger: &ledger, now: free1.clock.now, userInitiated: true)
		check(unverified == .failed(.notVerified) && ledger.records[free1.bundle]?.lastFailure?.reason == .notVerified,
			  "a refresh whose expiry cannot be read back is recorded as not verified")
		await free1.device.setUnverifiable(false)

		// Removing an account: confirmation, its secrets gone, its apps kept but never refreshed.
		let plan = try! await free1.directory.removalPlan(for: paid.account, ledger: ledger)
		check(plan.dependentApps == [paid.bundle, "com.example.fifth.SIMPAID001", org.bundle].sorted(), "removal lists every app the account signed, across its teams")
		let stale = ZagAccountRemovalPlan(accountID: paid.account, maskedAppleID: plan.maskedAppleID, teams: plan.teams, dependentApps: [paid.bundle])
		do { try await free1.directory.remove(stale.confirm(.keepUntilExpiry), ledger: &ledger); check(false, "stale removal") }
		catch { check(error as? ZagAccountError == .removalNotConfirmed && paid.identity != nil, "a confirmation that does not list the current apps is refused") }
		try! await free1.directory.remove(plan.confirm(.keepUntilExpiry), ledger: &ledger)
		let left = free1.secrets.items.keys
		check(!left.contains { $0.hasPrefix("\(paid.account).") } && left.contains { $0.hasPrefix("\(free1.account).") } && left.contains { $0.hasPrefix("\(free2.account).") },
			  "removal deletes every Keychain item of that account (both teams) and none of the others'")
		let removedRoute = await free1.directory.route(paid.bundle, ledger: ledger)
		check(removedRoute == .blocked(.accountRemoved) && ledger.records[org.bundle]?.owner?.scope == org.scope
			  && ledger.begin(paid.bundle, at: free1.clock.now, userInitiated: true) == .ownerRemoved
			  && !ledger.refreshAllOrder(at: free1.clock.now + 30 * 86_400, minimum: .normal).contains(paid.bundle),
			  "its apps stay installed with their owner, and never refresh or move to another account")
		let remaining = await free1.directory.registry.accounts.map(\.id)
		let second = try? await free1.directory.authorize(free2.scope)
		let first = try? await free1.directory.authorize(free1.scope)
		let stillSignedIn = second != nil && first != nil
		check(Set(remaining) == [free1.account, free2.account] && stillSignedIn, "the other accounts stay signed in")
		check(free1.stagingIsEmpty && free2.stagingIsEmpty && paid.stagingIsEmpty, "no key file is left behind by any account")
	}
}

extension Result where Failure == ZagProvisioningFailure {
	var value: Success? { if case .success(let v) = self { return v } else { return nil } }
}
