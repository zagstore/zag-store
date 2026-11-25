#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
import Foundation

@MainActor
enum ZagNativeAccountInstall {
	enum Failure: LocalizedError {
		case busy, signIn, personalTeam, pairing, invalidApp, identity, installationUnverified

		var errorDescription: String? {
			switch self {
			case .busy: "An Apple Account installation is already in progress."
			case .signIn: "Sign in under Settings › Apple Accounts & Signing."
			case .personalTeam: "No active Personal Team was found for this Apple Account."
			case .pairing: "Pair this iPhone in Settings before signing and installing."
			case .invalidApp: "Zag Store could not read the app or one of its extensions."
			case .identity: "Zag Store could not load the signing identity for this Apple Account."
			case .installationUnverified: "The installer finished, but Zag Store could not verify the app and its provisioning profile on this iPhone."
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

	private static var running = false
	static let namespace = "app.zagstore.native-account"
	static var secrets: ZagKeychainFreeAccountSecretStore { .init(service: namespace) }

	static func withExclusiveOperation<T>(_ operation: () async throws -> T) async throws -> T {
		guard !running else { throw Failure.busy }
		running = true
		defer { running = false }
		return try await operation()
	}

	static func portal(token: ZagPersistedDeveloperToken, consent: ZagAccountMutationConsent) -> ZagNativeDeveloperPortal {
		let machine = ZagAppleAuthMachine.nativeAccount()
		return ZagNativeDeveloperPortal(transport: ZagNativeDeveloperPortal.transport(), headers: {
			guard let headers = await machine.developerHeaders(expectedAccountID: token.accountID) else {
				throw ZagPortalError.sessionRejected
			}
			return headers
		}, consent: consent, maxRequests: nil)
	}
	static var hasSession: Bool {
		ZagDeveloperTokenStore().load(scope: "device")?.isUsable(at: Date()) == true
	}

	static func install(source: URL, name: String, expectedScope: ZagSigningScope? = nil) async throws -> ZagInstallVerification {
		try await withExclusiveOperation { try await performInstall(source: source, name: name, expectedScope: expectedScope) }
	}

	private static func performInstall(source: URL, name: String, expectedScope: ZagSigningScope?) async throws -> ZagInstallVerification {
		guard let device = ZagDeveloperAccountLive.pairedDevice else { throw Failure.pairing }
		guard let token = ZagDeveloperTokenStore().load(scope: "device"), token.isUsable(at: Date()) else {
			throw Failure.signIn
		}

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let app = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
		try FileManager.default.copyItem(at: source, to: app)
		let main = try component(at: app, name: name)
		let extensions = try ZagFreeAccountSigningAdapter.extensionPaths(in: app).values.sorted().map {
			try component(at: app.appendingPathComponent($0), name: appendingName(name, path: $0))
		}

		let consent = ZagMutationConsentCoordinator()
		consent.authorize([.addDevice, .addAppID, .submitCSR, .downloadProfile, .addAppGroup, .assignAppGroups])
		defer { consent.cancel() }
		let portal = portal(token: token, consent: consent)
		guard let team = try await portal.teams().first(where: { $0.isPersonalTeam && (expectedScope == nil || $0.teamID == expectedScope?.teamID) }) else { throw Failure.personalTeam }
		let authorization = ZagSigningAuthorization.nativeAccount(token: token, teamID: team.teamID)
		let scope = authorization.scope
		guard expectedScope == nil || expectedScope == scope else { throw Failure.signIn }
		let keys = ZagKeychainSigningKeys(namespace: namespace)
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: ZagKeychainSigningKeyFactory(keys: keys),
													secrets: secrets, account: scope.accountID)
		let request = ZagProvisioningRequest(accountID: scope.accountID, team: scope.teamID, deviceUDID: device.udid,
											 deviceName: device.name, app: main, extensions: extensions, installedFreeAccountApps: [])
		let result: ZagProvisioningResult
		switch await provisioner.provision(request, authorization: authorization) {
		case .success(let provisioned):
			result = provisioned
		case .failure(let failure):
			switch failure.kind {
			case .certificateRequestUnresolved:
				let recovery = ZagCertificateRecoveryModel(scope: scope, service: LockedRecovery(provisioner: provisioner)) { scope in
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
		guard let data = try secrets.load(.signingPrivateKey, account: scope.accountID, team: scope.teamID) else {
			throw Failure.identity
		}
		let identity = try JSONDecoder().decode(ZagSigningIdentity.self, from: data)
		let adapter = ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), keychainKeys: keys)
		let record = try adapter.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: Date())
		guard ZagDeveloperTokenStore().load(scope: "device")?.accountID == token.accountID else { throw Failure.signIn }
		guard ZagDeveloperAccountLive.pairedDevice?.udid == device.udid else { throw Failure.pairing }
		let installer = ZagRPPairingFreeAccountInstaller()
		try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier)
		return await installer.verify(ZagInstallExpectation(
			bundleIdentifier: record.bundleIdentifier, profileUUID: result.app.profile.uuid,
			profileExpiresAt: result.app.profile.expiresAt, certificateExpiresAt: record.certificateExpiresAt,
			signerCommonName: ZagCertificateInspection(der: identity.certificate)?.commonName,
			teamIdentifier: result.team, extensionProfileUUIDs: result.extensions.map(\.profile.uuid)
		))
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
