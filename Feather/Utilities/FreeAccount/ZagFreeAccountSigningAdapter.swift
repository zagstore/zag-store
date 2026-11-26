import Foundation
#if canImport(ZsignSwift)
import ZsignSwift
#endif

enum ZagFreeAccountSigning {
	#if ZAG_ZSIGN_STRICT && (canImport(ZagAppleAuth) || ZAG_LIVE_EXPERIMENT)
	/// G5 experiment build only (plan §3.2): the campaign's one test app.
	static let isEnabled = true
	#else
	/// Signing with Apple Account certificates is not enabled in this version.
	static let isEnabled = false
	#endif
}

/// Signing availability for the native, paid and simulated account paths.
struct ZagFreeAccountSigningGate: Equatable, Sendable {
	let isOpen: Bool

	private init(isOpen: Bool) { self.isOpen = isOpen }

	static let production = ZagFreeAccountSigningGate(isOpen: ZagFreeAccountSigning.isEnabled)
	/// The adapter as the paid developer-account method uses it: open only with
	/// that method's own gate, so it never depends on (or opens) free-account
	/// signing. Closed in every release build.
	static let developerAccount = ZagFreeAccountSigningGate(isOpen: ZagSigningMethodAvailability.developerAccountEnabled)
	#if DEBUG
	static let simulationOnly = ZagFreeAccountSigningGate(isOpen: true)
	#endif
}

/// Signs a bundle in place.
protocol ZagCodeSigner: Sendable {
	func sign(app: URL, profile: URL, privateKey: URL, entitlements: URL, bundleIdentifier: String) throws
}

/// A signer's own failure message (Zsign's lists the files it could not sign).
struct ZagSignerFailure: Error, Equatable { let message: String }

/// The signing step of the pipeline: a provisioned app plus its identity and
/// authorisation become a signed-app record. `ZagFreeAccountSigningAdapter` is
/// the production implementation (Zsign); a coordinator depends on this seam so
/// it can be tested without running a real signer.
protocol ZagAppSigning: Sendable {
	func sign(
		appAt app: URL,
		with result: ZagProvisioningResult,
		identity: ZagSigningIdentity,
		authorization: ZagSigningAuthorization,
		now: Date
	) throws -> ZagSignedAppRecord
}

#if canImport(ZsignSwift) || ZAG_ZSIGN_TESTS
/// The existing Zsign signer, called as `ZsignHandler` calls it. Zsign reads
/// the private key file directly (no PKCS #12) and takes the matching
/// certificate from the profile. It signs every nested bundle with the main
/// app's entitlements, so apps with extensions are refused before it runs.
struct ZagZsignCodeSigner: ZagCodeSigner {
	typealias Failure = ZagSignerFailure

	func sign(app: URL, profile: URL, privateKey: URL, entitlements: URL, bundleIdentifier: String) throws {
		var reported: Error?
		let succeeded = Zsign.sign(
			appPath: app.path,
			provisionPath: profile.path,
			p12Path: privateKey.path,
			p12Password: "",
			entitlementsPath: entitlements.path,
			customIdentifier: bundleIdentifier,
			removeProvision: true, // true embeds the profile (see ZsignHandler)
			completion: { _, error in reported = error }
		)
		if let reported { throw Failure(message: reported.localizedDescription) }
		guard succeeded else { throw Failure(message: "Zsign failed without returning an error.") }
	}
}
#endif

enum ZagFreeAccountSigningError: LocalizedError, Equatable {
	/// Free-account signing is not enabled in this build.
	case disabled
	/// No valid authorisation for the result's account and team.
	case notAuthorized
	/// The stored identity is not the certificate the profiles were issued for.
	case identityMismatch
	case bundleMismatch(expected: String, found: String?)
	/// The pinned Zsign signs nested bundles with the main app's entitlements
	/// and profile; a free team needs each extension signed for its own App ID.
	case extensionsNeedPerBundleSigning([String])
	case staging
	case signer(String)
	case verification(String)
	/// The identity's key is in the Keychain, and this build has no Keychain
	/// signing (it needs ZAG_ZSIGN_STRICT).
	case keychainSigningUnavailable
	/// The identity's Keychain key item is missing or unreadable.
	case keychainKeyMissing
	/// The identity carries key bytes, and writing them for the signer is
	/// not allowed (`allowsKeyFiles`).
	case keyFilesNotAllowed
	var errorDescription: String? {
		switch self {
		case .disabled: "Apple Account signing is unavailable in this build."
		case .notAuthorized: "The Apple Account session expired before signing completed."
		case .identityMismatch: "The signing certificate does not match the provisioning profile."
		case .bundleMismatch: "The app’s bundle identifier changed before signing."
		case .extensionsNeedPerBundleSigning: "One or more app extensions could not be matched to provisioning profiles."
		case .staging: "The app’s signing files could not be prepared."
		case .signer(let reason): "Zsign could not sign the app. \(reason)"
		case .verification(let reason): "The signed app failed verification. \(reason)"
		case .keychainSigningUnavailable: "Keychain signing is unavailable in this build."
		case .keychainKeyMissing: "The signing key could not be read from this iPhone’s Keychain."
		case .keyFilesNotAllowed: "This signing method requires a Keychain-backed signing key."
		}
	}
}

