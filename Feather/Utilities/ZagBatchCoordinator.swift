import SwiftUI
import CoreData
import Security
import AltSourceKit

@MainActor
final class ZagBatchCoordinator: ObservableObject {
	static let shared = ZagBatchCoordinator()

	@TaskLocal static var allowsForegroundInteraction = true

	struct Report {
		let title: String
		let message: String
		let needsAttention: Bool
		var diagnostics = ""

		static func attention(_ operation: ZagBatchOperation, _ message: String) -> Self {
			.init(title: operation.title, message: message, needsAttention: true)
		}

		static func busy(_ operation: ZagBatchOperation) -> Self {
			attention(operation, "Another batch is running. Try again after it finishes.")
		}
	}

	@Published private var reservation = ZagBatchReservation()
	@Published private(set) var completed = 0
	@Published private(set) var total = 0
	var operation: ZagBatchOperation? { reservation.operation }
	private var isCancelled: Bool { reservation.cancelled || Task.isCancelled }
	private var refreshJobs: Set<String> = []

	func cancel() {
		reservation.cancel()
		for job in refreshJobs { _ = ZagInstallJobs.shared.requestCancel(job) }
	}

	func start(_ operation: ZagBatchOperation, origin: ZagBatchOrigin) {
		Task { _ = await run(operation, origin: origin) }
	}

	func run(_ operation: ZagBatchOperation, origin: ZagBatchOrigin, only identifier: String? = nil) async -> Report {
		guard reservation.begin(operation) else { return .busy(operation) }
		completed = 0
		total = 0
		defer { reservation.finish() }

		let report = await Self.$allowsForegroundInteraction.withValue(origin != .shortcut && origin != .automatic) {
			await execute(operation, origin: origin, only: identifier)
		}
		if !report.diagnostics.isEmpty {
			UserDefaults.standard.set(report.diagnostics, forKey: "ZagNativeSigningDiagnostics")
		}
		let unlocked = UserDefaults.standard.bool(forKey: "ZagStore.advancedSettingsUnlocked")
		let presentation = origin.presentation(unlocked: unlocked, needsAttention: report.needsAttention)
		if presentation != .none {
			var actions = [UIAlertAction(title: "OK", style: .cancel)]
			if presentation == .details, !report.diagnostics.isEmpty {
				actions.append(UIAlertAction(title: "Copy Diagnostics", style: .default) { _ in
					UIPasteboard.general.string = report.diagnostics
				})
			}
			UIAlertController.showAlert(title: report.title, message: report.message, actions: actions)
		}
		return report
	}

	private func execute(_ operation: ZagBatchOperation, origin: ZagBatchOrigin, only identifier: String?) async -> Report {
		if origin == .automatic, ZagNetworkPath.shared.summary == "Offline" {
			return .attention(operation, "The network is unavailable.")
		}
		guard ZagRPPairingCore.shared.hasSavedPairing else {
			return .attention(operation, "Set up installation pairing in Zag Store and try again.")
		}
		var remainingChecks = 60
		while origin != .inApp, origin != .automatic, ZagRPPairingCore.shared.isTransportBusy, remainingChecks > 0, !isCancelled {
			try? await Task.sleep(for: .milliseconds(250))
			remainingChecks -= 1
		}
		if isCancelled { return .init(title: operation.title, message: "Cancelled.", needsAttention: false) }
		do {
			switch operation {
			case .refresh:
				await ZagRunningInstallation.shared.inspect()
				let request = Signed.fetchRequest()
				request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
				let items = refreshItems(try Storage.shared.context.fetch(request), automatic: origin == .automatic)
					.filter { identifier == nil || $0.app.identifier == identifier }
				guard !items.isEmpty else {
					return .init(title: operation.title, message: "No eligible apps to refresh.", needsAttention: false)
				}
				return await refresh(items, automatic: origin == .automatic, interactive: identifier != nil && origin == .inApp)
			case .update:
				return try await update(origin: origin)
			}
		} catch {
			return .attention(operation, "Zag Store could not prepare the batch. Open Zag Store and try again.")
		}
	}

