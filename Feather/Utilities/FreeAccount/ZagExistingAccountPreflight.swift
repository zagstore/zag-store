#if ZAG_EXISTING_ACCOUNT_EXPERIMENT
#if !ZAG_LIVE_EXPERIMENT
#error("The existing-account experiment is a mode of the G5 live experiment")
#endif
import Foundation
import Security

// G5 existing-account path (issue #37): a read-only inventory of an Apple
// Account that has signed apps before, and the decision it supports. It
// replaces E4's "the account is empty" only in builds made with
// ZAG_EXISTING_ACCOUNT_EXPERIMENT; the empty-account campaign is unchanged.
//
// - Read-only: the inventory goes through `ZagPortalReader`, which has the
//   three listings and nothing else. Profiles have no read-only listing (the
//   portal's profile call creates or renews one), so a profile is always an
//   approved mutation.
// - A listing that failed, was cut short or was cancelled is unknown, never
//   empty, and an unknown inventory decides nothing.
// - A certificate is reusable only when this app holds its private key in
//   this device's Keychain for this account and team, and the key is proven
//   to match the certificate. Certificates from other machines or tools are
//   counted, never reused, never revoked, never deleted.
// - The device is identified by the UDID the paired device reported over its
//   verified pairing (RPPairing), never by a guess.

/// The Apple-side changes the existing-account path can make, each needing
/// the owner's separate approval (`ZagExistingAccountApprovals`).
enum ZagExistingAccountMutation: String, Codable, CaseIterable, Comparable, Sendable {
	case certificate, device, appID, profile

	static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

/// The portal's read-only listings: what the inventory may call.
/// The Keychain key lookup the preflight needs: `nil` when the key item is
/// absent, a thrown error when the Keychain could not be read.
protocol ZagSigningKeyLookup {
	func key(account: UUID, team: String, slot: String?) throws -> SecKey?
}

extension ZagKeychainSigningKeys: ZagSigningKeyLookup {}

protocol ZagPortalReader: Sendable {
	func devices(team: String) async throws -> [ZagRegisteredDevice]
	func appIDs(team: String) async throws -> [ZagRegisteredAppID]
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate]
}

/// A portal seen through its listings only.
struct ZagReadOnlyPortal: ZagPortalReader {
	private let portal: ZagDeveloperPortalService
	init(_ portal: ZagDeveloperPortalService) { self.portal = portal }
	func devices(team: String) async throws -> [ZagRegisteredDevice] { try await portal.devices(team: team) }
	func appIDs(team: String) async throws -> [ZagRegisteredAppID] { try await portal.appIDs(team: team) }
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] { try await portal.certificates(team: team) }
}

enum ZagExistingAccountPreflight {
	enum Listing<Item: Sendable>: Sendable {
		case complete([Item])
		/// Failed, refused, cancelled or malformed: never read as empty.
		case unknown

		var items: [Item]? { if case .complete(let items) = self { items } else { nil } }
	}

	struct Inventory: Sendable {
		let team: ZagDeveloperTeam
		/// Teams the signed-in account has.
		let teamCount: Int
		let certificates: Listing<ZagDevelopmentCertificate>
		let devices: Listing<ZagRegisteredDevice>
		let appIDs: Listing<ZagRegisteredAppID>
	}

	/// What this device holds for the account and team.
	struct LocalKeys: Equatable, Sendable {
		/// The stored identity's serial, when its key is in the Keychain and
		/// proven to match its certificate.
		var possessedSerial: String?
		/// The stored identity's certificate (DER), compared with the listing's
		/// copy when the listing has one.
		var possessedCertificate: Data?
		/// A certificate request whose outcome is not known yet.
		var unresolvedRequest = false
		/// The local signing state could not be read or is inconsistent: it
		/// blocks, so an unexpected failure never leads to a new certificate.
		var unreadable: Unreadable?
	}

