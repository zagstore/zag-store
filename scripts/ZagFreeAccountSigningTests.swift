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
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID) throws { lock.withLock { items["\(account).\(kind)"] = secret } }
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID) throws -> Data? { lock.withLock { items["\(account).\(kind)"] } }
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID) throws { lock.withLock { items["\(account).\(kind)"] = nil } }
	var identity: ZagSigningIdentity? { items["\(account).signingPrivateKey"].flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) } }
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

/// Stands in for the RPPairing installer: "installs" by copying, then reads
/// the expiry back from the installed app, as the real check will.
actor TestDevice: ZagFreeAccountInstaller {
	enum Failure: Error { case installFailed }
	private(set) var installs = 0
	var failNext = false
	var reportOldExpiryNext: Date?
	func setFailNext() { failNext = true }
	func setReportOldExpiryNext(_ date: Date) { reportOldExpiryNext = date }

	func install(signedApp: URL, bundleIdentifier: String) async throws -> (profileExpiresAt: Date, certificateExpiresAt: Date) {
		if failNext { failNext = false; throw Failure.installFailed }
		let destination = work.appendingPathComponent("device/\(bundleIdentifier).app")
		try? FileManager.default.removeItem(at: destination)
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: signedApp, to: destination)
		installs += 1
		let profile = try Certificate.decode(profileData: Data(contentsOf: destination.appendingPathComponent("embedded.mobileprovision")))!
		let certificate = (profile.DeveloperCertificates ?? []).compactMap { ZagCertificateInspection(der: $0)?.expiresAt }.min()!
		if let old = reportOldExpiryNext { reportOldExpiryNext = nil; return (old, certificate) }
		return (profile.ExpirationDate, certificate)
	}
}

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

struct Harness {
	let clock = TestClock()
	let secrets = MemorySecrets()
	let diagnostics = ZagFreeAccountDiagnostics()
	let signer = RecordingSigner()
	let device = TestDevice()
	let staging: URL
	let portal: ZagSimulatedDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner
	let lifecycle: ZagFreeAccountLifecycle
	var adapter: ZagFreeAccountSigningAdapter { lifecycle.adapter }