	private func update(origin: ZagBatchOrigin) async throws -> Report {
		let updates = UpdateManager.shared
		let sources = SourcesViewModel.shared
		if !updates.hasCompletedUpdateCheck {
			if sources.isFinished {
				let records = try Storage.shared.context.fetch(AltSource.fetchRequest())
				await sources.fetchSources(records)
			}
			var remainingChecks = 60
			while !updates.hasCompletedUpdateCheck, remainingChecks > 0, !isCancelled {
				if sources.isFinished, case .failed = ZagRPPairingCore.shared.installedAppsState { break }
				try? await Task.sleep(for: .milliseconds(250))
				remainingChecks -= 1
			}
		}
		if isCancelled { return .init(title: "Update All", message: "Cancelled.", needsAttention: false) }
		guard updates.hasCompletedUpdateCheck else {
			return .attention(.update, "The update check hasn’t finished. Open Zag Store and try again.")
		}

		let manager = ZagUpdateTransactionManager.shared
		let pending = updates.visibleUpdates.filter {
			$0.installedBundleID != Bundle.main.bundleIdentifier &&
				(manager.stage(for: $0) == nil || manager.isRetryable($0))
		}
		total = pending.count
		guard !pending.isEmpty else {
			return .init(title: "Update All", message: "No eligible updates.", needsAttention: false)
		}

		var installed = 0
		var saved = 0
		var failures: [String] = []
		var details: [String] = []
		for update in pending {
			guard !isCancelled else { break }
			guard manager.stage(for: update) == nil || manager.isRetryable(update) else { continue }
			defer { completed += 1 }
			do {
				let signedUUID = try await manager.prepareAsync(update, interactive: origin == .inApp)
				if isCancelled, manager.stage(for: update) == .readyToInstall {
					manager.pausePreparedUpdate(update)
					break
				}
				if try await manager.installPreparedUpdate(signedUUID: signedUUID, verifyDevice: true) {
					installed += 1
					Self.recordCompletedUpdate(Self.updateSnapshot(update, completedAt: Date()))
				} else {
					saved += 1
				}
			} catch {
				manager.failInstallation(update: update, error: error)
				let name = ZagDeveloperServicesProtocol.sanitizeMessage(update.app.currentName)
				failures.append(name)
				let reason = ZagDeveloperServicesProtocol.sanitizeMessage(error.localizedDescription, limit: 500)
				details.append("\(name): \(reason)")
			}
		}
		var lines = [installed == 1 ? "1 update installed." : "\(installed) updates installed."]
		if saved > 0 { lines.append(saved == 1 ? "1 signed update saved in Apps." : "\(saved) signed updates saved in Apps.") }
		if !failures.isEmpty {
			lines.append("Couldn’t update \(failures.joined(separator: ", ")). Retry in Zag Store.")
		}
		if isCancelled { lines.append("Cancelled.") }
		let message = lines.joined(separator: " ")
		return .init(title: "Update All", message: message, needsAttention: !failures.isEmpty,
			diagnostics: ([message] + details).joined(separator: "\n"))
	}

	static func recordCompletedUpdate(_ row: ZagUpdateRowSnapshot) {
		var recent = ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.recentKey)
		recent.removeAll { $0.bundleID == row.bundleID }
		recent.insert(row, at: 0)
		ZagUpdateRowSnapshot.save(recent, key: ZagUpdateRowSnapshot.recentKey)

