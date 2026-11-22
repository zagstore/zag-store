import Foundation

// An App Store Connect API implementation of `ZagDeveloperPortalService`, so
// the existing provisioning plans, profile checks and profile parser work over
// a paid developer account's ASC key instead of GrandSlam. The team's ASC key
// scopes every call; the `team` argument is the ten-character Team ID the
// profile checks expect and is not re-sent to Apple.
//
// App groups are not part of Milestone 2; an app that requests them fails
// cleanly rather than being signed without them.

/// The portals the ASC provisioner may submit certificate requests to: the
/// App Store Connect portal only. The free-account portal does not conform, so
/// a free account's certificate requests can never bypass the free-account
/// provisioner and its certificate budget (G5 T11).
protocol ZagASCProvisioningPortal: ZagDeveloperPortalService {
	/// A development profile for `appID` that names `deviceUDID` and the
	/// certificate `certificateSerial` and is valid until at least
	/// `validUntil`: the existing Zag Store profile when it qualifies (no
	/// write), otherwise a new one that replaces it. `created` says which.
	func developmentProfile(
		for appID: ZagRegisteredAppID, team: String, deviceUDID: String, certificateSerial: String, validUntil: Date
	) async throws -> (profile: ZagIssuedProfile, created: Bool)
}

extension ZagASCProvisioningPortal {
	/// Portals that cannot list profiles cut a new one each time.
	func developmentProfile(
		for appID: ZagRegisteredAppID, team: String, deviceUDID: String, certificateSerial: String, validUntil: Date
	) async throws -> (profile: ZagIssuedProfile, created: Bool) {
		(try await profile(for: appID, team: team), true)
	}
}

/// Both of an App ID's Zag Store profile names are held by profiles that can
/// still sign, and Apple refused a replacement alongside them. Nothing was
/// deleted. Recoverable: removing one of the named profiles at Apple frees a
/// name for the next attempt.
struct ZagASCProfileReplacementBlocked: Error, Equatable, Sendable {
	let profileNames: [String]
}

struct ZagASCDeveloperPortal: ZagASCProvisioningPortal {
	let client: ZagASCClient
	/// Decodes a downloaded `.mobileprovision` into the checked profile. The
	/// default parses the real file; tests inject a decoder for canned content.
	var decodeProfile: @Sendable (Data) throws -> ZagIssuedProfile = { try ZagIssuedProfile(profileData: $0) }

	// MARK: Devices

