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

/// A certificate request in progress for one account and team, kept with
/// `ZagFreeAccountSecretKind.pendingSigningKey`. The same request is retried at
/// most `maximumAttempts` times within `lifetime`; after that a new key is made.
/// `certificate` is set once Apple's certificate has been verified against the
/// pending key, so an interrupted finish is completed rather than re-requested.
struct ZagPendingSigningKey: Codable, Equatable, Sendable {
	static let maximumAttempts = 3
	static let lifetime: TimeInterval = 86_400

	struct Issued: Codable, Equatable, Sendable {
		let data: Data
		let serialNumber: String
		let expiresAt: Date
	}

	let request: Data
	/// Empty when the key is a Keychain key item.
	let privateKey: Data
	/// The new key's slot (`ZagKeychainSigningKeys`), beside the key in use.
	let keySlot: String?
	let startedAt: Date
	var attempts: Int
	var certificate: Issued?
	/// Set before each request is sent and cleared only when Apple has
	/// definitely not issued a certificate (it refused the request). While set,
	/// the request's outcome is unknown: a certificate may have been issued
	/// whose response was lost, so nothing is requested again until the
	/// team's certificate listing settles it.
	var submissionUnconfirmed: Bool?

	func allowsRetry(at now: Date) -> Bool {
		attempts < Self.maximumAttempts && now >= startedAt && now.timeIntervalSince(startedAt) < Self.lifetime
	}
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
		/// The request is not for the authorised account and team, the
		/// authorisation has lapsed, or this provisioner belongs to another account.
		case notAuthorized
		/// Three apps from this team are already on the device.
		case installSlotsFull(installed: [String])
		case deviceLimitReached
		case appIDCapacityExhausted(needed: Int, available: Int, nextSlotFreesAt: Date?)
		case identifierUnavailable(String)
		/// The certificate limit is reached; the user chooses one to revoke.
		case certificateMustBeRevoked(candidates: [ZagDevelopmentCertificate])
		/// An earlier certificate request may have been granted, but its
		/// response was lost and the team's listing cannot show whether it was.
		/// Nothing more is requested, and nothing is revoked, until the user
		/// decides (`abandonUnresolvedCertificateRequest`).
		case certificateRequestUnresolved
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
		case .notAuthorized: return "This Apple Account is not signed in. Sign in to it to sign or refresh its apps."
		case .installSlotsFull: return "Three apps signed with this Apple Account are already installed. Remove one first."
		case .deviceLimitReached: return "This Apple Account already has three registered devices."
		case .appIDCapacityExhausted: return "This Apple Account has used its 10 App IDs for this week."
		case .identifierUnavailable: return "Another developer owns this app's identifier."
		case .certificateMustBeRevoked: return "This Apple Account has reached its development-certificate limit. Choose one to revoke."
		case .certificateRequestUnresolved: return "An earlier certificate request may have succeeded, but Zag Store cannot confirm it. Check this Apple Account's certificates before requesting another."
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
/// - Every call needs a `ZagSigningAuthorization` for the request's own
///   account and team; a provisioner bound to an account (its portal session)
///   refuses any other. Limits follow the team kind.
actor ZagFreeAccountProvisioner {
	private let portal: ZagDeveloperPortalService
	/// The account whose portal session this provisioner uses, if bound.
	let account: UUID?
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
		account: UUID? = nil,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.account = account
		self.portal = portal
		self.keys = keys
		self.secrets = secrets
		self.diagnostics = diagnostics
		self.operationTimeout = operationTimeout
		self.now = now
	}