		let available = ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.availableKey)
		ZagUpdateRowSnapshot.save(available.filter { $0.bundleID != row.bundleID }, key: ZagUpdateRowSnapshot.availableKey)
		UpdateManager.shared.updateCompletionDidChange()
	}
	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	private let _certificateRefreshCache = CertificateRefreshCache()

	@MainActor
	private final class CertificateRefreshCache {
		private struct Stamp: Equatable {
			let path: String
			let modified: Date?
			let size: Int?
			init(_ url: URL) {
				path = url.path
				let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
				modified = values?.contentModificationDate
				size = values?.fileSize
			}
		}

		private var catalog: [Stamp] = []
		private var device: String?
		private var ineligible: [String: Stamp] = [:]

		func update(records: [CertificatePair]) {
			let stamps = records.filter { !$0.revoked }.flatMap { pair in
				[Storage.FileRequest.provision, .certificate].compactMap { Storage.shared.getFile($0, from: pair) }.map(Stamp.init)
			}.sorted { $0.path < $1.path }
			let udid = ZagRPPairingCore.shared.pairedIdentity?.udid
			if catalog != stamps || device != udid {
				catalog = stamps
				device = udid
				ineligible.removeAll()
			}
		}

		func plan(_ row: Signed) -> CertificateRefresh? {
			guard let id = row.uuid, let source = Storage.shared.getAppDirectory(for: row) else { return nil }
			let stamp = Stamp(source.appendingPathComponent("embedded.mobileprovision"))
			if ineligible[id] == stamp { return nil }
			if let result = try? CertificateRefresh(row) { return result }
			ineligible[id] = stamp
			return nil
		}
	}

	private struct CertificateRefresh {
		let certificate: CertificatePair
		let record: Signed?
		let source: URL
		let current: ZagInstallExpectation
		let replacement: ZagInstallExpectation
		let replacementProfile: ZagIssuedProfile
		let replacementBytes: Data
		let signer: Data
		let entitlementsByComponent: [String: ZagEntitlementSet]
		private var refreshedProfile: URL {
			record == nil ? ZagCertificateProfileReceipt.runningLocation :
				ZagCertificateProfileReceipt.location(in: source.deletingLastPathComponent())
		}

		private static func entitlements(in bundle: Bundle, signedBy signer: Data) -> ZagEntitlementSet? {
			guard let executable = bundle.executableURL,
				  let binary = try? Data(contentsOf: executable, options: .mappedIfSafe),
				  ZagCodeSignatureInspection.matchesSigner(signer, in: binary),
				  let entitlements = try? ZagMachOSignatureInspector.entitlements(at: executable) else { return nil }
			return try? ZagEntitlementSet(entitlements)
		}

		@MainActor
		init(_ app: Signed) throws(RefreshSkip) {
			let storage = Storage.shared
			guard let recorded = app.certificate, let source = storage.getAppDirectory(for: app) else {
				throw RefreshSkip("The signed archive or recorded certificate is unavailable.")
			}
			try self.init(app: app, record: app, source: source, recorded: recorded)
		}

		@MainActor
		init(running app: ZagRunningApp, recorded: CertificatePair) throws(RefreshSkip) {
			try self.init(app: app, record: nil, source: Bundle.main.bundleURL, recorded: recorded)
		}

		@MainActor
		private init(app: AppInfoPresentable, record: Signed?, source: URL, recorded: CertificatePair) throws(RefreshSkip) {
			let storage = Storage.shared
			guard !recorded.revoked, storage.getFile(.certificate, from: recorded) != nil,
				  let bundle = Bundle(url: source), let id = app.identifier, bundle.bundleIdentifier == id,
				  let currentBytes = try? Data(contentsOf: source.appendingPathComponent("embedded.mobileprovision")),
				  let embeddedProfile = try? ZagIssuedProfile(profileData: currentBytes) else {
				throw RefreshSkip("The original certificate or profile is unavailable.")
			}
			let renewed = ZagCertificateProfileReceipt.load(for: app).flatMap { receipt -> ZagCertificateProfileReceipt? in
				guard let running = app as? ZagRunningApp else { return receipt }
				guard receipt.runningBundleIdentifier == running.identifier, receipt.runningVersion == running.version,
					  receipt.runningBuild == running.build,
					  receipt.effectiveExpiration == ZagRunningInstallation.shared.expiry else { return nil }
				return receipt
			}.flatMap { try? ZagCMSVerifier.verify($0.profile).get() }
				.flatMap { try? ZagIssuedProfile(profileData: $0) }
			let currentProfile = renewed ?? embeddedProfile

			func signingCertificate(_ pair: CertificatePair) -> Data? {
				guard let p12 = storage.getFile(.certificate, from: pair),
					  let bytes = try? Data(contentsOf: p12),
					  let identity = try? ZagImportedSigningIdentity.importIdentity(pkcs12: bytes, password: pair.password ?? "").get() else { return nil }
				var certificate: SecCertificate?
				guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
				return SecCertificateCopyData(certificate) as Data
			}
			let newerProfiles = storage.getAllCertificates().compactMap { pair -> (CertificatePair, Data, Date)? in
				guard !pair.revoked, let url = storage.getFile(.provision, from: pair),
					  let bytes = try? Data(contentsOf: url), let preview = try? ZagIssuedProfile(profileData: bytes),
					  preview.teamIdentifier == currentProfile.teamIdentifier, preview.uuid != currentProfile.uuid,
					  preview.expiresAt > max(Date(), currentProfile.expiresAt) else { return nil }
				return (pair, bytes, preview.expiresAt)
			}.sorted { $0.2 > $1.2 }
			guard !newerProfiles.isEmpty else { throw RefreshSkip("No newer provisioning profile is available for the recorded team.") }
			guard let signer = signingCertificate(recorded), let inspection = ZagCertificateInspection(der: signer),
				  let team = inspection.organizationalUnit, team == currentProfile.teamIdentifier,
				  currentProfile.certificateSerials.contains(inspection.serialNumber),
				  let entitlements = Self.entitlements(in: bundle, signedBy: signer) else {
				throw RefreshSkip("The recorded certificate does not match the archived signer.")
			}
			guard let currentAppID = currentProfile.entitlements.dictionary["application-identifier"] as? String,
				  ZagImportedIdentityProfileMatch.bundleMatches(target: id, applicationIdentifier: currentAppID, team: team) else {
				throw RefreshSkip("The original profile does not cover this app’s bundle identifier.")
			}
			var componentIDs = [id]
			var entitlementsByComponent = ["": entitlements]
			for path in ZagFreeAccountSigningAdapter.nestedBundles(in: source) {
				let component = source.appendingPathComponent(path)
				guard component.pathExtension == "appex",
					  let bundle = Bundle(url: component), let id = bundle.bundleIdentifier,
					  let embedded = try? Data(contentsOf: component.appendingPathComponent("embedded.mobileprovision")),
					  embedded == currentBytes,
					  ZagImportedIdentityProfileMatch.bundleMatches(target: id, applicationIdentifier: currentAppID, team: team),
					  let entitlements = Self.entitlements(in: bundle, signedBy: signer) else {
					throw RefreshSkip("A nested component needs independent provisioning; its current signing identity cannot be preserved by this profile.")
				}
				componentIDs.append(id)
				entitlementsByComponent[path] = entitlements
			}
			let pairedUDID = ZagRPPairingCore.shared.pairedIdentity?.udid
			func replacement(for candidate: (CertificatePair, Data, Date)) -> ZagIssuedProfile? {
				let (pair, bytes, _) = candidate
				guard signingCertificate(pair) == signer,
					  let authenticated = try? ZagCMSVerifier.verify(bytes).get(),
					  let profile = try? ZagIssuedProfile(profileData: authenticated),
					  let contents = ZagMobileProvision.parseUnverified(authenticated),
					  contents.developerCertificates.contains(signer),
					  profile.teamIdentifier == team, profile.uuid != currentProfile.uuid,
					  ZagNativeSigningPipeline.extendsValidity(previousProfile: currentProfile.expiresAt,
						newProfile: profile.expiresAt, certificate: inspection.expiresAt, now: Date()),
					  Self.coversDevice(profile, udid: pairedUDID),
					  componentIDs.allSatisfy({ ZagImportedIdentityProfileMatch.bundleMatches(target: $0, applicationIdentifier: contents.applicationIdentifier, team: team) }),
					  entitlementsByComponent.values.allSatisfy({
						  ZagEntitlementAudit.disallowed(requested: $0.dictionary.mapValues(ZagEntitlementValue.init),
							granted: contents.entitlements).isEmpty
					  }) else { return nil }
				return profile
			}
			// A separately imported newer profile is usable only with byte-for-byte
			// the same signing certificate as the recorded pair and archive.
			guard let candidate = newerProfiles.lazy.compactMap({ candidate in
				replacement(for: candidate).map { (candidate.0, candidate.1, $0) }
			}).first else {
				throw RefreshSkip("No compatible profile extends validity with the original certificate and entitlements.")
			}
			func expectation(_ profile: ZagIssuedProfile) -> ZagInstallExpectation {
				ZagInstallExpectation(bundleIdentifier: id, profileUUID: profile.uuid, profileExpiresAt: profile.expiresAt,
					certificateExpiresAt: inspection.expiresAt, signerCommonName: inspection.commonName, teamIdentifier: team,
					version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
					build: bundle.infoDictionary?["CFBundleVersion"] as? String, certificateSerial: inspection.serialNumber,
					allowsWildcardProfile: true)
			}
			self.certificate = candidate.0
			self.record = record
			self.source = source
			self.current = expectation(currentProfile)
			self.replacement = expectation(candidate.2)
			self.replacementProfile = candidate.2
			self.replacementBytes = candidate.1
			self.signer = signer
			self.entitlementsByComponent = entitlementsByComponent
		}

		private static func coversDevice(_ profile: ZagIssuedProfile, udid: String?) -> Bool {
			if profile.deviceUDIDs.isEmpty {
				return ZagMobileProvision.extractUnverifiedPlist(from: profile.data)?["ProvisionsAllDevices"] as? Bool == true
			}
			guard let udid else { return true }
			return profile.deviceUDIDs.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
		}

		@MainActor
		func renew(job: String) async throws {
			try await ZagNativeAccountInstall.RefreshCoordinator.onDevice {
				let start = ContinuousClock.now
				defer { ZagSigningDiagnostics.elapsed("Certificate profile-only total", since: start) }
				let pairing = ZagRPPairingCore.shared
				let (device, _) = try await pairing.signingDeviceInventory()
				guard Self.coversDevice(replacementProfile, udid: device.udid) else {
					throw RefreshSkip("The replacement profile does not include this iPhone.")
				}
				let verifier = ZagRPPairingFreeAccountInstaller()
				guard case .verified(let oldExpiry, let oldCertExpiry) = await verifier.verify(current),
					  ZagNativeSigningPipeline.extendsValidity(previousProfile: oldExpiry,
						newProfile: replacement.profileExpiresAt, certificate: oldCertExpiry, now: Date()) else {
					throw RefreshSkip("The installed signing identity could not be verified.")
				}
				let jobs = ZagInstallJobs.shared
				try jobs.checkpoint(job)
				guard record?.isDeleted != true, !certificate.isDeleted, !certificate.revoked else {
					throw RefreshSkip("The signing certificate is unavailable.")
				}
				try jobs.beginInstalling(job)
				let readback: [Data]
				do { readback = try await ZagNativeAccountInstall.RefreshCoordinator.installAndReadBack([replacementBytes]) }
				catch where error.localizedDescription.localizedCaseInsensitiveContains("misagent over RSD failed: service not found") {
					guard record != nil else { throw RefreshSkip("This iPhone cannot update the running app’s profile in place. Use the original signing identity to recover.") }
					// An explicitly unsupported service can use the established full-signing path.
					jobs.advance(job, to: .signing)
					try await renewBySigning(job: job)
					return
				}
				jobs.reportNative(job, .verifying)
				guard pairing.pairedIdentity == device, readback.contains(replacementBytes),
					  case .verified(let expiry, let certExpiry) = ZagInstalledProfileCheck.verify(replacement, installedProfiles: readback),
					  ZagNativeSigningPipeline.extendsValidity(previousProfile: oldExpiry, newProfile: expiry,
						certificate: certExpiry, now: Date()) else { throw ZagProfileOnlyRenewal.Failure.readback }
				var receipt = ZagCertificateProfileReceipt(profile: replacementBytes, effectiveExpiration: min(expiry, certExpiry))
				if record == nil {
					let running = ZagRunningInstallation.shared.runningApp
					receipt.runningBundleIdentifier = running.identifier
					receipt.runningVersion = running.version
					receipt.runningBuild = running.build
				}
				try FileManager.default.createDirectory(at: refreshedProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
				try JSONEncoder().encode(receipt).write(to: refreshedProfile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
				if let record {
					record.certificate = certificate
					try Storage.shared.context.save()
				} else {
					ZagRunningInstallation.shared.certificateDidRenew(to: receipt.effectiveExpiration)
				}
			}
		}

		@MainActor
		private func renewBySigning(job: String) async throws {
			try await ZagNativeAccountInstall.withExclusiveOperation {
				let pairing = ZagRPPairingCore.shared
				let (device, _) = try await pairing.signingDeviceInventory()
				guard Self.coversDevice(replacementProfile, udid: device.udid) else {
					throw RefreshSkip("The replacement profile does not include this iPhone.")
				}
				let verifier = ZagRPPairingFreeAccountInstaller()
				guard case .verified(let oldExpiry, let oldCertExpiry) = await verifier.verify(current),
					  ZagNativeSigningPipeline.extendsValidity(previousProfile: oldExpiry,
						newProfile: replacement.profileExpiresAt, certificate: oldCertExpiry, now: Date()) else {
					throw RefreshSkip("The installed profile could not be matched to an extendable archive.")
				}
				let jobs = ZagInstallJobs.shared
				try jobs.checkpoint(job)
				guard let record, !record.isDeleted, record.identifier != Bundle.main.bundleIdentifier,
					  !certificate.isDeleted, !certificate.revoked else { throw RefreshSkip("The signing record or its certificate is unavailable.") }
				let staging = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
				try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
				defer { try? FileManager.default.removeItem(at: staging) }
				let stagedApp = staging.appendingPathComponent(source.lastPathComponent)
				try FileManager.default.copyItem(at: source, to: stagedApp)
				let entitlementFile = staging.appendingPathComponent("entitlements.plist")
				try PropertyListSerialization.data(fromPropertyList: entitlementsByComponent[""]?.dictionary ?? [:], format: .xml, options: 0)
					.write(to: entitlementFile, options: .atomic)
				var options = Options.defaultOptions
				options.appEntitlementsFile = entitlementFile
				let signing = ZsignHandler(appUrl: stagedApp, options: options, cert: certificate)
				try await signing.sign()
				if let error = signing.hadError { throw error }
				for (path, entitlements) in entitlementsByComponent {
					let component = path.isEmpty ? stagedApp : stagedApp.appendingPathComponent(path)
					guard let bundle = Bundle(url: component),
						  let embedded = try? Data(contentsOf: component.appendingPathComponent("embedded.mobileprovision")),
						  embedded == replacementBytes,
						  Self.entitlements(in: bundle, signedBy: signer) == entitlements,
						  pairing.pairedIdentity == device else {
						throw ZagFreeAccountSigningError.verification("The renewed archive did not preserve its original signing identity.")
					}
				}
				try jobs.checkpoint(job)
				jobs.advance(job, to: .packaging)
				let ipa = try await Task.detached(priority: .utility) {
					try ZagRPPairingFreeAccountInstaller.package(stagedApp, in: staging)
				}.value
				try jobs.checkpoint(job)
				jobs.advance(job, to: .preparingMobileDataFix)
				let coordinator = ZagMobileDataInstallCoordinator.shared
				try await coordinator.install(jobID: job, bundleID: replacement.bundleIdentifier,
					cancelRequested: { jobs.isCancelRequested(job) }) {
					try jobs.beginInstalling(job)
					defer { if coordinator.usingMobileDataFix { jobs.advance(job, to: .restoringMobileData) } }
					try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
						do {
							try pairing.installGate4IPA(at: ipa, retryTransientFailures: true) {
								continuation.resume(with: $0)
							}
						} catch { continuation.resume(throwing: error) }
					}
				}
				guard case .verified(let expiry, let certExpiry) = await verifier.verify(replacement),
					  pairing.pairedIdentity == device,
					  ZagNativeSigningPipeline.extendsValidity(previousProfile: oldExpiry, newProfile: expiry,
						certificate: certExpiry, now: Date()) else {
					throw ZagFreeAccountSigningError.verification("The device did not verify an extended installed profile.")
				}
				_ = try FileManager.default.replaceItemAt(source, withItemAt: stagedApp)
				try? FileManager.default.removeItem(at: refreshedProfile)
				if !record.isDeleted, !certificate.isDeleted, record.certificate != certificate {
					record.certificate = certificate
					Storage.shared.saveContext()
				}
			}
		}
	}
	#else
	private struct CertificateRefresh {}
	#endif

	private enum RefreshMethod {
		case appleID(ZagSigningScope)
		case certificate(CertificateRefresh)
	}

	private struct RefreshItem {
		let app: AppInfoPresentable
		let eligibility: Result<RefreshMethod, RefreshSkip>
		var name: String { app.name ?? "App" }
	}

	private struct RefreshSkip: LocalizedError {
		let reason: String
		init(_ reason: String) { self.reason = reason }
		var errorDescription: String? { reason }
	}

	private func refreshItems(_ rows: [Signed], automatic: Bool = false) -> [RefreshItem] {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		let data = UserDefaults.standard.data(forKey: "zagStore.managedInstalledBundleIDs") ?? Data()
		let installed = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
		var seen: Set<String> = []
		if !automatic { _certificateRefreshCache.update(records: Storage.shared.getAllCertificates()) }
		let now = Date()
		var items: [RefreshItem] = rows.compactMap { row in
			guard let id = row.identifier, !ZagUpdateTransactionManager.shared.isPendingInstallationSigned(uuid: row.uuid)
			else { return nil }
			let selfApp = ZagRunningAppPolicy.isRunning(id, bundle: Bundle.main.bundleIdentifier)
			guard selfApp || installed.contains(id) else { return nil }
			if selfApp, row.uuid != ZagRunningInstallation.shared.nativeUUID { return nil }
			let entry = ZagNativeAppInventory.entry(row)
			guard entry?.pendingInstall == nil, seen.insert(id).inserted else { return nil }
			let eligibility = Result<RefreshMethod, RefreshSkip> { () throws(RefreshSkip) -> RefreshMethod in
				guard ZagRPPairingCore.shared.hasSavedPairing else { throw RefreshSkip("Installation pairing is unavailable.") }
				if let entry {
					let record = entry.installation.record
					guard let owner = record.owner else { throw RefreshSkip("Signing ownership is unavailable.") }
					if automatic || selfApp {
						guard record.bundleIdentifier == id, record.expiryVerified == true, owner.teamKind == .personalFree,
							  entry.installation.executableIdentity != nil else { throw RefreshSkip("Verified signing evidence is unavailable.") }
					}
					if automatic {
						let retryAt = record.lastFailure.map {
							ZagAppleIDMaintenancePolicy.retry(at: $0.at, afterAttempts: record.consecutiveFailures, transient: !$0.reason.needsUser)
						}
						guard ZagAppleIDMaintenancePolicy.isDue(expiry: record.expiresAt, now: now,
							attempts: record.consecutiveFailures, retryAt: retryAt, lastSuccess: record.lastSuccessfulRefresh),
							ZagNativeAccountInstall.hasConnectedAccount(owner.scope.accountID) else { throw RefreshSkip("Not due for automatic refresh.") }
					}
					guard entry.installation.executableIdentity != nil || ZagNativeAppInventory.hasSource(entry) else { throw RefreshSkip("Import its original IPA to restore signing evidence.") }
					return .appleID(owner.scope)
				}
				guard !automatic, !selfApp, let plan = _certificateRefreshCache.plan(row) else { throw RefreshSkip("No compatible later profile is available.") }
				return .certificate(plan)
			}
			if case .failure = eligibility { return nil }
			return RefreshItem(app: row, eligibility: eligibility)
		}
		if !automatic, let plan = runningCertificatePlan() {
			items.insert(.init(app: ZagRunningInstallation.shared.runningApp, eligibility: .success(.certificate(plan))), at: 0)
		}
		return items
		#else
		return []
		#endif
	}

	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	private var runningPlanCache: (key: String, plan: CertificateRefresh?)?

	private func runningCertificatePlan() -> CertificateRefresh? {
		let status = ZagRunningInstallation.shared
		guard status.method == .imported, let cert = status.importedCertificate,
			  ZagRPPairingCore.shared.hasSavedPairing else { return nil }
		let catalog = Storage.shared.getAllCertificates().map {
			let path = Storage.shared.getFile(.provision, from: $0)
			let modified = try? path?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
			return "\($0.objectID.uriRepresentation())|\($0.revoked)|\(String(describing: modified))"
		}.joined(separator: ";")
		let key = "\(catalog)|\(String(describing: status.expiry))|\(String(describing: ZagRPPairingCore.shared.pairedIdentity?.udid))"
		if let cached = runningPlanCache, cached.key == key { return cached.plan }
		let plan = try? CertificateRefresh(running: status.runningApp, recorded: cert)
		runningPlanCache = (key, plan)
		return plan
	}
	#endif

	func canRefreshRunning() -> Bool {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		return ZagRPPairingCore.shared.hasSavedPairing &&
			(ZagRunningInstallation.shared.nativeUUID != nil || runningCertificatePlan() != nil)
		#else
		return false
		#endif
	}

	func refreshRunning() async {
		guard let identifier = Bundle.main.bundleIdentifier else { return }
		_ = await run(.refresh, origin: .inApp, only: identifier)
	}

	func refreshEligibleCount(_ rows: [Signed]) -> Int { refreshItems(rows).count }

	private func refresh(_ items: [RefreshItem], automatic: Bool, interactive: Bool) async -> Report {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		guard ZagNativeAccountInstall.RefreshCoordinator.beginBatch() else { return .busy(.refresh) }
		total = items.count
		let jobs = ZagInstallJobs.shared
		let jobIDs = items.map { item -> String? in
			guard let id = item.app.uuid else { return nil }
			let job = "library:\(id)"
			guard jobs.begin(job, stage: .signing) else { return nil }
			jobs.setNativeProgress(job, caption: "Refreshing", fraction: 0)
			refreshJobs.insert(job)
			return job
		}
		do {
			defer {
				for job in refreshJobs { jobs.finish(job) }
				refreshJobs.removeAll()
				ZagNativeAccountInstall.RefreshCoordinator.endBatch()
			}
			let started = ContinuousClock.now
			let coordinator = ZagNativeAccountInstall.RefreshCoordinator()
			let reports = items.map { _ in ZagSigningDiagnostics() }
			let results = await ZagNativeAppleIDs.shared.withStableActiveSelection {
				await ZagNativeSigningPipeline.concurrentRefresh(count: items.count, isCancelled: { isCancelled }) { index in
					let item = items[index]
					defer { self.completed += 1 }
					guard let job = jobIDs[index] else { return .skipped("A job is already running.") }
					defer {
						jobs.finish(job)
						self.refreshJobs.remove(job)
					}
					let report = reports[index]
					let original = automatic ? ZagNativeAppInventory.entry(item.app) : nil
					return await ZagSigningDiagnostics.current.withValue(report) {
						do {
							try jobs.checkpoint(job)
							switch try item.eligibility.get() {
							case .appleID(let scope):
								guard interactive || ZagNativeAccountInstall.hasConnectedAccount(scope.accountID) else {
									return .skipped("Sign in to this app’s Apple ID, then try Refresh.")
								}
								guard case .verified = try await ZagNativeAccountInstall.runInline(item.app, job: job,
									options: OptionsManager.shared.appleIDSigningDefaults, renew: true,
									interactive: interactive, refreshCoordinator: coordinator, profileOnly: automatic) else {
									throw ZagNativeAppInventory.Failure.unverified
								}
							case .certificate(let plan): try await plan.renew(job: job)
							}
							return .refreshed
						} catch is ZagInstallCancelled {
							return .skipped("Cancelled.")
						} catch is CancellationError {
							return .skipped("Cancelled.")
						} catch let skip as RefreshSkip {
							return .skipped(skip.reason)
						} catch {
							ZagSigningDiagnostics.recordFailure(.refresh, error)
							if let original {
								ZagNativeAppInventory.recordAutomaticFailure(original,
									reason: ZagNativeAccountInstall.automaticFailureReason(error))
							}
							return .failed(error.localizedDescription)
						}
					}
				}
			}
			var diagnostics = ["Refresh All wall time: \(started.duration(to: .now))"]
			diagnostics += reports.map(\.report).filter { !$0.isEmpty }
			if automatic, results.contains(.refreshed) {
				UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ZagAppleIDMaintenancePolicy.lastSuccessKey)
			}
			let summary = ZagNativeSigningPipeline.RefreshSummary(results, cancelled: isCancelled)
			for (item, result) in zip(items, results) {
				switch result {
				case .refreshed: break
				case .skipped(let reason), .failed(let reason):
					let safeReason = ZagDeveloperServicesProtocol.sanitizeMessage(reason, limit: 500)
					let safeName = ZagDeveloperServicesProtocol.sanitizeMessage(item.name)
					diagnostics.append("\(safeName): \(safeReason)")
				}
			}
			let needsAttention = results.contains { result in
				switch result {
				case .failed: return true
				case .skipped(let reason): return reason != "Cancelled." && reason != "A job is already running."
				case .refreshed: return false
				}
			}
			return Report(title: summary.title, message: summary.message, needsAttention: needsAttention,
				diagnostics: diagnostics.joined(separator: "\n\n"))
		}
		#else
		return .attention(.refresh, "Refresh is unavailable in this build.")
		#endif
	}

	static func updateSnapshot(_ update: UpdateManager.AvailableUpdate, completedAt: Date? = nil) -> ZagUpdateRowSnapshot {
		let notes =
			update.app.currentAppVersion?.localizedDescription ??
			update.app.versionDescription ??
			update.app.localizedDescription

		var metadata: [String] = []
		if let version = update.app.currentVersion {
			var value = String(format: .localized("Version %@"), version)
			if let build = update.app.currentAppVersion?.build,
			   !build.isEmpty, build != version {
				value += " (\(build))"
			}
			metadata.append(value)
		}
		if let size = update.app.size {
			metadata.append(size.formattedByteCount)
		}

		return ZagUpdateRowSnapshot(
			id: update.id,
			bundleID: update.installedBundleID ?? update.id,
			name: update.app.currentName,
			iconURL: update.app.iconURL?.absoluteString,
			sourceIconURL: update.source.currentIconURL?.absoluteString,
			releaseDateText: nil,
			releaseNotes: notes,
			metadataText: metadata.isEmpty ? nil : metadata.joined(separator: " • "),
			version: update.availableVersion,
			build: update.availableBuild,
			completedAt: completedAt
		)
	}

}
