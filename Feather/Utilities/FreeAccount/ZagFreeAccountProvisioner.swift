import Foundation

/// What to provision: an app and its extensions, for one device and team.
struct ZagProvisioningRequest: Sendable {
	struct Component: Sendable {
		let originalBundleIdentifier: String
		let name: String
		/// The entitlements in the component's original signature.
		let entitlements: ZagEntitlementSet
	}

	/// The signed-in account; its signing identity is kept under this ID.
	let accountID: UUID
	let team: String
	let deviceUDID: String
	let deviceName: String
	let app: Component
	let extensions: [Component]
	/// Mapped bundle IDs on the device already signed by this team.
	let installedFreeAccountApps: Set<String>
}

/// Everything signing needs: the identity and, per bundle, the profile and
/// the entitlements it allows.
struct ZagProvisioningResult: Sendable {
	struct Component: Sendable, Equatable {
		let originalBundleIdentifier: String
		let bundleIdentifier: String
		let profile: ZagIssuedProfile
		let entitlements: ZagEntitlementSet
		/// Requested entitlements the profile does not allow (features that will not work).
		let rejected: [ZagFreeAccountEntitlements.Rejection]
	}

	/// What this run created on the team.
	struct Changes: Equatable, Sendable {
		var registeredDevice = false
		var createdCertificate = false
		var registeredAppIDs: [String] = []
		var registeredAppGroups: [String] = []
	}

	let team: String
	let certificateSerial: String
	let app: Component
	let extensions: [Component]
	let changes: Changes

	/// The installed app stops launching at the earliest of these.
	var expiresAt: Date { ([app] + extensions).map(\.profile.expiresAt).min() ?? app.profile.expiresAt }
}

struct ZagProvisioningFailure: Error, Equatable, Sendable {
	enum Step: String, Sendable {
		case request
		case installSlots
		case device
		case appIDs
		case certificate
		case appGroups
		case profiles
	}

	enum Kind: Equatable, Sendable {
		case invalidRequest
		/// Three apps from this team are already on the device.
		case installSlotsFull(installed: [String])
		case deviceLimitReached
		case appIDCapacityExhausted(needed: Int, available: Int, nextSlotFreesAt: Date?)
		case identifierUnavailable(String)
		/// The certificate limit is reached; the user chooses one to revoke.
		case certificateMustBeRevoked(candidates: [ZagDevelopmentCertificate])
		case invalidProfile(ZagProvisioningProfileCheck.Problem)
		case keyStorage
		case sessionRejected
		case network
		case rateLimited
		case unexpectedResponse
		case timedOut
		case cancelled
		/// The live developer portal is not enabled in this build.
		case unavailable
	}

	let kind: Kind
	let step: Step

	var message: String {
		switch kind {
		case .invalidRequest: return "This app cannot be signed with a free Apple Account."
		case .installSlotsFull: return "Three apps signed with this Apple Account are already installed. Remove one first."
		case .deviceLimitReached: return "This Apple Account already has three registered devices."
		case .appIDCapacityExhausted: return "This Apple Account has used its 10 App IDs for this week."
		case .identifierUnavailable: return "Another developer owns this app's identifier."
		case .certificateMustBeRevoked: return "This Apple Account has reached its development-certificate limit. Choose one to revoke."
		case .invalidProfile: return "Apple issued a provisioning profile Zag Store cannot use."
		case .keyStorage: return "The signing key could not be stored in this device's Keychain."
		case .sessionRejected: return "Your Apple Account session has expired. Sign in again."
		case .network: return "Apple's developer services could not be reached."
		case .rateLimited: return "Apple is limiting requests for now. Try again later."
		case .unexpectedResponse: return "Apple returned a response Zag Store does not recognise."
		case .timedOut: return "Apple's developer services did not respond in time."
		case .cancelled: return "Provisioning was cancelled."
		case .unavailable: return "Free Apple Account signing is not available in this version of Zag Store."
		}
	}
}

