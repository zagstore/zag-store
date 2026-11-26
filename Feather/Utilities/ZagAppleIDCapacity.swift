import Foundation

#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
@MainActor
enum ZagAppleIDCapacity {
	struct TeamSnapshot {
		let synchronizedAt: Date
		let appIDs: [ZagRegisteredAppID]
		let certificateExpirations: [Date]
		let deviceCount: Int

		var activeAppIDCount: Int { appIDs.filter { $0.isActive(at: .now) }.count }
		var nextAppIDExpiry: Date? { appIDs.compactMap(\.expiresAt).filter { $0 > .now }.min() }
	}

	private static var teams: [ZagSigningScope: TeamSnapshot] = [:]

	static func cached(_ scope: ZagSigningScope) -> TeamSnapshot? {
		guard let snapshot = teams[scope], Date().timeIntervalSince(snapshot.synchronizedAt) < 15 * 60 else { return nil }
		return snapshot
	}

	static func synchronize(_ scope: ZagSigningScope) async throws -> TeamSnapshot {
		guard let token = ZagNativeAppleIDs.shared.connectedToken(scope.accountID) else {
			throw ZagNativeAccountInstall.Failure.signIn
		}
		let portal = ZagNativeAccountInstall.portal(token: token, consent: ZagMutationConsentCoordinator(), maxRequests: 8)
		do {
			async let appIDs = portal.appIDs(team: scope.teamID)
			async let certificates = portal.certificates(team: scope.teamID)
			async let devices = portal.devices(team: scope.teamID)
			let snapshot = try await TeamSnapshot(synchronizedAt: .now, appIDs: appIDs,
				certificateExpirations: certificates.map(\.expiresAt).sorted(), deviceCount: Set(devices.map(\.udid)).count)
			guard ZagNativeAppleIDs.shared.connectedToken(scope.accountID) == token else {
				throw ZagNativeAccountInstall.Failure.signIn
			}
			teams[scope] = snapshot
			return snapshot
		} catch let failure as ZagPortalOperationFailure where failure.underlying == .sessionRejected {
			try? ZagNativeAppleIDs.shared.invalidate(token)
			throw failure
		}
	}

	struct DeviceSnapshot {
		let count: Int
		let checkedAt: Date
	}
	private static var deviceSnapshot: DeviceSnapshot?
	private static var deviceTask: Task<Int, Error>?
	static var cachedDevice: DeviceSnapshot? { deviceSnapshot }
	static func invalidateDevice() {
		if let old = deviceSnapshot { deviceSnapshot = .init(count: old.count, checkedAt: .distantPast) }
	}
	static func synchronizeDevice(force: Bool = true) async throws -> Int {
		if let task = deviceTask { return try await task.value }
		if !force, let cached = deviceSnapshot, Date().timeIntervalSince(cached.checkedAt) < 300 { return cached.count }
		let task = Task { try await readDeviceCount() }
		deviceTask = task
		defer { deviceTask = nil }
		let count = try await task.value
		deviceSnapshot = .init(count: count, checkedAt: .now)
		return count
	}
	private static func readDeviceCount() async throws -> Int {
		await ZagRunningInstallation.shared.inspect()
		let pairing = ZagRPPairingCore.shared
		let (device, installed) = try await pairing.signingDeviceInventory()
		let profiles = try await ZagRPPairingFreeAccountInstaller.readProfiles().get()
			.compactMap { try? ZagIssuedProfile(profileData: $0) }
		guard pairing.pairedIdentity == device else { throw ZagNativeAccountInstall.Failure.pairing }
		let proven = ZagNativeAppInventory.verifiedInstalledEntries().filter { entry in
			let receipt = entry.installation
			let record = receipt.record
			guard let owner = record.owner, owner.teamKind == .personalFree,
				  let app = installed[record.bundleIdentifier], let identity = receipt.executableIdentity,
				  identity.version == app.version, identity.build == app.build,
				  let certificate = ZagCertificateInspection(der: identity.certificate),
				  certificate.commonName == app.signerIdentity else { return false }
			return receipt.profiles.allSatisfy { component in
				profiles.contains {
					$0.uuid == component.uuid && $0.bundleIdentifier == component.bundleIdentifier &&
					$0.teamIdentifier == owner.scope.teamID && $0.certificateSerials.contains(owner.certificateSerial)
				}
			}
		}
		return proven.count
	}
}
#endif