	/// The team's enabled iOS devices. A disabled device cannot be put in a
	/// profile, so it is not "registered" for planning; `registerDevice`
	/// re-enables it.
	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		let (records, _) = try await mapping {
			try await client.list(.devices, as: ZagASCDevice.self, filters: ["platform": "IOS", "status": "ENABLED"])
		}
		return records.compactMap { record in
			guard let udid = record.attributes?.udid, !udid.isEmpty else { return nil }
			return ZagRegisteredDevice(udid: udid, name: record.attributes?.name ?? "Device")
		}
	}

	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice {
		do {
			let record = try await client.create(.devices, attributes: ["name": name, "platform": "IOS", "udid": udid], as: ZagASCDevice.self)
			return ZagRegisteredDevice(udid: record.attributes?.udid ?? udid, name: record.attributes?.name ?? name)
		} catch ZagASCError.conflict {
			// Already on the team (ASC never deletes a device, only disables
			// one): find it in any state and re-enable it if it was disabled.
			let (records, _) = try await mapping { try await client.list(.devices, as: ZagASCDevice.self, filters: ["udid": udid]) }
			guard let existing = records.first(where: { $0.attributes?.udid?.lowercased() == udid.lowercased() }) else {
				throw ZagPortalError.malformedResponse
			}
			if existing.attributes?.status == "DISABLED" {
				_ = try await mapping { try await client.update(.devices, id: existing.id, attributes: ["status": "ENABLED"], as: ZagASCDevice.self) }
			}
			return ZagRegisteredDevice(udid: existing.attributes?.udid ?? udid, name: existing.attributes?.name ?? name)
		} catch { throw Self.portalError(error) }
	}

	// MARK: App IDs (bundle IDs)

	func appIDs(team: String) async throws -> [ZagRegisteredAppID] {
		let (records, _) = try await mapping { try await client.list(.bundleIDs, as: ZagASCBundleID.self) }
		return records.compactMap { record in
			guard let identifier = record.attributes?.identifier else { return nil }
			// Paid bundle IDs do not expire (unlike a free team's 7-day App IDs).
			return ZagRegisteredAppID(identifier: identifier, bundleIdentifier: identifier, expiresAt: nil)
		}
	}

	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID {
		do {
			let record = try await client.create(
				.bundleIDs,
				attributes: ["identifier": bundleIdentifier, "name": name, "platform": "IOS"],
				as: ZagASCBundleID.self
			)
			let identifier = record.attributes?.identifier ?? bundleIdentifier
			return ZagRegisteredAppID(identifier: identifier, bundleIdentifier: identifier, expiresAt: nil)
		} catch ZagASCError.conflict {
			// Either this team already owns it (reuse) or another team does.
			// Looked up by identifier, so a team with more bundle IDs than one
			// page still finds its own.
			if try await bundleIDRecordID(bundleIdentifier) != nil {
				return ZagRegisteredAppID(identifier: bundleIdentifier, bundleIdentifier: bundleIdentifier, expiresAt: nil)
			}
			throw ZagPortalError.identifierUnavailable(bundleIdentifier)
		} catch { throw Self.portalError(error) }
	}

	// MARK: App groups (not supported in M2)

	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] { [] }
	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup { throw ZagPortalError.malformedResponse }
	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws { throw ZagPortalError.malformedResponse }

	// MARK: Certificates

	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		let (records, _) = try await mapping {
			try await client.list(.certificates, as: ZagASCCertificate.self, filters: ["certificateType": "IOS_DEVELOPMENT"])
		}
		return records.compactMap { Self.certificate(from: $0.attributes) }
	}

	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		do {
			let record = try await client.create(
				.certificates,
				attributes: ["certificateType": "IOS_DEVELOPMENT", "csrContent": ZagASCClient.pemCSR(request.data)],
				as: ZagASCCertificate.self
			)
			guard let certificate = Self.certificate(from: record.attributes), let data = certificate.data else {
				throw ZagPortalError.malformedResponse
			}
			return ZagIssuedCertificate(certificate: certificate, data: data)
		} catch ZagASCError.conflict {
			throw ZagPortalError.certificateLimitReached
		} catch { throw Self.portalError(error) }
	}

	// MARK: Profiles

	/// Zag Store keeps one development profile per App ID, under a fixed name,
	/// so a refresh can find it again instead of adding another. A replacement
	/// is made under the second name before the old profile is removed, so a
	/// working profile is never deleted until its replacement exists; there
	/// are never more than two.
	static func profileName(for bundleIdentifier: String) -> String { "Zag Store \(bundleIdentifier)" }
	static func profileNames(for bundleIdentifier: String) -> [String] {
		let name = profileName(for: bundleIdentifier)
		return [name, name + " B"]
	}

	func developmentProfile(
		for appID: ZagRegisteredAppID, team: String, deviceUDID: String, certificateSerial: String, validUntil: Date
	) async throws -> (profile: ZagIssuedProfile, created: Bool) {
		let names = Self.profileNames(for: appID.bundleIdentifier)
		let (listed, _) = try await mapping {
			try await client.list(.profiles, as: ZagASCProfile.self, filters: ["name": names.joined(separator: ","), "profileType": "IOS_APP_DEVELOPMENT"])
		}
		// Apple's name filter is not documented as exact; only ours count.
		let ours = listed.filter { names.contains($0.attributes?.name ?? "") }
		var usable: [ZagIssuedProfile?] = []
		for record in ours {
			// Usable: active, readable and unexpired, so it can still sign.
			let profile = record.attributes?.profileState == "ACTIVE" ? try? decodedProfile(record.attributes) : nil
			usable.append(profile.flatMap { $0.expiresAt > client.now() ? $0 : nil })
			guard let profile else { continue }
			let problem = ZagProvisioningProfileCheck.check(
				profile, team: team, bundleIdentifier: appID.bundleIdentifier,
				deviceUDID: deviceUDID, certificateSerial: certificateSerial, now: client.now()
			)
			if problem == nil, profile.expiresAt >= validUntil { return (profile, false) }
		}
		// None qualifies (new device or certificate, expiring, or invalid).
		// A usable profile is never deleted before its replacement exists.
		let taken = Set(ours.compactMap { $0.attributes?.name })
		let replacement: ZagIssuedProfile
		let replacementID: String
		if let free = names.first(where: { !taken.contains($0) }) {
			(replacement, replacementID) = try await createProfile(for: appID, name: free)
		} else if let unusable = zip(ours, usable).first(where: { $0.1 == nil })?.0 {
			// Both names taken (an earlier cleanup did not finish), one by a
			// profile that can no longer sign: removing it first loses nothing.
			try await mapping { try await client.delete(.profiles, id: unusable.id) }
			(replacement, replacementID) = try await createProfile(for: appID, name: unusable.attributes?.name ?? names[0])
		} else {
			// Both names taken by usable profiles. Try the create with nothing
			// deleted (under the older one's name, which Apple may allow); if
			// Apple refuses, both stay and the user is told how to recover.
			let older = zip(ours, usable).min { ($0.1?.expiresAt ?? .distantPast) < ($1.1?.expiresAt ?? .distantPast) }!.0
			(replacement, replacementID) = try await createProfile(
				for: appID, name: older.attributes?.name ?? names[0],
				refused: ZagASCProfileReplacementBlocked(profileNames: names)
			)
		}
		// Then remove the superseded ones. The replacement already exists, so
		// a failure here is left for the next replacement to tidy.
		for record in ours where record.id != replacementID {
			try? await client.delete(.profiles, id: record.id)
		}
		return (replacement, true)
	}

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		try await createProfile(for: appID, name: Self.profileName(for: appID.bundleIdentifier)).profile
	}

	/// Creates a profile named `name`. With `refused`, Apple rejecting the
	/// request itself (409, 400/422) throws that error instead.
	private func createProfile(
		for appID: ZagRegisteredAppID, name: String, refused: Error? = nil
	) async throws -> (profile: ZagIssuedProfile, id: String) {
		guard let bundleIDRecordID = try await bundleIDRecordID(appID.bundleIdentifier) else { throw ZagPortalError.malformedResponse }
		let certificateIDs = try await mapping {
			try await client.list(.certificates, as: ZagASCCertificate.self, filters: ["certificateType": "IOS_DEVELOPMENT"]).records.map(\.id)
		}
		let deviceIDs = try await mapping {
			try await client.list(.devices, as: ZagASCDevice.self, filters: ["platform": "IOS", "status": "ENABLED"]).records.map(\.id)
		}
		guard !certificateIDs.isEmpty, !deviceIDs.isEmpty else { throw ZagPortalError.malformedResponse }

		let relationships: [String: Any] = [
			"bundleId": ["data": ["type": "bundleIds", "id": bundleIDRecordID]],
			"certificates": ["data": certificateIDs.map { ["type": "certificates", "id": $0] }],
			"devices": ["data": deviceIDs.map { ["type": "devices", "id": $0] }]
		]
		let record: ZagASCRecord<ZagASCProfile>
		do {
			record = try await client.create(
				.profiles,
				attributes: ["name": name, "profileType": "IOS_APP_DEVELOPMENT"],
				relationships: relationships,
				as: ZagASCProfile.self
			)
		} catch ZagASCError.conflict where refused != nil {
			throw refused!
		} catch ZagASCError.invalidRequest where refused != nil {
			throw refused!
		} catch {
			throw Self.portalError(error)
		}
		return (try decodedProfile(record.attributes), record.id)
	}

	private func decodedProfile(_ attributes: ZagASCProfile?) throws -> ZagIssuedProfile {
		guard let content = attributes?.profileContent,
			  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters), !data.isEmpty else {
			throw ZagPortalError.malformedResponse
		}
		do {
			return try decodeProfile(data)
		} catch {
			throw ZagPortalError.malformedResponse
		}
	}

	// MARK: Helpers

	/// The ASC record ID of a bundle ID, matched exactly (Apple's identifier
	/// filter also matches longer identifiers that contain it).
	private func bundleIDRecordID(_ identifier: String) async throws -> String? {
		let (records, _) = try await mapping { try await client.list(.bundleIDs, as: ZagASCBundleID.self, filters: ["identifier": identifier]) }
		return records.first { $0.attributes?.identifier == identifier }?.id
	}

	private static func certificate(from attributes: ZagASCCertificate?) -> ZagDevelopmentCertificate? {
		guard let attributes, let serial = attributes.serialNumber,
			  let expiry = attributes.expirationDate.flatMap(parseDate) else { return nil }
		let data = attributes.certificateContent.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
		return ZagDevelopmentCertificate(serialNumber: serial, name: attributes.name ?? "Development", machineName: nil, expiresAt: expiry, data: data)
	}

	/// ISO 8601, with or without fractional seconds (ASC uses both).
	static func parseDate(_ text: String) -> Date? {
		let withFraction = ISO8601DateFormatter()
		withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let date = withFraction.date(from: text) { return date }
		let plain = ISO8601DateFormatter()
		plain.formatOptions = [.withInternetDateTime]
		return plain.date(from: text)
	}

	/// Runs an ASC call and maps any `ZagASCError` to a `ZagPortalError`.
	private func mapping<T>(_ body: () async throws -> T) async throws -> T {
		do { return try await body() } catch { throw Self.portalError(error) }
	}

	/// The portal error for an ASC failure. Cancellation stays cancellation
	/// (`CancellationError`), so it is never reported as a network problem.
	static func portalError(_ error: Error) -> Error {
		switch error {
		case is CancellationError, ZagASCError.transport(.cancelled): return CancellationError()
		default: return mappedPortalError(error)
		}
	}

	private static func mappedPortalError(_ error: Error) -> ZagPortalError {
		switch error {
		case let portal as ZagPortalError: return portal
		case ZagASCError.unauthorized, ZagASCError.forbidden: return .sessionRejected
		case ZagASCError.rateLimited: return .rateLimited
		// Conflicts the portal understands (an existing device, bundle ID or
		// the certificate limit) are handled where they happen; any other is
		// unexpected, and Apple's code is never shown as an identifier.
		case ZagASCError.conflict: return .malformedResponse
		case ZagASCError.transport(.offline), ZagASCError.transport(.timedOut): return .network
		case ZagASCError.transport: return .network
		case ZagASCError.server: return .malformedResponse
		default: return .malformedResponse
		}
	}
}
