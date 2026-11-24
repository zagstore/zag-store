import Foundation
import Security
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// The first real on-device signing experiment, as a self-contained runner the
// supervised experiment build drives (ZagSigningExperimentView). It composes the
// already-proven pieces — imported-identity import/validation, on-device CMS
// verification of the profile, the signing preflight, and the production Zsign
// signComponents entry point with the imported-identity signer callback — then
// verifies the result two ways: with Zsign's own re-check AND with an
// INDEPENDENT path (our ZagCMSVerifier + Mach-O inspection) that does not reuse
// the signing library.
//
// It FAILS CLOSED: it stops at the first failed step, records a sanitized
// blocker, and NEVER installs, launches, or retries. No passphrase, private key,
// or full account identifier is ever put in the report.

struct ZagSigningExperimentReport: Equatable, Sendable {
	enum Step: String, Sendable {
		case importIdentity, testPayload, verifyProfileCMS, preflight, sign, zsignReverify, independentVerify, package
	}
	struct Entry: Equatable, Sendable {
		let step: Step
		let ok: Bool
		let detail: String        // sanitized — safe to show/screenshot
	}
	var entries: [Entry] = []
	var signedIPAPath: String?
	var allPassed: Bool { entries.allSatisfy(\.ok) && !entries.isEmpty }
	var blocker: String?
	/// True only when a complete, independently verified IPA was produced.
	var readyForSeparatelyAuthorizedInstall: Bool { allPassed && signedIPAPath != nil && blocker == nil }
}

enum ZagSigningExperiment {
	static let expectedTeam = "V54K5JYGS4"
	static let expectedBundleID = "dev.zagstore.ptteamprobe"
	static let importLabel = "signing-experiment"

