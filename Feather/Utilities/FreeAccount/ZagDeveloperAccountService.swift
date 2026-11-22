import Foundation

// The developer-account method end to end, for one connected account: the
// stored credential, the ASC client, the provisioner, the existing signing
// adapter and the existing installer. Every dependency is injected, so the
// app supplies the real ones (`ZagDeveloperAccountLive`) and the tests a
// mock ASC API, an in-memory store and stub signers and installers.
//
// Nothing runs while the gate is closed (every release build).

/// One app to sign and install, from the user's Library.
struct ZagDeveloperAccountApp: Sendable {
	let url: URL
	let originalBundleIdentifier: String
	let name: String
	var entitlements: ZagEntitlementSet

	/// Nested bundles (extensions in PlugIns/ or Extensions/, App Clips,
	/// watch apps) are not supported by this method yet.
	var hasExtensions: Bool { !ZagFreeAccountSigningAdapter.nestedBundles(in: url).isEmpty }
}

struct ZagDeveloperAccountService: Sendable {
	struct Dependencies: Sendable {
		var transport: ZagHTTPTransport
		var secrets: ZagFreeAccountSecretStore
		var keys: ZagSigningKeyFactory
		var signer: ZagAppSigning
		var installer: ZagFreeAccountInstaller
		var gate: ZagDeveloperAccountGate = .production
		var now: @Sendable () -> Date = { Date() }
		/// Deletes every Keychain signing key of an account, whatever its team
		/// (the app: `ZagKeychainSigningKeys.deleteAll`). Nil: by the stored
		/// credential's team only.
		var discardAllKeys: (@Sendable (UUID) throws -> Void)?
		/// Where the app is copied to be signed; the Library's copy is never
		/// modified.
		var workRoot = FileManager.default.temporaryDirectory
		/// Tests only: decodes a mock ASC API's profiles. The app uses the
		/// real `.mobileprovision` parser.
		var decodeProfile: (@Sendable (Data) throws -> ZagIssuedProfile)?
	}

	enum Outcome: Equatable, Sendable {
		/// No credential is stored: connect a key first.
		case notConnected
		case installed(ZagSignedAppRecord)
		case installedUnverified(ZagSignedAppRecord)
		case failed(ZagASCSigningError)
		/// The app has extensions or app groups, which this method cannot sign yet.
		case unsupportedApp
	}

	let account: UUID
	let dependencies: Dependencies

	var store: ZagDeveloperAccountStore { ZagDeveloperAccountStore(secrets: dependencies.secrets) }

	/// A client for `credential` over the injected transport.
	func client(for credential: ZagDeveloperAccountCredential, writeObserver: (@Sendable () -> Void)? = nil) -> ZagASCClient {
		var client = ZagASCClient(transport: dependencies.transport, credential: credential, now: dependencies.now)
		client.writeObserver = writeObserver
		return client
	}

	/// Provisions, signs, installs and verifies `app` on `device` with the
	/// connected team. A write that succeeds along the way (even if a later
	/// step fails) marks the key's provisioning as verified.
	func install(_ app: ZagDeveloperAccountApp, on device: ZagTargetDevice) async -> Outcome {
		guard dependencies.gate.isOpen else { return .failed(.disabled) }
		guard let credential = try? store.load(account: account) else { return .notConnected }
		guard !app.hasExtensions, app.entitlements.dictionary[Self.appGroupsKey] == nil else { return .unsupportedApp }

		// Sign a private copy: the adapter signs in place, and the Library's
		// copy is what every other signing method starts from.
		let fileManager = FileManager.default
		let work = dependencies.workRoot.appendingPathComponent("zag-developer-account-\(UUID().uuidString)", isDirectory: true)
		let copy = work.appendingPathComponent(app.url.lastPathComponent, isDirectory: true)
		defer { try? fileManager.removeItem(at: work) }
		do {
			try fileManager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
			try fileManager.copyItem(at: app.url, to: copy)
		} catch {
			return .failed(.signing)
		}

		let wrote = ZagWriteFlag()
		var portal = ZagASCDeveloperPortal(client: client(for: credential) { wrote.set() })
		if let decode = dependencies.decodeProfile { portal.decodeProfile = decode }
		let coordinator = ZagASCSigningCoordinator(
			provisioner: ZagASCProvisioner(portal: portal, keys: dependencies.keys, secrets: dependencies.secrets, now: dependencies.now),
			secrets: dependencies.secrets,
			signer: dependencies.signer,
			installer: dependencies.installer,
			gate: dependencies.gate,
			now: dependencies.now
		)
		let outcome = await coordinator.install(
			app: .init(originalBundleIdentifier: app.originalBundleIdentifier, name: app.name, entitlements: app.entitlements),
			account: account, team: credential.team, device: device, appAt: copy
		)
		if wrote.value { try? store.markProvisioningVerified(account: account, at: dependencies.now()) }
		switch outcome {
		case .installed(let record): return .installed(record)
		case .installedUnverified(let record): return .installedUnverified(record)
		case .failed(let error): return .failed(error)
		}
	}

	/// Removes the developer account from this device: the API key, the
	/// signing identity and its Keychain keys. Nothing is changed at Apple
	/// (certificates, devices, bundle IDs and profiles stay on the team).
	///
	/// Every deletion is attempted even if one fails (the first failure is
	/// thrown), and keys are found by account, so a disconnected account
	/// (no credential, hence no team) is removed completely too.
	func removeAccount() throws {
		var failure: Error?
		do {
			if let discardAllKeys = dependencies.discardAllKeys {
				try discardAllKeys(account)
			} else if let team = (try? store.load(account: account))?.teamID {
				try dependencies.keys.discardKeys(account: account, team: team, except: [])
			}
		} catch { failure = error }
		do { try dependencies.secrets.deleteAll(account: account) } catch { failure = failure ?? error }
		if let failure { throw failure }
	}

	static let appGroupsKey = "com.apple.security.application-groups"
}

/// Set from the client's write observer; read once the run ends.
private final class ZagWriteFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var wrote = false
	func set() { lock.withLock { wrote = true } }
	var value: Bool { lock.withLock { wrote } }
}