	/// Why the local signing state is not known. Only a genuinely absent
	/// identity or key means "not possessed".
	enum Unreadable: String, Equatable, Sendable {
		/// The secret store failed to read the pending request or the identity.
		case secretStore
		/// A stored pending request or identity does not decode.
		case corruptedRecord
		/// The Keychain failed to look up the identity's key.
		case keyStore
		/// The stored identity's key is present but does not match its
		/// certificate, or holds exported key bytes.
		case identityMismatch
	}

	enum Blocker: String, Equatable, Sendable {
		case notPersonalTeam, teamCountNotOne, missingIdentity, ambiguousDevice, deviceLimit
		case ambiguousAppID, appIDCapacity, duplicateCertificate, unresolvedCertificateRequest
		case signingKeysUnreadable
	}

	enum Unknown: String, Equatable, Sendable {
		case certificates, devices, appIDs, cancelled
	}

	enum Decision: Equatable, Sendable {
		/// The certificate, device and App ID are reused; only the profile
		/// (always) needs approval.
		case reusePossible
		/// These must be created or registered, each with approval.
		case needsNewAssets(Set<ZagExistingAccountMutation>)
		case blocked(Blocker)
		case unknown(Unknown)

		var allowsProvisioning: Bool {
			switch self {
			case .reusePossible, .needsNewAssets: true
			case .blocked, .unknown: false
			}
		}
	}

	struct Assessment: Equatable, Sendable {
		let decision: Decision
		/// The mutations the owner may approve: those the decision needs.
		let required: Set<ZagExistingAccountMutation>
		/// The certificate listing's size, for the budget's recheck.
		let certificateCount: Int
		let report: Report
	}

	/// Redacted: counts, booleans and expiry in days. Never a UDID, address,
	/// serial, bundle identifier or name.
	struct Report: Equatable, Sendable {
		var teamIsPersonal = false
		var teamCount = 0
		var certificates: Int?
		var validCertificates: Int?
		var reusableCertificateDaysLeft: Int?
		var foreignValidCertificates: Int?
		var devices: Int?
		var thisDeviceRegistered: Bool?
		var appIDs: Int?
		var testAppIDRegistered: Bool?
		var unresolvedCertificateRequest = false
		var signingKeysReadable = true