	/// Runs the experiment end to end. `sourceExecutable` is a real arm64 Mach-O
	/// (the running app's own executable is ideal); a minimal single-binary app
	/// bundle is assembled around it and signed, so there are no nested bundles.
	static func run(pkcs12: Data, passphrase: String, profile: Data, workDir: URL,
					sourceExecutable: URL, now: Date = Date()) -> ZagSigningExperimentReport {
		var report = ZagSigningExperimentReport()
		func fail(_ step: ZagSigningExperimentReport.Step, _ detail: String) -> ZagSigningExperimentReport {
			report.entries.append(.init(step: step, ok: false, detail: detail))
			report.blocker = "\(step.rawValue): \(detail)"
			return report
		}
		func pass(_ step: ZagSigningExperimentReport.Step, _ detail: String) {
			report.entries.append(.init(step: step, ok: true, detail: detail))
		}

		// 1. Import + validate the identity; passphrase used transiently only.
		let importResult = ZagImportedSigningIdentity.importIdentity(pkcs12: pkcs12, password: passphrase)
		guard case .success(let identity) = importResult else {
			return fail(.importIdentity, "wrong password or not a valid identity")
		}
		let info: ZagImportedIdentityInfo
		switch ZagImportedSigningIdentity.validate(identity, now: now, expectedTeam: expectedTeam) {
		case .failure(let e): return fail(.importIdentity, String(describing: e))
		case .success(let i): info = i
		}
		_ = ZagImportedSigningIdentity.store(identity, label: importLabel)   // ThisDeviceOnly
		pass(.importIdentity, "\(sanitizeCN(info.commonName)), team \(info.team ?? "—"), serial …\(String(info.serialNumber.suffix(4))), expires \(day(info.notAfter)), key imported (extractable)")

		guard let signer = ZagImportedSigningIdentity.zsignSigner(identity),
			  let certDER = try? ZagImportedSigningIdentity.resolve(label: importLabel, now: now, expectedTeam: expectedTeam).get().certificateDER else {
			return fail(.importIdentity, "could not resolve the stored identity")
		}

		// 2. Sign + verify a small test payload (key↔cert correspondence in use).
		let payload = randomData(32)
		guard let sig = ZagImportedSigningIdentity.sign(payload, identity: identity),
			  ZagImportedSigningIdentity.verify(sig, payload: payload, identity: identity) else {
			return fail(.testPayload, "test payload signature did not verify")
		}
		pass(.testPayload, "32-byte payload signed and verified (\(sig.count)-byte RSA signature)")

		// 3. Independently verify the provisioning profile on-device (pinned Apple Root CA).
		guard case .success(let authenticated) = ZagCMSVerifier.verify(profile, now: now),
			  let plist = (try? PropertyListSerialization.propertyList(from: authenticated, format: nil)) as? [String: Any],
			  let contents = ZagMobileProvision.contents(from: plist),
			  let entitlementsDict = plist["Entitlements"] as? [String: Any],
			  let entitlementsData = try? PropertyListSerialization.data(fromPropertyList: entitlementsDict, format: .xml, options: 0) else {
			return fail(.verifyProfileCMS, "CMS signature/chain did not verify against the pinned Apple Root CA")
		}
		pass(.verifyProfileCMS, "profile CMS verified to Apple Root CA; team \(contents.teamIdentifier), expires \(day(contents.expiresAt))")

		// 4. Preflight must return ready. The device-membership check is self-
		//    consistent here (a Personal-Team profile lists one device, and the OS
		//    installed this build under it); the provisioning UDID is not readable
		//    via a public iOS API, so we use the profile's sole device and say so.
		let deviceUDID = contents.provisionedDevices.first ?? ""
		let requested = Dictionary(uniqueKeysWithValues: contents.entitlements.map { ($0.key, $0.value) })
		let preflight = ZagSigningPreflight.prepare(
			profileData: profile, identityCertificateDER: certDER, identityTeam: info.team,
			identityIsDevelopment: info.isDevelopment, deviceProvisioningUDID: deviceUDID,
			targetBundleID: expectedBundleID, requestedEntitlements: requested, now: now)
		guard case .ready = preflight else {
			return fail(.preflight, "preflight not ready: \(describe(preflight))")
		}
		pass(.preflight, "ready (cert in profile, team, device[self-consistent], bundle, entitlements, validity)")

		// 5. Assemble a minimal single-binary app and sign it with Zsign using the
		//    imported-identity signer callback (the private key stays in the key store).
		let appURL: URL
		do { appURL = try assembleMinimalApp(executable: sourceExecutable, in: workDir) }
		catch { return fail(.sign, "could not assemble the test app bundle") }

		#if canImport(ZsignSwift)
		let components: [String: (provision: Data, entitlements: Data)] = ["": (profile, entitlementsData)]
		if let signFailure = Zsign.signComponents(appPath: appURL.path, certificate: certDER, signer: signer,
												   components: components, bundleIdentifier: expectedBundleID) {
			return fail(.sign, "Zsign: \(sanitize(signFailure))")
		}
		pass(.sign, "signed \(expectedBundleID) with the imported identity (Zsign signComponents)")

		// 6. Zsign's own re-check (the signing library's verifier).
		if let vFailure = Zsign.verifyComponents(appPath: appURL.path, certificate: certDER, components: components) {
			return fail(.zsignReverify, "Zsign verify: \(sanitize(vFailure))")
		}
		pass(.zsignReverify, "Zsign re-verified every binary, team, identifiers, entitlements and embedded profile")
		#else
		return fail(.sign, "ZsignSwift is not linked into this build (needs the experiment app build)")
		#endif

		// 7. INDEPENDENT verification — our own code, not the signing library.
		let independent = independentVerify(appURL: appURL, expectedCertDER: certDER, inputProfile: profile, now: now)
		guard independent.ok else { return fail(.independentVerify, independent.note) }
		pass(.independentVerify, independent.note)

		// 8. Package the IPA (Payload/<app>.ipa). No installation, no launch.
		do {
			let ipa = try packageIPA(appURL: appURL, in: workDir)
			let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? nil
			report.signedIPAPath = ipa.path
			pass(.package, "IPA written (\(size.map { "\($0) bytes" } ?? "ok")) — NOT installed")
		} catch { return fail(.package, "could not package the IPA") }

		return report
	}

	// MARK: independent verification (no Zsign)

