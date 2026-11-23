#if ZAG_ZSIGN_STRICT
import Foundation

// The orchestrator the UI (and the acceptance test) calls: it turns a selected
// IPA, a device and a team into an installed, verified app, reusing the proven
// provisioning + engine-signing + install steps, and records what it installed
// so it can be renewed. Steps are blocking (they drive command-line tools); the
// UI runs them off the main thread and receives progress on the calling thread.

public struct ZagCompanionConfig: Sendable {
	public let templateProjectURL: URL
	public let workDirectory: URL
	public let outputDirectory: URL
	public let registryURL: URL
	/// How close to expiry a managed app must be before renewal tries to obtain
	/// a genuinely fresh profile. Default: 2 days.
	public var renewalThreshold: TimeInterval = 2 * 86_400

	/// Default locations under Application Support, with the template bundled
	/// beside the app (or pointed at the in-repo experiment for the CLI test).
	public init(templateProjectURL: URL,
				supportDirectory: URL? = nil,
				renewalThreshold: TimeInterval = 2 * 86_400) {
		self.renewalThreshold = renewalThreshold
		let support = supportDirectory ?? FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/ZagCompanion")
		try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		self.templateProjectURL = templateProjectURL
		self.workDirectory = support.appendingPathComponent("work")
		self.outputDirectory = support.appendingPathComponent("signed")
		self.registryURL = support.appendingPathComponent("managed-apps.json")
		try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
		try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
	}
}

public final class ZagCompanionService {
	public let config: ZagCompanionConfig
	private let provisioning: ZagCompanionProvisioning
	private let signer = ZagCompanionSigner()
	public let registry: ZagManagedAppRegistry

	public init(config: ZagCompanionConfig) {
		self.config = config
		self.provisioning = ZagCompanionProvisioning(templateProjectURL: config.templateProjectURL)
		self.registry = ZagManagedAppRegistry(url: config.registryURL)
	}

	public typealias Progress = (ZagCompanionProgress) -> Void

	/// Reads the IPA, resolves a profile, signs with the engine, verifies,
	/// installs, and records the result. `allowNewProvisioning` gates the only
	/// Apple-side action (device registration + profile issuance).
	@discardableResult
	public func install(ipa: URL, on device: ZagCompanionDevice, team: ZagCompanionTeam,
						allowNewProvisioning: Bool, now: Date = Date(), progress: Progress = { _ in }) throws -> ZagManagedApp {
		progress(ZagCompanionProgress(.readingIPA, "Reading \(ipa.lastPathComponent)…"))
		let info = try ZagIPA.info(ipa)
		if !info.extensionBundleIdentifiers.isEmpty {
			throw ZagCompanionError.unprovisionableExtensions(info.extensionBundleIdentifiers)
		}

		progress(ZagCompanionProgress(.resolvingProfile, "Finding a profile for \(info.bundleIdentifier) on \(device.name)…"))
		let profile: ZagResolvedProfile
		if let existing = ZagCompanionProvisioning.existingProfile(bundleID: info.bundleIdentifier, deviceUDID: device.udid, team: team.identifier, now: now) {
			profile = existing
		} else {
			progress(ZagCompanionProgress(.provisioning, "Asking Xcode to provision \(info.bundleIdentifier)…"))
			profile = try provisioning.resolve(bundleID: info.bundleIdentifier, device: device, team: team,
											   allowNewProvisioning: allowNewProvisioning, now: now)
		}

		let signed = try signAndInstall(ipa: ipa, info: info, profile: profile, device: device, now: now, progress: progress)

		let managed = ZagManagedApp(
			bundleIdentifier: info.bundleIdentifier, displayName: info.displayName, deviceUDID: device.udid,
			deviceName: device.name, teamIdentifier: profile.teamIdentifier, sourceIPAPath: ipa.path,
			certificateSerial: signed.certificateSerial, profileExpiresAt: signed.profileExpiresAt, installedAt: now)
		registry.upsert(managed)
		progress(ZagCompanionProgress(.done, "Installed \(info.displayName). Expires \(Self.format(signed.profileExpiresAt))."))
		return managed
	}

