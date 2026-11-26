#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
import Foundation
import CryptoKit
import UIKit

@MainActor
enum ZagNativeAccountInstall {
	enum Failure: LocalizedError, Equatable {
		case busy, signIn, personalTeam, pairing, invalidApp
		case unsupportedOptions([String])

		var errorDescription: String? {
			switch self {
			case .busy: "An Apple Account installation is already in progress."
			case .signIn: "Sign in under Settings › Apple Accounts & Signing."
			case .personalTeam: "No active Personal Team was found for this Apple Account."
			case .pairing: "Pair this iPhone in Settings before signing and installing."
			case .unsupportedOptions(let changes): "Use Certificate to apply these customisations: \(changes.joined(separator: ", "))."
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
		let machine = ZagAppleAuthMachine.nativeAccount(accountID: token.nativeAccountID)
		return ZagNativeDeveloperPortal(transport: ZagNativeDeveloperPortal.transport(), headers: {
			guard await ZagNativeAppleIDs.shared.connectedToken(token.nativeAccountID) == token,
				  let headers = await machine.developerHeaders(expectedAccountID: token.accountID),
				  await ZagNativeAppleIDs.shared.connectedToken(token.nativeAccountID) == token else {
				throw ZagPortalError.sessionRejected
			}
			return headers
		}, consent: consent, maxRequests: maxRequests)
	}
	static func validateSigningScope(_ scope: ZagSigningScope) async throws {
		guard let token = ZagNativeAppleIDs.shared.connectedToken(scope.accountID) else { throw Failure.signIn }
		let reader = portal(token: token, consent: ZagMutationConsentCoordinator(), maxRequests: 2)
		let teams = try await reader.teams()
		_ = try await ZagAppleIDSigningSelection.team(from: teams, required: scope.teamID)
		guard ZagNativeAppleIDs.shared.connectedToken(scope.accountID) == token else { throw Failure.signIn }
	}

	static var hasSession: Bool {
		((try? ZagNativeAppleIDs.shared.catalog().accounts) ?? []).contains { ZagNativeAppleIDs.shared.connectedToken($0.id) != nil }
	}

	static func hasConnectedAccount(_ accountID: UUID) -> Bool {
		ZagNativeAppleIDs.shared.connectedToken(accountID) != nil
	}

	/// A batch owns its inventory snapshot and read-only developer discovery.
	/// The device queue is shared with individual refreshes and full fallback.
	@MainActor
	final class RefreshCoordinator {
		private struct Discovery: Sendable {
			let portal: ZagNativeDeveloperPortal
			let appIDs: [ZagRegisteredAppID]
			let certificates: [ZagDevelopmentCertificate]
			let token: ZagPersistedDeveloperToken
		}
		private let discovery = ZagProfileOnlyRenewal.ReadCache<ZagSigningScope, Discovery>()
		private let inventory = ZagProfileOnlyRenewal.ReadCache<Bool, (ZagPairedDeviceIdentity, [String: ZagRPPairingCore.InstalledAppInfo])>()
		private static let deviceQueue = ZagProfileOnlyRenewal.DeviceQueue()
		private static var refreshingApps: Set<String> = []
		private static var batchRunning = false

		static func beginBatch() -> Bool {
			guard !batchRunning else { return false }
			batchRunning = true
			return true
		}

		static func endBatch() { batchRunning = false }

		static func onDevice<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
			try await deviceQueue.run(operation)
		}

		static func reserve(_ uuid: String) throws {
			guard refreshingApps.insert(uuid).inserted else { throw Failure.busy }
		}

		static func release(_ uuid: String) { refreshingApps.remove(uuid) }

		static func installAndReadBack(_ profiles: [Data]) async throws -> [Data] {
			let pairing = ZagRPPairingCore.shared
			do { return try await pairing.installProfiles(profiles) }
			catch {
				let reason = error.localizedDescription.lowercased()
				guard ["broken pipe", "channel closed", "connection reset", "timed out", "already running", "socket io failed"]
					.contains(where: { reason.contains($0) }) else { throw error }
				ZagSigningDiagnostics.record("Retrying profile management once after a transport failure")
				try await Task.sleep(for: .milliseconds(250))
				if let observed = try? await ZagRPPairingFreeAccountInstaller.readProfiles().get(),
				   profiles.allSatisfy({ observed.contains($0) }) { return observed }
				return try await pairing.installProfiles(profiles)
			}
		}

		private func discover(_ scope: ZagSigningScope) async throws -> Discovery {
			try await discovery.value(for: scope) {
				guard let token = ZagNativeAppleIDs.shared.connectedToken(scope.accountID) else { throw Failure.signIn }
				let consent = ZagMutationConsentCoordinator()
				consent.authorize([.downloadProfile])
				let portal = ZagNativeAccountInstall.portal(token: token, consent: consent)
				do {
					async let apps = portal.appIDs(team: scope.teamID)
					async let certificates = portal.certificates(team: scope.teamID)
					return try await Discovery(portal: portal, appIDs: apps, certificates: certificates, token: token)
				} catch let error as ZagPortalOperationFailure where error.underlying == .sessionRejected {
					try? ZagNativeAppleIDs.shared.invalidate(token)
					throw error
				}
			}
		}

		private func readDevice() async throws -> (ZagPairedDeviceIdentity, [String: ZagRPPairingCore.InstalledAppInfo]) {
			try await inventory.value(for: true) {
				try await Self.onDevice { try await ZagRPPairingCore.shared.signingDeviceInventory() }
			}
		}

		func renew(_ entry: ZagNativeAppInventory.Entry, job: String) async throws -> ZagInstallVerification {
			let receipt = entry.installation
			let start = ContinuousClock.now
			defer { ZagSigningDiagnostics.elapsed("Profile-only attempt total", since: start) }
			ZagSigningDiagnostics.record("Renewal strategy: attempting profile-only")
			func requiresResign(_ reason: String) -> ZagProfileOnlyRenewal.Failure {
				ZagSigningDiagnostics.record("Profile-only rejected: \(reason)")
				return .needsResign
			}
			guard let owner = receipt.record.owner else { throw requiresResign("missing signing owner") }
			guard let identity = receipt.executableIdentity else { throw requiresResign("missing executable identity (legacy receipt)") }
			guard let certificate = ZagCertificateInspection(der: identity.certificate) else { throw requiresResign("saved certificate could not be inspected") }
			guard certificate.serialNumber == owner.certificateSerial else { throw requiresResign("certificate serial mismatch") }
			guard certificate.organizationalUnit == owner.scope.teamID else { throw requiresResign("certificate team mismatch") }
			guard certificate.expiresAt > Date() else { throw requiresResign("certificate expired") }
			guard receipt.profiles.allSatisfy({ $0.signedEntitlements != nil }) else { throw requiresResign("missing signed component entitlements") }
			let jobs = ZagInstallJobs.shared
			try jobs.checkpoint(job)
			jobs.reportNative(job, .provisioning)
			let pairing = ZagRPPairingCore.shared
			async let developer = discover(owner.scope)
			let (device, installed) = try await readDevice()
			ZagSigningDiagnostics.elapsed("Installed app inventory", since: start)
			guard let installedApp = installed[receipt.record.bundleIdentifier],
				  let version = identity.version, installedApp.version == version,
				  let build = identity.build, installedApp.build == build,
				  let name = certificate.commonName, !name.isEmpty, installedApp.signerIdentity == name else {
				throw ZagProfileOnlyRenewal.Failure.appUnavailable
			}
			let discovered = try await developer
			ZagSigningDiagnostics.elapsed("Scoped developer discovery", since: start)
			guard discovered.certificates.contains(where: {
				$0.serialNumber == owner.certificateSerial && $0.expiresAt > Date()
					&& ($0.data == nil || $0.data == identity.certificate)
			}) else { throw requiresResign("saved certificate not found or incompatible in developer inventory") }

			let requestStart = ContinuousClock.now
			var requested: [ZagIssuedProfile] = []
			// One app requests its extensions in order. Independent apps share
			// discovery but perform these developer calls concurrently.
			for component in receipt.profiles {
				try Task.checkCancellation()
				try jobs.checkpoint(job)
				guard let appID = discovered.appIDs.first(where: { $0.bundleIdentifier == component.bundleIdentifier }) else {
					throw requiresResign("registered component App ID missing")
				}
				let profile: ZagIssuedProfile
				do {
					do { profile = try await discovered.portal.profile(for: appID, team: owner.scope.teamID) }
					catch where (error as? ZagPortalOperationFailure)?.underlying == .network || (error as? ZagPortalError) == .network {
						try await Task.sleep(for: .milliseconds(250))
						try jobs.checkpoint(job)
						profile = try await discovered.portal.profile(for: appID, team: owner.scope.teamID)
					}
				} catch let error as ZagPortalOperationFailure where error.underlying == .sessionRejected {
					try? ZagNativeAppleIDs.shared.invalidate(discovered.token)
					throw error
				}
				do {
					requested.append(try ZagProfileOnlyRenewal.validate(profile.data, component: component,
						team: owner.scope.teamID, certificate: identity.certificate, udid: device.udid))
				} catch {
					ZagSigningDiagnostics.record("Profile-only component validation failed")
					throw error
				}
			}
			ZagSigningDiagnostics.elapsed("Renew and validate profiles", since: requestStart)
			_ = try ZagProfileOnlyRenewal.effectiveExpiry(requested, certificateExpires: certificate.expiresAt,
				previous: receipt.record.expiresAt, now: Date())

			let queued = ContinuousClock.now
			return try await Self.onDevice {
				try jobs.checkpoint(job)
				guard pairing.pairedIdentity == device,
					  ZagNativeAppleIDs.shared.connectedToken(owner.scope.accountID) == discovered.token else { throw Failure.signIn }
				ZagSigningDiagnostics.elapsed("Device queue wait", since: queued)
				try jobs.beginInstalling(job)
				jobs.setNativeProgress(job, caption: "Installing", fraction: ZagNativeSigningProgress.installing.fraction)
				let handoff = ContinuousClock.now
				let readback = try await Self.installAndReadBack(requested.map(\.data))
				ZagSigningDiagnostics.elapsed("Misagent install and readback", since: handoff)
				jobs.reportNative(job, .verifying)
				guard requested.allSatisfy({ readback.contains($0.data) }), pairing.pairedIdentity == device else {
					throw ZagProfileOnlyRenewal.Failure.readback
				}
				let expiry = try ZagProfileOnlyRenewal.effectiveExpiry(requested, certificateExpires: certificate.expiresAt,
					previous: receipt.record.expiresAt, now: Date())
				let persistence = ContinuousClock.now
				try ZagNativeAppInventory.confirmProfileRefresh(entry, profiles: requested)
				ZagSigningDiagnostics.elapsed("Persist verified expiry", since: persistence)
				return .verified(profileExpiresAt: expiry, certificateExpiresAt: certificate.expiresAt)
			}
		}
	}