/// Signs one provisioned app with Zsign.
///
/// An identity whose key is a Keychain key item (`keyIsInKeychain`) is signed
/// through the key reference only, with Zsign's raw-signer callback; no key
/// bytes leave the Keychain (ZagStrictComponentSigning.swift, compiled with
/// ZAG_ZSIGN_STRICT). That is the only path for the supervised experiment.
///
/// The older path writes the key for the signer, readable by this user
/// alone, in a private folder removed (after overwriting the key) whether
/// signing succeeds or not; see SIGNING-KEY-SECURITY.md for what deletion
/// does and does not guarantee. It is refused unless `allowsKeyFiles` is set,
/// which only tests of that path do.
struct ZagFreeAccountSigningAdapter: Sendable {
	let signer: ZagCodeSigner
	var workRoot = FileManager.default.temporaryDirectory
	var gate = ZagFreeAccountSigningGate.production
	/// The Keychain key items, for identities whose key is in the Keychain.
	var keychainKeys: ZagKeychainSigningKeys?
	var allowsKeyFiles = false
	#if DEBUG
	/// Tests only: a local test authority Zsign may chain to.
	var testIntermediates: [Data] = []
	#endif

	func sign(
		appAt app: URL,
		with result: ZagProvisioningResult,
		identity: ZagSigningIdentity,
		authorization: ZagSigningAuthorization,
		now: Date
	) throws -> ZagSignedAppRecord {
		guard gate.isOpen else { throw ZagFreeAccountSigningError.disabled }
		guard authorization.isValid(at: now), authorization.scope.teamID == result.team else {
			throw ZagFreeAccountSigningError.notAuthorized
		}
		guard identity.serialNumber == result.certificateSerial else { throw ZagFreeAccountSigningError.identityMismatch }
		if identity.keyIsInKeychain {
			#if ZAG_ZSIGN_STRICT
			return try signWithKeychainKey(appAt: app, with: result, identity: identity, authorization: authorization, now: now)
			#else
			throw ZagFreeAccountSigningError.keychainSigningUnavailable
			#endif
		}
		guard allowsKeyFiles else { throw ZagFreeAccountSigningError.keyFilesNotAllowed }

		let found = Self.bundleIdentifier(of: app)
		guard found == result.app.originalBundleIdentifier || found == result.app.bundleIdentifier else {
			throw ZagFreeAccountSigningError.bundleMismatch(expected: result.app.originalBundleIdentifier, found: found)
		}
		let nested = Self.nestedBundles(in: app)
		guard nested.isEmpty, result.extensions.isEmpty else {
			throw ZagFreeAccountSigningError.extensionsNeedPerBundleSigning(nested.isEmpty ? result.extensions.map(\.originalBundleIdentifier) : nested)
		}

		let fileManager = FileManager.default
		let staging = workRoot.appendingPathComponent("zag-free-account-signing-\(UUID().uuidString)", isDirectory: true)
		let keyFile = staging.appendingPathComponent("signing.key")
		do {
			try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [
				.posixPermissions: 0o700,
				.protectionKey: FileProtectionType.completeUnlessOpen
			])
		} catch {
			throw ZagFreeAccountSigningError.staging
		}
		defer {
			if let handle = try? FileHandle(forWritingTo: keyFile) {
				handle.write(Data(count: identity.privateKey.count))
				try? handle.synchronize()
				try? handle.close()
			}
			try? fileManager.removeItem(at: staging)
		}