	/// Renews a managed app. Validates that the selected device and team match
	/// the ones the app was installed under, decides (purely) whether a fresh
	/// profile is needed from its expiry and the configured threshold, obtains
	/// one through Xcode when authorised, and reports an extension only when the
	/// new expiry is genuinely later than the old one.
	@discardableResult
	public func renew(_ app: ZagManagedApp, on device: ZagCompanionDevice, team: ZagCompanionTeam,
					  allowNewProvisioning: Bool, now: Date = Date(), progress: Progress = { _ in }) throws -> ZagRenewalOutcome {
		// 1. Device and team must match what this app was installed under.
		guard device.udid == app.deviceUDID else {
			throw ZagCompanionError.deviceMismatch(expectedUDIDSuffix: String(app.deviceUDID.suffix(6)))
		}
		guard team.identifier == app.teamIdentifier else {
			throw ZagCompanionError.teamMismatch(expected: app.teamIdentifier, got: team.identifier)
		}
		let ipa = URL(fileURLWithPath: app.sourceIPAPath)
		guard FileManager.default.fileExists(atPath: ipa.path) else {
			throw ZagCompanionError.ipaUnreadable("source IPA missing")
		}
		progress(ZagCompanionProgress(.resolvingProfile, "Renewing \(app.displayName)…"))
		let info = try ZagIPA.info(ipa)

		// 2. Decide from dates + authorisation (pure), then obtain the profile.
		let candidate = ZagCompanionProvisioning.existingProfile(bundleID: app.bundleIdentifier, deviceUDID: device.udid, team: team.identifier, now: now)
		let decision = ZagRenewalPlanner.plan(previousExpiry: app.profileExpiresAt, candidateExpiry: candidate?.expiresAt,
											  now: now, threshold: config.renewalThreshold, allowNewProvisioning: allowNewProvisioning)
		let profile: ZagResolvedProfile
		var issuedFresh = false
		switch decision.action {
		case .reuseNewerProfile, .reuseWithoutExtension:
			guard let candidate else { throw ZagCompanionError.noUsableProfile(bundleID: app.bundleIdentifier, device: device.name) }
			profile = candidate
		case .provisionFresh:
			progress(ZagCompanionProgress(.provisioning, "Obtaining a fresh profile from Xcode…"))
			profile = try provisioning.provisionViaXcode(bundleID: app.bundleIdentifier, device: device, team: team)
			issuedFresh = true
		case .blockedNeedsAuthorization:
			throw ZagCompanionError.renewalNeedsAuthorization(bundleID: app.bundleIdentifier)
		}

		// 3. Validate the resolved profile against the app before re-signing.
		guard profile.bundleIdentifier == app.bundleIdentifier,
			  profile.teamIdentifier == app.teamIdentifier,
			  profile.deviceUDIDs.contains(device.udid) else {
			throw ZagCompanionError.verificationFailed("the renewal profile does not match the app, team and device")
		}

		let signed = try signAndInstall(ipa: ipa, info: info, profile: profile, device: device, now: now, progress: progress)

		// 4. Only claim an extension if the expiry is genuinely later.
		let previousExpiry = app.profileExpiresAt
		let newExpiry = signed.profileExpiresAt
		let extended = newExpiry > previousExpiry
		var updated = app
		updated.certificateSerial = signed.certificateSerial
		updated.profileExpiresAt = newExpiry
		updated.lastRenewedAt = now
		registry.upsert(updated)
		progress(ZagCompanionProgress(.done, extended
			? "Renewed \(app.displayName). Expiry extended to \(Self.format(newExpiry))."
			: "Reinstalled \(app.displayName) with the current profile — expiry unchanged (\(Self.format(newExpiry)))."))
		return ZagRenewalOutcome(app: updated, previousExpiry: previousExpiry, newExpiry: newExpiry, extended: extended, issuedFreshProfile: issuedFresh)
	}

	// MARK: - Shared pipeline

	private func signAndInstall(ipa: URL, info: ZagCompanionIPAInfo, profile: ZagResolvedProfile,
								device: ZagCompanionDevice, now: Date, progress: Progress) throws -> ZagCompanionSigningOutcome {
		let work = config.workDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: work) }
		let app = try ZagIPA.unpack(ipa, into: work)

		progress(ZagCompanionProgress(.signing, "Signing \(info.displayName) with Zag Store's engine…"))
		let outcome = try signer.sign(app: app, profileData: profile.data, workRoot: work, now: now)

		progress(ZagCompanionProgress(.verifying, "Verified (\(outcome.signatureCount) signatures, codesign + Zsign)."))
		let outIPA = config.outputDirectory.appendingPathComponent("\(info.bundleIdentifier).ipa")
		try ZagIPA.repack(workDir: work, to: outIPA)

		progress(ZagCompanionProgress(.installing, "Installing on \(device.name)…"))
		try ZagDeviceControl.install(outIPA, on: device)
		return outcome
	}

	static func format(_ date: Date) -> String {
		let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: date)
	}
}

/// A tiny JSON-backed registry of apps Zag Companion installed, keyed by
/// bundle ID + device. Holds only renewal metadata — never key material.
public final class ZagManagedAppRegistry {
	private let url: URL
	private let queue = DispatchQueue(label: "zag.companion.registry")
	public init(url: URL) { self.url = url }

	public func all() -> [ZagManagedApp] {
		queue.sync {
			guard let data = try? Data(contentsOf: url),
				  let apps = try? JSONDecoder.zag.decode([ZagManagedApp].self, from: data) else { return [] }
			return apps.sorted { $0.profileExpiresAt < $1.profileExpiresAt }
		}
	}

	public func upsert(_ app: ZagManagedApp) {
		queue.sync {
			var apps = (try? JSONDecoder.zag.decode([ZagManagedApp].self, from: (try? Data(contentsOf: url)) ?? Data())) ?? []
			apps.removeAll { $0.id == app.id }
			apps.append(app)
			if let data = try? JSONEncoder.zag.encode(apps) { try? data.write(to: url, options: .atomic) }
		}
	}

	public func remove(_ app: ZagManagedApp) {
		queue.sync {
			var apps = (try? JSONDecoder.zag.decode([ZagManagedApp].self, from: (try? Data(contentsOf: url)) ?? Data())) ?? []
			apps.removeAll { $0.id == app.id }
			if let data = try? JSONEncoder.zag.encode(apps) { try? data.write(to: url, options: .atomic) }
		}
	}
}

extension JSONEncoder { static var zag: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }
extension JSONDecoder { static var zag: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
#endif
