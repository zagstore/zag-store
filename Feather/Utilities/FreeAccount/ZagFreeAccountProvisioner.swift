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
	var reusableProfiles: [ZagIssuedProfile] = []
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
	/// A definite issuance conflict leaves this CSR reusable after the user
	/// resolves the conflict, even if reviewing the certificates takes time.
	var preserveAfterConflict: Bool? = nil

	func allowsRetry(at now: Date) -> Bool {
		attempts < Self.maximumAttempts && now >= startedAt && now.timeIntervalSince(startedAt) < Self.lifetime
	}
}

/// A certificate request whose outcome is unknown (`certificateRequestUnresolved`).
struct ZagUnresolvedCertificateRequest: Equatable, Sendable {
	let accountID: UUID
	let team: String
	let startedAt: Date
	let attempts: Int
}

/// What a recovery action did. Only `recovered`, `notIssued` and `abandoned`
/// change anything, and none of them sends a certificate request or revokes.
enum ZagCertificateRecoveryOutcome: Equatable, Sendable {
	/// The certificate issued for the request was found in the team's listing
	/// (proof of possession) and is now used. Nothing was requested.
	case recovered(serialNumber: String, expiresAt: Date)
	/// The listing shows no certificate was issued for it. Signing may send
	/// the same request again.
	case notIssued
	/// Still cannot be established. Nothing changed.
	case unresolved
	/// The user gave the request up: its key and record are gone.
	case abandoned
	/// There is no unresolved request for this account and team.
	case nothingPending
	/// The check could not run (signed out, network, cancelled…). Nothing changed.
	case checkFailed(ZagProvisioningFailure.Kind)
}

struct ZagProvisioningFailure: LocalizedError, Equatable, Sendable {
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
		case appIDServerLimitReached
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
	var portalFailure: ZagPortalOperationFailure? = nil
	var invalidField: String? = nil
	var appleAppIDRejection: ZagAppIDServerRejection? = nil

	var errorDescription: String? { message }

	var message: String {
		if let portalFailure { return "\(summary) \(portalFailure.localizedDescription)" }
		guard let rejection = appleAppIDRejection else { return summary }
		let operation = rejection.action == .addAppID ? "App ID registration" : "App ID inventory"
		var result = "Apple rejected \(operation) (HTTP \(rejection.fault.httpStatus)"
		if let code = rejection.fault.resultCode { result += ", code \(code)" }
		result += "). "
		return result + (rejection.fault.message.isEmpty ? summary : rejection.fault.message)
	}