		let profileFile = staging.appendingPathComponent("embedded.mobileprovision")
		let entitlementsFile = staging.appendingPathComponent("entitlements.plist")
		guard fileManager.createFile(atPath: keyFile.path, contents: identity.privateKey, attributes: [
				.posixPermissions: 0o600,
				.protectionKey: FileProtectionType.completeUnlessOpen
			  ]),
			  let entitlements = try? PropertyListSerialization.data(fromPropertyList: result.app.entitlements.dictionary, format: .xml, options: 0),
			  (try? result.app.profile.data.write(to: profileFile)) != nil,
			  (try? entitlements.write(to: entitlementsFile)) != nil else {
			throw ZagFreeAccountSigningError.staging
		}

		do {
			try signer.sign(app: app, profile: profileFile, privateKey: keyFile, entitlements: entitlementsFile, bundleIdentifier: result.app.bundleIdentifier)
		} catch let failure as ZagSignerFailure {
			throw ZagFreeAccountSigningError.signer(failure.message)
		} catch {
			throw ZagFreeAccountSigningError.signer(String(describing: type(of: error)))
		}

		// What iOS will read: the team's bundle ID and this exact profile.
		guard Self.bundleIdentifier(of: app) == result.app.bundleIdentifier else {
			throw ZagFreeAccountSigningError.verification("bundle identifier")
		}
		// The pinned Zsign reports success even when it could not make the CMS
		// signature (for a certificate it does not recognise), so look for it.
		guard let executable = Self.executableName(of: app),
			  let binary = try? Data(contentsOf: app.appendingPathComponent(executable)),
			  ZagCodeSignatureInspection.hasCMSSignature(binary) else {
			throw ZagFreeAccountSigningError.verification("no signature")
		}
		guard let embedded = try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")),
			  embedded == result.app.profile.data,
			  let parsed = try? Certificate.decode(profileData: embedded),
			  parsed.ExpirationDate == result.app.profile.expiresAt else {
			throw ZagFreeAccountSigningError.verification("embedded profile")
		}
		return ZagSignedAppRecord(
			bundleIdentifier: result.app.bundleIdentifier,
			originalBundleIdentifier: result.app.originalBundleIdentifier,
			signedAt: now,
			profileExpiresAt: result.app.profile.expiresAt,
			certificateExpiresAt: identity.expiresAt,
			owner: ZagAppOwnership(
				scope: authorization.scope,
				teamKind: authorization.teamKind,
				certificateSerial: identity.serialNumber,
				profileUUID: result.app.profile.uuid
			)
		)
	}

	static func bundleIdentifier(of app: URL) -> String? { infoValue("CFBundleIdentifier", of: app) }
	static func executableName(of app: URL) -> String? { infoValue("CFBundleExecutable", of: app) }

	private static func infoValue(_ key: String, of app: URL) -> String? {
		guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
			  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
		return plist[key] as? String
	}

	/// Extensions, App Clips and watch apps inside the app (frameworks are fine).
	static func nestedBundles(in app: URL) -> [String] {
		let root = app.resolvingSymlinksInPath()
		guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
		var found: [String] = []
		for case let url as URL in walker where ["appex", "app"].contains(url.pathExtension) {
			found.append(String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)))
		}
		return found.sorted()
	}
}

/// Reads a Mach-O file's embedded code signature (thin or universal).
enum ZagCodeSignatureInspection {
	static let codeDirectorySlot = 0
	static let cmsSlot = 0x10000

	/// Whether every slice holds a non-empty CMS signature.
	static func hasCMSSignature(_ data: Data) -> Bool {
		guard let slices = signatureBlobs(data), !slices.isEmpty else { return false }
		return slices.allSatisfy { ($0[cmsSlot]?.count ?? 0) > 8 }
	}

