import Foundation
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// Free-account signing in production code, behind a gate that is closed in
// this version (`ZagFreeAccountSigning.isEnabled`): from a provisioning
// result to a signed app, its installation through the existing RPPairing
// installer, a verified record, and refreshes routed to the app's own
// account and team. The AppTesters signing path (`ZsignHandler`) and the
// RPPairing installer are unchanged.

enum ZagFreeAccountSigning {
	/// Signing with Apple Account certificates is not enabled in this version.
	static let isEnabled = false
}

/// Whether free-account signing may run. Release builds can only make the
/// production gate, which is closed; the open gate exists in Debug builds,
/// for simulated accounts and local test authorities.
struct ZagFreeAccountSigningGate: Equatable, Sendable {
	let isOpen: Bool

	private init(isOpen: Bool) { self.isOpen = isOpen }

	static let production = ZagFreeAccountSigningGate(isOpen: ZagFreeAccountSigning.isEnabled)
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

enum ZagFreeAccountSigningError: Error, Equatable {
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
}

/// Signs one provisioned app with Zsign. The private key is written for the
/// signer only, readable by this user alone, in a private folder that is
/// removed (after overwriting the key) whether signing succeeds or not; see
/// SIGNING-KEY-SECURITY.md for what deletion does and does not guarantee.
struct ZagFreeAccountSigningAdapter: Sendable {
	let signer: ZagCodeSigner
	var workRoot = FileManager.default.temporaryDirectory
	var gate = ZagFreeAccountSigningGate.production

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
struct ZagInstallExpectation: Equatable, Sendable {
	let bundleIdentifier: String
	let profileUUID: String
	let profileExpiresAt: Date
	let certificateExpiresAt: Date
	/// The signing certificate's common name, as installation_proxy reports it.
	let signerCommonName: String?
	var teamIdentifier: String?
	/// Each extension's profile, which the device installs alongside the app's.
	var extensionProfileUUIDs: [String] = []
}

/// Compares the provisioning profiles the device reports as installed
/// (RPPairing misagent, draft PR #25) with what Zag Store installed. The
/// device does not say which app uses which profile, so profiles are
/// matched by the UUID of the exact profile Zag Store embedded; its team,
/// App ID and expiry must then be the expected ones. Anything less is not
/// success.
enum ZagInstalledProfileCheck {
	static func verify(_ expectation: ZagInstallExpectation, installedProfiles: [Data]) -> ZagInstallVerification {
		var byUUID: [String: Certificate] = [:]
		for data in installedProfiles {
			if let profile = try? Certificate.decode(profileData: data) { byUUID[profile.UUID] = profile }
		}
		guard let app = byUUID[expectation.profileUUID] else {
			return .unverifiable("the app's profile is not among the device's installed profiles")
		}
		let team = expectation.teamIdentifier ?? app.TeamIdentifier.first ?? ""
		guard app.TeamIdentifier.first == team else { return .mismatch("profile team") }
		guard app.Entitlements?["application-identifier"]?.value as? String == "\(team).\(expectation.bundleIdentifier)" else {
			return .mismatch("profile App ID")
		}
		guard abs(app.ExpirationDate.timeIntervalSince(expectation.profileExpiresAt)) < 1 else { return .mismatch("profile expiry") }
		var earliest = app.ExpirationDate
		for uuid in expectation.extensionProfileUUIDs {
			guard let profile = byUUID[uuid] else { return .unverifiable("an extension's profile is not among the device's installed profiles") }
			guard profile.TeamIdentifier.first == team else { return .mismatch("extension profile team") }
			earliest = min(earliest, profile.ExpirationDate)
		}
		return .verified(profileExpiresAt: earliest, certificateExpiresAt: expectation.certificateExpiresAt)
	}
}

/// What the device reported after an installation.
enum ZagInstallVerification: Equatable, Sendable {
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
		case .mismatch, .notInstalled:
			return .failed(.installFailed)
		}
	}

	static func reason(for kind: ZagProvisioningFailure.Kind) -> ZagRefreshFailureReason {
		switch kind {
		// Retrying cannot help until the user signs in (or a build that can).
		case .sessionRejected, .unavailable, .notAuthorized: return .signedOut
		case .network, .rateLimited, .timedOut, .unexpectedResponse: return .network
		case .appIDCapacityExhausted: return .appIDCapacity
		case .installSlotsFull: return .installSlots
		case .cancelled: return .cancelled
		case .invalidRequest, .deviceLimitReached, .identifierUnavailable, .certificateMustBeRevoked, .invalidProfile, .keyStorage:
			return .signingFailed
		}
	}
}
