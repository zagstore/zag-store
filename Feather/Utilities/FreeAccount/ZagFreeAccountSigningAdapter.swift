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

	static func signerCertificates(in executable: Data) -> [Data]? {
		guard let slices = signatureBlobs(executable), !slices.isEmpty else { return nil }
		let signers = slices.compactMap { slice -> Data? in
			guard let cms = slice[cmsSlot], cms.count > 8 else { return nil }
			return ZagCMSVerifier.embeddedSigner(Data(cms.dropFirst(8)))
		}
		return signers.count == slices.count ? signers : nil
	}

	static func matchesSigner(_ certificate: Data, in executable: Data) -> Bool {
		signerCertificates(in: executable)?.allSatisfy { $0 == certificate } == true
	}

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
	var allowsWildcardProfile: Bool?
	var signingScope: ZagSigningScope?
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
		let appID = app.entitlements.dictionary["application-identifier"] as? String
		let matchesBundle = expectation.allowsWildcardProfile == true
			? ZagImportedIdentityProfileMatch.bundleMatches(target: expectation.bundleIdentifier, applicationIdentifier: appID ?? "", team: team)
			: appID == "\(team).\(expectation.bundleIdentifier)"
		guard matchesBundle else { return .mismatch("profile App ID") }
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
		case .preparing: "Preparing"
		case .provisioning: "Provisioning"
		case .signing: "Signing"
		case .installing: "Installing"
		case .verifying: "Verifying"
		case .verified: "Verifying"
		}
	}
}

struct ZagNativeInstalledProfiles: Codable, Equatable, Sendable {
	struct Component: Codable, Equatable, Sendable {
		let originalBundleIdentifier: String
		let bundleIdentifier: String
		var uuid: String
		var expiresAt: Date
		var appGroups: [String]? = nil
		var signedEntitlements: Data? = nil
	}
	var record: ZagSignedAppRecord
	let profiles: [Component]
	var executableIdentity: ExecutableIdentity? = nil

	struct ExecutableIdentity: Codable, Equatable, Sendable {
		let certificate: Data
		let version: String?
		let build: String?
	}
}

extension ZagNativeInstalledProfiles {
	func validateArtifact(_ source: URL, expectation: ZagInstallExpectation, deviceUDID: String) throws {
		let error = ZagFreeAccountSigningError.verification("Saved app identity or provisioning profile")
		guard let owner = record.owner,
			  record.bundleIdentifier == expectation.bundleIdentifier,
			  owner.scope.teamID == expectation.teamIdentifier,
			  expectation.signingScope == nil || expectation.signingScope == owner.scope,
			  owner.profileUUID == expectation.profileUUID,
			  owner.certificateSerial == expectation.certificateSerial,
			  record.certificateExpiresAt == expectation.certificateExpiresAt,
			  profiles.map(\.expiresAt).min() == record.profileExpiresAt else { throw error }

		let components = [source] + ZagFreeAccountSigningAdapter.nestedBundles(in: source).map { source.appendingPathComponent($0) }
		guard components.count == profiles.count else { throw error }
		var verified: Set<String> = []
		for component in components {
			guard let bundle = Bundle(url: component), let id = bundle.bundleIdentifier, verified.insert(id).inserted,
				  let saved = profiles.first(where: { $0.bundleIdentifier == id }),
				  let bytes = try? Data(contentsOf: component.appendingPathComponent("embedded.mobileprovision")),
				  let authentic = try? ZagCMSVerifier.verify(bytes).get(),
				  let profile = try? ZagIssuedProfile(profileData: authentic),
				  let contents = ZagMobileProvision.parseUnverified(authentic),
				  profile.uuid == saved.uuid, profile.expiresAt == saved.expiresAt,
				  profile.teamIdentifier == owner.scope.teamID, profile.bundleIdentifier == id,
				  profile.deviceUDIDs.contains(where: { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }),
				  let executable = bundle.executableURL,
				  let binary = try? Data(contentsOf: executable, options: .mappedIfSafe),
				  let signers = ZagCodeSignatureInspection.signerCertificates(in: binary),
				  signers.allSatisfy({ der in
					  guard let certificate = ZagCertificateInspection(der: der) else { return false }
					  return contents.developerCertificates.contains(der) && certificate.serialNumber == owner.certificateSerial
						  && certificate.organizationalUnit == owner.scope.teamID && certificate.expiresAt == expectation.certificateExpiresAt
				  }) else { throw error }
			if id == record.bundleIdentifier {
				guard component == source, saved.uuid == expectation.profileUUID,
					  saved.expiresAt == expectation.profileExpiresAt,
					  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == expectation.version,
					  bundle.infoDictionary?["CFBundleVersion"] as? String == expectation.build else { throw error }
			} else {
				guard expectation.extensionProfileUUIDs.contains(saved.uuid),
					  expectation.extensionIdentifiers[saved.uuid] == id,
					  expectation.extensionProfileExpirations[saved.uuid] == saved.expiresAt else { throw error }
			}
		}
	}
}