	/// For each slice, the signature's blobs by slot, headers included; nil
	/// when the file is not a 64-bit Mach-O or its signature cannot be read.
	static func signatureBlobs(_ data: Data) -> [[Int: Data]]? {
		let bytes = [UInt8](data)
		func big(_ at: Int) -> Int? {
			guard at >= 0, at + 4 <= bytes.count else { return nil }
			return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
		}
		func little(_ at: Int) -> Int? {
			guard at >= 0, at + 4 <= bytes.count else { return nil }
			return Int(bytes[at + 3]) << 24 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 1]) << 8 | Int(bytes[at])
		}
		func slice(at base: Int) -> [Int: Data]? {
			guard little(base) == 0xFEEDFACF, let commands = little(base + 16) else { return nil }
			var offset = base + 32
			for _ in 0..<commands {
				guard let command = little(offset), let size = little(offset + 4), size >= 8 else { return nil }
				if command == 0x1D { // LC_CODE_SIGNATURE
					guard let dataOffset = little(offset + 8) else { return nil }
					let superBlob = base + dataOffset
					guard big(superBlob) == 0xFADE0CC0, let count = big(superBlob + 8) else { return nil }
					var blobs: [Int: Data] = [:]
					for index in 0..<count {
						let entry = superBlob + 12 + index * 8
						guard let type = big(entry), let blobOffset = big(entry + 4),
							  let length = big(superBlob + blobOffset + 4), length >= 8,
							  superBlob + blobOffset + length <= bytes.count else { return nil }
						blobs[type] = Data(bytes[(superBlob + blobOffset)..<(superBlob + blobOffset + length)])
					}
					return blobs
				}
				offset += size
			}
			return [:]
		}
		if big(0) == 0xCAFEBABE, let count = big(4), count > 0 {
			var slices: [[Int: Data]] = []
			for index in 0..<count {
				guard let base = big(8 + index * 20 + 8), let blobs = slice(at: base) else { return nil }
				slices.append(blobs)
			}
			return slices
		}
		return slice(at: 0).map { [$0] }
	}
}

// MARK: - Installation

/// What a verified installation must show.
struct ZagInstallExpectation: Codable, Equatable, Sendable {
	let bundleIdentifier: String
	let profileUUID: String
	let profileExpiresAt: Date
	let certificateExpiresAt: Date
	/// The signing certificate's common name, as installation_proxy reports it.
	let signerCommonName: String?
	var teamIdentifier: String?
	/// Each extension's profile, which the device installs alongside the app's.
	var extensionProfileUUIDs: [String] = []
	var version: String?
	var build: String?
	var certificateSerial: String?
	var extensionIdentifiers: [String: String] = [:]
	var extensionProfileExpirations: [String: Date] = [:]
}

/// Compares the provisioning profiles the device reports as installed
/// (RPPairing misagent, draft PR #25) with what Zag Store installed. The
/// device does not say which app uses which profile, so profiles are
/// matched by the UUID of the exact profile Zag Store embedded; its team,
/// App ID and expiry must then be the expected ones. Anything less is not
/// success.
enum ZagInstalledProfileCheck {
	static func verify(_ expectation: ZagInstallExpectation, installedProfiles: [Data]) -> ZagInstallVerification {
		var byUUID: [String: ZagIssuedProfile] = [:]
		for data in installedProfiles {
			if let profile = try? ZagIssuedProfile(profileData: data) { byUUID[profile.uuid] = profile }
		}
		guard let app = byUUID[expectation.profileUUID] else {
			return .unverifiable("the app's profile is not among the device's installed profiles")
		}
		let team = expectation.teamIdentifier ?? app.teamIdentifier
		guard app.teamIdentifier == team else { return .mismatch("profile team") }
		guard app.entitlements.dictionary["application-identifier"] as? String == "\(team).\(expectation.bundleIdentifier)" else {
			return .mismatch("profile App ID")
		}
		guard abs(app.expiresAt.timeIntervalSince(expectation.profileExpiresAt)) < 1 else { return .mismatch("profile expiry") }
		if let serial = expectation.certificateSerial, !app.certificateSerials.contains(serial) { return .mismatch("profile certificate") }
		var earliest = app.expiresAt
		for uuid in expectation.extensionProfileUUIDs {
			guard let profile = byUUID[uuid] else { return .unverifiable("an extension's profile is not among the device's installed profiles") }
			guard profile.teamIdentifier == team else { return .mismatch("extension profile team") }
			if let bundle = expectation.extensionIdentifiers[uuid],
			   profile.entitlements.dictionary["application-identifier"] as? String != "\(team).\(bundle)" { return .mismatch("extension profile App ID") }
			if let serial = expectation.certificateSerial, !profile.certificateSerials.contains(serial) { return .mismatch("extension profile certificate") }
			if let expiry = expectation.extensionProfileExpirations[uuid], abs(profile.expiresAt.timeIntervalSince(expiry)) >= 1 {
				return .mismatch("extension profile expiry")
			}
			earliest = min(earliest, profile.expiresAt)
		}
		return .verified(profileExpiresAt: earliest, certificateExpiresAt: expectation.certificateExpiresAt)
	}

}

