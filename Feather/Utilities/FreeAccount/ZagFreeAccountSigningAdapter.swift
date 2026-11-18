#if DEBUG
import Foundation
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// Debug builds only: the test adapter between `ZagFreeAccountProvisioner`
// and the existing Zsign signer, and the sign-install-refresh lifecycle
// around it. Nothing calls it in the app; tests drive it with the real Zsign
// sources, a local test authority and a stand-in device. The AppTesters
// signing path (`ZsignHandler`) and the RPPairing installer are unchanged.

/// Signs a bundle in place.
protocol ZagCodeSigner: Sendable {
	func sign(app: URL, profile: URL, privateKey: URL, entitlements: URL, bundleIdentifier: String) throws
}

/// A signer's own failure message (Zsign's lists the files it could not sign).
struct ZagSignerFailure: Error, Equatable { let message: String }

#if canImport(ZsignSwift) || ZAG_ZSIGN_TESTS
/// The existing Zsign signer, called as `ZsignHandler` calls it. Zsign reads
/// the private key file directly (no PKCS #12) and takes the matching
/// certificate from the profile.
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
	/// The stored identity is not the certificate the profiles were issued for.
	case identityMismatch
	case bundleMismatch(expected: String, found: String?)
	/// Zsign signs nested bundles with the main app's entitlements and profile;
	/// a free team needs each extension signed for its own App ID.
	case extensionsNeedPerBundleSigning([String])
	case staging
	case signer(String)
	case verification(String)
}

/// Signs one provisioned app with Zsign. The private key is written for the
/// signer only, readable by this user alone, in a private folder that is
/// removed (after overwriting the key) whether signing succeeds or not.
struct ZagFreeAccountSigningAdapter: Sendable {
	let signer: ZagCodeSigner
	var workRoot = FileManager.default.temporaryDirectory

	func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity, now: Date) throws -> ZagSignedAppRecord {
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
			try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
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
		guard fileManager.createFile(atPath: keyFile.path, contents: identity.privateKey, attributes: [.posixPermissions: 0o600]),
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
		// Zsign reports success even when it could not make the CMS signature
		// (for a certificate it does not recognise), so look for it.
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
			certificateExpiresAt: identity.expiresAt
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

// MARK: - Lifecycle

/// Installs a signed app and reads back, from the device, the expiry iOS
/// will enforce. The real one will wrap the existing RPPairing installer.
protocol ZagFreeAccountInstaller: Sendable {
	func install(signedApp: URL, bundleIdentifier: String) async throws -> (profileExpiresAt: Date, certificateExpiresAt: Date)
}

/// Provision, sign, install and record; and the same again as a refresh,
/// which succeeds only when the device reports a later expiry.
struct ZagFreeAccountLifecycle: Sendable {
	enum Outcome: Equatable, Sendable {
		case installed(ZagSignedAppRecord)
		case failed(ZagRefreshFailureReason)
		case notStarted(ZagRefreshLedger.BeginResult)
	}

	let provisioner: ZagFreeAccountProvisioner
	let adapter: ZagFreeAccountSigningAdapter
	let installer: ZagFreeAccountInstaller
	let secrets: ZagFreeAccountSecretStore

	func install(_ request: ZagProvisioningRequest, appAt app: URL, ledger: inout ZagRefreshLedger, now: Date) async -> Outcome {
		switch await signAndInstall(request, appAt: app, now: now) {
		case .installed(var verified, let profileExpiresAt, let certificateExpiresAt):
			verified.profileExpiresAt = profileExpiresAt
			verified.certificateExpiresAt = certificateExpiresAt
			ledger.record(verified)
			return .installed(verified)
		case .failed(let reason):
			return .failed(reason)
		}
	}

	/// `request` is the original app again; the app already holds its install
	/// slot, so it is listed as installed.
	func refresh(_ bundleIdentifier: String, request: ZagProvisioningRequest, appAt app: URL, ledger: inout ZagRefreshLedger, now: Date, userInitiated: Bool) async -> Outcome {
		let begin = ledger.begin(bundleIdentifier, at: now, userInitiated: userInitiated)
		guard begin == .started else { return .notStarted(begin) }
		let refreshing = ZagProvisioningRequest(
			accountID: request.accountID, team: request.team, deviceUDID: request.deviceUDID, deviceName: request.deviceName,
			app: request.app, extensions: request.extensions,
			installedFreeAccountApps: request.installedFreeAccountApps.union([bundleIdentifier])
		)
		switch await signAndInstall(refreshing, appAt: app, now: now) {
		case .installed(_, let profileExpiresAt, let certificateExpiresAt):
			do {
				try ledger.finishSucceeded(bundleIdentifier, installedProfileExpiresAt: profileExpiresAt, installedCertificateExpiresAt: certificateExpiresAt, at: now)
			} catch {
				return .failed(.notVerified)
			}
			return ledger.records[bundleIdentifier].map(Outcome.installed) ?? .failed(.notVerified)
		case .failed(let reason):
			ledger.finishFailed(bundleIdentifier, reason: reason, at: now)
			return .failed(reason)
		}
	}

	private enum Attempt {
		case installed(ZagSignedAppRecord, profileExpiresAt: Date, certificateExpiresAt: Date)
		case failed(ZagRefreshFailureReason)
	}

	private func signAndInstall(_ request: ZagProvisioningRequest, appAt app: URL, now: Date) async -> Attempt {
		let result: ZagProvisioningResult
		switch await provisioner.provision(request) {
		case .success(let value): result = value
		case .failure(let failure): return .failed(Self.reason(for: failure.kind))
		}
		guard let stored = try? secrets.load(.signingPrivateKey, account: request.accountID),
			  let identity = try? JSONDecoder().decode(ZagSigningIdentity.self, from: stored) else {
			return .failed(.signingFailed)
		}
		let record: ZagSignedAppRecord
		do {
			record = try adapter.sign(appAt: app, with: result, identity: identity, now: now)
		} catch {
			return .failed(.signingFailed)
		}
		do {
			let installed = try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier)
			return .installed(record, profileExpiresAt: installed.profileExpiresAt, certificateExpiresAt: installed.certificateExpiresAt)
		} catch {
			return .failed(.installFailed)
		}
	}

	static func reason(for kind: ZagProvisioningFailure.Kind) -> ZagRefreshFailureReason {
		switch kind {
		// Retrying cannot help until the user signs in (or a build that can).
		case .sessionRejected, .unavailable: return .signedOut
		case .network, .rateLimited, .timedOut, .unexpectedResponse: return .network
		case .appIDCapacityExhausted: return .appIDCapacity
		case .installSlotsFull: return .installSlots
		case .cancelled: return .cancelled
		case .invalidRequest, .deviceLimitReached, .identifierUnavailable, .certificateMustBeRevoked, .invalidProfile, .keyStorage:
			return .signingFailed
		}
	}
}
#endif
