import Foundation

// Resolving a usable free-account provisioning profile for a (bundle ID,
// device) pair: first by reusing one Xcode already issued, and only with
// explicit authorisation by asking Xcode to provision a bundle-ID-specific
// temporary project. The private key is never touched here — only the profile.

public struct ZagResolvedProfile: Sendable {
	public let data: Data
	public let url: URL
	public let teamIdentifier: String
	public let bundleIdentifier: String
	public let certificateSerials: [String]
	public let deviceUDIDs: [String]
	public let expiresAt: Date
	public let issuedByCompanion: Bool
}

public struct ZagCompanionProvisioning {
	public static var profilesDirectory: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
	}

	/// The temporary Xcode project the companion uses to ask Xcode to provision
	/// an arbitrary bundle ID. Bundled beside the companion; a copy is edited
	/// per bundle ID so the template is never mutated.
	public let templateProjectURL: URL
	public init(templateProjectURL: URL) { self.templateProjectURL = templateProjectURL }

	// MARK: - Teams

	/// Free "Personal Team"s known to Xcode, plus any paid teams, de-duplicated.
	/// A free team is flagged so the UI and limits are correct.
	public static func availableTeams() -> [ZagCompanionTeam] {
		var teams: [String: ZagCompanionTeam] = [:]
		let userData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/UserData")
		let plists = (try? FileManager.default.contentsOfDirectory(atPath: userData.path)) ?? []
		for name in plists where name.hasPrefix("IDEProvisioningTeamByIdentifier") && name.hasSuffix(".plist") {
			guard let data = try? Data(contentsOf: userData.appendingPathComponent(name)),
				  let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
			for (teamID, value) in root {
				guard let entries = value as? [[String: Any]], let entry = entries.first else { continue }
				let teamName = (entry["teamName"] as? String) ?? teamID
				let type = (entry["teamType"] as? String)?.lowercased() ?? ""
				let free = ((entry["isFreeProvisioningTeam"] as? Bool) ?? (entry["freeProvisioningStyle"] != nil)) || type.contains("personal")
				teams[teamID] = ZagCompanionTeam(identifier: teamID, name: teamName, isFree: free)
			}
		}
		// Fall back to the teams implied by Apple Development identities present.
		for serial in ZagCompanionKeychain.appleDevelopmentTeams() where teams[serial.team] == nil {
			teams[serial.team] = ZagCompanionTeam(identifier: serial.team, name: serial.commonName, isFree: true)
		}
		return teams.values.sorted { ($0.isFree ? 0 : 1, $0.name) < ($1.isFree ? 0 : 1, $1.name) }
	}

	// MARK: - Resolve

	/// A profile that covers this bundle ID on this device, not expired, whose
	/// certificate is a Keychain identity we can sign with. Newest expiry wins.
	public static func existingProfile(bundleID: String, deviceUDID: String, now: Date = Date()) -> ZagResolvedProfile? {
		let dir = profilesDirectory
		let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
		var best: ZagResolvedProfile?
		for file in files where file.hasSuffix(".mobileprovision") {
			let url = dir.appendingPathComponent(file)
			guard let data = try? Data(contentsOf: url), let profile = try? ZagIssuedProfile(profileData: data) else { continue }
			guard profile.bundleIdentifier == bundleID,
				  profile.deviceUDIDs.contains(deviceUDID),
				  profile.expiresAt > now,
				  profile.certificateSerials.contains(where: { ZagCompanionKeychain.hasIdentity(serial: $0) }) else { continue }
			let candidate = ZagResolvedProfile(
				data: data, url: url, teamIdentifier: profile.teamIdentifier, bundleIdentifier: profile.bundleIdentifier,
				certificateSerials: profile.certificateSerials, deviceUDIDs: profile.deviceUDIDs,
				expiresAt: profile.expiresAt, issuedByCompanion: false)
			if best == nil || candidate.expiresAt > best!.expiresAt { best = candidate }
		}
		return best
	}

	/// Resolves a profile, provisioning through Xcode only when none exists and
	/// `allowNewProvisioning` is set (a new Apple-side action: registers the
	/// device, issues a profile, and may consume a free-team slot).
	public func resolve(bundleID: String, device: ZagCompanionDevice, team: ZagCompanionTeam,
						allowNewProvisioning: Bool, now: Date = Date()) throws -> ZagResolvedProfile {
		if let existing = Self.existingProfile(bundleID: bundleID, deviceUDID: device.udid, now: now) { return existing }
		guard allowNewProvisioning else { throw ZagCompanionError.noUsableProfile(bundleID: bundleID, device: device.name) }
		return try provisionViaXcode(bundleID: bundleID, device: device, team: team)
	}

	/// Asks Xcode to provision `bundleID` for `device` using a disposable copy
	/// of the template project. Validates the resulting profile before use.
	public func provisionViaXcode(bundleID: String, device: ZagCompanionDevice, team: ZagCompanionTeam) throws -> ZagResolvedProfile {
		let work = FileManager.default.temporaryDirectory.appendingPathComponent("zag-provision-\(UUID().uuidString)")
		try? FileManager.default.removeItem(at: work)
		try FileManager.default.copyItem(at: templateProjectURL, to: work)
		let pbxproj = work.appendingPathComponent("XcodePTTeamProbe.xcodeproj/project.pbxproj")
		guard var text = try? String(contentsOf: pbxproj, encoding: .utf8) else {
			throw ZagCompanionError.provisioningRefused("template project unreadable")
		}
		text = text.replacingOccurrences(of: "dev.zagstore.ptteamprobe", with: bundleID)
		try text.write(to: pbxproj, atomically: true, encoding: .utf8)

		let dd = work.appendingPathComponent("dd")
		let build = ZagProcess.xcrun("xcodebuild", [
			"-allowProvisioningUpdates",
			"-project", work.appendingPathComponent("XcodePTTeamProbe.xcodeproj").path,
			"-scheme", "PTTeamProbe",
			"-destination", "platform=iOS,id=\(device.udid)",
			"-derivedDataPath", dd.path,
			"DEVELOPMENT_TEAM=\(team.identifier)",
			"PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
			"build",
		])
		guard build.combined.contains("BUILD SUCCEEDED") else {
			throw ZagCompanionError.provisioningRefused(String(build.combined.suffix(600)))
		}
		let app = dd.appendingPathComponent("Build/Products/Debug-iphoneos/PTTeamProbe.app")
		let embedded = app.appendingPathComponent("embedded.mobileprovision")
		guard let data = try? Data(contentsOf: embedded), let profile = try? ZagIssuedProfile(profileData: data) else {
			throw ZagCompanionError.provisioningRefused("no profile was produced")
		}
		// Validate what Xcode actually issued — never assume it matches the ask.
		guard profile.bundleIdentifier == bundleID else {
			throw ZagCompanionError.provisioningRefused("Xcode issued a profile for \(profile.bundleIdentifier), not \(bundleID)")
		}
		guard profile.deviceUDIDs.contains(device.udid) else {
			throw ZagCompanionError.provisioningRefused("the issued profile does not include this device")
		}
		return ZagResolvedProfile(
			data: data, url: embedded, teamIdentifier: profile.teamIdentifier, bundleIdentifier: profile.bundleIdentifier,
			certificateSerials: profile.certificateSerials, deviceUDIDs: profile.deviceUDIDs,
			expiresAt: profile.expiresAt, issuedByCompanion: true)
	}
}
