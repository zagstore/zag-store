import Foundation

// Provisions an app for a paid developer team through App Store Connect,
// producing the same `ZagProvisioningResult` the free path produces, so the
// existing signing adapter and installer sign and install it unchanged.
//
// It reuses the shared plans (devices, App IDs, certificates), the profile
// check and the profile parser. It is deliberately simpler than the free
// provisioner: the ASC API is not lossy the way GrandSlam is, so there is no
// certificate journaling — a certificate is reused when the device still holds
// its key, otherwise one is created from a device-made CSR and stored.
//
// The signing private key never leaves the device: only the CSR is sent, and
// the issued certificate is checked against the key before it is stored.
struct ZagASCProvisioner: Sendable {
	let portal: ZagDeveloperPortalService
	let keys: ZagSigningKeyFactory
	let secrets: ZagFreeAccountSecretStore
	var limits: ZagTeamLimits = .forTeam(.individualPaid)
	var now: @Sendable () -> Date = { Date() }

	typealias Failure = ZagProvisioningFailure

	func provision(_ request: ZagProvisioningRequest) async -> Result<ZagProvisioningResult, Failure> {
		do { return .success(try await run(request)) }
		catch let failure as Failure { return .failure(failure) }
		catch { return .failure(Failure(kind: ZagFreeAccountProvisioner.kind(for: error), step: .request)) }
	}

	private func run(_ request: ZagProvisioningRequest) async throws -> ZagProvisioningResult {
		let team = request.team
		guard ZagDeveloperTeam.isValidIdentifier(team), !request.deviceUDID.isEmpty,
			  let appBundle = ZagBundleIdentifierMapping.mapped(request.app.originalBundleIdentifier, team: team) else {
			throw Failure(kind: .invalidRequest, step: .request)
		}
		var components: [(request: ZagProvisioningRequest.Component, bundle: String)] = [(request.app, appBundle)]
		for item in request.extensions {
			guard let bundle = ZagBundleIdentifierMapping.mappedExtension(item.originalBundleIdentifier, appOriginal: request.app.originalBundleIdentifier, team: team) else {
				throw Failure(kind: .invalidRequest, step: .request)
			}
			components.append((item, bundle))
		}
		guard Set(components.map(\.bundle)).count == components.count else {
			throw Failure(kind: .invalidRequest, step: .request)
		}
		var changes = ZagProvisioningResult.Changes()

		// Device.
		let devices = try await portalCall(.device) { try await portal.devices(team: team) }
		switch ZagDeviceRegistrationPlan.make(udid: request.deviceUDID, registeredUDIDs: devices.map(\.udid), limit: limits.devicesPerPlatform) {
		case .alreadyRegistered:
			break
		case .register:
			_ = try await portalCall(.device) { try await portal.registerDevice(udid: request.deviceUDID, name: request.deviceName, team: team) }
			changes.registeredDevice = true
		case .limitReached:
			throw Failure(kind: .deviceLimitReached, step: .device)
		}

		// App ID capacity (paid teams have no 7-day/10-App-ID cap, so this
		// normally passes; the plan still guards a configured limit).
		let registered = try await portalCall(.appIDs) { try await portal.appIDs(team: team) }
		let plan = ZagAppIDPlan.make(bundleIdentifiers: components.map(\.bundle), registered: registered, limit: limits.appIDs ?? Int.max, now: now())
		if case .capacityExhausted(let needed, let available, let freesAt) = plan.outcome {
			throw Failure(kind: .appIDCapacityExhausted(needed: needed, available: available, nextSlotFreesAt: freesAt), step: .appIDs)
		}

		// Certificate.
		let identity = try await signingIdentity(for: request, team: team, changes: &changes)

		// App IDs.
		var appIDs: [String: ZagRegisteredAppID] = [:]
		for appID in registered where appID.isActive(at: now()) { appIDs[appID.bundleIdentifier] = appID }
		if case .register(let missing) = plan.outcome {
			for bundle in missing {
				let name = components.first { $0.bundle == bundle }?.request.name ?? bundle
				do {
					appIDs[bundle] = try await portalCall(.appIDs) { try await portal.registerAppID(bundleIdentifier: bundle, name: name, team: team) }
				} catch let portal as ZagPortalError {
					if case .identifierUnavailable(let identifier) = portal { throw Failure(kind: .identifierUnavailable(identifier), step: .appIDs) }
					throw Failure(kind: ZagFreeAccountProvisioner.kind(for: portal), step: .appIDs)
				}
				changes.registeredAppIDs.append(bundle)
			}
		}

		// Profiles, each checked before use.
		var results: [ZagProvisioningResult.Component] = []
		for component in components {
			guard let appID = appIDs[component.bundle] else { throw Failure(kind: .unexpectedResponse, step: .profiles) }
			let profile = try await portalCall(.profiles) { try await portal.profile(for: appID, team: team) }
			if let problem = ZagProvisioningProfileCheck.check(
				profile, team: team, bundleIdentifier: component.bundle,
				deviceUDID: request.deviceUDID, certificateSerial: identity.serialNumber, now: now()
			) {
				throw Failure(kind: .invalidProfile(problem), step: .profiles)
			}
			let resolved = ZagFreeAccountEntitlements.resolve(
				requested: component.request.entitlements.dictionary,
				profile: profile.entitlements.dictionary,
				team: team,
				bundleIdentifier: component.bundle
			)
			guard let entitlements = try? ZagEntitlementSet(resolved.entitlements) else {
				throw Failure(kind: .unexpectedResponse, step: .profiles)
			}
			results.append(.init(
				originalBundleIdentifier: component.request.originalBundleIdentifier,
				bundleIdentifier: component.bundle,
				profile: profile,
				entitlements: entitlements,
				rejected: resolved.rejected
			))
		}
		return ZagProvisioningResult(
			team: team,
			certificateSerial: identity.serialNumber,
			app: results[0],
			extensions: Array(results.dropFirst()),
			changes: changes
		)
	}