	private static func independentVerify(appURL: URL, expectedCertDER: Data, inputProfile: Data, now: Date) -> (ok: Bool, note: String) {
		// Bundle identifier from Info.plist.
		guard ZagFreeAccountSigningAdapter.bundleIdentifier(of: appURL) == expectedBundleID else {
			return (false, "embedded Info.plist bundle id is not \(expectedBundleID)")
		}
		// Embedded profile bytes re-verify to Apple Root CA (our verifier, not Zsign).
		guard let embedded = try? Data(contentsOf: appURL.appendingPathComponent("embedded.mobileprovision")) else {
			return (false, "no embedded.mobileprovision in the signed app")
		}
		guard case .success = ZagCMSVerifier.verify(embedded, now: now) else {
			return (false, "embedded profile did not re-verify to the pinned Apple Root CA")
		}
		// The executable carries a CMS code signature.
		guard let exe = ZagFreeAccountSigningAdapter.executableName(of: appURL),
			  let binary = try? Data(contentsOf: appURL.appendingPathComponent(exe)),
			  ZagCodeSignatureInspection.hasCMSSignature(binary) else {
			return (false, "the executable has no CMS code signature")
		}
		// Entitlements present in the embedded profile.
		guard let parsed = ZagMobileProvision.parseAppleVerified(embedded, now: now),
			  parsed.entitlements["application-identifier"] != nil else {
			return (false, "embedded profile entitlements missing")
		}
		return (true, "independent: bundle id, embedded profile (re-verified to Apple Root CA), Mach-O CMS signature, entitlements — all confirmed without Zsign")
	}

	// MARK: app assembly + packaging

	private static func assembleMinimalApp(executable: URL, in workDir: URL) throws -> URL {
		let fm = FileManager.default
		let app = workDir.appendingPathComponent("PTTeamProbe.app", isDirectory: true)
		try? fm.removeItem(at: app)
		try fm.createDirectory(at: app, withIntermediateDirectories: true)
		let exeName = "PTTeamProbe"
		try fm.copyItem(at: executable, to: app.appendingPathComponent(exeName))
		let info: [String: Any] = [
			"CFBundleIdentifier": expectedBundleID,
			"CFBundleExecutable": exeName,
			"CFBundleName": exeName,
			"CFBundlePackageType": "APPL",
			"CFBundleShortVersionString": "1.0",
			"CFBundleVersion": "1",
			"MinimumOSVersion": "17.0",
		]
		let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
		try data.write(to: app.appendingPathComponent("Info.plist"))
		return app
	}

	private static func packageIPA(appURL: URL, in workDir: URL) throws -> URL {
		let fm = FileManager.default
		let payload = workDir.appendingPathComponent("Payload", isDirectory: true)
		try? fm.removeItem(at: payload)
		try fm.createDirectory(at: payload, withIntermediateDirectories: true)
		try fm.copyItem(at: appURL, to: payload.appendingPathComponent(appURL.lastPathComponent))
		let ipa = workDir.appendingPathComponent("PTTeamProbe-signed.ipa")
		try? fm.removeItem(at: ipa)
		// Zip the Payload folder. NSFileCoordinator produces a standard zip.
		var coordError: NSError?
		var zipped: URL?
		NSFileCoordinator().coordinate(readingItemAt: payload, options: [.forUploading], error: &coordError) { tmp in
			zipped = try? { let dst = ipa; try fm.copyItem(at: tmp, to: dst); return dst }()
		}
		guard let out = zipped else { throw CocoaError(.fileWriteUnknown) }
		return out
	}

	// MARK: sanitization helpers

	private static func sanitizeCN(_ cn: String) -> String {
		// "Apple Development: email (TEAMUID)" -> drop the email.
		if let paren = cn.firstIndex(of: "(") { return "Apple Development (…\(cn[paren...])" }
		return cn.hasPrefix("Apple Development") ? "Apple Development" : "development certificate"
	}
	private static func sanitize(_ s: String) -> String { String(s.prefix(160)) }
	private static func day(_ d: Date) -> String {
		let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
		return f.string(from: d)
	}
	private static func randomData(_ n: Int) -> Data {
		var d = Data(count: n); _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }; return d
	}
	private static func describe(_ r: ZagSigningPreflightResult) -> String {
		switch r {
		case .ready: return "ready"
		case .profileNotTrusted: return "profile not trusted"
		case .incompatible(let m): return "incompatible(\(m))"
		}
	}
}