/// What the device reported after an installation.
enum ZagInstallVerification: Equatable, Sendable {
	case signedOnly
	/// The device itself reported this app's profile and its expiry.
	case verified(profileExpiresAt: Date, certificateExpiresAt: Date)
	/// The app is installed, but the device's expiry cannot be read back with
	/// the current RPPairing core; success is not claimed.
	case unverifiable(String)
	/// The device reports something else (another signer, an older profile).
	case mismatch(String)
	case notInstalled
}

/// Installs through the existing installer, then asks the device what it
/// installed. Only `.verified` counts as a successful install or refresh.
protocol ZagFreeAccountInstaller: Sendable {
	func install(signedApp: URL, bundleIdentifier: String) async throws
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification
}

/// The native signing entry point and offline integration tests run this same
/// sequence. The caller owns account selection, source staging and the device
/// transport. A verified install always comes from the device's read-back.
enum ZagNativeSigningProgress: Int, CaseIterable, Comparable, Sendable {
	case preparing, provisioning, signing, installing, verifying, verified

	static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

	var fraction: Double { Double(rawValue) / Double(Self.verified.rawValue) }

	var title: String {
		switch self {
		case .preparing: "Preparing App"
		case .provisioning: "Provisioning"
		case .signing: "Signing and Checking Signature"
		case .installing: "Installing"
		case .verifying: "Verifying Installation"
		case .verified: "Installed and Verified"
		}
	}
}

struct ZagNativeInstalledProfiles: Codable, Equatable, Sendable {
	struct Component: Codable, Equatable, Sendable {
		let originalBundleIdentifier: String
		let bundleIdentifier: String
		let uuid: String
		let expiresAt: Date
		var appGroups: [String]? = nil
	}
	var record: ZagSignedAppRecord
	let profiles: [Component]
}

enum ZagNativeSigningPipeline {
	enum Failure: LocalizedError {
		case missingIdentity, changedIdentity, expiryNotExtended

		var errorDescription: String? {
			switch self {
			case .missingIdentity: "Zag Store could not load the provisioned signing identity."
			case .changedIdentity: "The source app does not match the installed app and its extensions."
			case .expiryNotExtended: "Apple did not issue profiles that extend the installed app’s expiration."
			}
		}
	}

	@MainActor
	static func refreshSequentially<App>(_ apps: [App],
		refresh: (App, Int) async throws -> Void) async -> [Result<Void, Error>] {
		var results: [Result<Void, Error>] = []
		for (index, app) in apps.enumerated() {
			guard !Task.isCancelled else { break }
			do {
				try await refresh(app, index)
				results.append(.success(()))
			} catch {
				results.append(.failure(error))
			}
		}
		return results
	}