/// The signing pipeline verifies the exact component entitlements before
/// persisting the receipt. Older receipts without that evidence need a re-sign.
enum ZagProfileOnlyRenewal {
	enum Failure: LocalizedError, Equatable {
		case needsResign
		case noExtension
		case readback
		case appUnavailable

		var errorDescription: String? {
			switch self {
			case .needsResign: "This app needs to be signed again to refresh its current signing identity."
			case .noExtension: "Apple did not issue compatible profiles with a later expiration."
			case .readback: "The iPhone did not report all renewed profiles. Try Refresh again."
			case .appUnavailable: "Zag Store could not match the installed app to its saved signing identity."
			}
		}
	}

	@MainActor
	final class ReadCache<Key: Hashable, Value: Sendable> {
		private var tasks: [Key: Task<Value, Error>] = [:]

		func value(for key: Key, load: @escaping @MainActor () async throws -> Value) async throws -> Value {
			if let task = tasks[key] { return try await task.value }
			let task = Task { try await load() }
			tasks[key] = task
			return try await task.value
		}
	}

	@MainActor
	final class DeviceQueue {
		private var tail: Task<Void, Never>?

		func run<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
			let previous = tail
			let work = Task { @MainActor in
				await previous?.value
				try Task.checkCancellation()
				return try await operation()
			}
			tail = Task { _ = try? await work.value }
			return try await withTaskCancellationHandler {
				try await work.value
			} onCancel: { work.cancel() }
		}
	}

	static func validate(_ bytes: Data, component: ZagNativeInstalledProfiles.Component,
		team: String, certificate: Data, udid: String, now: Date = Date(),
		authenticate: (Data) throws -> Data = { try ZagCMSVerifier.verify($0).get() }) throws -> ZagIssuedProfile {
		let authenticated = try authenticate(bytes)
		let profile = try ZagIssuedProfile(profileData: authenticated)
		func incompatible(_ reason: String) -> Failure {
			ZagSigningDiagnostics.record("Profile compatibility rejected: \(reason)")
			return .needsResign
		}
		guard let contents = ZagMobileProvision.parseUnverified(authenticated) else { throw incompatible("profile payload unreadable") }
		guard contents.teamIdentifier == team else { throw incompatible("team mismatch") }
		guard profile.bundleIdentifier == component.bundleIdentifier else { throw incompatible("bundle mismatch") }
		guard contents.applicationIdentifier == "\(team).\(component.bundleIdentifier)" else { throw incompatible("application identifier mismatch") }
		guard contents.developerCertificates.contains(certificate) else { throw incompatible("original certificate not granted") }
		guard contents.provisionedDevices.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) else { throw incompatible("device not covered") }
		guard let evidence = component.signedEntitlements,
			  let signed = try? PropertyListSerialization.propertyList(from: evidence, format: nil) as? [String: Any] else { throw incompatible("signed entitlement evidence unreadable") }
		guard ZagEntitlementAudit.disallowed(requested: signed.mapValues(ZagEntitlementValue.init),
			granted: contents.entitlements).isEmpty else { throw incompatible("signed entitlements not granted") }
		guard profile.expiresAt > now else { throw Failure.noExtension }
		return .init(uuid: profile.uuid, teamIdentifier: profile.teamIdentifier, bundleIdentifier: profile.bundleIdentifier,
			certificateSerials: profile.certificateSerials, deviceUDIDs: profile.deviceUDIDs, entitlements: profile.entitlements,
			createdAt: profile.createdAt, expiresAt: profile.expiresAt, data: bytes)
	}

	static func effectiveExpiry(_ profiles: [ZagIssuedProfile], certificateExpires: Date, previous: Date, now: Date) throws -> Date {
		guard let earliest = profiles.map(\.expiresAt).min() else { throw Failure.readback }
		let expiry = min(earliest, certificateExpires)
		guard expiry > max(previous, now) else { throw Failure.noExtension }
		return expiry
	}
}

