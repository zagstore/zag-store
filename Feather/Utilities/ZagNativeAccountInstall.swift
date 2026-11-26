#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
import Foundation
import CryptoKit

@MainActor
enum ZagNativeAccountInstall {
	enum Failure: LocalizedError {
		case busy, signIn, personalTeam, pairing, invalidApp

		var errorDescription: String? {
			switch self {
			case .busy: "An Apple Account installation is already in progress."
			case .signIn: "Sign in under Settings › Apple Accounts & Signing."
			case .personalTeam: "No active Personal Team was found for this Apple Account."
			case .pairing: "Pair this iPhone in Settings before signing and installing."
			case .invalidApp: "Zag Store could not read the app or one of its extensions."
			}
		}
	}

	struct CertificateIssue: LocalizedError {
		let failure: ZagProvisioningFailure
		let scope: ZagSigningScope
		let teamName: String
		let recovery: ZagCertificateRecoveryModel?

		var errorDescription: String? { failure.message }
	}

	/// The native installer creates provisioners per operation. Use the same
	/// lock for recovery so two instances cannot modify the same journal.
	private struct LockedRecovery: ZagCertificateRecoveryService {
		let provisioner: ZagFreeAccountProvisioner

		func unresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagUnresolvedCertificateRequest? {
			await provisioner.unresolvedCertificateRequest(accountID: accountID, team: team)
		}

		func checkUnresolvedCertificateRequest(accountID: UUID, team: String, authorization: ZagSigningAuthorization) async -> ZagCertificateRecoveryOutcome {
			do {
				return try await ZagNativeAccountInstall.withExclusiveOperation {
					await provisioner.checkUnresolvedCertificateRequest(accountID: accountID, team: team, authorization: authorization)
				}
			} catch { return .checkFailed(.unavailable) }
		}

		func abandonUnresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagCertificateRecoveryOutcome {
			do {
				return try await ZagNativeAccountInstall.withExclusiveOperation {
					await provisioner.abandonUnresolvedCertificateRequest(accountID: accountID, team: team)
				}
			} catch { return .checkFailed(.unavailable) }
		}
	}

	/// Only Apple-signed profiles are reused. The provisioner rechecks the
	/// profile against the selected certificate, app and device before signing.
	private struct ProfileCache: Sendable {
		let directory: URL

		init(scope: ZagSigningScope) {
			directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
				.appendingPathComponent("ZagStore/Profiles/\(scope.accountID)/\(scope.teamID)", isDirectory: true)
		}

		private func path(for bundle: String) -> URL {
			let digest = SHA256.hash(data: Data(bundle.utf8)).map { String(format: "%02x", $0) }.joined()
			return directory.appendingPathComponent(digest).appendingPathExtension("mobileprovision")
		}

		func profile(for bundle: String) -> ZagIssuedProfile? {
			guard let data = try? Data(contentsOf: path(for: bundle)), data.count <= 1 << 20 else { return nil }
			return try? ZagIssuedProfile(profileData: data)
		}

		func save(_ profile: ZagIssuedProfile) {
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				try profile.data.write(to: path(for: profile.bundleIdentifier), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			} catch {
				// Cache failure never changes the validity of the fresh profile.
			}
		}
	}

	private static var running = false
	static let namespace = "app.zagstore.native-account"
	static var secrets: ZagKeychainFreeAccountSecretStore { .init(service: namespace) }

	static func withExclusiveOperation<T>(_ operation: () async throws -> T) async throws -> T {
		guard !running else { throw Failure.busy }
		running = true
		defer { running = false }
		return try await operation()
	}

	static func portal(token: ZagPersistedDeveloperToken, consent: ZagAccountMutationConsent, maxRequests: Int? = nil) -> ZagNativeDeveloperPortal {
		let machine = ZagAppleAuthMachine.nativeAccount()
		return ZagNativeDeveloperPortal(transport: ZagNativeDeveloperPortal.transport(), headers: {
			guard let headers = await machine.developerHeaders(expectedAccountID: token.accountID) else {
				throw ZagPortalError.sessionRejected
			}
			return headers
		}, consent: consent, maxRequests: maxRequests)
	}
	static var hasSession: Bool {
		ZagDeveloperTokenStore().load(scope: "device")?.isUsable(at: Date()) == true
	}