	init(issuer: OpenSSLIssuer = OpenSSLIssuer()) {
		let clock = self.clock
		staging = work.appendingPathComponent("staging-\(UUID().uuidString)")
		try! FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		portal = ZagSimulatedDeveloperPortal(team: team, clock: { clock.now }, issuer: issuer)
		provisioner = ZagFreeAccountProvisioner(
			portal: portal, keys: ZagSecuritySigningKeyFactory(), secrets: secrets,
			diagnostics: diagnostics, now: { clock.now }
		)
		lifecycle = ZagFreeAccountLifecycle(
			provisioner: provisioner,
			adapter: ZagFreeAccountSigningAdapter(signer: signer, workRoot: staging),
			installer: device,
			secrets: secrets
		)
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
		print("SUCCESS: \(passed) free-account signing and lifecycle checks passed")
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
		let h = Harness()
		guard let result = await h.provisioner.provision(request()).value else { return check(false, "provisioning with real keys") }
		guard let identity = h.secrets.identity else { return check(false, "identity stored") }
		check(identity.serialNumber == result.certificateSerial && result.changes.createdCertificate,
			  "provisioning makes a key, gets a certificate for it and stores the identity")
		let issued = await h.portal.issuedCertificates.count
		check(issued == 1, "one certificate request was sent")

		let app = makeApp()
		let record: ZagSignedAppRecord
		do { record = try h.adapter.sign(appAt: app, with: result, identity: identity, now: h.clock.now) } catch {
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
		let h = Harness()
		guard let result = await h.provisioner.provision(request()).value, let identity = h.secrets.identity else { return check(false, "provision") }

		let withExtension = makeApp(extensions: ["Widget"])
		do {
			_ = try h.adapter.sign(appAt: withExtension, with: result, identity: identity, now: h.clock.now)
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
			_ = try h.adapter.sign(appAt: makeApp(), with: result, identity: other, now: h.clock.now)
			check(false, "identity mismatch")
		} catch {
			check(error as? ZagFreeAccountSigningError == .identityMismatch && h.signer.calls == 0, "an identity that is not the profiles' certificate is refused")
		}
		do {
			_ = try h.adapter.sign(appAt: makeApp(bundleIdentifier: "com.example.other"), with: result, identity: identity, now: h.clock.now)
			check(false, "bundle mismatch")
		} catch {
			check(error as? ZagFreeAccountSigningError == .bundleMismatch(expected: "com.example.notes", found: "com.example.other") && h.signer.calls == 0,
				  "an app that is not the provisioned one is refused")
		}

		let broken = makeApp()
		try! Data("not a Mach-O".utf8).write(to: broken.appendingPathComponent("Notes"))
		do {
			_ = try h.adapter.sign(appAt: broken, with: result, identity: identity, now: h.clock.now)
			check(false, "broken executable")
		} catch {
			if case .signer? = error as? ZagFreeAccountSigningError { check(true, "a signing failure from Zsign is reported") } else { check(false, "signer error: \(error)") }
		}
		check(h.stagingIsEmpty, "the key file is removed after a failed signing too")

		// Zsign says "Signed OK" for a certificate whose issuer it does not
		// recognise, but makes no CMS signature; the adapter must catch that.
		let unrecognised = Harness(issuer: OpenSSLIssuer(authority: otherAuthority))
		guard let otherResult = await unrecognised.provisioner.provision(request()).value, let otherIdentity = unrecognised.secrets.identity else {
			return check(false, "provision with the other authority")
		}
		do {
			_ = try unrecognised.adapter.sign(appAt: makeApp(), with: otherResult, identity: otherIdentity, now: unrecognised.clock.now)
			check(false, "unsigned result accepted")
		} catch {
			check(error as? ZagFreeAccountSigningError == .verification("no signature") && unrecognised.stagingIsEmpty,
				  "a result Zsign reports as signed but that has no CMS signature is refused")
		}
	}

	// MARK: Lifecycle

	static func lifecycle() async {
		let h = Harness()
		var ledger = ZagRefreshLedger()
		let bundle = "com.example.notes.\(team)"
		let start = h.clock.now

		guard case .installed(let first) = await h.lifecycle.install(request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now) else {
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
		guard case .installed(let refreshed) = await h.lifecycle.refresh(bundle, request: request(installed: []), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: false) else {
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
		guard case .installed(let revived) = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true) else {
			return check(false, "refresh after expiry")
		}
		let calls = await h.portal.calls
		check(calls.filter { $0 == .registerAppID }.count == 2 && revived.expiresAt > h.clock.now + 6 * 86_400,
			  "an expired app is brought back: its lapsed App ID is registered again")
		check(h.stagingIsEmpty && h.signer.calls == 3, "three signings, nothing left on disk")
	}

	static func lifecycleFailures() async {
		let h = Harness()
		var ledger = ZagRefreshLedger()
		let bundle = "com.example.notes.\(team)"
		guard case .installed = await h.lifecycle.install(request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now) else { return check(false, "install") }

		h.clock.advance(days: 4.5)
		let old = ledger.records[bundle]!.profileExpiresAt
		await h.device.setReportOldExpiryNext(old)
		let stale = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(stale == .failed(.notVerified) && ledger.records[bundle]?.lastFailure?.reason == .notVerified && ledger.records[bundle]?.profileExpiresAt == old,
			  "a refresh the device does not confirm is recorded as not verified, not as done")

		await h.device.setFailNext()
		let failed = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(failed == .failed(.installFailed), "an installation failure is recorded")
		let automatic = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: false)
		if case .notStarted(.backingOff) = automatic { check(true, "automatic refreshes back off after failures") } else { check(false, "backoff: \(automatic)") }

		await h.portal.fail(.appIDs, with: .sessionRejected)
		let signedOut = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		let held = ledger.begin(bundle, at: h.clock.now + 86_400, userInitiated: false)
		check(signedOut == .failed(.signedOut) && held == .backingOff(until: .distantFuture), "an expired session stops automatic refreshes until the user signs in")
		ledger.finishFailed(bundle, reason: .cancelled, at: h.clock.now)
		ledger.resolve(.cancelled)
		await h.portal.fail(.appIDs, with: nil)

		let signings = h.signer.calls
		await h.portal.tamperProfiles(.missingDevice)
		let tampered = await h.lifecycle.refresh(bundle, request: request(), appAt: makeApp(), ledger: &ledger, now: h.clock.now, userInitiated: true)
		check(tampered == .failed(.signingFailed) && h.signer.calls == signings, "a profile without this device is never used to sign")
		await h.portal.tamperProfiles(nil)

		let full = await h.lifecycle.install(request(installed: ["a.\(team)", "b.\(team)", bundle], app: "com.example.fourth"), appAt: makeApp(bundleIdentifier: "com.example.fourth"), ledger: &ledger, now: h.clock.now)
		check(full == .failed(.installSlots) && h.signer.calls == signings, "a fourth app is refused before anything is signed")

		let limited = Harness()
		await limited.portal.seedCertificate(serial: "AAAA", expiresAt: limited.clock.now + 100 * 86_400)
		await limited.portal.seedCertificate(serial: "BBBB", expiresAt: limited.clock.now + 200 * 86_400)
		var other = ZagRefreshLedger()
		let refused = await limited.lifecycle.install(request(), appAt: makeApp(), ledger: &other, now: limited.clock.now)
		let remaining = await limited.portal.issuedCertificates.map(\.serialNumber)
		check(refused == .failed(.signingFailed) && remaining == ["AAAA", "BBBB"] && limited.signer.calls == 0,
			  "at the certificate limit nothing is revoked and nothing is signed")

		let disabled = ZagFreeAccountLifecycle(
			provisioner: ZagFreeAccountProvisioner(secrets: MemorySecrets()),
			adapter: ZagFreeAccountSigningAdapter(signer: limited.signer, workRoot: limited.staging),
			installer: limited.device, secrets: MemorySecrets()
		)
		var none = ZagRefreshLedger()
		let unavailable = await disabled.install(request(), appAt: makeApp(), ledger: &none, now: Date())
		check(unavailable == .failed(.signedOut) && limited.signer.calls == 0 && ZagLivePortal.isEnabled == false && ZagLiveAuthentication.isEnabled == false && ZagAnisetteLive.isEnabled == false,
			  "the default build cannot provision or sign: live portal, sign-in and anisette are off")
	}
}

extension Result where Failure == ZagProvisioningFailure {
	var value: Success? { if case .success(let v) = self { return v } else { return nil } }
}