/// Provisions an app for a free (or any development) team: device, signing
/// certificate, App IDs, app groups and profiles, using the Phase 1 plans.
///
/// - Every limit that can be checked before changing the team is checked
///   first (install slots, devices, App ID capacity), so a request that cannot
///   succeed creates nothing.
/// - Certificates are reused when this device holds the key; a certificate is
///   never revoked automatically.
/// - Every profile is checked against the team, bundle ID, device and
///   certificate before it is returned.
actor ZagFreeAccountProvisioner {
	private let portal: ZagDeveloperPortalService
	private let keys: ZagSigningKeyFactory
	private let secrets: ZagFreeAccountSecretStore
	private let diagnostics: ZagFreeAccountDiagnostics
	private let operationTimeout: TimeInterval
	private let now: @Sendable () -> Date
	private(set) var currentStep: ZagProvisioningFailure.Step?

	init(
		portal: ZagDeveloperPortalService = ZagDisabledDeveloperPortal(),
		keys: ZagSigningKeyFactory = ZagDisabledSigningKeyFactory(),
		secrets: ZagFreeAccountSecretStore,
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		operationTimeout: TimeInterval = 30,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.portal = portal
		self.keys = keys
		self.secrets = secrets
		self.diagnostics = diagnostics
		self.operationTimeout = operationTimeout
		self.now = now
	}

	func provision(_ request: ZagProvisioningRequest) async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		defer { currentStep = nil }
		do {
			let result = try await run(request)
			diagnostics.record("Provisioned \(result.app.bundleIdentifier); profiles expire \(ISO8601DateFormatter().string(from: result.expiresAt))", at: now())
			return .success(result)
		} catch let failure as ZagProvisioningFailure {
			diagnostics.record("Provisioning failed at \(failure.step.rawValue): \(failure.message)", at: now())
			return .failure(failure)
		} catch {
			let failure = ZagProvisioningFailure(kind: Self.kind(for: error), step: currentStep ?? .request)
			diagnostics.record("Provisioning failed at \(failure.step.rawValue): \(failure.message)", at: now())
			return .failure(failure)
		}
	}

	// MARK: Steps

	private func run(_ request: ZagProvisioningRequest) async throws -> ZagProvisioningResult {
		let team = request.team
		let portal = self.portal
		var changes = ZagProvisioningResult.Changes()

		// Bundle IDs for this team.
		currentStep = .request
		guard ZagDeveloperTeam.isValidIdentifier(team), !request.deviceUDID.isEmpty,
			  let appBundle = ZagBundleIdentifierMapping.mapped(request.app.originalBundleIdentifier, team: team) else {
			throw ZagProvisioningFailure(kind: .invalidRequest, step: .request)
		}
		var components: [(request: ZagProvisioningRequest.Component, bundle: String)] = [(request.app, appBundle)]
		for item in request.extensions {
			guard let bundle = ZagBundleIdentifierMapping.mappedExtension(
				item.originalBundleIdentifier, appOriginal: request.app.originalBundleIdentifier, team: team
			) else { throw ZagProvisioningFailure(kind: .invalidRequest, step: .request) }
			components.append((item, bundle))
		}
		guard Set(components.map(\.bundle)).count == components.count else {
			throw ZagProvisioningFailure(kind: .invalidRequest, step: .request)
		}

		// 1. Install slots (local, no request).
		currentStep = .installSlots
		if case .full(let installed) = ZagInstallSlotPlan.make(installing: appBundle, installedFreeAccountApps: request.installedFreeAccountApps) {
			throw ZagProvisioningFailure(kind: .installSlotsFull(installed: installed), step: .installSlots)
		}

		// 2. Device.
		currentStep = .device
		let devices = try await call { try await portal.devices(team: team) }
		switch ZagDeviceRegistrationPlan.make(udid: request.deviceUDID, registeredUDIDs: devices.map(\.udid)) {
		case .alreadyRegistered:
			break
		case .register:
			let udid = request.deviceUDID, name = request.deviceName
			_ = try await call { try await portal.registerDevice(udid: udid, name: name, team: team) }
			changes.registeredDevice = true
			diagnostics.record("Device registered", at: now())
		case .limitReached:
			throw ZagProvisioningFailure(kind: .deviceLimitReached, step: .device)
		}

		// 3. App ID capacity, before anything else is created.
		currentStep = .appIDs
		let registered = try await call { try await portal.appIDs(team: team) }
		let plan = ZagAppIDPlan.make(bundleIdentifiers: components.map(\.bundle), registered: registered, now: now())
		if case .capacityExhausted(let needed, let available, let freesAt) = plan.outcome {
			throw ZagProvisioningFailure(kind: .appIDCapacityExhausted(needed: needed, available: available, nextSlotFreesAt: freesAt), step: .appIDs)
		}

		// 4. Certificate.
		currentStep = .certificate
		let identity = try await signingIdentity(for: request, team: team, changes: &changes)

		// 5. App IDs.
		currentStep = .appIDs
		var appIDs: [String: ZagRegisteredAppID] = [:]
		for appID in registered where appID.isActive(at: now()) { appIDs[appID.bundleIdentifier] = appID }
		if case .register(let missing) = plan.outcome {
			for bundle in missing {
				let name = components.first { $0.bundle == bundle }?.request.name ?? bundle
				do {
					appIDs[bundle] = try await call { try await portal.registerAppID(bundleIdentifier: bundle, name: name, team: team) }
				} catch ZagPortalError.appIDLimitReached {
					throw ZagProvisioningFailure(kind: .appIDCapacityExhausted(needed: missing.count, available: 0, nextSlotFreesAt: plan.capacity.nextSlotFreesAt), step: .appIDs)
				} catch ZagPortalError.identifierUnavailable(let identifier) {
					throw ZagProvisioningFailure(kind: .identifierUnavailable(identifier), step: .appIDs)
				}
				changes.registeredAppIDs.append(bundle)
			}
		}

		// 6. App groups, mapped for the team like bundle IDs.
		currentStep = .appGroups
		var groupsByBundle: [String: [String]] = [:]
		for component in components {
			let requested = component.request.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String] ?? []
			let mapped = requested.compactMap { ZagBundleIdentifierMapping.mappedAppGroup($0, team: team) }
			if !mapped.isEmpty { groupsByBundle[component.bundle] = mapped }
		}
		if !groupsByBundle.isEmpty {
			let existing = Set(try await call { try await portal.appGroups(team: team) }.map(\.identifier))
			for group in Set(groupsByBundle.values.joined()).sorted() where !existing.contains(group) {
				_ = try await call { try await portal.registerAppGroup(group, team: team) }
				changes.registeredAppGroups.append(group)
			}
			for (bundle, groups) in groupsByBundle.sorted(by: { $0.key < $1.key }) {
				guard let appID = appIDs[bundle] else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .appGroups) }
				try await call { try await portal.assignAppGroups(groups, to: appID, team: team) }
			}
		}

		// 7. Profiles, each checked before use.
		currentStep = .profiles
		var results: [ZagProvisioningResult.Component] = []
		for component in components {
			guard let appID = appIDs[component.bundle] else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .profiles) }
			let profile = try await call { try await portal.profile(for: appID, team: team) }
			if let problem = ZagProvisioningProfileCheck.check(
				profile, team: team, bundleIdentifier: component.bundle,
				deviceUDID: request.deviceUDID, certificateSerial: identity.serialNumber, now: now()
			) {
				throw ZagProvisioningFailure(kind: .invalidProfile(problem), step: .profiles)
			}
			let resolved = ZagFreeAccountEntitlements.resolve(
				requested: component.request.entitlements.dictionary,
				profile: profile.entitlements.dictionary,
				team: team,
				bundleIdentifier: component.bundle
			)
			guard let entitlements = try? ZagEntitlementSet(resolved.entitlements) else {
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .profiles)
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

	/// Reuses the stored identity when Apple still lists its certificate with
	/// enough time left; otherwise creates a key on the device and asks Apple
	/// for a certificate. Never revokes one.
	private func signingIdentity(for request: ZagProvisioningRequest, team: String, changes: inout ZagProvisioningResult.Changes) async throws -> ZagSigningIdentity {
		let portal = self.portal
		let stored = (try? secrets.load(.signingPrivateKey, account: request.accountID))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		let remote = try await call { try await portal.certificates(team: team) }
		let plan = ZagCertificatePlan.make(
			remote: remote,
			localKeySerials: stored.map { [$0.serialNumber] } ?? [],
			limit: nil,
			now: now()
		)
		switch plan {
		case .reuse(let serial):
			guard let stored, stored.serialNumber == serial else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate) }
			return stored
		case .userMustRevoke(let candidates):
			throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: candidates), step: .certificate)
		case .create:
			let key: (privateKey: Data, request: ZagCertificateRequest)
			do {
				key = try keys.makeKey(commonName: "Zag Store")
			} catch {
				throw ZagProvisioningFailure(kind: .unavailable, step: .certificate)
			}
			let csr = key.request
			let issued: ZagIssuedCertificate
			do {
				issued = try await call { try await portal.submitCertificateRequest(csr, team: team) }
			} catch ZagPortalError.certificateLimitReached {
				let valid = remote.filter { $0.expiresAt > now() }.sorted { $0.expiresAt < $1.expiresAt }
				throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: valid), step: .certificate)
			}
			guard !issued.data.isEmpty, issued.certificate.expiresAt > now() else {
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate)
			}
			let identity = ZagSigningIdentity(
				serialNumber: issued.certificate.serialNumber,
				certificate: issued.data,
				privateKey: key.privateKey,
				expiresAt: issued.certificate.expiresAt
			)
			do {
				try secrets.save(try JSONEncoder().encode(identity), kind: .signingPrivateKey, account: request.accountID)
			} catch {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
			changes.createdCertificate = true
			diagnostics.record("Development certificate created", at: now())
			return identity
		}
	}

	// MARK: Internals

	/// Runs one portal call under the operation deadline; maps its errors.
	private func call<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let step = currentStep ?? .request
		if Task.isCancelled { throw ZagProvisioningFailure(kind: .cancelled, step: step) }
		do {
			return try await ZagDeadline.run(seconds: operationTimeout, operation)
		} catch let error as ZagPortalError {
			switch error {
			case .appIDLimitReached, .identifierUnavailable, .certificateLimitReached: throw error
			default: throw ZagProvisioningFailure(kind: Self.kind(for: error), step: step)
			}
		} catch {
			throw ZagProvisioningFailure(kind: Task.isCancelled ? .cancelled : Self.kind(for: error), step: step)
		}
	}

	static func kind(for error: Error) -> ZagProvisioningFailure.Kind {
		switch error {
		case let error as ZagPortalError:
			switch error {
			case .sessionRejected: return .sessionRejected
			case .network: return .network
			case .rateLimited: return .rateLimited
			case .malformedResponse: return .unexpectedResponse
			case .identifierUnavailable(let identifier): return .identifierUnavailable(identifier)
			case .deviceLimitReached: return .deviceLimitReached
			case .appIDLimitReached: return .appIDCapacityExhausted(needed: 1, available: 0, nextSlotFreesAt: nil)
			case .certificateLimitReached: return .certificateMustBeRevoked(candidates: [])
			case .livePortalDisabled: return .unavailable
			}
		case ZagTransportError.timedOut: return .timedOut
		case ZagTransportError.cancelled, is CancellationError: return .cancelled
		case is ZagTransportError: return .network
		default: return .unexpectedResponse
		}
	}
}
