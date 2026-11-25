#if DEBUG
import Foundation

// Debug builds only. An in-memory developer team for exercising
// `ZagFreeAccountProvisioner`: free-account limits, 7-day App IDs and
// profiles, failures and tampered profiles on request. Nothing here contacts
// Apple or any server. Certificates and profiles are synthetic bytes unless
// a test supplies a `ZagSimulatedIssuer` (a throwaway local test authority).

/// Issues real, locally signed certificates and profiles for the simulation.
/// Only test code implements it; the issuing authority is never Apple's.
protocol ZagSimulatedIssuer: Sendable {
	/// A DER certificate for the request's public key.
	func certificate(for request: ZagCertificateRequest, serialNumber: String) throws -> Data
	/// A signed .mobileprovision holding `plist`.
	func profile(signing plist: Data) throws -> Data
}

actor ZagSimulatedDeveloperPortal: ZagDeveloperPortalService {
	enum Failure: Sendable, Equatable {
		case sessionRejected
		case network
		case rateLimited
		case malformed
		case certificateConflict
		/// The call never answers (for timeouts and cancellation).
		case noResponse
		/// Certificate requests only, once: the certificate is issued, then the
		/// answer is lost (a network failure after Apple acted).
		case lostResponse
	}

	enum Operation: String, Sendable {
		case devices, registerDevice, appIDs, registerAppID, appGroups, registerAppGroup, assignAppGroups
		case certificates, submitCertificateRequest, profile
	}

	enum ProfileTamper: Sendable {
		case wrongTeam, wrongBundle, missingDevice, missingCertificate, expired, wrongApplicationIdentifier
	}

	let team: String
	var deviceLimit = ZagFreeAccountLimits.devicesPerPlatform
	var appIDLimit = ZagFreeAccountLimits.appIDsAtOnce
	var certificateLimit = 2
	private(set) var devices: [ZagRegisteredDevice] = []
	private(set) var registeredAppIDs: [ZagRegisteredAppID] = []
	private(set) var groups: [String] = []
	private(set) var assignments: [String: [String]] = [:]
	private(set) var issuedCertificates: [ZagDevelopmentCertificate] = []
	/// Identifiers another team owns.
	var foreignIdentifiers: Set<String> = []
	/// Failures injected for an operation (all calls of it while set).
	private var failures: [Operation: Failure] = [:]
	private var tamper: ProfileTamper?
	private(set) var calls: [Operation] = []
	/// Issued certificate files by serial (real issuer only).
	private var certificateFiles: [String: Data] = [:]
	private let clock: @Sendable () -> Date
	private let issuer: ZagSimulatedIssuer?

	init(team: String = "SIMTEAM001", clock: @escaping @Sendable () -> Date = { Date() }, issuer: ZagSimulatedIssuer? = nil) {
		self.team = team
		self.clock = clock
		self.issuer = issuer
	}

	// MARK: Set-up for tests and the debug screen

	func fail(_ operation: Operation, with failure: Failure?) { failures[operation] = failure }
	func tamperProfiles(_ tamper: ProfileTamper?) { self.tamper = tamper }
	func setCertificateLimit(_ value: Int) { certificateLimit = value }
	func setForeignIdentifiers(_ value: Set<String>) { foreignIdentifiers = value }
	func seedDevice(_ udid: String) { devices.append(ZagRegisteredDevice(udid: udid, name: "Other device")) }
	func seedAppID(_ bundle: String, expiresAt: Date) {
		registeredAppIDs.append(ZagRegisteredAppID(identifier: "SIM-\(bundle)", bundleIdentifier: bundle, expiresAt: expiresAt))
	}
	func seedCertificate(serial: String, expiresAt: Date) {
		issuedCertificates.append(ZagDevelopmentCertificate(serialNumber: serial, name: "Other Mac", machineName: "Mac", expiresAt: expiresAt))
	}
	/// Calls that changed the team.
	var mutations: [Operation] {
		calls.filter { [.registerDevice, .registerAppID, .registerAppGroup, .assignAppGroups, .submitCertificateRequest].contains($0) }
	}

	// MARK: Service

	private func begin(_ operation: Operation, team requested: String) async throws {
		calls.append(operation)
		guard requested == team else { throw ZagPortalError.sessionRejected }
		switch failures[operation] {
		case .none: return
		case .sessionRejected: throw ZagPortalError.sessionRejected
		case .network: throw ZagPortalError.network
		case .rateLimited: throw ZagPortalError.rateLimited
		case .malformed: throw ZagPortalError.malformedResponse
		case .certificateConflict: throw ZagPortalError.existingCertificateOrPendingRequest
		case .noResponse:
			try await Task.sleep(nanoseconds: 120_000_000_000)
			throw ZagPortalError.network
		case .lostResponse:
			return
		}
	}

	private var activeAppIDs: [ZagRegisteredAppID] { registeredAppIDs.filter { $0.isActive(at: clock()) } }
	private var validCertificates: [ZagDevelopmentCertificate] { issuedCertificates.filter { $0.expiresAt > clock() } }

	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		try await begin(.devices, team: team)
		return devices
	}

	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice {
		try await begin(.registerDevice, team: team)
		guard devices.count < deviceLimit else { throw ZagPortalError.deviceLimitReached }
		let device = ZagRegisteredDevice(udid: udid, name: name)
		devices.append(device)
		return device
	}

	func appIDs(team: String) async throws -> [ZagRegisteredAppID] {
		try await begin(.appIDs, team: team)
		return registeredAppIDs
	}

	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID {
		try await begin(.registerAppID, team: team)
		guard !foreignIdentifiers.contains(bundleIdentifier) else { throw ZagPortalError.identifierUnavailable(bundleIdentifier) }
		guard activeAppIDs.count < appIDLimit else { throw ZagPortalError.appIDLimitReached }
		let appID = ZagRegisteredAppID(
			identifier: "SIM-\(bundleIdentifier)",
			bundleIdentifier: bundleIdentifier,
			expiresAt: clock() + ZagFreeAccountLimits.appIDLifetime
		)
		registeredAppIDs.append(appID)
		return appID
	}

	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] {
		try await begin(.appGroups, team: team)
		return groups.map(ZagRegisteredAppGroup.init)
	}

	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup {
		try await begin(.registerAppGroup, team: team)
		guard !foreignIdentifiers.contains(identifier) else { throw ZagPortalError.identifierUnavailable(identifier) }
		groups.append(identifier)
		return ZagRegisteredAppGroup(identifier: identifier)
	}

	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws {
		try await begin(.assignAppGroups, team: team)
		guard groups.allSatisfy(self.groups.contains) else { throw ZagPortalError.malformedResponse }
		assignments[appID.bundleIdentifier] = groups
	}

	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		try await begin(.certificates, team: team)
		return issuedCertificates
	}

	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		try await begin(.submitCertificateRequest, team: team)
		if failures[.submitCertificateRequest] == .lostResponse {
			failures[.submitCertificateRequest] = nil
			_ = try await issue(request)
			throw ZagPortalError.network
		}
		return try await issue(request)
	}

	private func issue(_ request: ZagCertificateRequest) async throws -> ZagIssuedCertificate {
		guard !request.data.isEmpty else { throw ZagPortalError.malformedResponse }
		guard validCertificates.count < certificateLimit else { throw ZagPortalError.certificateLimitReached }
		let serial = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
		if let issuer {
			let data = try issuer.certificate(for: request, serialNumber: serial)
			guard let inspection = ZagCertificateInspection(der: data) else { throw ZagPortalError.malformedResponse }
			let certificate = ZagDevelopmentCertificate(serialNumber: inspection.serialNumber, name: "Zag Store", machineName: "Zag Store", expiresAt: inspection.expiresAt, data: data)
			issuedCertificates.append(certificate)
			certificateFiles[inspection.serialNumber] = data
			return ZagIssuedCertificate(certificate: certificate, data: data)
		}
		let certificate = ZagDevelopmentCertificate(serialNumber: serial, name: "Zag Store", machineName: "Zag Store", expiresAt: clock() + 365 * 86_400)
		issuedCertificates.append(certificate)
		return ZagIssuedCertificate(certificate: certificate, data: Data("SIMULATED-CERTIFICATE-\(serial)".utf8))
	}

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		try await begin(.profile, team: team)
		guard activeAppIDs.contains(where: { $0.bundleIdentifier == appID.bundleIdentifier }) else { throw ZagPortalError.malformedResponse }
		let now = clock()
		var profileTeam = team, bundle = appID.bundleIdentifier
		var udids = devices.map(\.udid), serials = validCertificates.map(\.serialNumber)
		var expiresAt = min(now + 7 * 86_400, validCertificates.map(\.expiresAt).min() ?? now)
		var applicationIdentifier = "\(team).\(appID.bundleIdentifier)"
		switch tamper {
		case .wrongTeam: profileTeam = "OTHERTEAM1"
		case .wrongBundle:
			bundle += ".other"
			applicationIdentifier = "\(team).\(bundle)"
		case .missingDevice: udids = []
		case .missingCertificate: serials = []
		case .expired: expiresAt = now - 60
		case .wrongApplicationIdentifier: applicationIdentifier = "OTHERTEAM1.\(appID.bundleIdentifier)"
		case .none: break
		}
		var entitlements: [String: Any] = [
			ZagFreeAccountEntitlements.applicationIdentifierKey: applicationIdentifier,
			ZagFreeAccountEntitlements.teamIdentifierKey: team,
			ZagFreeAccountEntitlements.getTaskAllowKey: true,
			ZagFreeAccountEntitlements.keychainGroupsKey: ["\(team).*"]
		]
		if let assigned = assignments[appID.bundleIdentifier] {
			entitlements[ZagFreeAccountEntitlements.appGroupsKey] = assigned
		}
		if let issuer {
			// A real profile file, read back with Zag Store's profile parser.
			let plist: [String: Any] = [
				"AppIDName": "Zag Store \(bundle)",
				"ApplicationIdentifierPrefix": [profileTeam],
				"CreationDate": now,
				"Platform": ["iOS"],
				"IsXcodeManaged": false,
				"DeveloperCertificates": serials.compactMap { certificateFiles[$0] },
				"DER-Encoded-Profile": Data([0x30, 0x00]),
				"Entitlements": entitlements,
				"ExpirationDate": expiresAt,
				"Name": "Zag Store \(bundle)",
				"ProvisionedDevices": udids,
				"TeamIdentifier": [profileTeam],
				"TeamName": "Simulated Team",
				"TimeToLive": 7,
				"UUID": UUID().uuidString,
				"Version": 1
			]
			let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
			return try ZagIssuedProfile(profileData: try issuer.profile(signing: xml))
		}
		return ZagIssuedProfile(
			uuid: UUID().uuidString,
			teamIdentifier: profileTeam,
			bundleIdentifier: bundle,
			certificateSerials: serials,
			deviceUDIDs: udids,
			entitlements: try ZagEntitlementSet(entitlements),
			createdAt: now,
			expiresAt: expiresAt,
			data: Data("SIMULATED-PROFILE-\(appID.bundleIdentifier)".utf8)
		)
	}
}

/// Synthetic key material: random bytes standing in for a private key, and
/// a placeholder request. Never a usable key.
struct ZagSimulatedSigningKeyFactory: ZagSigningKeyFactory {
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) {
		let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
		return (key, ZagCertificateRequest(data: Data("SIMULATED-CSR \(commonName)".utf8)))
	}

	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { .notInspected }
}
#endif
