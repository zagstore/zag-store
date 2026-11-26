import Foundation

extension Tests {
	@MainActor
	static func nativeAppIDsAcrossAccounts() async {
		await testNativeAccountLibrary()
		let clock = TestClock()
		let secrets = MemorySecrets()
		let original = "com.example.integration"
		let accounts = ["111111111", "222222222", "333333333"]
		let teams = ["FREETEAM01", "FREETEAM02", "FREETEAM03"]
		let fixture = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
		let certificate = ZagCertificateInspection(der: fixture)!
		let expiration = clock.now + 7 * 86_400
		let transport = NativeAppIDTransport(teams: Dictionary(uniqueKeysWithValues: zip(accounts, teams)), certDER: fixture,
			certificateSerial: certificate.serialNumber, now: clock.now)
		let parallelA = NativeAppIDTransport(teams: [accounts[0]: teams[0]], certDER: fixture,
			certificateSerial: certificate.serialNumber, now: clock.now)
		let parallelB = NativeAppIDTransport(teams: [accounts[1]: teams[1]], certDER: fixture,
			certificateSerial: certificate.serialNumber, now: clock.now)
		await parallelA.select(accounts[0])
		await parallelB.select(accounts[1])
		let a = ZagPersistedDeveloperToken(accountID: accounts[0], token: "mock-token-\(accounts[0])", expiresAtMs: 0)
		let b = ZagPersistedDeveloperToken(accountID: accounts[1], token: "mock-token-\(accounts[1])", expiresAtMs: 0)
		let firstPortal = ZagNativeDeveloperPortal(transport: parallelA, headers: { try await parallelA.headers(for: a) })
		let secondPortal = ZagNativeDeveloperPortal(transport: parallelB, headers: { try await parallelB.headers(for: b) })
		async let teamsA = try? firstPortal.teams()
		async let teamsB = try? secondPortal.teams()
		let (discoveryA, discoveryB) = await (teamsA, teamsB)
		check(ZagNativeDeveloperTeam.personalTeam(in: discoveryA ?? [])?.teamID == teams[0] &&
			ZagNativeDeveloperTeam.personalTeam(in: discoveryB ?? [])?.teamID == teams[1],
			"overlapping portal requests use each account’s own headers and team")
		check(ZagNativeDeveloperTeam.personalTeam(in: discoveryA ?? [], expectedID: teams[1]) == nil
			&& ZagNativeDeveloperTeam.personalTeam(in: discoveryA ?? [], expectedID: teams[0])?.teamID == teams[0],
			"a connected account must still have the exact recorded Personal Team")

		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		do {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let consent = ZagMutationConsentCoordinator()
			consent.authorize([.addDevice, .submitCSR, .addAppID, .downloadProfile, .addAppGroup, .assignAppGroups, .updateAppID])
			let tokens = accounts.map { ZagPersistedDeveloperToken(accountID: $0, token: "mock-token-\($0)", expiresAtMs: 0) }
			let portals = tokens.map { token in
				ZagNativeDeveloperPortal(transport: transport, headers: { try await transport.headers(for: token) }, consent: consent, maxRequests: nil)
			}
			await transport.seed(
				(0..<12).map { .init(identifier: "UNDATED\($0)", bundleIdentifier: "com.other.app\($0)", expiresAt: nil) },
				team: teams[1]
			)
			let existingBundle = ZagBundleIdentifierMapping.mapped(original, team: teams[2])!
			await transport.seed([
				.init(identifier: "EXISTING", bundleIdentifier: existingBundle, expiresAt: expiration),
				.init(identifier: "EXISTING", bundleIdentifier: existingBundle, expiresAt: expiration),
				.init(identifier: "EXPIRED", bundleIdentifier: "com.example.expired", expiresAt: clock.now - 1)
			], team: teams[2])
			let mainID = "com.example.main"
			let extensionID = "com.example.main.widget"
			let extensionExpiry = expiration - 3_600
			func installedProfile(id: String, uuid: String, expiry: Date) throws -> Data {
				try PropertyListSerialization.data(fromPropertyList: [
					"CreationDate": clock.now, "ExpirationDate": expiry,
					"DeveloperCertificates": [fixture], "Entitlements": ["application-identifier": "\(teams[0]).\(id)"],
					"TeamIdentifier": [teams[0]], "UUID": uuid
				], format: .xml, options: 0)
			}
			let expectation = ZagInstallExpectation(bundleIdentifier: mainID, profileUUID: "MAIN",
				profileExpiresAt: expiration, certificateExpiresAt: certificate.expiresAt, signerCommonName: nil,
				teamIdentifier: teams[0], extensionProfileUUIDs: ["EXT"], certificateSerial: certificate.serialNumber,
				extensionIdentifiers: ["EXT": extensionID], extensionProfileExpirations: ["EXT": extensionExpiry])
			let mainProfile = try installedProfile(id: mainID, uuid: "MAIN", expiry: expiration)
			let extensionProfile = try installedProfile(id: extensionID, uuid: "EXT", expiry: extensionExpiry)
			let olderProfile = try installedProfile(id: extensionID, uuid: "EXT", expiry: extensionExpiry - 3_600)
			check(ZagInstalledProfileCheck.verify(expectation, installedProfiles: [mainProfile, extensionProfile])
				== .verified(profileExpiresAt: extensionExpiry, certificateExpiresAt: certificate.expiresAt),
				"the earliest installed component profile expiry determines the saved expiration")
			check(ZagInstalledProfileCheck.verify(expectation, installedProfiles: [mainProfile, olderProfile])
				== .mismatch("extension profile expiry"), "renewal refuses a mismatched installed extension expiration")

			var scopes: Set<ZagSigningScope> = []
			check(ZagSigningPreference.resolve(saved: nil, legacyAsk: true) == .askEveryTime
				&& ZagSigningPreference.resolve(saved: nil, legacyAsk: false) == .importedCertificate
				&& ZagSigningPreference.resolve(saved: "appleAccount", legacyAsk: true) == .appleAccount
				&& ZagSigningPreference.resolve(saved: "importedCertificate", legacyAsk: true) == .importedCertificate,
				"signing preference migrates legacy Ask Every Time and respects an explicit method")

			check(ZagSigningPreference.allCases.map(\.title) == ["Apple ID", "Certificate", "Always Ask"],
				"signing method labels leave preference storage values unchanged")
			let preferenceSuite = "ZagSigningOptionTests." + UUID().uuidString
			let preferences = UserDefaults(suiteName: preferenceSuite)!
			defer { preferences.removePersistentDomain(forName: preferenceSuite) }
			let oldOptions = ZagAppleIDSigningOptions(installAfterSigning: true, deleteImportAfterSigning: false)
			let freshOptions = ZagAppleIDSigningOptions(installAfterSigning: false, deleteImportAfterSigning: true)
			check(ZagAppleIDSigningOptions.load(from: preferences, inheriting: oldOptions) == oldOptions,
				"Apple ID migrates only the legacy post-signing actions")
			check(ZagAppleIDSigningOptions.load(from: preferences, inheriting: freshOptions) == oldOptions,
				"later changes to certificate options leave Apple ID settings intact")
			freshOptions.save(to: preferences)
			check(ZagAppleIDSigningOptions.load(from: preferences, inheriting: oldOptions) == freshOptions,
				"Apple ID preferences round-trip independently")
			var certificateDefaults = Options.defaultOptions
			certificateDefaults.ppqProtection = true
			certificateDefaults.dynamicProtection = true
			certificateDefaults.identifiers[original] = "com.example.advanced"
			certificateDefaults.appEntitlementsFile = URL(fileURLWithPath: "/fixture/legacy.plist")
			check(certificateDefaults.certificateCustomisations(since: certificateDefaults,
				identifier: original, name: nil, hasIcon: false).isEmpty,
				"saved certificate defaults produce no Apple ID customisation conflicts")
			var custom = certificateDefaults
			custom.appName = "Edited name"
			custom.removeProvisioning = true
			custom.post_installAppAfterSigned = true
			let conflicts = custom.certificateCustomisations(since: certificateDefaults,
				identifier: original, name: nil, hasIcon: true)
			check(conflicts == ["App Icon", "Display Name", "Remove Provisioning Profile"],
				"explicit certificate edits are named and supported post-signing settings do not conflict")
			let validityBoundaries: [(TimeInterval, ZagAppleIDProfileValidity)] = [
				(345_600.001, .valid), (345_600, .soon), (172_800.001, .soon), (172_800, .urgent),
				(0.001, .urgent), (0, .expired), (-1, .expired)
			]
			check(validityBoundaries.allSatisfy { remaining, expected in
				ZagAppleIDProfileValidity(expiresAt: clock.now + remaining, now: clock.now) == expected
			}, "Apple ID expiry changes at the exact two-day, four-day and expiry boundaries")

			var refreshAttempts: [String] = []
			let batch = await ZagNativeSigningPipeline.refreshSequentially(accounts) { account, index in
				refreshAttempts.append(account)
				if index == 1 { throw ZagPortalError.network }
			}
			let batchFailures = batch.filter { if case .failure = $0 { return true }; return false }.count
			check(refreshAttempts == accounts && batchFailures == 1, "bulk renewal visits each app in order and isolates an individual failure")

			for index in accounts.indices {
				await transport.select(accounts[index])
				let discovered = try await portals[index].teams()
				guard let team = ZagNativeDeveloperTeam.personalTeam(in: discovered), team.teamID == teams[index] else {
					return check(false, "select the signed-in account's active Personal Team")
				}
				if index > 0 {
					do {
						_ = try await portals[index - 1].appIDs(team: teams[index - 1])
						check(false, "the previous account's portal should reject calls after switching")
					} catch ZagPortalError.sessionRejected {
						check(true, "switching invalidates the previous account's portal session")
					}
				}
				let authorization = ZagSigningAuthorization.nativeAccount(token: tokens[index], teamID: team.teamID)
				scopes.insert(authorization.scope)
				let provisioner = ZagFreeAccountProvisioner(portal: portals[index], keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
					account: authorization.scope.accountID, now: { clock.now })
				let appEntitlements = index == 0
					? try ZagEntitlementSet([ZagFreeAccountEntitlements.appGroupsKey: ["group.com.example.integration"]])
					: entitlements()
				let request = ZagProvisioningRequest(accountID: authorization.scope.accountID, team: team.teamID, deviceUDID: udid,
					deviceName: "Test Device", app: .init(originalBundleIdentifier: original, name: "Integration Test", entitlements: appEntitlements),
					extensions: [], installedFreeAccountApps: [])
				let checkpoints = NativeLifecycleCheckpoints()
				let actual = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
					provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(),
					verifyTarget: {}, progress: { await checkpoints.report($0) },
					onVerified: { await checkpoints.record($0) }, now: { clock.now })
				let stages = await checkpoints.progress
				check(stages == [.provisioning, .signing, .installing, .verifying, .verified], "native signing advances through verified installation in order")
				check(actual == .verified(profileExpiresAt: expiration, certificateExpiresAt: certificate.expiresAt),
					"native account \(index + 1) provisions, signs, installs and verifies the app")
				if index == 0, let installed = await checkpoints.installation {
					let data = try JSONEncoder().encode(installed)
					let restored = try JSONDecoder().decode(ZagNativeInstalledProfiles.self, from: data)
					check(restored == installed && restored.record.owner?.scope == authorization.scope,
						"persistent installation metadata round-trips with its account and verified profiles")
					do {
						_ = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
							provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(),
							verifyTarget: {}, renewing: restored, now: { clock.now })
						check(false, "same expiry must not be installed as a renewal")
					} catch ZagNativeSigningPipeline.Failure.expiryNotExtended {
						check(true, "unchanged profile expiry is rejected before installation")
					}
					let pending = NativeLifecycleCheckpoints()
					let signedOnly = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
						provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(refuseInstall: true),
						verifyTarget: { throw ZagPortalError.network }, progress: { await pending.report($0) },
						onVerified: { await pending.record($0) }, onSignedOnly: { metadata, expected, _ in
							await pending.recordPending(metadata, expectation: expected)
						}, now: { clock.now })
					let saved = await pending.pendingExpectation
					let signedMetadata = await pending.pendingMetadata
					let savedStages = await pending.progress
					let verifiedWhileSigning = await pending.installation
					check(signedOnly == .signedOnly && savedStages == [.provisioning, .signing]
						&& signedMetadata?.record.expiryVerified == false && verifiedWhileSigning == nil,
						"native sign-only saves a signed copy without installing or claiming verification")
					if let saved {
						let restored = try JSONDecoder().decode(ZagInstallExpectation.self, from: JSONEncoder().encode(saved))
						let later = AppIDTestInstaller()
						try await later.install(signedApp: root, bundleIdentifier: restored.bundleIdentifier)
						let readback = await later.verify(restored)
						check(readback == .verified(profileExpiresAt: expiration, certificateExpiresAt: certificate.expiresAt),
							"the saved native package installs later using persisted verification expectations")
					} else { check(false, "signed-only installation expectation was saved") }

					let extended = expiration + 3_600
					await transport.renewProfile(until: extended)
					let renewal = NativeLifecycleCheckpoints()
					let result = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
						provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(),
						verifyTarget: {}, renewing: restored, progress: { await renewal.report($0) },
						onVerified: { await renewal.record($0) }, now: { clock.now })
					let renewed = await renewal.installation?.record
					check(result == .verified(profileExpiresAt: extended, certificateExpiresAt: certificate.expiresAt)
						&& renewed?.bundleIdentifier == restored.record.bundleIdentifier
						&& renewed?.owner?.scope == restored.record.owner?.scope,
						"renewal extends expiry with the same mapped identity and account")
					let failure = NativeLifecycleCheckpoints()
					do {
						_ = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
							provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(refuseInstall: true),
							verifyTarget: {}, renewing: restored, progress: { await failure.report($0) },
							onVerified: { await failure.record($0) }, now: { clock.now })
						check(false, "installation should fail before recording expiration")
					} catch {
						let saved = await failure.installation
						let last = await failure.progress.last
						check(saved == nil && last == .installing, "installation failure neither commits expiry nor reports verification")
					}
					await transport.renewProfile(until: expiration)
				}
			}
			let registrationCounts = await transport.registrations
			check(scopes.count == 3 && registrationCounts == [teams[0]: 1, teams[1]: 1],
				"fresh and undated inventories allow registration, team scopes stay distinct, and an existing ID is reused")

			await transport.select(accounts[0])
			let group = ZagBundleIdentifierMapping.mappedAppGroup("group.com.example.integration", team: teams[0])!
			let groupAssigned = await transport.assigned[teams[0]] == [group]
			check(groupAssigned, "native App Group assignment follows capability enablement and carries the mapped group into the profile")
			let suiteName = "ZagSigningDiagnosticsTests." + UUID().uuidString
			let defaults = UserDefaults(suiteName: suiteName)!
			defer { defaults.removePersistentDomain(forName: suiteName) }
			await transport.setProfileFailure(true)
			do {
				_ = try await ZagSigningDiagnostics.current.withValue(ZagSigningDiagnostics(defaults: defaults)) {
					try await portals[0].profile(for: .init(identifier: "NEW0",
						bundleIdentifier: ZagBundleIdentifierMapping.mapped(original, team: teams[0])!, expiresAt: expiration), team: teams[0])
				}
				check(false, "incomplete profile reply should be rejected")
			} catch let failure as ZagPortalOperationFailure {
				let report = UserDefaults(suiteName: suiteName)?.string(forKey: "ZagNativeSigningDiagnostics") ?? ""
				check(failure.operation.hasSuffix("downloadTeamProvisioningProfile.action")
					&& report.contains("HTTP 200, Apple code 0") && report.contains("encodedProfile")
					&& !report.contains(teams[0]) && !report.contains(accounts[0]),
					"incomplete profile preserves endpoint, status, Apple code and missing field in the local report")
			}
			await transport.setProfileFailure(false)
			await transport.rejectRegistration(code: 37)
			let auth = ZagSigningAuthorization.nativeAccount(token: tokens[0], teamID: teams[0])
			let provisioner = ZagFreeAccountProvisioner(portal: portals[0], keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
				onCertificateReady: { await transport.certificateReady() }, account: auth.scope.accountID, now: { clock.now })
			let request = ZagProvisioningRequest(accountID: auth.scope.accountID, team: teams[0], deviceUDID: udid,
				deviceName: "Test Device", app: .init(originalBundleIdentifier: "com.example.second", name: "Second Test", entitlements: entitlements()),
				extensions: [], installedFreeAccountApps: [])
			let rejected = await provisioner.provision(request, authorization: auth)
			let certificateWasReady = await transport.certificatesReady == 1
			check(certificateWasReady, "certificate-ready notification clears recovery UI even when a later provisioning step fails")
			check(rejected.failure?.kind == .appIDServerLimitReached && rejected.failure?.appleAppIDRejection?.fault.resultCode == 37
				&& rejected.failure?.message.contains("code 37") == true && rejected.failure?.message.contains(accounts[0]) == false,
				"the server's genuine quota rejection retains its sanitized code and remains distinct from local capacity")
		} catch {
			check(false, "native three-account App ID and install integration: \(error)")
		}
	}
}