	/// Reuses the stored identity when Apple still lists its certificate and the
	/// device holds its key; otherwise creates a key and certificate. Never
	/// revokes.
	private func signingIdentity(for request: ZagProvisioningRequest, team: String, changes: inout ZagProvisioningResult.Changes) async throws -> ZagSigningIdentity {
		let account = request.accountID
		let stored = loadIdentity(account: account, team: team)
		let remote = try await portalCall(.certificate) { try await portal.certificates(team: team) }
		let usable = stored.flatMap {
			keys.check(certificate: $0.certificate, privateKey: $0.privateKey, account: account, team: team, keySlot: $0.keySlot) == .mismatch ? nil : $0
		}
		switch ZagCertificatePlan.make(remote: remote, localKeySerials: usable.map { [$0.serialNumber] } ?? [], limit: nil, now: now()) {
		case .reuse(let serial):
			guard let stored = usable, stored.serialNumber == serial else { throw Failure(kind: .unexpectedResponse, step: .certificate) }
			return stored
		case .userMustRevoke(let candidates):
			throw Failure(kind: .certificateMustBeRevoked(candidates: candidates), step: .certificate)
		case .create:
			let made: (privateKey: Data, request: ZagCertificateRequest, keySlot: String?)
			do {
				made = try keys.makePendingKey(commonName: "Zag Store", account: account, team: team)
			} catch {
				throw Failure(kind: .keyStorage, step: .certificate)
			}
			let issued: ZagIssuedCertificate
			do {
				issued = try await portal.submitCertificateRequest(ZagCertificateRequest(data: made.request.data), team: team)
			} catch ZagPortalError.certificateLimitReached {
				try? keys.discardKey(account: account, team: team, keySlot: made.keySlot)
				let valid = remote.filter { $0.expiresAt > now() }.sorted { $0.expiresAt < $1.expiresAt }
				throw Failure(kind: .certificateMustBeRevoked(candidates: valid), step: .certificate)
			} catch {
				try? keys.discardKey(account: account, team: team, keySlot: made.keySlot)
				throw Failure(kind: ZagFreeAccountProvisioner.kind(for: error), step: .certificate)
			}
			var serial = issued.certificate.serialNumber, expiresAt = issued.certificate.expiresAt
			switch keys.check(certificate: issued.data, privateKey: made.privateKey, account: account, team: team, keySlot: made.keySlot) {
			case .matches(let inspectedSerial, let inspectedExpiry):
				serial = inspectedSerial
				expiresAt = inspectedExpiry
			case .notInspected:
				break
			case .mismatch:
				try? keys.discardKey(account: account, team: team, keySlot: made.keySlot)
				throw Failure(kind: .unexpectedResponse, step: .certificate)
			}
			guard !issued.data.isEmpty, expiresAt > now() else {
				try? keys.discardKey(account: account, team: team, keySlot: made.keySlot)
				throw Failure(kind: .unexpectedResponse, step: .certificate)
			}
			let identity = ZagSigningIdentity(serialNumber: serial, certificate: issued.data, privateKey: made.privateKey, expiresAt: expiresAt, keySlot: made.keySlot)
			do {
				try secrets.save(try JSONEncoder().encode(identity), kind: .signingPrivateKey, account: account, team: team)
			} catch {
				throw Failure(kind: .keyStorage, step: .certificate)
			}
			changes.createdCertificate = true
			return identity
		}
	}

	private func loadIdentity(account: UUID, team: String) -> ZagSigningIdentity? {
		(try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}

	/// Maps a portal error raised inside `body` to a provisioning failure at
	/// `step`. `identifierUnavailable` and `certificateLimitReached` pass
	/// through for the caller to handle with context.
	private func portalCall<T>(_ step: Failure.Step, _ body: () async throws -> T) async throws -> T {
		do {
			return try await body()
		} catch let failure as Failure {
			throw failure
		} catch let portal as ZagPortalError {
			switch portal {
			case .identifierUnavailable, .certificateLimitReached: throw portal
			default: throw Failure(kind: ZagFreeAccountProvisioner.kind(for: portal), step: step)
			}
		} catch {
			throw Failure(kind: ZagFreeAccountProvisioner.kind(for: error), step: step)
		}
	}
}
