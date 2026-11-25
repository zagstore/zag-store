import CoreData
import Foundation

/// The developer-account method's real dependencies: the App Store Connect
/// transport, a dedicated Keychain store for the API key and signing identity,
/// Keychain-held signing keys, the existing signing adapter (Zsign, strict
/// Keychain-key path) and the existing RPPairing installer, both behind the
/// method's own gate. Reached only through the Signing screen's entry, which
/// is shown only while `developerAccountEnabled` is set (never in release).
enum ZagDeveloperAccountLive {
	/// This device's one developer account: its items live in their own
	/// Keychain service, apart from free-account data.
	static let keychainService = "app.zagstore.developer-account"
	static let account = UUID(uuidString: "5A4D0C9E-7E2B-4F0A-9D3C-2B1E6A0F4D11")!

	static var secrets: ZagFreeAccountSecretStore { ZagKeychainFreeAccountSecretStore(service: keychainService) }
	static var store: ZagDeveloperAccountStore { ZagDeveloperAccountStore(secrets: secrets) }

	static func service() -> ZagDeveloperAccountService {
		let keys = ZagKeychainSigningKeys(namespace: keychainService)
		var installer = ZagRPPairingFreeAccountInstaller(gate: .developerAccount)
		installer.installedProfiles = { await readInstalledProfiles() }
		return ZagDeveloperAccountService(account: account, dependencies: .init(
			transport: ZagURLSessionTransport.appStoreConnect(),
			secrets: secrets,
			keys: ZagKeychainSigningKeyFactory(keys: keys),
			signer: ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), gate: .developerAccount, keychainKeys: keys),
			installer: installer,
			discardAllKeys: { try keys.deleteAll(account: $0) }
		))
	}

	@MainActor
	static func onboardingModel() -> ZagDeveloperAccountOnboardingModel {
		let service = service()
		return ZagDeveloperAccountOnboardingModel(
			account: account, store: store,
			makeClient: { service.client(for: $0) },
			removeAll: { try service.removeAccount() }
		)
	}

	/// The paired device, if any.
	@MainActor
	static var pairedDevice: ZagTargetDevice? {
		let pairing = ZagRPPairingCore.shared
		guard pairing.hasSavedPairing, let identity = pairing.pairedIdentity else { return nil }
		return ZagTargetDevice(udid: identity.udid, name: identity.name)
	}

	/// The Library's imported (unsigned) apps that can be signed.
	@MainActor
	static func libraryApps() -> [ZagDeveloperAccountApp] {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		let imported = (try? Storage.shared.context.fetch(request)) ?? []
		return imported.compactMap { app in
			guard let url = Storage.shared.getAppDirectory(for: app), let identifier = app.identifier,
				  let entitlements = requestedEntitlements(of: url) else { return nil }
			return ZagDeveloperAccountApp(url: url, originalBundleIdentifier: identifier, name: app.name ?? identifier, entitlements: entitlements)
		}
	}

	/// The entitlements the app's own signature asks for (none if it is
	/// unsigned). The provisioner keeps only those the profile grants.
	static func requestedEntitlements(of app: URL) -> ZagEntitlementSet? {
		let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
		let requested = (info?["CFBundleExecutable"] as? String)
			.flatMap { try? ZagMachOSignatureInspector.entitlements(at: app.appendingPathComponent($0)) } ?? [:]
		return (try? ZagEntitlementSet(requested)) ?? (try? ZagEntitlementSet([:]))
	}

	/// The device's installed provisioning profiles (misagent), so an install
	/// is verified from the device rather than assumed.
	private static func readInstalledProfiles() async -> Result<[Data], Error> {
		await withCheckedContinuation { continuation in
			Task { @MainActor in
				ZagRPPairingCore.shared.readInstalledProfiles(deviceIP: ZagDeviceLink.peerAddress) { continuation.resume(returning: $0) }
			}
		}
	}
}