	static func install(source: URL, name: String, accountID: UUID, expectedScope: ZagSigningScope? = nil,
						requiredInstalledIdentifier: String? = nil,
						forbiddenInstalledIdentifier: String? = nil,
						installAfterSigning: Bool = true,
						archiveTime: Duration? = nil,
						checkpoint: @escaping @MainActor () throws -> Void = {},
						beginInstalling: @escaping @MainActor @Sendable () throws -> Void = {},
						onCertificateReady: (@Sendable () async -> Void)? = nil,
						renewing: ZagNativeAppInventory.Entry? = nil,
						progress: @escaping @Sendable (ZagNativeSigningProgress) async -> Void = { _ in },
						onSaved: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ZagInstallVerification {
		try await withExclusiveOperation {
			try await ZagSigningDiagnostics.current.withValue(ZagSigningDiagnostics.current.get() ?? ZagSigningDiagnostics()) {
				ZagSigningDiagnostics.record("Native signing attempt started")
				if let archiveTime { ZagSigningDiagnostics.record("Original IPA lookup and extraction: \(archiveTime)") }
				let started = ContinuousClock.now
				defer { ZagSigningDiagnostics.elapsed("Full signing total", since: started) }
				await progress(.preparing)
				if let renewing {
					guard let owner = renewing.installation.record.owner, owner.scope == expectedScope,
						  owner.scope.accountID == accountID else { throw ZagNativeAppInventory.Failure.wrongAccount }
				}
				return try await performInstall(source: source, name: name, accountID: accountID, expectedScope: expectedScope,
					requiredInstalledIdentifier: requiredInstalledIdentifier, forbiddenInstalledIdentifier: forbiddenInstalledIdentifier,
					installAfterSigning: installAfterSigning,
					checkpoint: checkpoint, beginInstalling: beginInstalling,
					onCertificateReady: onCertificateReady, renewing: renewing, progress: progress, onSaved: onSaved)
			}
		}
	}

	private static func performInstall(source: URL, name: String, accountID: UUID, expectedScope: ZagSigningScope?,
									   requiredInstalledIdentifier: String?, forbiddenInstalledIdentifier: String?, installAfterSigning: Bool,
									   checkpoint: @escaping @MainActor () throws -> Void,
									   beginInstalling: @escaping @MainActor @Sendable () throws -> Void,
									   onCertificateReady: (@Sendable () async -> Void)?,
									   renewing: ZagNativeAppInventory.Entry?,
									   progress: @escaping @Sendable (ZagNativeSigningProgress) async -> Void,
									   onSaved: @escaping @Sendable (String) async -> Void) async throws -> ZagInstallVerification {
		let pairing = ZagRPPairingCore.shared
		guard pairing.hasSavedPairing else { throw Failure.pairing }
		guard let token = ZagNativeAppleIDs.shared.connectedToken(accountID) else {
			throw Failure.signIn
		}
		if let expectedScope, expectedScope.accountID != accountID { throw Failure.signIn }

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let app = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
		let copyStart = ContinuousClock.now
		try await Task.detached(priority: .userInitiated) {
			try FileManager.default.copyItem(at: source, to: app)
		}.value
		ZagSigningDiagnostics.elapsed("Copy app bundle", since: copyStart)
		try Task.checkCancellation()
		let main = try component(at: app, name: name)
		let extensions = try ZagFreeAccountSigningAdapter.extensionPaths(in: app).values.sorted().map {
			try component(at: app.appendingPathComponent($0), name: appendingName(name, path: $0))
		}

		let inventoryStart = ContinuousClock.now
		ZagSigningDiagnostics.record("Reading paired device and installed apps")
		let (device, installed) = try await pairing.signingDeviceInventory()
		let installedProfiles = (try? await ZagRPPairingFreeAccountInstaller.readProfiles().get()) ?? []
		let profiles = installedProfiles.compactMap { try? ZagIssuedProfile(profileData: $0) }
		ZagSigningDiagnostics.elapsed("Full signing device inventory and profile readback", since: inventoryStart)


		if let renewing {
			let prior = renewing.installation
			let observed = prior.profiles.compactMap { expected in
				profiles.first { $0.uuid == expected.uuid && $0.bundleIdentifier == expected.bundleIdentifier
					&& $0.teamIdentifier == prior.record.owner?.scope.teamID }?.expiresAt
			}
			if observed.count == prior.profiles.count, let expiry = observed.min() {
				ZagSigningDiagnostics.record("Before refresh: installed profile expiry \(expiry)")
				guard expiry == prior.record.profileExpiresAt else { throw ZagNativeSigningPipeline.Failure.changedIdentity }
			} else {
				ZagSigningDiagnostics.record("Before refresh: last verified expiry \(prior.record.profileExpiresAt); prior profiles not all readable")
			}
		}

		let consent = ZagMutationConsentCoordinator()
		defer { consent.cancel() }
		let components = [main] + extensions
		let groupCount = components.reduce(0) {
			$0 + (($1.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String])?.count ?? 0)
		}
		let portal = portal(token: token, consent: consent, maxRequests: 24 + 8 * components.count + groupCount)
		ZagSigningDiagnostics.record("Selecting Personal Team")
		let teams: [ZagNativeDeveloperTeam]
		do { teams = try await portal.teams() }
		catch let failure as ZagPortalOperationFailure where failure.underlying == .sessionRejected {
			try? ZagNativeAppleIDs.shared.invalidate(token)
			throw failure
		}
		try? ZagNativeAppleIDs.shared.storeTeams(teams.map(\.signingTeam), for: accountID)
		let team = try await ZagAppleIDSigningSelection.team(from: teams, required: expectedScope?.teamID)
		let authorization = ZagSigningAuthorization.nativeAccount(token: token, teamID: team.teamID)
		let scope = authorization.scope
		guard expectedScope == nil || expectedScope == scope else { throw Failure.signIn }
		let keys = ZagKeychainSigningKeys(namespace: namespace)
		let keyFactory = ZagKeychainSigningKeyFactory(keys: keys)
		let cache = ProfileCache(scope: scope)
		consent.authorize([.addDevice, .addAppID, .submitCSR, .downloadProfile, .addAppGroup, .assignAppGroups, .updateAppID])
		let provisioner = ZagFreeAccountProvisioner(portal: portal, keys: keyFactory,
			secrets: secrets, certificateMinimumRemaining: 0, saveProfile: { cache.save($0) },
			onCertificateReady: onCertificateReady, account: scope.accountID)
		var request = ZagProvisioningRequest(accountID: scope.accountID, team: scope.teamID, deviceUDID: device.udid,
											 deviceName: device.name, app: main, extensions: extensions, installedFreeAccountApps: [])
		let componentIDs = Set(components.map(\.originalBundleIdentifier))
		let mappedIDs = Set(componentIDs.compactMap { id in
			id == main.originalBundleIdentifier
				? ZagBundleIdentifierMapping.mapped(id, team: scope.teamID)
				: ZagBundleIdentifierMapping.mappedExtension(id, appOriginal: main.originalBundleIdentifier, team: scope.teamID)
		})
		let mappedMain = ZagBundleIdentifierMapping.mapped(main.originalBundleIdentifier, team: scope.teamID)
		if let forbiddenInstalledIdentifier, forbiddenInstalledIdentifier == mappedMain {
			throw ZagNativeSigningPipeline.Failure.changedIdentity
		}
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
		try checkpoint()
		let retainSigned: @Sendable (ZagNativeInstalledProfiles, ZagInstallExpectation, URL) async throws -> Void = { metadata, expectation, signedApp in
			try await ZagNativeAppInventory.save(metadata, source: source, name: name, renewing: nil, signedOnly: (expectation, signedApp))
		}
		do {
			return try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: app,
				provisioner: provisioner, secrets: secrets,
				signer: ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), keychainKeys: keys),
				installer: ZagRPPairingFreeAccountInstaller(beforeHandoff: beginInstalling),
				verifyTarget: {
					guard ZagNativeAppleIDs.shared.connectedToken(accountID) == token else { throw Failure.signIn }
					guard pairing.hasSavedPairing, pairing.pairedIdentity == device else { throw Failure.pairing }
				}, beforeSigning: checkpoint, beforeInstalling: {
					try checkpoint()
					recordFreeAppLimitAdvisory(target: mappedMain,
						freeTeam: authorization.teamKind == .personalFree, installed: installed, profiles: profiles)
				},
				renewing: renewing?.installation, progress: progress, onVerified: { verified in
					try await ZagNativeAppInventory.save(verified, source: source, name: name, renewing: renewing)
					await onSaved(verified.record.bundleIdentifier)
				}, onSignedOnly: installAfterSigning ? nil : retainSigned, onDeferredInstall: retainSigned)
		} catch let error as ZagStagedSigningFailure where error.underlying is ZagInstallCancelled {
			throw error.underlying
		} catch let failure as ZagProvisioningFailure {
			switch failure.kind {
			case .certificateRequestUnresolved:
				let reader = Self.portal(token: token, consent: ZagDenyingMutationConsent())
				let recoveryProvisioner = ZagFreeAccountProvisioner(portal: reader, keys: keyFactory, secrets: secrets, account: scope.accountID)
				let recovery = ZagCertificateRecoveryModel(scope: scope, service: LockedRecovery(provisioner: recoveryProvisioner)) { scope in
					guard let current = await ZagNativeAppleIDs.shared.connectedToken(scope.accountID) else {
						throw Failure.signIn
					}
					let authorization = ZagSigningAuthorization.nativeAccount(token: current, teamID: scope.teamID)
					guard authorization.scope == scope else { throw Failure.signIn }
					return authorization
				}
				throw CertificateIssue(failure: failure, scope: scope, teamName: team.name, recovery: recovery)
			case .certificateMustBeRevoked:
				throw CertificateIssue(failure: failure, scope: scope, teamName: team.name, recovery: nil)
			case .sessionRejected:
				try? ZagNativeAppleIDs.shared.invalidate(token)
				throw failure
			default:
				throw failure
			}
		}
	}

	static func validateOptions(explicitCertificateChanges: [String]) throws {
		guard explicitCertificateChanges.isEmpty else { throw Failure.unsupportedOptions(explicitCertificateChanges) }
	}

	private static func recordFreeAppLimitAdvisory(target: String?, freeTeam: Bool,
		installed: [String: ZagRPPairingCore.InstalledAppInfo], profiles: [ZagIssuedProfile]) {
		guard freeTeam, let target, installed[target] == nil else { return }
		let proven = Set(profiles.compactMap { profile -> String? in
			guard installed[profile.bundleIdentifier] != nil,
				  let entry = ZagNativeAppInventory.entry(bundleIdentifier: profile.bundleIdentifier),
				  entry.pendingInstall == nil, entry.installation.record.expiryVerified == true,
				  let owner = entry.installation.record.owner, owner.teamKind == .personalFree,
				  owner.profileUUID == profile.uuid, owner.scope.teamID == profile.teamIdentifier,
				  profile.certificateSerials.contains(owner.certificateSerial) else { return nil }
			return profile.bundleIdentifier
		})
		if case .full(let installed) = ZagInstallSlotPlan.make(installing: target, installedFreeAccountApps: proven) {
			ZagSigningDiagnostics.record("Free app limit advisory: \(installed.count) verified free-profile apps are installed. Proceeding with installation for iOS to decide.")
		}
	}

	static func installSaved(entry: ZagNativeAppInventory.Entry, job: String) async throws {
		try await withExclusiveOperation {
			try await ZagSigningDiagnostics.current.withValue(ZagSigningDiagnostics.current.get() ?? ZagSigningDiagnostics()) {
				guard let expectation = entry.pendingInstall, let source = ZagNativeAppInventory.signedApp(entry) else {
					throw Failure.invalidApp
				}
				guard min(entry.installation.record.profileExpiresAt, expectation.certificateExpiresAt) > Date() else {
					throw ZagFreeAccountSigningError.verification("The signing certificate or provisioning profile expired. Resign this app first.")
				}
				let pairing = ZagRPPairingCore.shared
				guard pairing.hasSavedPairing else { throw Failure.pairing }
				let (device, installed) = try await pairing.signingDeviceInventory()
				ZagSigningDiagnostics.record("Validating previously signed app")
				do { try entry.installation.validateArtifact(source, expectation: expectation, deviceUDID: device.udid) }
				catch {
					ZagSigningDiagnostics.recordFailure(.verification, error)
					throw ZagStagedSigningFailure(phase: .verification, underlying: error)
				}
				if installed[expectation.bundleIdentifier] == nil, entry.installation.record.owner?.teamKind == .personalFree,
				   let readback = try? await ZagRPPairingFreeAccountInstaller.readProfiles().get() {
					recordFreeAppLimitAdvisory(target: expectation.bundleIdentifier, freeTeam: true, installed: installed,
						profiles: readback.compactMap { try? ZagIssuedProfile(profileData: $0) })
				}
				try ZagInstallJobs.shared.checkpoint(job)
				ZagInstallJobs.shared.reportNative(job, .installing)
				ZagSigningDiagnostics.record("Installing previously signed app")
				let installer = ZagRPPairingFreeAccountInstaller(beforeHandoff: {
					try ZagInstallJobs.shared.beginInstalling(job)
					ZagInstallJobs.shared.setNativeProgress(job, caption: ZagNativeSigningProgress.installing.title,
						fraction: ZagNativeSigningProgress.installing.fraction)
				})
				do { try await installer.install(signedApp: source, bundleIdentifier: expectation.bundleIdentifier) }
				catch is ZagInstallCancelled { throw ZagInstallCancelled() }
				catch {
					ZagSigningDiagnostics.recordFailure(.installation, error)
					throw ZagStagedSigningFailure(phase: .installation, underlying: error)
				}
				guard pairing.pairedIdentity == device else { throw Failure.pairing }
				ZagInstallJobs.shared.reportNative(job, .verifying)
				let result = await installer.verify(expectation)
				guard case .verified(let expiry, let certExpiry) = result else {
					let error = ZagFreeAccountSigningError.verification(String(describing: result))
					ZagSigningDiagnostics.recordFailure(.verification, error)
					throw ZagStagedSigningFailure(phase: .verification, underlying: error)
				}
				try ZagNativeAppInventory.confirm(entry, expiry: expiry, certificateExpiry: certExpiry)
				ZagInstallJobs.shared.reportNative(job, .verified)
			}
		}
	}

	/// Adopt an earlier native installation only when the original import, the
	/// scoped cached profiles and the paired device all prove the exact match.
	static func reconcile(imports: [Imported], installedIDs: Set<String>) async {
		guard !imports.isEmpty, !installedIDs.isEmpty, ZagRPPairingCore.shared.hasSavedPairing,
			  let catalog = try? ZagNativeAppleIDs.shared.catalog() else { return }
		for account in catalog.accounts {
			guard let token = ZagNativeAppleIDs.shared.connectedToken(account.id) else { continue }
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
					guard hasConnectedAccount(scope.accountID), let original = imported.identifier,
						  let mapped = ZagBundleIdentifierMapping.mapped(original, team: scope.teamID),
						  installedIDs.contains(mapped), ZagNativeAppInventory.entry(bundleIdentifier: mapped) == nil,
						  let source = Storage.shared.getAppDirectory(for: imported),
						  let metadata = try? reconcileProfiles(source: source, original: original, mapped: mapped, scope: scope,
							auth: auth, identity: identity, cache: cache, installed: installedProfiles) else { continue }
					try await ZagNativeAppInventory.save(metadata, source: source, name: imported.name ?? "App", renewing: nil)
				}
			}
		}
	}

	private static func reconcileProfiles(source: URL, original: String, mapped: String, scope: ZagSigningScope,
		auth: ZagSigningAuthorization, identity: ZagSigningIdentity, cache: ProfileCache, installed: [Data]) throws -> ZagNativeInstalledProfiles? {
		var identifiers = [(original, mapped)]
		for extensionID in ZagFreeAccountSigningAdapter.extensionPaths(in: source).keys.sorted() {
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

#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
extension ZagInstallJobs {
	func reportNative(_ id: String, _ stage: ZagNativeSigningProgress) {
		if stage == .installing {
			advance(id, to: .packaging)
			setNativeProgress(id, caption: "Preparing", fraction: stage.fraction)
		} else { setNativeProgress(id, caption: stage.title, fraction: stage.fraction) }
	}
}

extension ZagNativeAccountInstall {
	static func runInline(_ app: AppInfoPresentable, job: String, options: ZagAppleIDSigningOptions, renew: Bool = false,
		requiredInstalledIdentifier: String? = nil, requiredScope: ZagSigningScope? = nil,
		interactive: Bool = true, refreshCoordinator: RefreshCoordinator? = nil,
		onSaved: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ZagInstallVerification {
		let entry = ZagNativeAppInventory.entry(app)
		if renew {
			guard let entry, let scope = entry.installation.record.owner?.scope else {
				throw ZagNativeAppInventory.Failure.wrongAccount
			}
			ZagInstallJobs.shared.setNativeProgress(job, caption: hasConnectedAccount(scope.accountID) ? "Refreshing" : "Authenticating", fraction: 0)
			let id = try await ZagAppleIDSigningSelection.resolve(required: scope.accountID, interactive: interactive)
			let coordinator = refreshCoordinator ?? RefreshCoordinator()
			try RefreshCoordinator.reserve(entry.uuid)
			defer { RefreshCoordinator.release(entry.uuid) }
			do {
				return try await ZagSigningDiagnostics.current.withValue(ZagSigningDiagnostics.current.get() ?? ZagSigningDiagnostics()) {
					try await coordinator.renew(entry, job: job)
				}
			} catch where (error as? ZagProfileOnlyRenewal.Failure) == .needsResign
				|| error.localizedDescription.localizedCaseInsensitiveContains("misagent over RSD failed: service not found") {
				ZagSigningDiagnostics.record("Renewal strategy: full re-sign fallback")
				if (error as? ZagProfileOnlyRenewal.Failure) != .needsResign {
					ZagSigningDiagnostics.record("Fallback reason: misagent service unavailable")
				}
				ZagInstallJobs.shared.advance(job, to: .signing)
				guard ZagNativeAppInventory.hasSource(entry) else { throw ZagNativeAppInventory.Failure.missingSource }
				let started = ContinuousClock.now
				return try await ZagNativeAppInventory.withSource(entry) { source in
					let unpacked = started.duration(to: .now)
					let queued = ContinuousClock.now
					return try await RefreshCoordinator.onDevice {
						ZagSigningDiagnostics.elapsed("Full re-sign device queue wait", since: queued)
						try ZagInstallJobs.shared.checkpoint(job)
						return try await runInlineSource(source, name: entry.name, accountID: id, job: job,
							installAfterSigning: true, renewing: entry, interactive: interactive,
							archiveTime: unpacked)
					}
				}
			}
		}
		guard let source = Storage.shared.getAppDirectory(for: app) else { throw Failure.invalidApp }
		ZagInstallJobs.shared.setNativeProgress(job, caption: "Authenticating", fraction: 0)
		let id = try await ZagAppleIDSigningSelection.resolve(required: requiredScope?.accountID, interactive: interactive)
		return try await runInlineSource(source, name: app.name ?? "App", accountID: id, job: job,
			installAfterSigning: options.installAfterSigning, requiredInstalledIdentifier: requiredInstalledIdentifier,
			requiredScope: requiredScope, interactive: interactive, onSaved: onSaved)
	}

	static func signSeparateCopy(_ entry: ZagNativeAppInventory.Entry, using accountID: UUID, job: String,
		options: ZagAppleIDSigningOptions) async throws -> ZagInstallVerification {
		guard let owner = entry.installation.record.owner, owner.scope.accountID != accountID else {
			throw ZagNativeAppleIDs.Failure.wrongAccount
		}
		return try await ZagNativeAppInventory.withSource(entry) { source in
			try await runInlineSource(source, name: entry.name, accountID: accountID, job: job,
				installAfterSigning: options.installAfterSigning, forbiddenInstalledIdentifier: entry.installation.record.bundleIdentifier)
		}
	}

	private static func runInlineSource(_ source: URL, name: String, accountID: UUID, job: String, installAfterSigning: Bool,
		renewing: ZagNativeAppInventory.Entry? = nil, requiredInstalledIdentifier: String? = nil, forbiddenInstalledIdentifier: String? = nil,
		requiredScope: ZagSigningScope? = nil, interactive: Bool = true, archiveTime: Duration? = nil, onSaved: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ZagInstallVerification {
		let jobs = ZagInstallJobs.shared
		func attempt() async throws -> ZagInstallVerification {
			try await install(source: source, name: name, accountID: accountID, expectedScope: renewing?.installation.record.owner?.scope ?? requiredScope,
				requiredInstalledIdentifier: requiredInstalledIdentifier, forbiddenInstalledIdentifier: forbiddenInstalledIdentifier,
				installAfterSigning: installAfterSigning, archiveTime: archiveTime, checkpoint: { try jobs.checkpoint(job) },
				beginInstalling: {
					try jobs.beginInstalling(job)
					jobs.setNativeProgress(job, caption: ZagNativeSigningProgress.installing.title, fraction: ZagNativeSigningProgress.installing.fraction)
				}, renewing: renewing,
				progress: { @MainActor stage in jobs.reportNative(job, stage) }, onSaved: onSaved)
		}
		let result: ZagInstallVerification
		do { result = try await attempt() }
		catch {
			let rejected = (error as? ZagProvisioningFailure)?.kind == .sessionRejected
				|| (error as? ZagPortalOperationFailure)?.underlying == .sessionRejected
			guard interactive, rejected, ZagNativeAppleIDs.shared.connectedToken(accountID) == nil else { throw error }
			_ = try await ZagAppleIDSigningSelection.resolve(required: accountID)
			result = try await attempt()
		}
		switch result {
		case .verified, .signedOnly: return result
		default: throw ZagNativeAppInventory.Failure.unverified
		}
	}

	struct LocalCertificate: Identifiable {
		let scope: ZagSigningScope
		let title: String
		let serial: String
		let expires: Date
		let hasPrivateKey: Bool
		var id: ZagSigningScope { scope }
	}

	static func localCertificates() -> [LocalCertificate] {
		let keys = ZagKeychainSigningKeyFactory(keys: ZagKeychainSigningKeys(namespace: namespace))
		return ((try? secrets.signingIdentityScopes()) ?? []).compactMap { scope in
			guard let data = try? secrets.load(.signingPrivateKey, account: scope.accountID, team: scope.teamID),
				  let identity = try? JSONDecoder().decode(ZagSigningIdentity.self, from: data),
				  let certificate = ZagCertificateInspection(der: identity.certificate) else { return nil }
			let matches: Bool
			if identity.keyIsInKeychain, case .matches = keys.check(certificate: identity.certificate,
				privateKey: Data(), account: scope.accountID, team: scope.teamID, keySlot: identity.keySlot) {
				matches = true
			} else { matches = false }
			return LocalCertificate(scope: scope, title: certificate.commonName ?? "Apple Development",
				serial: certificate.serialNumber, expires: certificate.expiresAt, hasPrivateKey: matches)
		}.sorted { $0.expires > $1.expires }
	}

	static func failurePhase(_ error: Error, fallback: ZagSigningFailurePhase = .signing) -> ZagSigningFailurePhase {
		let staged = error as? ZagStagedSigningFailure
		let cause = staged?.underlying ?? error
		if (cause as? ZagNativeSigningPipeline.Failure) == .expiryNotExtended { return .refresh }
		if cause is ZagNativeAppleIDs.Failure || (cause as? Failure) == .signIn
			|| (cause as? ZagFreeAccountSigningError) == .notAuthorized { return .authentication }
		if let staged { return staged.phase }
		if let failure = cause as? ZagProvisioningFailure {
			return failure.kind == .sessionRejected || failure.kind == .notAuthorized ? .authentication : .provisioning
		}
		if (cause as? ZagPortalOperationFailure)?.underlying == .sessionRejected { return .authentication }
		if cause is ZagPortalOperationFailure || cause is CertificateIssue || (cause as? Failure) == .personalTeam { return .provisioning }
		if case .verification? = cause as? ZagFreeAccountSigningError { return .verification }
		return fallback
	}

	static func showInlineFailure(_ error: Error, fallback: ZagSigningFailurePhase = .signing, customise: (() -> Void)? = nil) {
		let phase = failurePhase(error, fallback: fallback)
		let limit = ZagFreeAppLimitReached.classify(error)
		let report = [ZagSigningDiagnostics.latest, ZagSigningDiagnostics.failureDetails(phase, error)].filter { !$0.isEmpty }.joined(separator: "\n")
		var actions = [UIAlertAction(title: "OK", style: .cancel),
			UIAlertAction(title: "Copy Diagnostics", style: .default) { _ in UIPasteboard.general.string = report }]
		if let limit {
			let installed = ZagRPPairingCore.shared.installedApps
			for id in limit.bundleIDs {
				guard let app = installed[id], !app.name.isEmpty, app.name != id else { continue }
				actions.append(UIAlertAction(title: "Open \(app.name)", style: .default) { _ in UIApplication.openApp(with: id) })
			}
		} else if phase == .signing, let customise {
			actions.append(UIAlertAction(title: "Customise App", style: .default) { _ in customise() })
		}
		let expiredRefresh = ((error as? ZagStagedSigningFailure)?.underlying ?? error) as? ZagNativeSigningPipeline.Failure
		let message = expiredRefresh == .expiryNotExtended ? "Apple did not issue a profile with a later expiration." : phase.message
		UIAlertController.showAlert(title: limit == nil ? phase.title : ZagFreeAppLimitReached.title,
			message: limit == nil ? message : ZagFreeAppLimitReached.message, actions: actions)
	}
}
#endif