	static func run(
		_ request: ZagProvisioningRequest, authorization: ZagSigningAuthorization, app: URL,
		provisioner: ZagFreeAccountProvisioner, secrets: ZagFreeAccountSecretStore,
		signer: ZagAppSigning, installer: ZagFreeAccountInstaller,
		verifyTarget: @MainActor () throws -> Void,
		beforeSigning: @MainActor () throws -> Void = {},
		beforeInstalling: @MainActor () throws -> Void = {},
		renewing: ZagNativeInstalledProfiles? = nil,
		progress: @Sendable (ZagNativeSigningProgress) async -> Void = { _ in },
		onVerified: @Sendable (ZagNativeInstalledProfiles) async throws -> Void = { _ in },
		onSignedOnly: (@Sendable (ZagNativeInstalledProfiles, ZagInstallExpectation, URL) async throws -> Void)? = nil,
		onDeferredInstall: (@Sendable (ZagNativeInstalledProfiles, ZagInstallExpectation, URL) async throws -> Void)? = nil,
		now: @Sendable () -> Date = { Date() }
	) async throws -> ZagInstallVerification {
		await progress(.provisioning)
		let provisioned = await provisioner.provision(request, authorization: authorization)
		if case .failure(let failure) = provisioned {
			var event = "Provisioning failed at \(failure.step.rawValue)"
			if let field = failure.invalidField { event += " — Missing or invalid: \(field)" }
			if case .invalidProfile(let problem) = failure.kind { event += " — \(problem.rawValue)" }
			ZagSigningDiagnostics.record(event)
		}
		let result = try provisioned.get()
		let components = ([result.app] + result.extensions).map {
			ZagNativeInstalledProfiles.Component(originalBundleIdentifier: $0.originalBundleIdentifier,
				bundleIdentifier: $0.bundleIdentifier, uuid: $0.profile.uuid, expiresAt: $0.profile.expiresAt,
				appGroups: ($0.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String] ?? []).sorted())
		}
		if let renewing {
			let old = Set(renewing.profiles.map { [$0.originalBundleIdentifier, $0.bundleIdentifier] })
			let new = Set(components.map { [$0.originalBundleIdentifier, $0.bundleIdentifier] })
			guard old == new, renewing.record.owner?.scope == authorization.scope,
				  renewing.profiles.allSatisfy({ prior in
					prior.appGroups == nil || components.first(where: { $0.bundleIdentifier == prior.bundleIdentifier })?.appGroups == prior.appGroups
				  }) else { throw Failure.changedIdentity }
			guard result.expiresAt > renewing.record.profileExpiresAt else { throw Failure.expiryNotExtended }
		}
		try await beforeSigning()
		await progress(.signing)
		ZagSigningDiagnostics.record("Provisioning succeeded; reading Keychain identity")
		guard let data = try secrets.load(.signingPrivateKey, account: request.accountID, team: request.team) else {
			throw Failure.missingIdentity
		}
		let identity = try JSONDecoder().decode(ZagSigningIdentity.self, from: data)
		ZagSigningDiagnostics.record("Signing and verifying app signature")
		let record: ZagSignedAppRecord
		do {
			record = try signer.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: now())
			ZagSigningDiagnostics.record("App signature verification succeeded")
		} catch {
			ZagSigningDiagnostics.record("Signing or signature verification failed")
			throw error
		}
		let info = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
			.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
		let expectation = ZagInstallExpectation(
			bundleIdentifier: record.bundleIdentifier, profileUUID: result.app.profile.uuid,
			profileExpiresAt: result.app.profile.expiresAt, certificateExpiresAt: record.certificateExpiresAt,
			signerCommonName: ZagCertificateInspection(der: identity.certificate)?.commonName,
			teamIdentifier: result.team, extensionProfileUUIDs: result.extensions.map(\.profile.uuid),
			version: info?["CFBundleShortVersionString"] as? String,
			build: info?["CFBundleVersion"] as? String, certificateSerial: identity.serialNumber,
			extensionIdentifiers: Dictionary(result.extensions.map { ($0.profile.uuid, $0.bundleIdentifier) }, uniquingKeysWith: { first, _ in first }),
			extensionProfileExpirations: Dictionary(result.extensions.map { ($0.profile.uuid, $0.profile.expiresAt) }, uniquingKeysWith: { first, _ in first })
		)
		try Task.checkCancellation()
		guard result.expiresAt > now(), identity.expiresAt > now() else {
			throw ZagFreeAccountSigningError.verification("The signing certificate or provisioning profile expired before installation.")
		}
		var saved = record
		saved.expiryVerified = false
		saved.owner = .init(scope: authorization.scope, teamKind: authorization.teamKind,
			certificateSerial: identity.serialNumber, profileUUID: expectation.profileUUID)
		let signed = ZagNativeInstalledProfiles(record: saved, profiles: components)
		if let onSignedOnly {
			try await onSignedOnly(signed, expectation, app)
			ZagSigningDiagnostics.record("Signed app saved for later installation")
			return .signedOnly
		}
		try await verifyTarget()
		do { try await beforeInstalling() }
		catch {
			try await onDeferredInstall?(signed, expectation, app)
			throw error
		}
		await progress(.installing)
		ZagSigningDiagnostics.record("Installing via RPPairing")
		do { try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier) }
		catch {
			ZagSigningDiagnostics.record("RPPairing installation failed")
			try await onDeferredInstall?(signed, expectation, app)
			throw error
		}
		ZagSigningDiagnostics.record("Installer returned success; verifying installed app")
		try await verifyTarget()
		await progress(.verifying)
		let installed = await installer.verify(expectation)
		switch installed {
		case .verified(let profileExpiry, let certificateExpiry):
			if let renewing, profileExpiry <= renewing.record.profileExpiresAt {
				ZagSigningDiagnostics.record("Installed profile expiry did not advance")
				throw Failure.expiryNotExtended
			}
			var verified = record
			verified.profileExpiresAt = profileExpiry
			verified.certificateExpiresAt = certificateExpiry
			verified.expiryVerified = true
			verified.owner = .init(scope: authorization.scope, teamKind: authorization.teamKind,
				certificateSerial: identity.serialNumber, profileUUID: expectation.profileUUID)
			if renewing != nil { verified.lastSuccessfulRefresh = now() }
			try await onVerified(.init(record: verified, profiles: components))
			await progress(.verified)
			ZagSigningDiagnostics.record("Installed app and profile verified")
		case .unverifiable: ZagSigningDiagnostics.record("Installed app could not be verified")
		case .mismatch: ZagSigningDiagnostics.record("Installed app or profile did not match")
		case .notInstalled, .signedOnly: ZagSigningDiagnostics.record("App missing from installed-app list")
		}
		return installed
	}
}