	func provision(_ request: ZagProvisioningRequest, authorization: ZagSigningAuthorization) async -> Result<ZagProvisioningResult, ZagProvisioningFailure> {
		defer { currentStep = nil }
		guard authorization.isValid(at: now()),
			  authorization.scope == ZagSigningScope(accountID: request.accountID, teamID: request.team),
			  account == nil || account == request.accountID else {
			diagnostics.record("Provisioning refused: not authorised for this account", at: now())
			return .failure(ZagProvisioningFailure(kind: .notAuthorized, step: .request))
		}
		do {
			let result = try await run(request, limits: authorization.limits)
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

	private func run(_ request: ZagProvisioningRequest, limits: ZagTeamLimits) async throws -> ZagProvisioningResult {
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
		// iOS's 3-app limit applies to free teams' apps only (device-wide).
		if limits.countsTowardsFreeAppLimit,
		   case .full(let installed) = ZagInstallSlotPlan.make(installing: appBundle, installedFreeAccountApps: request.installedFreeAccountApps) {
			throw ZagProvisioningFailure(kind: .installSlotsFull(installed: installed), step: .installSlots)
		}

		// 2. Device.
		currentStep = .device
		let devices = try await call { try await portal.devices(team: team) }
		switch ZagDeviceRegistrationPlan.make(udid: request.deviceUDID, registeredUDIDs: devices.map(\.udid), limit: limits.devicesPerPlatform) {
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
		let plan = ZagAppIDPlan.make(bundleIdentifiers: components.map(\.bundle), registered: registered, limit: limits.appIDs ?? Int.max, now: now())
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
		// A certificate issued and verified before an interruption is stored
		// first, so it is reused rather than requested again.
		if try finishPendingIdentity(account: request.accountID, team: team) {
			changes.createdCertificate = true
		}
		// Each account and team has its own identity.
		let stored = (try? secrets.load(.signingPrivateKey, account: request.accountID, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		let remote = try await call { try await portal.certificates(team: team) }
		// The stored identity counts as "key on this device" only if its key is
		// still there and still belongs to its certificate (a Keychain key can
		// be missing after a reset, a restore or a removed item). Otherwise a
		// new key and certificate are made instead of failing at signing.
		let usable = stored.flatMap {
			keys.check(certificate: $0.certificate, privateKey: $0.privateKey, account: request.accountID, team: team, keySlot: $0.keySlot) == .mismatch ? nil : $0
		}
		if stored != nil && usable == nil {
			diagnostics.record("Stored signing key missing or not matching its certificate; a new one is needed", at: now())
		}
		let plan = ZagCertificatePlan.make(
			remote: remote,
			localKeySerials: usable.map { [$0.serialNumber] } ?? [],
			limit: nil,
			now: now()
		)
		switch plan {
		case .reuse(let serial):
			guard let stored = usable, stored.serialNumber == serial else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate) }
			return stored
		case .userMustRevoke(let candidates):
			throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: candidates), step: .certificate)
		case .create:
			// An earlier request whose outcome is unknown is settled first, from
			// the team's certificate listing.
			if let earlier = pendingKey(account: request.accountID, team: team), earlier.certificate == nil, earlier.submissionUnconfirmed == true {
				switch resolveUnconfirmed(earlier, remote: remote, account: request.accountID, team: team) {
				case .issued(let found):
					var recovered = earlier
					recovered.certificate = found
					do {
						try secrets.save(try JSONEncoder().encode(recovered), kind: .pendingSigningKey, account: request.accountID, team: team)
					} catch {
						throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
					}
					guard try finishPendingIdentity(account: request.accountID, team: team), let identity = storedIdentity(account: request.accountID, team: team) else {
						throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate)
					}
					changes.createdCertificate = true
					diagnostics.record("A certificate issued for an interrupted request was found and used; none was requested again", at: now())
					return identity
				case .notIssued:
					var settled = earlier
					settled.submissionUnconfirmed = false
					try? secrets.save(try JSONEncoder().encode(settled), kind: .pendingSigningKey, account: request.accountID, team: team)
				case .unknown:
					diagnostics.record("An interrupted certificate request cannot be confirmed from the listing; nothing requested", at: now())
					throw ZagProvisioningFailure(kind: .certificateRequestUnresolved, step: .certificate)
				}
			}
			// The new key is made beside the key in use, and the stored identity
			// (possibly still valid) stays in use until the new certificate is
			// verified and stored.
			var pending = try beginPendingKey(account: request.accountID, team: team, inUse: stored)
			// Written ahead: if the app stops while the request is out, its
			// outcome is treated as unknown.
			pending.submissionUnconfirmed = true
			do {
				try secrets.save(try JSONEncoder().encode(pending), kind: .pendingSigningKey, account: request.accountID, team: team)
			} catch {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
			let csr = ZagCertificateRequest(data: pending.request)
			let issued: ZagIssuedCertificate
			do {
				issued = try await call { try await portal.submitCertificateRequest(csr, team: team) }
			} catch ZagPortalError.certificateLimitReached {
				markNotIssued(pending, account: request.accountID, team: team)
				let valid = remote.filter { $0.expiresAt > now() }.sorted { $0.expiresAt < $1.expiresAt }
				throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: valid), step: .certificate)
			} catch let failure as ZagProvisioningFailure where failure.kind == .rateLimited || failure.kind == .sessionRejected {
				// Apple refused the request: nothing was issued.
				markNotIssued(pending, account: request.accountID, team: team)
				throw failure
			}
			// The certificate must be for the pending key. If not, this request is
			// abandoned: nothing is published and the next attempt starts afresh.
			var serial = issued.certificate.serialNumber, expiresAt = issued.certificate.expiresAt
			switch keys.check(certificate: issued.data, privateKey: pending.privateKey, account: request.accountID, team: team, keySlot: pending.keySlot) {
			case .matches(let inspectedSerial, let inspectedExpiry):
				serial = inspectedSerial
				expiresAt = inspectedExpiry
			case .notInspected:
				break
			case .mismatch:
				abandon(pending, account: request.accountID, team: team)
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate)
			}
			guard !issued.data.isEmpty, expiresAt > now() else {
				abandon(pending, account: request.accountID, team: team)
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate)
			}
			// Journal the verified certificate before changing anything, so an
			// interruption from here on is finished by the next attempt.
			var verified = pending
			verified.certificate = ZagPendingSigningKey.Issued(data: issued.data, serialNumber: serial, expiresAt: expiresAt)
			do {
				try secrets.save(try JSONEncoder().encode(verified), kind: .pendingSigningKey, account: request.accountID, team: team)
			} catch {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
			guard try finishPendingIdentity(account: request.accountID, team: team),
				  let identity = (try? secrets.load(.signingPrivateKey, account: request.accountID, team: team))
					.flatMap({ $0 })
					.flatMap({ try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }) else {
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .certificate)
			}
			changes.createdCertificate = true
			diagnostics.record("Development certificate created", at: now())
			return identity
		}
	}

	// MARK: Pending signing keys

	enum UnconfirmedOutcome: Equatable {
		case issued(ZagPendingSigningKey.Issued)
		case notIssued
		case unknown
	}

	/// What became of a request whose response was lost, from the team's
	/// listing: a listed certificate whose public key is the pending key's
	/// (proof of possession) was issued for it. Only a listing that includes
	/// every certificate's data can show that none was. Anything less is
	/// unknown, and nothing is guessed.
	private func resolveUnconfirmed(_ pending: ZagPendingSigningKey, remote: [ZagDevelopmentCertificate], account: UUID, team: String) -> UnconfirmedOutcome {
		guard keys.hasKey(account: account, team: team, keySlot: pending.keySlot) else { return .unknown }
		for certificate in remote {
			guard let data = certificate.data,
				  case .matches(let serial, let expiresAt) = keys.check(certificate: data, privateKey: pending.privateKey, account: account, team: team, keySlot: pending.keySlot) else { continue }
			return expiresAt > now() ? .issued(.init(data: data, serialNumber: serial, expiresAt: expiresAt)) : .unknown
		}
		return remote.allSatisfy { $0.data != nil } ? .notIssued : .unknown
	}

	private func markNotIssued(_ pending: ZagPendingSigningKey, account: UUID, team: String) {
		var settled = pending
		settled.submissionUnconfirmed = false
		try? secrets.save(try JSONEncoder().encode(settled), kind: .pendingSigningKey, account: account, team: team)
	}

	private func storedIdentity(account: UUID, team: String) -> ZagSigningIdentity? {
		(try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}

	/// The user's decision after `certificateRequestUnresolved`: give up the
	/// unconfirmed request (its key and journal) so the next provisioning makes
	/// a new one. Any certificate Apple issued for it is never revoked here; it
	/// stays in the team's listing until it expires or the user revokes it.
	func abandonUnresolvedCertificateRequest(accountID: UUID, team: String) {
		guard account == nil || account == accountID, let pending = pendingKey(account: accountID, team: team), pending.certificate == nil else { return }
		abandon(pending, account: accountID, team: team)
		diagnostics.record("An unconfirmed certificate request was abandoned by the user", at: now())
	}

	private func pendingKey(account: UUID, team: String) -> ZagPendingSigningKey? {
		(try? secrets.load(.pendingSigningKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagPendingSigningKey.self, from: $0) }
	}

	/// The pending key and request to submit: the same request again while it
	/// has attempts and time left and its key is still there; otherwise a new
	/// key, after removing this team's keys that neither the identity in use
	/// nor a request in progress names (abandoned attempts).
	private func beginPendingKey(account: UUID, team: String, inUse: ZagSigningIdentity?) throws -> ZagPendingSigningKey {
		var pending: ZagPendingSigningKey
		if let earlier = pendingKey(account: account, team: team),
		   earlier.certificate == nil,
		   earlier.allowsRetry(at: now()),
		   keys.hasKey(account: account, team: team, keySlot: earlier.keySlot) {
			pending = earlier
			pending.attempts += 1
			diagnostics.record("Retrying the pending certificate request (attempt \(pending.attempts) of \(ZagPendingSigningKey.maximumAttempts))", at: now())
		} else {
			try? secrets.delete(.pendingSigningKey, account: account, team: team)
			try? keys.discardKeys(account: account, team: team, except: inUse.map { [$0.keySlot] } ?? [])
			let made: (privateKey: Data, request: ZagCertificateRequest, keySlot: String?)
			do {
				made = try keys.makePendingKey(commonName: "Zag Store", account: account, team: team)
			} catch {
				throw ZagProvisioningFailure(kind: .unavailable, step: .certificate)
			}
			pending = ZagPendingSigningKey(request: made.request.data, privateKey: made.privateKey, keySlot: made.keySlot, startedAt: now(), attempts: 1, certificate: nil)
		}
		do {
			try secrets.save(try JSONEncoder().encode(pending), kind: .pendingSigningKey, account: account, team: team)
		} catch {
			abandon(pending, account: account, team: team)
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
		return pending
	}

	/// Publishes a journalled, verified certificate: checks possession again,
	/// stores the identity naming the new key (the one write that switches to
	/// it), clears the journal, then removes the previous key. Each step can be
	/// repeated, so an interruption at any point is finished by the next call.
	/// A journal that no longer verifies is discarded without publishing
	/// anything. True when an identity was stored.
	private func finishPendingIdentity(account: UUID, team: String) throws -> Bool {
		guard let pending = pendingKey(account: account, team: team), let issued = pending.certificate else { return false }
		let previous = (try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		var serial = issued.serialNumber, expiresAt = issued.expiresAt
		switch keys.check(certificate: issued.data, privateKey: pending.privateKey, account: account, team: team, keySlot: pending.keySlot) {
		case .matches(let inspectedSerial, let inspectedExpiry):
			serial = inspectedSerial
			expiresAt = inspectedExpiry
		case .notInspected:
			break
		case .mismatch:
			expiresAt = .distantPast
		}
		guard expiresAt > now() else {
			diagnostics.record("A pending certificate no longer matches its key or has expired; discarded", at: now())
			abandon(pending, account: account, team: team)
			return false
		}
		let identity = ZagSigningIdentity(serialNumber: serial, certificate: issued.data, privateKey: pending.privateKey, expiresAt: expiresAt, keySlot: pending.keySlot)
		do {
			try secrets.save(try JSONEncoder().encode(identity), kind: .signingPrivateKey, account: account, team: team)
			try secrets.delete(.pendingSigningKey, account: account, team: team)
		} catch {
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
		if let previous, previous.keyIsInKeychain, previous.keySlot != pending.keySlot {
			// If this fails, the key is removed with the next new request's
			// abandoned keys, or with the account.
			try? keys.discardKey(account: account, team: team, keySlot: previous.keySlot)
		}
		return true
	}

	/// Removes a request in progress: its journal and its key (never the key
	/// the stored identity uses).
	private func abandon(_ pending: ZagPendingSigningKey, account: UUID, team: String) {
		try? secrets.delete(.pendingSigningKey, account: account, team: team)
		let inUse = (try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		if inUse.map({ $0.keySlot != pending.keySlot }) ?? true {
			try? keys.discardKey(account: account, team: team, keySlot: pending.keySlot)
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
