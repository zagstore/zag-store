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

/// A certificate signing request, generated on the device. Opaque here.
struct ZagCertificateRequest: Sendable, Equatable {
	let data: Data
}

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

enum ZagPortalError: Error, Equatable, Sendable {
	/// Apple no longer accepts the session; the user must sign in again.
	case sessionRejected
	case network
	case rateLimited
	case malformedResponse
	/// Another team owns this identifier.
	case identifierUnavailable(String)
	case deviceLimitReached
	case appIDLimitReached
	case certificateLimitReached
	case livePortalDisabled
}

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
	/// The live developer-portal service is not implemented or enabled.
	static let isEnabled = false
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

/// Creates the development signing key and its certificate signing request
/// on the device. Only a simulation implements it in this phase.
protocol ZagSigningKeyFactory: Sendable {
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest)
	/// Whether an issued certificate is for `privateKey`, with its serial and expiry.
	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck
	func makeKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest)
	func check(certificate: Data, privateKey: Data, account: UUID, team: String) -> ZagIssuedCertificateCheck
}

extension ZagSigningKeyFactory {
	/// For one account and team. A factory whose keys stay in the Keychain
	/// creates the key item for them and returns an empty `privateKey`.
	func makeKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest) {
		try makeKey(commonName: commonName)
	}
	func check(certificate: Data, privateKey: Data, account: UUID, team: String) -> ZagIssuedCertificateCheck {
		check(certificate: certificate, privateKey: privateKey)
	}
}

struct ZagDisabledSigningKeyFactory: ZagSigningKeyFactory {
	enum Failure: Error { case unavailable }
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) { throw Failure.unavailable }
	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { .mismatch }
}

/// The development signing identity kept in the Keychain
/// (`ZagFreeAccountSecretKind.signingPrivateKey`) for the signed-in account:
/// the private key and the certificate Apple issued for it.
struct ZagSigningIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
	let serialNumber: String
	let certificate: Data
	/// Empty when the key is a Keychain key item (`ZagKeychainSigningKeys`),
	/// which is never exported.
	let privateKey: Data
	let expiresAt: Date

	var keyIsInKeychain: Bool { privateKey.isEmpty }

	var description: String { "[signing identity \(serialNumber)]" }
}

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