private final class HostedAppleIDVault: ZagNativeAppleIDVault {
	var index = ZagNativeAppleIDCatalog()
	var tokens: [String: ZagPersistedDeveloperToken] = [:]
	var sessions: [String: Data] = [:]
	var failCatalogWrite = false
	var failSessionRead: String?

	func catalog() throws -> ZagNativeAppleIDCatalog { index }
	func saveCatalog(_ value: ZagNativeAppleIDCatalog) throws {
		if failCatalogWrite { throw ZagNativeAppleIDs.Failure.storage }
		index = value
	}
	func token(_ scope: String) -> ZagPersistedDeveloperToken? { tokens[scope] }
	func saveToken(_ value: ZagPersistedDeveloperToken, scope: String) throws { tokens[scope] = value }
	func session(_ scope: String) throws -> Data? {
		if failSessionRead == scope { throw ZagNativeAppleIDs.Failure.storage }
		return sessions[scope]
	}
	func saveSession(_ value: Data, scope: String) throws { sessions[scope] = value }
	func deleteToken(_ scope: String) throws { tokens[scope] = nil }
	func deleteSession(_ scope: String) throws { sessions[scope] = nil }
}

extension Tests {
	@MainActor
	static func testNativeAccountLibrary() async {
		let vault = HostedAppleIDVault()
		let directory = ZagNativeAppleIDs(vault: vault)
		let first = ZagPersistedDeveloperToken(accountID: "101", token: "fixture-one", expiresAtMs: 0)
		let second = ZagPersistedDeveloperToken(accountID: "202", token: "fixture-two", expiresAtMs: 0)
		let a = first.nativeAccountID, b = second.nativeAccountID
		let aScope = ZagNativeAppleIDs.scope(a), bScope = ZagNativeAppleIDs.scope(b)
		vault.tokens["device"] = first
		vault.sessions["device"] = Data([1])
		do {
			vault.failCatalogWrite = true
			check((try? directory.catalog()) == nil && vault.tokens["device"] == first
				&& vault.sessions["device"] == Data([1]) && vault.tokens[aScope] == nil && vault.sessions[aScope] == nil,
				"interrupted catalog write preserves legacy credentials and rolls back new scoped credentials")
			vault.tokens[aScope] = first
			vault.index.register(id: a, email: nil)
			vault.index.migratedLegacy = true
			vault.failCatalogWrite = false
			vault.failSessionRead = "device"
			check((try? directory.catalog()) == nil && vault.index.verifiedLegacyCredentials != true
				&& vault.tokens[aScope] == first && vault.sessions[aScope] == nil,
				"an unreadable legacy session leaves migration retryable")
			vault.failSessionRead = nil
			let migrated = try directory.catalog()
			let again = try directory.catalog()
			check(migrated == again && again.defaultID == a && again.accounts.map(\.id) == [a]
				&& again.verifiedLegacyCredentials == true && vault.sessions[aScope] == Data([1]),
				"legacy migration is idempotent and retains the stable installed-app owner")
			vault.tokens["staging-b"] = second
			vault.sessions["staging-b"] = Data([2])
			let cancelled = ZagNativeAuthenticationAttempt()
			cancelled.cancel()
			do {
				_ = try directory.completeAuthentication(temporaryScope: "staging-b", email: "two@example.test", expected: nil, attempt: cancelled)
				check(false, "cancelled authentication cannot adopt late staged credentials")
			} catch is CancellationError {
				check(vault.tokens[bScope] == nil && vault.sessions[bScope] == nil && directory.connectedToken(a) == first,
					"late results after cancellation leave existing credentials untouched")
			}
			let incomplete = "interrupted"
			vault.tokens[incomplete] = second
			do {
				_ = try directory.completeAuthentication(temporaryScope: incomplete, email: "two@example.test", expected: nil, attempt: .init())
				check(false, "authentication without a GrandSlam session cannot complete")
			} catch ZagNativeAppleIDs.Failure.storage {
				check(vault.tokens[bScope] == nil, "an interrupted login does not install its staged token")
			}
			let registered = try directory.completeAuthentication(temporaryScope: "staging-b", email: "two@example.test", expected: nil, attempt: .init())
			check(registered == b && directory.connectedToken(a) == first && directory.connectedToken(b) == second
				&& vault.sessions[aScope] == Data([1]) && vault.sessions[bScope] == Data([2]),
				"adding a second account keeps tokens and GrandSlam sessions separately scoped")
			try directory.setDefault(b)
			let changed = try directory.catalog()
			check(changed.defaultID == b && directory.connectedToken(a) == first,
				"changing default leaves a non-default account usable for its installed apps")
			do {
				_ = try directory.completeAuthentication(temporaryScope: "staging-b", email: "two@example.test", expected: a, attempt: .init())
				check(false, "wrong account must not be adopted after reauthentication")
			} catch ZagNativeAppleIDs.Failure.wrongAccount {
				check(directory.connectedToken(a) == first && directory.connectedToken(b) == second,
					"wrong-account reauthentication leaves both existing sessions intact")
			}
			try directory.invalidate(first)
			check(directory.connectedToken(a) == nil && vault.sessions[aScope] == Data([1])
				&& directory.connectedToken(b) == second, "a rejected token is invalidated only for its account")
			try directory.remove(b)
			let remaining = try directory.catalog()
			check(remaining.defaultID == a && vault.sessions[bScope] == nil && vault.sessions[aScope] == Data([1]),
				"removal clears only the selected credentials and deterministically changes the default")
			let readded = try directory.completeAuthentication(temporaryScope: "staging-b", email: "two@example.test", expected: nil, attempt: .init())
			check(readded == b && directory.connectedToken(b) == second,
				"re-adding the account restores the stable ID used by existing app ownership")
			let replacement = ZagPersistedDeveloperToken(accountID: first.accountID, token: "fixture-renewed", expiresAtMs: 0)
			vault.tokens["reauth-a"] = replacement
			vault.sessions["reauth-a"] = Data([3])
			let previousToken = vault.tokens[aScope]
			vault.failCatalogWrite = true
			if (try? directory.completeAuthentication(temporaryScope: "reauth-a", email: "one@example.test", expected: a, attempt: .init())) != nil {
				check(false, "reauthentication should fail when its catalog update fails")
			}
			vault.failCatalogWrite = false
			check(vault.tokens[aScope] == previousToken && vault.sessions[aScope] == Data([1])
				&& directory.connectedToken(b) == second && vault.sessions[bScope] == Data([2]),
				"failed reauthentication restores the prior token and session and preserves the other account")
			_ = try directory.completeAuthentication(temporaryScope: "reauth-a", email: "one@example.test", expected: a, attempt: .init())
			check(directory.connectedToken(a) == replacement && directory.connectedToken(b) == second
				&& vault.sessions[aScope] == Data([3]), "reauthentication replaces only the selected account’s session")
			try directory.signOut(a)
			let afterSignOut = try directory.catalog()
			check(afterSignOut.defaultID == a && directory.connectedToken(a) == nil
				&& vault.sessions[aScope] == nil && directory.connectedToken(b) == second,
				"signing out preserves the listed default account and the other session")

			let absentVault = HostedAppleIDVault()
			absentVault.tokens["device"] = first
			let absent = try ZagNativeAppleIDs(vault: absentVault).catalog()
			check(absent.verifiedLegacyCredentials == true && absentVault.sessions[aScope] == nil,
				"verified absence of a legacy GrandSlam session permits token-only migration")
			let firstChallenge = ZagTwoFactorCoordinator()
			let nextChallenge = ZagTwoFactorCoordinator()
			let waiting = Task.detached { firstChallenge.provideCode() }
			for _ in 0..<100 where firstChallenge.stage != .awaitingCode {
				try await Task.sleep(for: .milliseconds(5))
			}
			let askedForCode = firstChallenge.stage == .awaitingCode
			firstChallenge.cancel()
			let cancelledCode = await waiting.value
			nextChallenge.submitCode("000001")
			let retryCode = await Task.detached { nextChallenge.provideCode() }.value
			check(askedForCode && cancelledCode == nil && firstChallenge.didCancel
				&& !nextChallenge.didCancel && retryCode == "000001",
				"cancelling a pending two-factor code unblocks the worker and leaves a retry untouched")
		} catch { check(false, "native account library: \(error)") }
	}
}