extension ZagSigningDiagnostics {
	static func elapsed(_ stage: String, since start: ContinuousClock.Instant) {
		let duration = start.duration(to: .now).components
		let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
		record("\(stage): \(milliseconds) ms")
	}
}

enum ZagAppRowAction: String {
	case open = "Open", update = "Update", install = "Install", sign = "Sign", refresh = "Refresh"

	static func resolve(installed: Bool, hasUpdate: Bool, signed: Bool, launchable: Bool, canRefresh: Bool) -> Self {
		if installed && hasUpdate { return .update }
		if installed && launchable { return .open }
		if !installed && signed && launchable { return .install }
		return canRefresh ? .refresh : .sign
	}
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

	static func extendsValidity(previousProfile: Date, newProfile: Date, certificate: Date, now: Date) -> Bool {
		let renewed = min(newProfile, certificate)
		return renewed > now && renewed > min(previousProfile, certificate)
	}

	enum RefreshOutcome: Equatable, Sendable {
		case refreshed
		case skipped(String)
		case failed(String)
	}

	struct RefreshSummary {
		let title: String
		let message: String

		init(_ results: [RefreshOutcome], cancelled: Bool) {
			let count = results.filter { $0 == .refreshed }.count
			let unfinished = results.count - count - results.filter { $0 == .skipped("Cancelled.") }.count
			title = cancelled ? "Refresh Cancelled" : "Refresh Complete"
			var text = count == 1 ? "1 app refreshed successfully." : "\(count) apps refreshed successfully."
			if unfinished > 0 {
				text += unfinished == 1 ? "\n1 app couldn’t be refreshed. See diagnostics."
					: "\n\(unfinished) apps couldn’t be refreshed. See diagnostics."
			}
			message = text
		}
	}

	@MainActor
	static func concurrentRefresh(count: Int, limit: Int = 3, isCancelled: () -> Bool,
		operation: @escaping @MainActor (Int) async -> RefreshOutcome) async -> [RefreshOutcome] {
		guard count > 0 else { return [] }
		return await withTaskGroup(of: (Int, RefreshOutcome).self) { group in
			var results = Array(repeating: RefreshOutcome.skipped("Cancelled."), count: count)
			var launched = 0
			while launched < min(max(limit, 1), count), !isCancelled(), !Task.isCancelled {
				let index = launched
				group.addTask { (index, await operation(index)) }
				launched += 1
			}
			while let (index, outcome) = await group.next() {
				results[index] = outcome
				if launched < count, !isCancelled(), !Task.isCancelled {
					let next = launched
					group.addTask { (next, await operation(next)) }
					launched += 1
				}
			}
			return results
		}
	}