	private var summary: String {
		switch kind {
		case .invalidRequest: return "This app cannot be signed with a free Apple Account."
		case .notAuthorized: return "This Apple Account is not signed in. Sign in to it to sign or refresh its apps."
		case .installSlotsFull: return ZagFreeAppLimitReached.message
		case .deviceLimitReached: return "This Apple Account already has three registered devices."
		case .appIDCapacityExhausted(let needed, let available, _):
			return "This app needs \(needed) new App IDs. Zag Store counted \(available) available slots for this team."
		case .appIDServerLimitReached: return "Apple refused to register another App ID because this team reached its limit."
		case .identifierUnavailable: return "Another developer owns this app's identifier."
		case .certificateMustBeRevoked(let candidates):
			return candidates.isEmpty
				? "Apple refused the certificate request. An existing certificate or a pending request may be blocking issuance. Review the team’s certificates before retrying."
				: "Apple refused to issue a certificate. Review the team’s certificates before deciding whether to replace one."
		case .certificateRequestUnresolved: return "An earlier certificate request may have succeeded, but Zag Store cannot confirm it. Check this Apple Account's certificates before requesting another."
		case .invalidProfile(let problem): return "The provisioning profile failed validation (\(problem.rawValue))."
		case .keyStorage: return "The signing key could not be stored in this device's Keychain."
		case .sessionRejected: return "Your Apple Account session has expired. Sign in again."
		case .network: return "Apple's developer services could not be reached."
		case .rateLimited: return "Apple is limiting requests for now. Try again later."
		case .unexpectedResponse:
			let stage = "Signing could not complete the \(step.rawValue) stage."
			return invalidField.map { "\(stage) Missing or invalid: \($0)." } ?? stage
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
	private let certificateMinimumRemaining: TimeInterval
	private let onCertificateReady: (@Sendable () async -> Void)?
	private let saveProfile: (@Sendable (ZagIssuedProfile) -> Void)?
	private let now: @Sendable () -> Date
	private(set) var currentStep: ZagProvisioningFailure.Step?
	/// Account and team scopes with an operation running. Provisioning,
	/// Check Again, Abandon and the unresolved-request query of one scope run
	/// one at a time: the actor is reentrant at every portal call, and a
	/// second operation could otherwise settle, send again or remove a
	/// certificate request that is still out (two certificates for one key).
	private var busyScopes: Set<ZagSigningScope> = []
	private var scopeWaiters: [ZagSigningScope: [(ticket: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]
	/// Operations waiting for their scope (tests).
	var waitingOperations: Int { scopeWaiters.values.reduce(0) { $0 + $1.count } }

	init(
		portal: ZagDeveloperPortalService = ZagDisabledDeveloperPortal(),
		keys: ZagSigningKeyFactory = ZagDisabledSigningKeyFactory(),
		secrets: ZagFreeAccountSecretStore,
		diagnostics: ZagFreeAccountDiagnostics = ZagFreeAccountDiagnostics(),
		operationTimeout: TimeInterval = 30,
		certificateMinimumRemaining: TimeInterval = 7 * 86_400,
		saveProfile: (@Sendable (ZagIssuedProfile) -> Void)? = nil,
		onCertificateReady: (@Sendable () async -> Void)? = nil,
		account: UUID? = nil,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.account = account
		self.portal = portal
		self.keys = keys
		self.secrets = secrets
		self.diagnostics = diagnostics
		self.operationTimeout = operationTimeout
		self.certificateMinimumRemaining = certificateMinimumRemaining
		self.saveProfile = saveProfile
		self.onCertificateReady = onCertificateReady
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
			let result = try await exclusively(authorization.scope) { try await run(request, limits: authorization.limits) }
			diagnostics.record("Provisioned \(result.app.bundleIdentifier); profiles expire \(ISO8601DateFormatter().string(from: result.expiresAt))", at: now())
			return .success(result)
		} catch let failure as ZagProvisioningFailure {
			diagnostics.record("Provisioning failed at \(failure.step.rawValue): \(failure.message)", at: now())
			experimentStop(failure.kind)
			return .failure(failure)
		} catch {
			let failure = ZagProvisioningFailure(kind: Self.kind(for: error), step: currentStep ?? .request)
			diagnostics.record("Provisioning failed at \(failure.step.rawValue): \(failure.message)", at: now())
			experimentStop(failure.kind)
			return .failure(failure)
		}
	}

	// MARK: G5 experiment

	/// G5 (plan §7.3): in the experiment build every provisioning failure is a
	/// stop and halts the campaign, except a refusal by the campaign itself
	/// (already recorded, and halted where its check requires) and a local
	/// authorisation that lapsed before anything was sent.
	private func experimentStop(_ kind: ZagProvisioningFailure.Kind) {
		#if ZAG_LIVE_EXPERIMENT
		let rule: ZagStopRule? = switch kind {
		// A cancellation is a stop only between consume and the result, where
		// the portal adapter has already halted.
		case .unavailable, .notAuthorized, .invalidRequest, .cancelled: nil
		case .certificateMustBeRevoked: .certificateMustBeRevoked
		case .certificateRequestUnresolved: .certificateUnresolved
		case .deviceLimitReached: .deviceLimit
		case .appIDCapacityExhausted, .appIDServerLimitReached, .installSlotsFull: .appIDCapacity
		case .identifierUnavailable: .identifierUnavailable
		case .invalidProfile: .profileProblem
		case .keyStorage, .sessionRejected, .network, .rateLimited, .unexpectedResponse, .timedOut: .ownerUnrecognised
		}
		if let rule { ZagLiveExperiment.campaign.halt(rule) }
		#endif
	}

	private func experimentFailure(_ kind: ZagProvisioningFailure.Kind) -> String? {
		#if ZAG_LIVE_EXPERIMENT
		return ZagExperimentFailureMap.failure(kind)
		#else
		return nil
		#endif
	}

	/// G5: one `cert.*` event (logging spec §4.7); nothing outside the experiment.
	private func experimentEvent(_ name: String, outcome: String = "ok", failure: String? = nil, transition: String? = nil,
								 result: String? = nil, count: Int? = nil, possession: Bool? = nil) {
		#if ZAG_LIVE_EXPERIMENT
		var fields: [String: ZagLogValue] = [:]
		if let transition { fields["transition"] = .string(transition) }
		switch name {
		case "cert.recovery":
			fields["action"] = .string("checkAgain")
			if let result { fields["result"] = .string(result) }
			if let count { fields["listingCount"] = .int(min(500, count)) }
		case "cert.limit":
			fields["reason"] = .string("certificateMustBeRevoked")
			if let count { fields["candidateCount"] = .int(min(500, count)) }
		case "cert.verify":
			if let possession { fields["possessionMatch"] = .bool(possession) }
		default:
			if let count { fields["attempts"] = .int(min(10, count)) }
		}
		ZagLiveExperiment.logger?.record(name, outcome: outcome, failure: failure, fields: fields)
		#endif
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
		await onCertificateReady?()

		// 5. App IDs.
		currentStep = .appIDs
		var appIDs: [String: ZagRegisteredAppID] = [:]
		for appID in registered where appID.isActive(at: now()) {
			if let existing = appIDs[appID.bundleIdentifier],
			   (existing.expiresAt ?? .distantPast) >= (appID.expiresAt ?? .distantPast) { continue }
			appIDs[appID.bundleIdentifier] = appID
		}
		if case .register(let missing) = plan.outcome {
			for bundle in missing {
				let name = components.first { $0.bundle == bundle }?.request.name ?? bundle
				do {
					appIDs[bundle] = try await call { try await portal.registerAppID(bundleIdentifier: bundle, name: name, team: team) }
				} catch ZagPortalError.appIDLimitReached {
					throw ZagProvisioningFailure(kind: .appIDServerLimitReached, step: .appIDs)
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
				guard let appID = appIDs[bundle] else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .appGroups, invalidField: "resolved App ID") }
				try await call { try await portal.assignAppGroups(groups, to: appID, team: team) }
			}
		}

		// 7. Profiles, each checked before use.
		currentStep = .profiles
		var results: [ZagProvisioningResult.Component] = []
		for component in components {
			guard let appID = appIDs[component.bundle] else { throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .profiles, invalidField: "resolved App ID") }
			let cached = request.reusableProfiles
				.filter { profile in
					let groups = profile.entitlements.dictionary[ZagFreeAccountEntitlements.appGroupsKey] as? [String] ?? []
					return Set(groupsByBundle[component.bundle] ?? []).isSubset(of: groups)
						&& ZagProvisioningProfileCheck.check(profile, team: team, bundleIdentifier: component.bundle,
							deviceUDID: request.deviceUDID, certificateSerial: identity.serialNumber, now: now()) == nil
				}
				.max { $0.expiresAt < $1.expiresAt }
			let profile: ZagIssuedProfile
			if let cached { profile = cached }
			else { profile = try await call { try await portal.profile(for: appID, team: team) } }
			if let problem = ZagProvisioningProfileCheck.check(
				profile, team: team, bundleIdentifier: component.bundle,
				deviceUDID: request.deviceUDID, certificateSerial: identity.serialNumber, now: now()
			) {
				throw ZagProvisioningFailure(kind: .invalidProfile(problem), step: .profiles)
			}
			if cached == nil { saveProfile?(profile) }
			let resolved = ZagFreeAccountEntitlements.resolve(
				requested: component.request.entitlements.dictionary,
				profile: profile.entitlements.dictionary,
				team: team,
				bundleIdentifier: component.bundle
			)
			guard let entitlements = try? ZagEntitlementSet(resolved.entitlements) else {
				throw ZagProvisioningFailure(kind: .unexpectedResponse, step: .profiles, invalidField: "reconciled entitlements")
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
		let listed = try await call { try await portal.certificates(team: team) }
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
		let remote = listed.map { certificate in
			if let usable, certificate.expiresAt == .distantPast,
			   ZagActiveCertificateGuard.sameSerial(certificate.serialNumber, usable.serialNumber) {
				return ZagDevelopmentCertificate(serialNumber: usable.serialNumber, name: certificate.name,
					machineName: certificate.machineName, expiresAt: usable.expiresAt, data: certificate.data)
			}
			return certificate
		}
		let plan = ZagCertificatePlan.make(
			remote: remote,
			localKeySerials: usable.map { [$0.serialNumber] } ?? [],
			limit: nil,
			minimumRemaining: certificateMinimumRemaining,
			now: now()
		)
		switch plan {
		case .reuse(let serial):
			guard let stored = usable, stored.serialNumber == serial else { throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate) }
			return stored
		case .userMustRevoke(let candidates):
			experimentEvent("cert.limit", outcome: "blocked", failure: "portal.certificateLimit", count: candidates.count)
			throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: candidates), step: .certificate)
		case .create:
			// An earlier request whose outcome is unknown is settled first, from
			// the team's certificate listing.
			if let earlier = try loadPendingKey(account: request.accountID, team: team), earlier.certificate == nil, earlier.submissionUnconfirmed == true {
				switch resolveUnconfirmed(earlier, remote: remote, account: request.accountID, team: team) {
				case .issued(let found):
					let identity = try adoptIssued(found, for: earlier, account: request.accountID, team: team)
					changes.createdCertificate = true
					diagnostics.record("A certificate issued for an interrupted request was found and used; none was requested again", at: now())
					return identity
				case .unknown:
					diagnostics.record("An interrupted certificate request cannot be confirmed from the listing; nothing requested", at: now())
					experimentEvent("cert.journal", outcome: "blocked", failure: "cert.unresolved", transition: "unresolved", count: earlier.attempts)
					throw ZagProvisioningFailure(kind: .certificateRequestUnresolved, step: .certificate)
				}
			}
			// The new key is made beside the key in use, and the stored identity
			// (possibly still valid) stays in use until the new certificate is
			// verified and stored.
			var pending = try beginPendingKey(account: request.accountID, team: team, inUse: stored)
			experimentEvent("cert.journal", transition: "pendingCreated", count: pending.attempts)
			// Written ahead: if the app stops while the request is out, its
			// outcome is treated as unknown.
			pending.submissionUnconfirmed = true
			do {
				try secrets.save(try JSONEncoder().encode(pending), kind: .pendingSigningKey, account: request.accountID, team: team)
			} catch {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
			experimentEvent("cert.journal", transition: "submissionUnconfirmedSet", count: pending.attempts)
			let csr = ZagCertificateRequest(data: pending.request)
			let issued: ZagIssuedCertificate
			do {
				issued = try await call { try await portal.submitCertificateRequest(csr, team: team) }
			} catch let error as ZagPortalError where error == .certificateLimitReached || error == .existingCertificateOrPendingRequest {
				try markNotIssued(pending, account: request.accountID, team: team, conflict: true)
				let valid = remote.filter { $0.expiresAt == .distantPast || $0.expiresAt > now() }.sorted { $0.expiresAt < $1.expiresAt }
				experimentEvent("cert.limit", outcome: "blocked", failure: "portal.certificateLimit", count: valid.count)
				throw ZagProvisioningFailure(kind: .certificateMustBeRevoked(candidates: valid), step: .certificate)
			} catch let failure as ZagProvisioningFailure where failure.portalFailure?.resultCode == 3250
				|| failure.kind == .rateLimited || failure.kind == .sessionRejected {
				// Apple refused the request: nothing was issued.
				try markNotIssued(pending, account: request.accountID, team: team)
				throw failure
			} catch {
				#if ZAG_LIVE_EXPERIMENT
				if let refusal = error as? ZagLiveExperimentRefusal {
					// G5: refused by the campaign before anything was sent (E1);
					// the request is settled as not issued.
					try markNotIssued(pending, account: request.accountID, team: team)
					experimentEvent("cert.submit", outcome: "blocked", failure: ZagExperimentFailureMap.failure(refusal))
					throw ZagProvisioningFailure(kind: .unavailable, step: .certificate)
				}
				#endif
				throw ZagProvisioningFailure(kind: .certificateRequestUnresolved, step: .certificate)
			}
			// Keep the pending key if the response cannot prove possession.
			// Check Again may still find its certificate in the inventory.
			var serial = issued.certificate.serialNumber, expiresAt = issued.certificate.expiresAt
			switch keys.check(certificate: issued.data, privateKey: pending.privateKey, account: request.accountID, team: team, keySlot: pending.keySlot) {
			case .matches(let inspectedSerial, let inspectedExpiry):
				serial = inspectedSerial
				expiresAt = inspectedExpiry
				experimentEvent("cert.verify", possession: true)
			case .notInspected:
				experimentEvent("cert.verify", possession: false)
			case .mismatch:
				experimentEvent("cert.verify", outcome: "failed", failure: "cert.possessionMismatch", possession: false)
				#if ZAG_LIVE_EXPERIMENT
				ZagLiveExperiment.campaign.halt(.possessionMismatch)
				#endif
				throw ZagProvisioningFailure(kind: .certificateRequestUnresolved, step: .certificate)
			}
			guard !issued.data.isEmpty, expiresAt > now() else {
				throw ZagProvisioningFailure(kind: .certificateRequestUnresolved, step: .certificate)
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
			experimentEvent("cert.journal", transition: "issuedRecorded", count: verified.attempts)
			guard try finishPendingIdentity(account: request.accountID, team: team),
				  let identity = (try? secrets.load(.signingPrivateKey, account: request.accountID, team: team))
					.flatMap({ $0 })
					.flatMap({ try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }) else {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
			experimentEvent("cert.swap")
			changes.createdCertificate = true
			diagnostics.record("Development certificate created", at: now())
			return identity
		}
	}

	// MARK: Pending signing keys

	enum UnconfirmedOutcome: Equatable {
		case issued(ZagPendingSigningKey.Issued)
		case unknown
	}

	/// What became of a request whose response was lost, from the team's
	/// listing: a listed certificate whose public key is the pending key's
	/// (proof of possession) was issued for it. A snapshot with no match cannot
	/// establish whether Apple is still processing an interrupted request.
	private func resolveUnconfirmed(_ pending: ZagPendingSigningKey, remote: [ZagDevelopmentCertificate], account: UUID, team: String) -> UnconfirmedOutcome {
		guard keys.hasKey(account: account, team: team, keySlot: pending.keySlot) else { return .unknown }
		for certificate in remote {
			guard let data = certificate.data,
				  case .matches(let serial, let expiresAt) = keys.check(certificate: data, privateKey: pending.privateKey, account: account, team: team, keySlot: pending.keySlot) else { continue }
			return expiresAt > now() ? .issued(.init(data: data, serialNumber: serial, expiresAt: expiresAt)) : .unknown
		}
		return .unknown
	}

	private func markNotIssued(_ pending: ZagPendingSigningKey, account: UUID, team: String, conflict: Bool = false) throws {
		var settled = pending
		settled.submissionUnconfirmed = false
		if conflict { settled.preserveAfterConflict = true }
		do {
			try secrets.save(try JSONEncoder().encode(settled), kind: .pendingSigningKey, account: account, team: team)
		} catch {
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
		experimentEvent("cert.journal", transition: "submissionUnconfirmedCleared", count: pending.attempts)
	}

	private func storedIdentity(account: UUID, team: String) -> ZagSigningIdentity? {
		(try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}

	/// Publishes the certificate found for a pending request through its
	/// journal, as for any verified certificate.
	private func adoptIssued(_ found: ZagPendingSigningKey.Issued, for pending: ZagPendingSigningKey, account: UUID, team: String) throws -> ZagSigningIdentity {
		var recovered = pending
		recovered.certificate = found
		do {
			try secrets.save(try JSONEncoder().encode(recovered), kind: .pendingSigningKey, account: account, team: team)
		} catch {
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
		guard try finishPendingIdentity(account: account, team: team), let identity = storedIdentity(account: account, team: team) else {
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
		return identity
	}

	// MARK: Unresolved certificate requests (the user's recovery actions)

	private func unresolvedPendingKey(account accountID: UUID, team: String) -> ZagPendingSigningKey? {
		guard account == nil || account == accountID,
			  let pending = pendingKey(account: accountID, team: team),
			  pending.certificate == nil, pending.submissionUnconfirmed == true else { return nil }
		return pending
	}

	/// The account and team's certificate request whose outcome is unknown,
	/// if any. Local only: nothing is sent. A request still out is not
	/// unresolved; this waits for it.
	/// Cancelled while waiting: nil.
	func unresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagUnresolvedCertificateRequest? {
		try? await exclusively(ZagSigningScope(accountID: accountID, teamID: team)) {
			unresolvedPendingKey(account: accountID, team: team).map {
				ZagUnresolvedCertificateRequest(accountID: accountID, team: team, startedAt: $0.startedAt, attempts: $0.attempts)
			}
		}
	}

	/// Check Again: reads the team's certificate listing and settles the
	/// request from it exactly as provisioning would, but never sends a
	/// certificate request and never revokes. Needs the account's
	/// authorisation (its portal session). Nothing changes unless the listing
	/// settles the request, and only if the request is still the one checked.
	func checkUnresolvedCertificateRequest(accountID: UUID, team: String, authorization: ZagSigningAuthorization) async -> ZagCertificateRecoveryOutcome {
		defer { currentStep = nil }
		guard authorization.isValid(at: now()),
			  authorization.scope == ZagSigningScope(accountID: accountID, teamID: team),
			  account == nil || account == accountID else {
			return .checkFailed(.notAuthorized)
		}
		do {
			return try await exclusively(authorization.scope) {
				await checkUnresolved(accountID: accountID, team: team)
			}
		} catch {
			return .checkFailed(.cancelled)
		}
	}

	private func checkUnresolved(accountID: UUID, team: String) async -> ZagCertificateRecoveryOutcome {
		guard let before = unresolvedPendingKey(account: accountID, team: team) else { return .nothingPending }
		currentStep = .certificate
		let portal = self.portal
		let remote: [ZagDevelopmentCertificate]
		do {
			remote = try await call { try await portal.certificates(team: team) }
		} catch let failure as ZagProvisioningFailure {
			diagnostics.record("Check Again could not read the certificate listing: \(failure.message)", at: now())
			experimentEvent("cert.recovery", outcome: "failed", failure: experimentFailure(failure.kind), result: "checkFailed")
			return .checkFailed(failure.kind)
		} catch {
			return .checkFailed(Self.kind(for: error))
		}
		if Task.isCancelled { return .checkFailed(.cancelled) }
		// Abandoned or settled by provisioning while the listing was read.
		guard let pending = unresolvedPendingKey(account: accountID, team: team),
			  pending.keySlot == before.keySlot, pending.startedAt == before.startedAt, pending.request == before.request else {
			return .nothingPending
		}
		switch resolveUnconfirmed(pending, remote: remote, account: accountID, team: team) {
		case .issued(let found):
			do {
				_ = try adoptIssued(found, for: pending, account: accountID, team: team)
			} catch let failure as ZagProvisioningFailure {
				return .checkFailed(failure.kind)
			} catch {
				return .checkFailed(.keyStorage)
			}
			diagnostics.record("Check Again found the certificate issued for an interrupted request and used it; nothing was requested", at: now())
			experimentEvent("cert.recovery", result: "recovered", count: remote.count)
			return .recovered(serialNumber: found.serialNumber, expiresAt: found.expiresAt)
		case .unknown:
			diagnostics.record("Check Again: the interrupted certificate request is still unresolved; nothing requested", at: now())
			experimentEvent("cert.recovery", outcome: "blocked", failure: "cert.unresolved", result: "unresolved", count: remote.count)
			return .unresolved
		}
	}

	/// The user's decision after `certificateRequestUnresolved`: give up the
	/// unconfirmed request (its key and journal) so the next provisioning makes
	/// a new one. Local only, so it works signed out. Any certificate Apple
	/// issued for it is never revoked here; it stays in the team's listing
	/// until it expires or the user revokes it.
	/// A request still out is not abandoned; this waits for its outcome.
	@discardableResult
	func abandonUnresolvedCertificateRequest(accountID: UUID, team: String) async -> ZagCertificateRecoveryOutcome {
		#if ZAG_LIVE_EXPERIMENT
		// E3 (G5 plan §5.2): never during a campaign; only Check Again.
		if ZagLiveExperiment.campaign.refusesAbandon { return .checkFailed(.unavailable) }
		#endif
		do {
			return try await exclusively(ZagSigningScope(accountID: accountID, teamID: team)) {
				guard let pending = unresolvedPendingKey(account: accountID, team: team) else { return .nothingPending }
				do {
					let active = try secrets.load(.signingPrivateKey, account: accountID, team: team)
						.map { try JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
					try secrets.delete(.pendingSigningKey, account: accountID, team: team)
					if active.map({ $0.keySlot != pending.keySlot }) ?? true {
						try? keys.discardKey(account: accountID, team: team, keySlot: pending.keySlot)
					}
				} catch { return .checkFailed(.keyStorage) }
				diagnostics.record("An unconfirmed certificate request was abandoned by the user", at: now())
				return .abandoned
			}
		} catch {
			// Cancelled while waiting: nothing was abandoned.
			return .checkFailed(.cancelled)
		}
	}

	private func loadPendingKey(account: UUID, team: String) throws -> ZagPendingSigningKey? {
		do {
			return try secrets.load(.pendingSigningKey, account: account, team: team)
				.map { try JSONDecoder().decode(ZagPendingSigningKey.self, from: $0) }
		} catch {
			throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
		}
	}

	private func pendingKey(account: UUID, team: String) -> ZagPendingSigningKey? {
		try? loadPendingKey(account: account, team: team)
	}

	/// The pending key and request to submit: the same request again while it
	/// has attempts and time left and its key is still there; otherwise a new
	/// key, after removing this team's keys that neither the identity in use
	/// nor a request in progress names (abandoned attempts).
	private func beginPendingKey(account: UUID, team: String, inUse: ZagSigningIdentity?) throws -> ZagPendingSigningKey {
		var pending: ZagPendingSigningKey
		if let earlier = try loadPendingKey(account: account, team: team),
		   earlier.certificate == nil,
		   (earlier.preserveAfterConflict == true || earlier.allowsRetry(at: now())),
		   keys.hasKey(account: account, team: team, keySlot: earlier.keySlot) {
			pending = earlier
			pending.attempts += 1
			diagnostics.record("Retrying the pending certificate request (attempt \(pending.attempts))", at: now())
		} else {
			do {
				try secrets.delete(.pendingSigningKey, account: account, team: team)
			} catch {
				throw ZagProvisioningFailure(kind: .keyStorage, step: .certificate)
			}
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
		guard let pending = try loadPendingKey(account: account, team: team), let issued = pending.certificate else { return false }
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
		experimentEvent("cert.journal", transition: "pendingDiscarded", count: pending.attempts)
		try? secrets.delete(.pendingSigningKey, account: account, team: team)
		let inUse = (try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
		if inUse.map({ $0.keySlot != pending.keySlot }) ?? true {
			try? keys.discardKey(account: account, team: team, keySlot: pending.keySlot)
		}
	}

	// MARK: Internals

	/// Runs `body` once no other operation of `scope` is running here. A
	/// caller cancelled before or while it waits throws `CancellationError`
	/// at once and runs nothing.
	private func exclusively<T>(_ scope: ZagSigningScope, _ body: () async throws -> T) async throws -> T {
		while busyScopes.contains(scope) {
			try Task.checkCancellation()
			let ticket = UUID()
			await withTaskCancellationHandler {
				await withCheckedContinuation { scopeWaiters[scope, default: []].append((ticket, $0)) }
			} onCancel: {
				Task { await self.stopWaiting(ticket, scope: scope) }
			}
		}
		try Task.checkCancellation()
		busyScopes.insert(scope)
		defer {
			busyScopes.remove(scope)
			// Every waiter checks again: one takes the scope, cancelled ones
			// leave, the rest wait again. None depends on another to wake it.
			scopeWaiters.removeValue(forKey: scope)?.forEach { $0.continuation.resume() }
		}
		return try await body()
	}

	/// A waiter whose task was cancelled stops waiting (resumed once: by
	/// whichever of this and the scope's release removes it first).
	private func stopWaiting(_ ticket: UUID, scope: ZagSigningScope) {
		guard var waiting = scopeWaiters[scope], let index = waiting.firstIndex(where: { $0.ticket == ticket }) else { return }
		let waiter = waiting.remove(at: index)
		scopeWaiters[scope] = waiting.isEmpty ? nil : waiting
		waiter.continuation.resume()
	}

	/// Runs one portal call under the operation deadline; maps its errors.
	private func call<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let step = currentStep ?? .request
		ZagSigningDiagnostics.record("Provisioning stage: \(step.rawValue)")
		if Task.isCancelled { throw ZagProvisioningFailure(kind: .cancelled, step: step) }
		do {
			return try await ZagDeadline.run(seconds: operationTimeout, operation)
		} catch let detail as ZagPortalOperationFailure {
			throw ZagProvisioningFailure(kind: Self.kind(for: detail.underlying), step: step, portalFailure: detail)
		} catch let rejection as ZagAppIDServerRejection {
			throw ZagProvisioningFailure(kind: Self.kind(for: rejection.error), step: step, appleAppIDRejection: rejection)
		} catch let error as ZagPortalError {
			switch error {
			case .appIDLimitReached, .identifierUnavailable, .certificateLimitReached, .existingCertificateOrPendingRequest: throw error
			default: throw ZagProvisioningFailure(kind: Self.kind(for: error), step: step)
			}
		} catch {
			#if ZAG_LIVE_EXPERIMENT
			// G5: a campaign refusal reaches the step that can settle it.
			if let refusal = error as? ZagLiveExperimentRefusal { throw refusal }
			#endif
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
			case .appIDLimitReached: return .appIDServerLimitReached
			case .certificateLimitReached: return .certificateMustBeRevoked(candidates: [])
			case .existingCertificateOrPendingRequest: return .certificateMustBeRevoked(candidates: [])
			case .livePortalDisabled: return .unavailable
			}
		case ZagTransportError.timedOut: return .timedOut
		case ZagTransportError.cancelled, is CancellationError: return .cancelled
		case is ZagTransportError: return .network
		default: return .unexpectedResponse
		}
	}
}
