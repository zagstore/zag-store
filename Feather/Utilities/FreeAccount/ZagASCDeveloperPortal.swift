import Foundation

// An App Store Connect API implementation of `ZagDeveloperPortalService`, so
// the existing provisioning plans, profile checks and profile parser work over
// a paid developer account's ASC key instead of GrandSlam. The team's ASC key
// scopes every call; the `team` argument is the ten-character Team ID the
// profile checks expect and is not re-sent to Apple.
//
// App groups are not part of Milestone 2; an app that requests them fails
// cleanly rather than being signed without them.

struct ZagASCDeveloperPortal: ZagDeveloperPortalService {
	let client: ZagASCClient
	/// Decodes a downloaded `.mobileprovision` into the checked profile. The
	/// default parses the real file; tests inject a decoder for canned content.
	var decodeProfile: @Sendable (Data) throws -> ZagIssuedProfile = { try ZagIssuedProfile(profileData: $0) }

	// MARK: Devices

	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		let (records, _) = try await mapping { try await client.list(.devices, as: ZagASCDevice.self) }
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
			// Already registered (ASC never deletes a device): find and reuse it.
			if let existing = try await devices(team: team).first(where: { $0.udid.lowercased() == udid.lowercased() }) {
				return existing
			}
			throw ZagPortalError.malformedResponse
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
			if let mine = try await appIDs(team: team).first(where: { $0.bundleIdentifier == bundleIdentifier }) {
				return mine
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

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		let bundleIDRecordID = try await resourceID(.bundleIDs, as: ZagASCBundleID.self, where: { $0.identifier == appID.bundleIdentifier })
		guard let bundleIDRecordID else { throw ZagPortalError.malformedResponse }
		let certificateIDs = try await mapping {
			try await client.list(.certificates, as: ZagASCCertificate.self, filters: ["certificateType": "IOS_DEVELOPMENT"]).records.map(\.id)
		}
		let deviceIDs = try await mapping { try await client.list(.devices, as: ZagASCDevice.self).records.map(\.id) }
		guard !certificateIDs.isEmpty, !deviceIDs.isEmpty else { throw ZagPortalError.malformedResponse }

		let name = "Zag Store \(appID.bundleIdentifier) \(Int(client.now().timeIntervalSince1970))"
		let relationships: [String: Any] = [
			"bundleId": ["data": ["type": "bundleIds", "id": bundleIDRecordID]],
			"certificates": ["data": certificateIDs.map { ["type": "certificates", "id": $0] }],
			"devices": ["data": deviceIDs.map { ["type": "devices", "id": $0] }]
		]
		let record = try await mapping {
			try await client.create(
				.profiles,
				attributes: ["name": name, "profileType": "IOS_APP_DEVELOPMENT"],
				relationships: relationships,
				as: ZagASCProfile.self
			)
		}
		guard let content = record.attributes?.profileContent,
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

	private func resourceID<Attributes: Decodable & Sendable>(
		_ resource: ZagASCResource, as _: Attributes.Type, where match: (Attributes) -> Bool
	) async throws -> String? {
		let (records, _) = try await mapping { try await client.list(resource, as: Attributes.self) }
		return records.first { $0.attributes.map(match) ?? false }?.id
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

	static func portalError(_ error: Error) -> ZagPortalError {
		switch error {
		case let portal as ZagPortalError: return portal
		case ZagASCError.unauthorized, ZagASCError.forbidden: return .sessionRejected
		case ZagASCError.rateLimited: return .rateLimited
		case ZagASCError.conflict(let code):
			return code.map(ZagPortalError.identifierUnavailable) ?? .malformedResponse
		case ZagASCError.transport(.offline), ZagASCError.transport(.timedOut): return .network
		case ZagASCError.transport: return .network
		case ZagASCError.server: return .malformedResponse
		default: return .malformedResponse
		}
	}
}