	static func currentAccountMatches(_ scope: ZagSigningScope) -> Bool {
		guard let token = ZagDeveloperTokenStore().load(scope: "device"), token.isUsable(at: Date()) else { return false }
		return ZagSigningAuthorization.nativeAccount(token: token, teamID: scope.teamID).scope == scope
	}

	static func install(source: URL, name: String, expectedScope: ZagSigningScope? = nil,
						requiredInstalledIdentifier: String? = nil,
						onCertificateReady: (@Sendable () async -> Void)? = nil,
						renewing: ZagNativeAppInventory.Entry? = nil,
						progress: @escaping @Sendable (ZagNativeSigningProgress) async -> Void = { _ in },
						onSaved: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ZagInstallVerification {
		try await withExclusiveOperation {
			try await ZagSigningDiagnostics.current.withValue(ZagSigningDiagnostics()) {
				ZagSigningDiagnostics.record("Native signing attempt started")
				await progress(.preparing)
				if let renewing, renewing.installation.record.owner?.scope != expectedScope {
					throw ZagNativeAppInventory.Failure.wrongAccount
				}
				return try await performInstall(source: source, name: name, expectedScope: expectedScope,
					requiredInstalledIdentifier: requiredInstalledIdentifier,
					onCertificateReady: onCertificateReady, renewing: renewing, progress: progress, onSaved: onSaved)
			}
		}
	}

	private static func performInstall(source: URL, name: String, expectedScope: ZagSigningScope?,
									   requiredInstalledIdentifier: String?,
									   onCertificateReady: (@Sendable () async -> Void)?,
									   renewing: ZagNativeAppInventory.Entry?,
									   progress: @escaping @Sendable (ZagNativeSigningProgress) async -> Void,
									   onSaved: @escaping @Sendable (String) async -> Void) async throws -> ZagInstallVerification {
		let pairing = ZagRPPairingCore.shared
		guard pairing.hasSavedPairing else { throw Failure.pairing }
		guard let token = ZagDeveloperTokenStore().load(scope: "device"), token.isUsable(at: Date()) else {
			throw Failure.signIn
		}
		if let expectedScope, !currentAccountMatches(expectedScope) { throw Failure.signIn }

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let app = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
		try await Task.detached(priority: .userInitiated) {
			try FileManager.default.copyItem(at: source, to: app)
		}.value
		try Task.checkCancellation()
		let main = try component(at: app, name: name)
		let extensions = try ZagFreeAccountSigningAdapter.extensionPaths(in: app).values.sorted().map {
			try component(at: app.appendingPathComponent($0), name: appendingName(name, path: $0))
		}

		ZagSigningDiagnostics.record("Reading paired device and installed apps")
		let (device, installed) = try await pairing.signingDeviceInventory()
		let installedProfiles = (try? await ZagRPPairingFreeAccountInstaller.readProfiles().get()) ?? []
		let profiles = installedProfiles.compactMap { try? ZagIssuedProfile(profileData: $0) }
		let installedFreeApps = Set(profiles.filter {
			installed[$0.bundleIdentifier] != nil && $0.expiresAt > Date()
				&& $0.expiresAt.timeIntervalSince($0.createdAt) <= 7 * 86_400 + 60
		}.map(\.bundleIdentifier))

		let consent = ZagMutationConsentCoordinator()
		consent.authorize([.addDevice, .addAppID, .submitCSR, .downloadProfile, .addAppGroup, .assignAppGroups, .updateAppID])
		defer { consent.cancel() }
		let components = [main] + extensions
		let groupCount = components.reduce(0) {
			$0 + (($1.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String])?.count ?? 0)
		}
		let portal = portal(token: token, consent: consent, maxRequests: 24 + 8 * components.count + groupCount)
		ZagSigningDiagnostics.record("Selecting Personal Team")
		guard let team = ZagNativeDeveloperTeam.personalTeam(in: try await portal.teams(), expectedID: expectedScope?.teamID) else { throw Failure.personalTeam }
		let authorization = ZagSigningAuthorization.nativeAccount(token: token, teamID: team.teamID)
		let scope = authorization.scope
		guard expectedScope == nil || expectedScope == scope else { throw Failure.signIn }
		let keys = ZagKeychainSigningKeys(namespace: namespace)
		let keyFactory = ZagKeychainSigningKeyFactory(keys: keys)
		let cache = ProfileCache(scope: scope)
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: keyFactory,
			secrets: secrets, certificateMinimumRemaining: 0, saveProfile: { cache.save($0) },
			onCertificateReady: onCertificateReady, account: scope.accountID)
		var request = ZagProvisioningRequest(accountID: scope.accountID, team: scope.teamID, deviceUDID: device.udid,
											 deviceName: device.name, app: main, extensions: extensions, installedFreeAccountApps: installedFreeApps)
		let componentIDs = Set(components.map(\.originalBundleIdentifier))
		let mappedIDs = Set(componentIDs.compactMap { id in
			id == main.originalBundleIdentifier
				? ZagBundleIdentifierMapping.mapped(id, team: scope.teamID)
				: ZagBundleIdentifierMapping.mappedExtension(id, appOriginal: main.originalBundleIdentifier, team: scope.teamID)
		})
		let mappedMain = ZagBundleIdentifierMapping.mapped(main.originalBundleIdentifier, team: scope.teamID)
		if let requiredInstalledIdentifier, requiredInstalledIdentifier != mappedMain {
			throw ZagNativeSigningPipeline.Failure.changedIdentity
		}
		if let mappedMain,
		   let existing = ZagNativeAppInventory.entry(bundleIdentifier: mappedMain),
		   existing.installation.record.owner?.scope != scope {
			throw ZagNativeAppInventory.Failure.wrongAccount
		}
		if renewing == nil {
			request.reusableProfiles = (profiles + mappedIDs.compactMap { cache.profile(for: $0) }).filter {
			$0.teamIdentifier == scope.teamID && mappedIDs.contains($0.bundleIdentifier)
					&& (try? ZagCMSVerifier.verify($0.data).get()) != nil
			}
		}
		if let renewing {
			let originalIDs = Set(renewing.installation.profiles.map(\.originalBundleIdentifier))
			let mapped = Set(renewing.installation.profiles.map(\.bundleIdentifier))
			guard originalIDs == componentIDs, mapped == mappedIDs,
				  main.originalBundleIdentifier == renewing.installation.record.originalBundleIdentifier else {
				throw ZagNativeSigningPipeline.Failure.changedIdentity
			}
		}
		do {
			return try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: app,
				provisioner: provisioner, secrets: secrets,
				signer: ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), keychainKeys: keys),
				installer: ZagRPPairingFreeAccountInstaller(),
				verifyTarget: {
					guard ZagDeveloperTokenStore().load(scope: "device")?.accountID == token.accountID else { throw Failure.signIn }
					guard pairing.hasSavedPairing, pairing.pairedIdentity == device else { throw Failure.pairing }
				}, renewing: renewing?.installation, progress: progress, onVerified: { verified in
					try await ZagNativeAppInventory.save(verified, source: source, name: name, renewing: renewing)
					await onSaved(verified.record.bundleIdentifier)
				})
		} catch let failure as ZagProvisioningFailure {
			switch failure.kind {
			case .certificateRequestUnresolved:
				let reader = Self.portal(token: token, consent: ZagDenyingMutationConsent())
				let recoveryProvisioner = ZagFreeAccountProvisioner(portal: reader, keys: keyFactory, secrets: secrets, account: scope.accountID)
				let recovery = ZagCertificateRecoveryModel(scope: scope, service: LockedRecovery(provisioner: recoveryProvisioner)) { scope in
					guard let current = ZagDeveloperTokenStore().load(scope: "device"), current.isUsable(at: Date()) else {
						throw Failure.signIn
					}
					let authorization = ZagSigningAuthorization.nativeAccount(token: current, teamID: scope.teamID)
					guard authorization.scope == scope else { throw Failure.signIn }
					return authorization
				}
				throw CertificateIssue(failure: failure, scope: scope, teamName: team.name, recovery: recovery)
			case .certificateMustBeRevoked:
				throw CertificateIssue(failure: failure, scope: scope, teamName: team.name, recovery: nil)
			default:
				throw failure
			}
		}
	}

	/// Adopt an earlier native installation only when the original import, the
	/// scoped cached profiles and the paired device all prove the exact match.
	static func reconcile(imports: [Imported], installedIDs: Set<String>) async {
		guard !imports.isEmpty, !installedIDs.isEmpty, let token = ZagDeveloperTokenStore().load(scope: "device"),
			  token.isUsable(at: Date()), ZagRPPairingCore.shared.hasSavedPairing else { return }
		try? await withExclusiveOperation {
			let teams = try await portal(token: token, consent: ZagDenyingMutationConsent(), maxRequests: 1).teams()
			guard let team = ZagNativeDeveloperTeam.personalTeam(in: teams) else { return }
			let auth = ZagSigningAuthorization.nativeAccount(token: token, teamID: team.teamID)
			let scope = auth.scope
			let cache = ProfileCache(scope: scope)
			guard let raw = try secrets.load(.signingPrivateKey, account: scope.accountID, team: scope.teamID),
				  let identity = try? JSONDecoder().decode(ZagSigningIdentity.self, from: raw),
				  identity.keyIsInKeychain else { return }
			let keys = ZagKeychainSigningKeyFactory(keys: ZagKeychainSigningKeys(namespace: namespace))
			guard case .matches = keys.check(certificate: identity.certificate, privateKey: identity.privateKey,
				account: scope.accountID, team: scope.teamID, keySlot: identity.keySlot) else { return }
			let installedProfiles = try await ZagRPPairingFreeAccountInstaller.readProfiles().get()
			for imported in imports {
				guard currentAccountMatches(scope), let original = imported.identifier,
					  let mapped = ZagBundleIdentifierMapping.mapped(original, team: scope.teamID),
					  installedIDs.contains(mapped), ZagNativeAppInventory.entry(bundleIdentifier: mapped) == nil,
					  let source = Storage.shared.getAppDirectory(for: imported),
					  let metadata = try? reconcileProfiles(source: source, original: original, mapped: mapped, scope: scope,
						auth: auth, identity: identity, cache: cache, installed: installedProfiles) else { continue }
				try await ZagNativeAppInventory.save(metadata, source: source, name: imported.name ?? "App", renewing: nil)
			}
		}
	}

	private static func reconcileProfiles(source: URL, original: String, mapped: String, scope: ZagSigningScope,
		auth: ZagSigningAuthorization, identity: ZagSigningIdentity, cache: ProfileCache, installed: [Data]) throws -> ZagNativeInstalledProfiles? {
		var identifiers = [(original, mapped)]
		for extensionID in try ZagFreeAccountSigningAdapter.extensionPaths(in: source).keys.sorted() {
			guard let mappedExtension = ZagBundleIdentifierMapping.mappedExtension(extensionID, appOriginal: original, team: scope.teamID) else { return nil }
			identifiers.append((extensionID, mappedExtension))
		}
		var components: [ZagNativeInstalledProfiles.Component] = []
		var profiles: [ZagIssuedProfile] = []
		for (originalID, mappedID) in identifiers {
			guard let profile = cache.profile(for: mappedID), installed.contains(profile.data),
				  (try? ZagCMSVerifier.verify(profile.data).get()) != nil,
				  profile.teamIdentifier == scope.teamID, profile.bundleIdentifier == mappedID,
				  profile.certificateSerials.contains(identity.serialNumber) else { return nil }
			profiles.append(profile)
			components.append(.init(originalBundleIdentifier: originalID, bundleIdentifier: mappedID,
				uuid: profile.uuid, expiresAt: profile.expiresAt))
		}
		guard let main = profiles.first, let expires = profiles.map(\.expiresAt).min(),
			  let installedApp = ZagRPPairingCore.shared.installedAppInfo(bundleID: mapped),
			  let cn = ZagCertificateInspection(der: identity.certificate)?.commonName, installedApp.signerIdentity == cn else { return nil }
		let bundle = Bundle(url: source)
		guard bundle?.version == installedApp.version,
			  bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == installedApp.build else { return nil }
		let record = ZagSignedAppRecord(bundleIdentifier: mapped, originalBundleIdentifier: original, signedAt: main.createdAt,
			profileExpiresAt: expires, certificateExpiresAt: identity.expiresAt,
			owner: .init(scope: scope, teamKind: auth.teamKind, certificateSerial: identity.serialNumber, profileUUID: main.uuid),
			expiryVerified: true)
		return .init(record: record, profiles: components)
	}

	private static func component(at app: URL, name: String) throws -> ZagProvisioningRequest.Component {
		guard let identifier = ZagFreeAccountSigningAdapter.bundleIdentifier(of: app),
			  let entitlements = ZagDeveloperAccountLive.requestedEntitlements(of: app) else { throw Failure.invalidApp }
		return .init(originalBundleIdentifier: identifier, name: name, entitlements: entitlements)
	}

	private static func appendingName(_ name: String, path: String) -> String {
		"\(name) \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
	}
}
#endif