// MARK: - Lifecycle

struct ZagTargetDevice: Equatable, Sendable {
	let udid: String
	let name: String
}

/// Provision, sign, install, verify and record; and the same again as a
/// refresh, routed to the app's own account and team and successful only
/// when the device reports a later expiry. An account that is signed out or
/// expired never signs, and another account is never used instead.
struct ZagFreeAccountLifecycle: Sendable {
	enum Outcome: Equatable, Sendable {
		/// Installed and verified from the device.
		case installed(ZagSignedAppRecord)
		/// Installed, but the device's expiry could not be confirmed: recorded,
		/// never counted as a successful refresh.
		case installedUnverified(ZagSignedAppRecord)
		case failed(ZagRefreshFailureReason)
		case notStarted(ZagRefreshLedger.BeginResult)
	}

	let directory: ZagAccountDirectory
	let provisioner: ZagFreeAccountProvisioner
	let adapter: ZagFreeAccountSigningAdapter
	let installer: ZagFreeAccountInstaller
	let secrets: ZagFreeAccountSecretStore

	/// A first installation, for the chosen (or default) account and team.
	func install(
		app component: ZagProvisioningRequest.Component,
		scope explicit: ZagSigningScope?,
		device: ZagTargetDevice,
		appAt app: URL,
		ledger: inout ZagRefreshLedger,
		now: Date
	) async -> Outcome {
		let authorization: ZagSigningAuthorization
		do {
			authorization = try await directory.authorize(try await directory.signingScope(explicit: explicit))
		} catch {
			return .failed(.signedOut)
		}
		let request = Self.request(component, authorization: authorization, device: device, ledger: ledger)
		switch await signAndInstall(request, authorization: authorization, appAt: app, now: now) {
		case .verified(var record, let profileExpiresAt, let certificateExpiresAt):
			record.profileExpiresAt = profileExpiresAt
			record.certificateExpiresAt = certificateExpiresAt
			record.expiryVerified = true
			ledger.record(record)
			return .installed(record)
		case .unverified(var record):
			record.expiryVerified = false
			ledger.record(record)
			return .installedUnverified(record)
		case .failed(let reason):
			return .failed(reason)
		}
	}

	/// Refreshes an installed app with the account and team that signed it.
	func refresh(
		_ bundleIdentifier: String,
		app component: ZagProvisioningRequest.Component,
		device: ZagTargetDevice,
		appAt app: URL,
		ledger: inout ZagRefreshLedger,
		now: Date,
		userInitiated: Bool
	) async -> Outcome {
		let authorization: ZagSigningAuthorization
		switch await directory.route(bundleIdentifier, ledger: ledger) {
		case .blocked(let reason):
			ledger.markBlocked(bundleIdentifier, reason: reason, at: now)
			return .failed(reason)
		case .refresh(let granted):
			authorization = granted
		}
		let begin = ledger.begin(bundleIdentifier, at: now, userInitiated: userInitiated)
		guard begin == .started else { return .notStarted(begin) }
		let request = Self.request(component, authorization: authorization, device: device, ledger: ledger)
		switch await signAndInstall(request, authorization: authorization, appAt: app, now: now) {
		case .verified(let record, let profileExpiresAt, let certificateExpiresAt):
			do {
				try ledger.finishSucceeded(bundleIdentifier, installedProfileExpiresAt: profileExpiresAt, installedCertificateExpiresAt: certificateExpiresAt, at: now)
			} catch {
				return .failed(.notVerified)
			}
			ledger.updateOwnership(bundleIdentifier, certificateSerial: record.owner?.certificateSerial, profileUUID: record.owner?.profileUUID)
			return ledger.records[bundleIdentifier].map(Outcome.installed) ?? .failed(.notVerified)
		case .unverified:
			ledger.finishFailed(bundleIdentifier, reason: .notVerified, at: now)
			return .failed(.notVerified)
		case .failed(let reason):
			ledger.finishFailed(bundleIdentifier, reason: reason, at: now)
			return .failed(reason)
		}
	}