	@MainActor
	static func refreshBatch<App>(_ apps: [App], eligibility: (App) -> String?,
		isCancelled: () -> Bool, renew: (App, Int) async throws -> RefreshOutcome) async -> [RefreshOutcome] {
		var results: [RefreshOutcome] = []
		for (index, app) in apps.enumerated() {
			if isCancelled() || Task.isCancelled {
				results.append(.skipped("Cancelled."))
			} else if let reason = eligibility(app) {
				results.append(.skipped(reason))
			} else {
				do { results.append(try await renew(app, index)) }
				catch is CancellationError { results.append(.skipped("Cancelled.")) }
				catch { results.append(.failed(error.localizedDescription)) }
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
		let provisionStart = ContinuousClock.now
		let provisioned = await provisioner.provision(request, authorization: authorization)
		ZagSigningDiagnostics.elapsed("Full provisioning", since: provisionStart)
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
				appGroups: ($0.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String] ?? []).sorted(),
				signedEntitlements: $0.entitlements.data)
		}
		if let renewing {
			let old = Set(renewing.profiles.map { [$0.originalBundleIdentifier, $0.bundleIdentifier] })
			let new = Set(components.map { [$0.originalBundleIdentifier, $0.bundleIdentifier] })
			guard old == new, renewing.record.owner?.scope == authorization.scope,
				  renewing.profiles.allSatisfy({ prior in
					prior.appGroups == nil || components.first(where: { $0.bundleIdentifier == prior.bundleIdentifier })?.appGroups == prior.appGroups
				  }) else { throw Failure.changedIdentity }
			ZagSigningDiagnostics.record("Profile renewal expiry: installed \(renewing.record.profileExpiresAt); issued \(result.expiresAt)")
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
		let signStart = ContinuousClock.now
		do {
			record = try signer.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: now())
			ZagSigningDiagnostics.elapsed("Mach-O signing and signature verification", since: signStart)
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
			extensionProfileExpirations: Dictionary(result.extensions.map { ($0.profile.uuid, $0.profile.expiresAt) }, uniquingKeysWith: { first, _ in first }),
			signingScope: authorization.scope
		)
		try Task.checkCancellation()
		guard result.expiresAt > now(), identity.expiresAt > now() else {
			throw ZagFreeAccountSigningError.verification("The signing certificate or provisioning profile expired before installation.")
		}
		var saved = record
		saved.expiryVerified = false
		saved.owner = .init(scope: authorization.scope, teamKind: authorization.teamKind,
			certificateSerial: identity.serialNumber, profileUUID: expectation.profileUUID)
		let signed = ZagNativeInstalledProfiles(record: saved, profiles: components,
			executableIdentity: .init(certificate: identity.certificate, version: expectation.version, build: expectation.build))
		if let onSignedOnly {
			try await onSignedOnly(signed, expectation, app)
			ZagSigningDiagnostics.record("Signed app saved for later installation")
			return .signedOnly
		}
		var phase: ZagSigningFailurePhase = .installation
		do {
			try await verifyTarget()
			try await beforeInstalling()
			await progress(.installing)
			ZagSigningDiagnostics.record("Installing via RPPairing")
			try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier)
			phase = .verification
			ZagSigningDiagnostics.record("Installer returned success; verifying installed app")
			try await verifyTarget()
			await progress(.verifying)
			let verificationStart = ContinuousClock.now
			let installed = await installer.verify(expectation)
			ZagSigningDiagnostics.elapsed("Full installation verification", since: verificationStart)
			guard case .verified(let profileExpiry, let certificateExpiry) = installed else {
				throw ZagFreeAccountSigningError.verification(String(describing: installed))
			}
			if let renewing {
				ZagSigningDiagnostics.record("Installed profile expiry: before \(renewing.record.profileExpiresAt); after \(profileExpiry)")
				guard profileExpiry > renewing.record.profileExpiresAt else { throw Failure.expiryNotExtended }
			}
			var verified = signed
			verified.record.profileExpiresAt = profileExpiry
			verified.record.certificateExpiresAt = certificateExpiry
			verified.record.expiryVerified = true
			if renewing != nil { verified.record.lastSuccessfulRefresh = now() }
			try await onVerified(verified)
			await progress(.verified)
			ZagSigningDiagnostics.record("Installed app and profile verified")
			return installed
		} catch {
			ZagSigningDiagnostics.recordFailure(phase, error)
			do { try await onDeferredInstall?(signed, expectation, app) }
			catch { ZagSigningDiagnostics.recordFailure(.signing, error) }
			throw error is CancellationError ? error : ZagStagedSigningFailure(phase: phase, underlying: error)
		}
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