private actor NativeLifecycleCheckpoints {
	var progress: [ZagNativeSigningProgress] = []
	var installation: ZagNativeInstalledProfiles?
	var pendingMetadata: ZagNativeInstalledProfiles?
	var pendingExpectation: ZagInstallExpectation?
	func recordPending(_ value: ZagNativeInstalledProfiles, expectation: ZagInstallExpectation) {
		pendingMetadata = value
		pendingExpectation = expectation
	}
	func report(_ stage: ZagNativeSigningProgress) { progress.append(stage) }
	func record(_ value: ZagNativeInstalledProfiles) { installation = value }
}

private actor NativeAppIDTransport: ZagHTTPTransport {
	let teams: [String: String]
	let certDER: Data
	let certificateSerial: String
	let now: Date
	var selected: String?
	var rows: [String: [ZagRegisteredAppID]] = [:]
	var registeredDevices = Set<String>()
	var issued = Set<String>()
	var registrations: [String: Int] = [:]
	var registrationRejection: Int?
	var certificatesReady = 0
	var groups: [String: String] = [:]
	var capabilityEnabled = Set<String>()
	var assigned: [String: [String]] = [:]
	var profileFailure = false
	var profileExpiry: Date?

	init(teams: [String: String], certDER: Data, certificateSerial: String, now: Date) {
		self.teams = teams
		self.certDER = certDER
		self.certificateSerial = certificateSerial
		self.now = now
	}

	func select(_ account: String) { selected = account }
	func seed(_ ids: [ZagRegisteredAppID], team: String) { rows[team] = ids }
	func rejectRegistration(code: Int) { registrationRejection = code }
	func certificateReady() { certificatesReady += 1 }
	func setProfileFailure(_ value: Bool) { profileFailure = value }
	func renewProfile(until expiry: Date) { profileExpiry = expiry }

	func headers(for token: ZagPersistedDeveloperToken) throws -> [String: String] {
		guard selected == token.accountID else { throw ZagPortalError.sessionRejected }
		return ["X-Apple-I-Identity-Id": token.accountID, "X-Apple-GS-Token": token.token]
	}

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		guard let selected, let team = teams[selected], request.method == "POST",
			  request.headers["X-Apple-I-Identity-Id"] == selected,
			  request.headers["X-Apple-GS-Token"] == "mock-token-\(selected)", let body = request.body else {
			throw ZagPortalError.sessionRejected
		}

		if request.url.path == "/services/v1/certificates" {
			let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
			guard json?["urlEncodedQueryParams"] == "teamId=\(team)",
				  request.headers["X-HTTP-Method-Override"] == "GET" else { throw ZagPortalError.malformedResponse }
			let rows: [[String: Any]] = issued.contains(team) ? [["id": "CERT", "attributes": [
				"serialNumber": certificateSerial, "certificateContent": certDER.base64EncodedString()
			]]] : []
			return .init(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: ["data": rows]))
		}

		let params = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
		guard params?["clientId"] as? String == "XABBG36SBA", params?["protocolVersion"] as? String == "QH65B2",
			  request.url.query == "clientId=XABBG36SBA", request.headers["Content-Type"] == "text/x-xml-plist" else {
			throw ZagPortalError.malformedResponse
		}
		let action = request.url.lastPathComponent
		if action != "listTeams.action", params?["teamId"] as? String != team { throw ZagPortalError.sessionRejected }
		var reply: [String: Any] = ["resultCode": 0]
		switch action {
		case "listTeams.action":
			reply["teams"] = [
				["teamId": "PAIDTEAM01", "name": "Organization", "status": "active", "type": "Company"],
				["teamId": "OLDTEAM001", "name": "Expired (Personal Team)", "status": "expired"],
				["teamId": team, "name": "Test Personal Team", "status": "active", "memberships": [["name": "Free Provisioning"]]]
			]
		case "listDevices.action":
			reply["devices"] = registeredDevices.contains(team) ? [["deviceNumber": udid, "name": "Test Device"]] : []
		case "addDevice.action":
			guard params?["deviceNumber"] as? String == udid else { throw ZagPortalError.malformedResponse }
			registeredDevices.insert(team)
			reply["device"] = ["deviceNumber": udid, "name": "Test Device"]
		case "listAppIds.action":
			// Apple can omit the optional array on an explicitly successful empty reply.
			if let ids = rows[team] {
				reply["appIds"] = ids.map { row in
					var encoded: [String: Any] = ["appIdId": row.identifier, "identifier": row.bundleIdentifier]
					if let expiry = row.expiresAt { encoded["expirationDate"] = expiry }
					return encoded
				}
			}
		case "submitDevelopmentCSR.action":
			issued.insert(team)
			reply["certRequest"] = ["certContent": certDER, "serialNumber": certificateSerial]
		case "addAppId.action":
			guard let bundle = params?["identifier"] as? String, bundle.hasSuffix(".\(team)"),
				  let name = params?["name"] as? String, !name.isEmpty else { throw ZagPortalError.malformedResponse }
			if let code = registrationRejection {
				reply = ["resultCode": code, "userString": "App ID limit reached for \(selected) on \(team)."]
			} else {
				let id = "NEW\(registrations[team, default: 0])"
				let expiry = now + 7 * 86_400
				registrations[team, default: 0] += 1
				rows[team, default: []].append(.init(identifier: id, bundleIdentifier: bundle, expiresAt: expiry))
				reply["appId"] = ["appIdId": id, "identifier": bundle, "expirationDate": expiry]
			}
		case "listApplicationGroups.action":
			if let group = groups[team] {
				reply["applicationGroupList"] = [["identifier": group, "name": "Integration", "applicationGroup": "GROUP1"]]
			}
		case "addApplicationGroup.action":
			guard let identifier = params?["identifier"] as? String, let name = params?["name"] as? String,
				  !name.contains(".") else { throw ZagPortalError.malformedResponse }
			groups[team] = identifier
			reply["applicationGroup"] = ["identifier": identifier, "applicationGroup": "GROUP1"]
		case "updateAppId.action":
			guard let id = params?["appIdId"] as? String, let app = rows[team]?.first(where: { $0.identifier == id }),
				  params?["APG3427HIY"] as? Bool == true else { throw ZagPortalError.malformedResponse }
			capabilityEnabled.insert(team)
			reply["appId"] = ["appIdId": id, "identifier": app.bundleIdentifier, "features": ["APG3427HIY": true]]
		case "assignApplicationGroupToAppId.action":
			guard capabilityEnabled.contains(team), params?["applicationGroups"] as? [String] == ["GROUP1"],
				  let group = groups[team] else { throw ZagPortalError.malformedResponse }
			assigned[team] = [group]
		case "downloadTeamProvisioningProfile.action":
			if profileFailure { break }
			guard let id = params?["appIdId"] as? String, let app = rows[team]?.first(where: { $0.identifier == id }) else {
				throw ZagPortalError.malformedResponse
			}
			let profile = try PropertyListSerialization.data(fromPropertyList: [
				"CreationDate": now, "ExpirationDate": profileExpiry ?? now + 7 * 86_400,
				"DeveloperCertificates": [certDER],
				"Entitlements": ["application-identifier": "\(team).\(app.bundleIdentifier)",
				                 ZagFreeAccountEntitlements.appGroupsKey: assigned[team] ?? []],
				"ProvisionedDevices": [udid], "TeamIdentifier": [team], "UUID": "TESTPROFILE"
			], format: .xml, options: 0)
			reply["provisioningProfile"] = ["encodedProfile": profile]
		default: throw ZagPortalError.malformedResponse
		}
		return .init(statusCode: 200, headers: [:], body: try PropertyListSerialization.data(fromPropertyList: reply, format: .xml, options: 0))
	}
}

