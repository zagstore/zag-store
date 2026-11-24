import Foundation

// Phase 3: the developer-portal operations a free account needs (devices,
// App IDs, app groups, development certificates, provisioning profiles),
// as an interface. Only a simulation implements it; the live service is a
// disabled stub until it is specified, reviewed and tested under supervision.

/// Entitlements as a property list, so they can cross actor boundaries.
struct ZagEntitlementSet: Sendable, Equatable {
	let data: Data

	init(_ dictionary: [String: Any]) throws {
		data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
	}

	var dictionary: [String: Any] {
		(try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
	}

	static func == (lhs: ZagEntitlementSet, rhs: ZagEntitlementSet) -> Bool {
		NSDictionary(dictionary: lhs.dictionary).isEqual(to: rhs.dictionary)
	}
}

struct ZagRegisteredDevice: Codable, Equatable, Sendable {
	let udid: String
	let name: String
}

struct ZagRegisteredAppGroup: Codable, Equatable, Sendable {
	let identifier: String
}

/// What the portal returns for a new development certificate. The private
/// key never leaves the device; only the certificate signing request is sent.
struct ZagIssuedCertificate: Sendable, Equatable {
	let certificate: ZagDevelopmentCertificate
	/// The DER certificate.
	let data: Data
}

// ZagCertificateRequest, ZagSigningKeyFactory, ZagDisabledSigningKeyFactory and
// ZagSigningIdentity now live in ZagSigningModels.swift (a light file with no
// profile-parser dependency), so the on-device signing stack can be reused by
// the certificate-issuance harness without pulling in Certificate.decode.

/// A provisioning profile as issued. `data` is the signed file embedded in
/// the app; the other fields are read from that file (by the live service)
/// and checked by `ZagProvisioningProfileCheck` before the profile is used.
struct ZagIssuedProfile: Sendable, Equatable {
	let uuid: String
	let teamIdentifier: String
	let bundleIdentifier: String
	let certificateSerials: [String]
	let deviceUDIDs: [String]
	let entitlements: ZagEntitlementSet
	let createdAt: Date
	let expiresAt: Date
	let data: Data
}

extension ZagIssuedProfile {
	/// Reads a signed .mobileprovision with Zag Store's profile parser
	/// (`Certificate.decode`). Certificate serials come from the profile's own
	/// developer certificates, in `ZagCertificateInspection`'s format.
	init(profileData: Data) throws {
		guard let profile = try? Certificate.decode(profileData: profileData),
			  let team = profile.TeamIdentifier.first,
			  let entitlements = profile.Entitlements?.mapValues(\.value),
			  let applicationIdentifier = entitlements[ZagFreeAccountEntitlements.applicationIdentifierKey] as? String,
			  let dot = applicationIdentifier.firstIndex(of: "."),
			  let entitlementSet = try? ZagEntitlementSet(entitlements) else {
			throw ZagPortalError.malformedResponse
		}
		self.init(
			uuid: profile.UUID,
			teamIdentifier: team,
			bundleIdentifier: String(applicationIdentifier[applicationIdentifier.index(after: dot)...]),
			certificateSerials: (profile.DeveloperCertificates ?? []).compactMap { ZagCertificateInspection(der: $0)?.serialNumber },
			deviceUDIDs: profile.ProvisionedDevices ?? [],
			entitlements: entitlementSet,
			createdAt: profile.CreationDate,
			expiresAt: profile.ExpirationDate,
			data: profileData
		)
	}
}

extension ZagProfileIdentityAudit {
	/// Audits a parsed profile against the discovered team and this device.
	/// Pulls primitives from `ZagIssuedProfile`; the audit itself is pure.
	init(profile: ZagIssuedProfile, discoveredTeam: String, expectedDeviceUDID: String?,
		 targetBundle: String?, now: Date = Date()) {
		self = ZagProfileIdentityAudit.audit(
			profileTeam: profile.teamIdentifier,
			profileDevices: profile.deviceUDIDs,
			profileCertificateSerials: profile.certificateSerials,
			profileBundle: profile.bundleIdentifier,
			profileExpiresAt: profile.expiresAt,
			discoveredTeam: discoveredTeam,
			expectedDeviceUDID: expectedDeviceUDID,
			targetBundle: targetBundle,
			now: now)
	}
}

// ZagPortalError now lives in ZagPortalError.swift (so the pure developer-
// services codec can be compiled and host-tested without the model graph).

/// The portal operations, for one signed-in team.
protocol ZagDeveloperPortalService: Sendable {
	func devices(team: String) async throws -> [ZagRegisteredDevice]
	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice
	func appIDs(team: String) async throws -> [ZagRegisteredAppID]
	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID
	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup]
	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup
	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate]
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate
	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile
}

enum ZagLivePortal {
	#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG
	/// G5 experiment build only (plan §3.2): the live portal, bounded by the campaign.
	static let isEnabled = true
	#else
	/// The live developer-portal service is not implemented or enabled.
	static let isEnabled = false
	#endif
}

struct ZagDisabledDeveloperPortal: ZagDeveloperPortalService {
	func devices(team: String) async throws -> [ZagRegisteredDevice] { throw ZagPortalError.livePortalDisabled }
	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice { throw ZagPortalError.livePortalDisabled }
	func appIDs(team: String) async throws -> [ZagRegisteredAppID] { throw ZagPortalError.livePortalDisabled }
	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID { throw ZagPortalError.livePortalDisabled }
	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] { throw ZagPortalError.livePortalDisabled }
	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup { throw ZagPortalError.livePortalDisabled }
	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws { throw ZagPortalError.livePortalDisabled }
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] { throw ZagPortalError.livePortalDisabled }
	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate { throw ZagPortalError.livePortalDisabled }
	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile { throw ZagPortalError.livePortalDisabled }
}

// MARK: - Signing key

// MARK: - Profile checks

/// Checks an issued profile before anything is signed with it.
enum ZagProvisioningProfileCheck {
	enum Problem: String, Error, Equatable, Sendable {
		case wrongTeam
		case wrongBundleIdentifier
		case deviceMissing
		case certificateMissing
		case expired
		case wrongApplicationIdentifier
		case empty
	}

	static func check(
		_ profile: ZagIssuedProfile,
		team: String,
		bundleIdentifier: String,
		deviceUDID: String,
		certificateSerial: String,
		now: Date
	) -> Problem? {
		if profile.data.isEmpty { return .empty }
		if profile.teamIdentifier != team { return .wrongTeam }
		if profile.bundleIdentifier != bundleIdentifier { return .wrongBundleIdentifier }
		if !profile.deviceUDIDs.contains(where: { $0.lowercased() == deviceUDID.lowercased() }) { return .deviceMissing }
		if !profile.certificateSerials.contains(certificateSerial) { return .certificateMissing }
		// At least an hour left: a profile about to lapse is not worth installing.
		if profile.expiresAt.timeIntervalSince(now) < 3_600 { return .expired }
		let identifier = profile.entitlements.dictionary[ZagFreeAccountEntitlements.applicationIdentifierKey] as? String
		if identifier != "\(team).\(bundleIdentifier)" { return .wrongApplicationIdentifier }
		return nil
	}
}