		var lines: [String] {
			func value<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "unknown" }
			return [
				"Team: \(teamIsPersonal ? "Personal Team" : "not a Personal Team") (\(teamCount) team\(teamCount == 1 ? "" : "s"))",
				"Certificates: \(value(certificates)) listed, \(value(validCertificates)) valid, \(value(foreignValidCertificates)) valid without a key on this iPhone",
				"Reusable certificate: \(reusableCertificateDaysLeft.map { "yes, \($0) days left" } ?? "none")",
				"Devices: \(value(devices)) registered; this iPhone \(thisDeviceRegistered.map { $0 ? "registered" : "not registered" } ?? "unknown")",
				"App IDs: \(value(appIDs)) active; the test app's \(testAppIDRegistered.map { $0 ? "registered" : "not registered" } ?? "unknown")",
				"Earlier certificate request with unknown outcome: \(unresolvedCertificateRequest ? "yes" : "no")",
				"Signing keys on this iPhone: \(signingKeysReadable ? "read" : "could not be read (blocked)")",
				"Profiles: not listed (a profile is requested only with approval)",
			]
		}
	}

	/// A reused certificate must last at least this long (as `ZagCertificatePlan`).
	static let minimumCertificateRemaining: TimeInterval = 7 * 86_400

	// MARK: Reading

	/// Reads the three listings, each on its own; nothing else is called.
	static func read(_ reader: ZagPortalReader, team: ZagDeveloperTeam, teamCount: Int) async -> Inventory {
		func listing<T>(_ body: () async throws -> [T]) async -> Listing<T> {
			guard !Task.isCancelled, let items = try? await body(), !Task.isCancelled else { return .unknown }
			return .complete(items)
		}
		let id = team.identifier
		let certificates = await listing { try await reader.certificates(team: id) }
		let devices = await listing { try await reader.devices(team: id) }
		let appIDs = await listing { try await reader.appIDs(team: id) }
		return Inventory(team: team, teamCount: teamCount, certificates: certificates, devices: devices, appIDs: appIDs)
	}

	/// What the Keychain holds for this account and team: the stored identity
	/// counts only if its key is present and proven to match its certificate.
	static func localKeys(secrets: ZagFreeAccountSecretStore, keys: ZagSigningKeyFactory, lookup: ZagSigningKeyLookup,
						  account: UUID, team: String) -> LocalKeys {
		var local = LocalKeys()
		let pendingData: Data?
		do {
			pendingData = try secrets.load(.pendingSigningKey, account: account, team: team)
		} catch {
			local.unreadable = .secretStore
			return local
		}
		if let pendingData {
			guard let pending = try? JSONDecoder().decode(ZagPendingSigningKey.self, from: pendingData) else {
				local.unreadable = .corruptedRecord
				return local
			}
			if pending.certificate == nil, pending.submissionUnconfirmed == true { local.unresolvedRequest = true }
		}
		let identityData: Data?
		do {
			identityData = try secrets.load(.signingPrivateKey, account: account, team: team)
		} catch {
			local.unreadable = .secretStore
			return local
		}
		// No stored identity: genuinely nothing possessed.
		guard let identityData else { return local }
		guard let identity = try? JSONDecoder().decode(ZagSigningIdentity.self, from: identityData) else {
			local.unreadable = .corruptedRecord
			return local
		}
		// Exported key bytes are never reused (live builds keep keys in the Keychain).
		guard identity.keyIsInKeychain else {
			local.unreadable = .identityMismatch
			return local
		}
		let key: SecKey?
		do {
			key = try lookup.key(account: account, team: team, slot: identity.keySlot)
		} catch {
			local.unreadable = .keyStore
			return local
		}
		// The key item is gone (deleted, or the Keychain was reset): not possessed.
		guard key != nil else { return local }
		guard case .matches(let serial, _) = keys.check(certificate: identity.certificate, privateKey: identity.privateKey,
														  account: account, team: team, keySlot: identity.keySlot),
			  serial == identity.serialNumber else {
			local.unreadable = .identityMismatch
			return local
		}
		local.possessedSerial = serial
		local.possessedCertificate = identity.certificate
		return local
	}

	// MARK: Deciding

	static func evaluate(_ inventory: Inventory, local: LocalKeys, bundleIdentifier: String, deviceUDID: String,
						 limits: ZagTeamLimits = .free, now: Date) -> Assessment {
		var report = Report()
		report.teamIsPersonal = inventory.team.kind == .personalFree
		report.teamCount = inventory.teamCount
		report.unresolvedCertificateRequest = local.unresolvedRequest
		report.signingKeysReadable = local.unreadable == nil
		let certificates = inventory.certificates.items, devices = inventory.devices.items, appIDs = inventory.appIDs.items
		let active = appIDs?.filter { $0.isActive(at: now) }
		let valid = certificates?.filter { $0.expiresAt > now }
		report.certificates = certificates?.count
		report.validCertificates = valid?.count
		report.devices = devices?.count
		report.appIDs = active?.count
		let matchingDevices = devices?.filter { $0.udid.lowercased() == deviceUDID.lowercased() }
		report.thisDeviceRegistered = matchingDevices.map { !$0.isEmpty }
		let matchingAppIDs = active?.filter { $0.bundleIdentifier == bundleIdentifier }
		report.testAppIDRegistered = matchingAppIDs.map { !$0.isEmpty }
		let reusable = valid?.first { certificate in
			guard let serial = local.possessedSerial, certificate.serialNumber == serial,
				  certificate.expiresAt.timeIntervalSince(now) >= minimumCertificateRemaining else { return false }
			// When the listing has the certificate itself, it must be the one stored.
			return certificate.data == nil || certificate.data == local.possessedCertificate
		}
		report.reusableCertificateDaysLeft = reusable.map { Int($0.expiresAt.timeIntervalSince(now) / 86_400) }
		report.foreignValidCertificates = valid.map { list in list.filter { $0.serialNumber != local.possessedSerial }.count }

		func result(_ decision: Decision, _ required: Set<ZagExistingAccountMutation> = []) -> Assessment {
			Assessment(decision: decision, required: required, certificateCount: certificates?.count ?? -1, report: report)
		}
		if Task.isCancelled { return result(.unknown(.cancelled)) }
		guard inventory.team.kind == .personalFree else { return result(.blocked(.notPersonalTeam)) }
		guard inventory.teamCount == 1 else { return result(.blocked(.teamCountNotOne)) }
		guard ZagDeveloperTeam.isValidIdentifier(inventory.team.identifier), !bundleIdentifier.isEmpty, !deviceUDID.isEmpty else {
			return result(.blocked(.missingIdentity))
		}
		guard local.unreadable == nil else { return result(.blocked(.signingKeysUnreadable)) }
		guard let certificates else { return result(.unknown(.certificates)) }
		guard let devices, let matchingDevices else { return result(.unknown(.devices)) }
		guard let active, let matchingAppIDs else { return result(.unknown(.appIDs)) }
		guard Set(certificates.map(\.serialNumber)).count == certificates.count else { return result(.blocked(.duplicateCertificate)) }
		guard !local.unresolvedRequest else { return result(.blocked(.unresolvedCertificateRequest)) }

		var required: Set<ZagExistingAccountMutation> = [.profile]
		switch matchingDevices.count {
		case 0:
			guard devices.count < limits.devicesPerPlatform else { return result(.blocked(.deviceLimit)) }
			required.insert(.device)
		case 1: break
		default: return result(.blocked(.ambiguousDevice))
		}
		switch matchingAppIDs.count {
		case 0:
			if let limit = limits.appIDs, active.count >= limit { return result(.blocked(.appIDCapacity)) }
			required.insert(.appID)
		case 1: break
		default: return result(.blocked(.ambiguousAppID))
		}
		if reusable == nil { required.insert(.certificate) }
		return result(required == [.profile] ? .reusePossible : .needsNewAssets(required), required)
	}

	// MARK: Running

	/// Reads, decides and, when the decision allows provisioning, records it
	/// with the campaign (which pins the account) and the approvals journal
	/// (which then accepts approvals for exactly the required mutations).
	/// Nothing is sent to Apple except the three listings.
	static func run(reader: ZagPortalReader, team: ZagDeveloperTeam, teamCount: Int, accountKey: String, account: UUID,
					secrets: ZagFreeAccountSecretStore, keys: ZagKeychainSigningKeyFactory, bundleIdentifier: String, deviceUDID: String,
					campaign: ZagLiveExperimentCampaign, approvals: ZagExistingAccountApprovals,
					limits: ZagTeamLimits = .free, now: @Sendable () -> Date = { Date() }) async throws -> Assessment {
		try campaign.checkAccount(accountKey)
		try campaign.authorize(.portalRead)
		let inventory = await read(reader, team: team, teamCount: teamCount)
		let local = localKeys(secrets: secrets, keys: keys, lookup: keys.keys, account: account, team: team.identifier)
		let assessment = evaluate(inventory, local: local, bundleIdentifier: bundleIdentifier, deviceUDID: deviceUDID, limits: limits, now: now())
		try campaign.acceptExistingAccountPreflight(accountKey: accountKey, team: team.identifier, assessment: assessment)
		try approvals.recordPreflight(accountKey: accountKey, team: team.identifier, required: assessment.required)
		return assessment
	}
}
#endif