private struct AppIDTestSigner: ZagAppSigning {
	func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity,
			  authorization: ZagSigningAuthorization, now: Date) throws -> ZagSignedAppRecord {
		guard identity.serialNumber == result.certificateSerial, result.team == authorization.scope.teamID,
			  result.app.entitlements.dictionary["application-identifier"] as? String == "\(result.team).\(result.app.bundleIdentifier)" else {
			throw ZagFreeAccountSigningError.identityMismatch
		}
		try Data(result.app.bundleIdentifier.utf8).write(to: app.appendingPathComponent("signature"))
		try result.app.profile.data.write(to: app.appendingPathComponent("embedded.mobileprovision"))
		return .init(bundleIdentifier: result.app.bundleIdentifier, originalBundleIdentifier: result.app.originalBundleIdentifier,
			signedAt: now, profileExpiresAt: result.expiresAt, certificateExpiresAt: identity.expiresAt)
	}
}

private actor AppIDTestInstaller: ZagFreeAccountInstaller {
	var refuseInstall = false
	init(refuseInstall: Bool = false) { self.refuseInstall = refuseInstall }
	var installed: String?
	var installedProfiles: [Data] = []
	func install(signedApp: URL, bundleIdentifier: String) async throws {
		if refuseInstall { throw ZagPortalError.network }
		guard try String(contentsOf: signedApp.appendingPathComponent("signature"), encoding: .utf8) == bundleIdentifier else {
			throw ZagFreeAccountSigningError.verification("test signature")
		}
		installed = bundleIdentifier
		installedProfiles = [try Data(contentsOf: signedApp.appendingPathComponent("embedded.mobileprovision"))]
	}
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		guard installed == expectation.bundleIdentifier, expectation.profileUUID == "TESTPROFILE" else { return .notInstalled }
		return ZagInstalledProfileCheck.verify(expectation, installedProfiles: installedProfiles)
	}
}