	/// The request for the authorised scope. iOS's 3-app limit for free
	/// development profiles is counted across every account's free-team apps.
	static func request(_ component: ZagProvisioningRequest.Component, authorization: ZagSigningAuthorization, device: ZagTargetDevice, ledger: ZagRefreshLedger) -> ZagProvisioningRequest {
		ZagProvisioningRequest(
			accountID: authorization.scope.accountID,
			team: authorization.scope.teamID,
			deviceUDID: device.udid,
			deviceName: device.name,
			app: component,
			extensions: [],
			installedFreeAccountApps: ledger.freeAppLimitApps
		)
	}

	private enum Attempt {
		case verified(ZagSignedAppRecord, profileExpiresAt: Date, certificateExpiresAt: Date)
		case unverified(ZagSignedAppRecord)
		case failed(ZagRefreshFailureReason)
	}

	private func signAndInstall(_ request: ZagProvisioningRequest, authorization: ZagSigningAuthorization, appAt app: URL, now: Date) async -> Attempt {
		let result: ZagProvisioningResult
		switch await provisioner.provision(request, authorization: authorization) {
		case .success(let value): result = value
		case .failure(let failure): return .failed(Self.reason(for: failure.kind))
		}
		guard let stored = try? secrets.load(.signingPrivateKey, account: authorization.scope.accountID, team: authorization.scope.teamID),
			  let identity = try? JSONDecoder().decode(ZagSigningIdentity.self, from: stored) else {
			return .failed(.signingFailed)
		}
		let record: ZagSignedAppRecord
		do {
			record = try adapter.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: now)
		} catch {
			return .failed(.signingFailed)
		}
		do {
			try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier)
		} catch {
			return .failed(.installFailed)
		}
		let expectation = ZagInstallExpectation(
			bundleIdentifier: record.bundleIdentifier,
			profileUUID: result.app.profile.uuid,
			profileExpiresAt: record.profileExpiresAt,
			certificateExpiresAt: record.certificateExpiresAt,
			signerCommonName: ZagCertificateInspection(der: identity.certificate)?.commonName,
			teamIdentifier: result.team,
			extensionProfileUUIDs: result.extensions.map(\.profile.uuid)
		)
		switch await installer.verify(expectation) {
		case .verified(let profileExpiresAt, let certificateExpiresAt):
			return .verified(record, profileExpiresAt: profileExpiresAt, certificateExpiresAt: certificateExpiresAt)
		case .unverifiable:
			return .unverified(record)
		case .mismatch, .notInstalled, .signedOnly:
			return .failed(.installFailed)
		}
	}

	static func reason(for kind: ZagProvisioningFailure.Kind) -> ZagRefreshFailureReason {
		switch kind {
		// Retrying cannot help until the user signs in (or a build that can).
		case .sessionRejected, .unavailable, .notAuthorized: return .signedOut
		case .network, .rateLimited, .timedOut, .unexpectedResponse: return .network
		case .appIDCapacityExhausted, .appIDServerLimitReached: return .appIDCapacity
		case .installSlotsFull: return .installSlots
		case .cancelled: return .cancelled
		// An unresolved certificate request waits for the user; never retried.
		case .invalidRequest, .deviceLimitReached, .identifierUnavailable, .certificateMustBeRevoked, .certificateRequestUnresolved, .invalidProfile, .keyStorage:
			return .signingFailed
		}
	}
}

/// The production signer used by `ZagASCSigningCoordinator`.
extension ZagFreeAccountSigningAdapter: ZagAppSigning {}
