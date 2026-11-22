import Foundation

// Milestone 3: ties the ASC provisioner to the existing signing adapter and
// installer, so a paid developer account produces a signed, installed and
// verified app through the same pipeline the free path uses. The signer and
// installer are the real ones in production; both are protocols here so the
// coordinator's orchestration is tested offline with stubs.
//
// Nothing runs unless the feature gate is open (closed in every release
// build), and the signing authorisation is the developer-account one
// (`ZagSigningAuthorization.developerAccount`). The production signer is a
// `ZagFreeAccountSigningAdapter` with the `.developerAccount` gate, so this
// method never depends on free-account signing being enabled.
//
// Cancellation is checked between steps. A cancelled or failed run leaves
// nothing half-used: what Apple already created (device, bundle ID,
// certificate) is reused by the next run, and the stored identity is only
// written once its certificate is issued and checked.

enum ZagASCSigningError: Equatable, Sendable {
	/// The developer-account feature gate is closed.
	case disabled
	case provisioning(ZagProvisioningFailure.Kind)
	/// Provisioning succeeded but the stored signing identity was not found.
	case noIdentity
	case signing
	case install
	/// Installed, but the device did not confirm the expected profile.
	case notVerified
	/// The task was cancelled; the next run resumes from what was created.
	case cancelled
}

struct ZagASCSigningCoordinator: Sendable {
	let provisioner: ZagASCProvisioner
	let secrets: ZagFreeAccountSecretStore
	let signer: ZagAppSigning
	let installer: ZagFreeAccountInstaller
	var gate: ZagDeveloperAccountGate = .production
	var authorizationLifetime: TimeInterval = 10 * 60
	var now: @Sendable () -> Date = { Date() }

	enum Outcome: Equatable, Sendable {
		/// Installed and confirmed from the device.
		case installed(ZagSignedAppRecord)
		/// Installed, but the device's expiry could not be read back.
		case installedUnverified(ZagSignedAppRecord)
		case failed(ZagASCSigningError)
	}

	/// Provisions, signs, installs and verifies one app for the connected team.
	func install(
		app component: ZagProvisioningRequest.Component,
		account: UUID,
		team: ZagDeveloperTeam,
		device: ZagTargetDevice,
		appAt app: URL
	) async -> Outcome {
		guard gate.isOpen else { return .failed(.disabled) }

		let request = ZagProvisioningRequest(
			accountID: account,
			team: team.identifier,
			deviceUDID: device.udid,
			deviceName: device.name,
			app: component,
			extensions: [],
			installedFreeAccountApps: []
		)
		let result: ZagProvisioningResult
		switch await provisioner.provision(request) {
		case .success(let value): result = value
		case .failure(let failure):
			return .failed(failure.kind == .cancelled || Task.isCancelled ? .cancelled : .provisioning(failure.kind))
		}
		if Task.isCancelled { return .failed(.cancelled) }
		guard let identity = loadIdentity(account: account, team: team.identifier) else { return .failed(.noIdentity) }

		let authorization = ZagSigningAuthorization.developerAccount(
			scope: ZagSigningScope(accountID: account, teamID: team.identifier),
			teamKind: team.kind,
			validUntil: now().addingTimeInterval(authorizationLifetime)
		)
		let record: ZagSignedAppRecord
		do {
			record = try signer.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: now())
		} catch {
			return .failed(.signing)
		}
		if Task.isCancelled { return .failed(.cancelled) }
		do {
			try await installer.install(signedApp: app, bundleIdentifier: record.bundleIdentifier)
		} catch {
			return .failed(Task.isCancelled ? .cancelled : .install)
		}
		let expectation = ZagInstallExpectation(
			bundleIdentifier: record.bundleIdentifier,
			profileUUID: result.app.profile.uuid,
			profileExpiresAt: record.profileExpiresAt,
			certificateExpiresAt: record.certificateExpiresAt,
			signerCommonName: ZagCertificateInspection(der: identity.certificate)?.commonName,
			teamIdentifier: result.team,
			extensionProfileUUIDs: result.extensions.map(\.profile.uuid)
		)
		switch await installer.verify(expectation) {
		case .verified(let profileExpiresAt, let certificateExpiresAt):
			var confirmed = record
			confirmed.profileExpiresAt = profileExpiresAt
			confirmed.certificateExpiresAt = certificateExpiresAt
			confirmed.expiryVerified = true
			return .installed(confirmed)
		case .unverifiable:
			var unverified = record
			unverified.expiryVerified = false
			return .installedUnverified(unverified)
		case .mismatch, .notInstalled:
			return .failed(.notVerified)
		}
	}

	private func loadIdentity(account: UUID, team: String) -> ZagSigningIdentity? {
		(try? secrets.load(.signingPrivateKey, account: account, team: team))
			.flatMap { $0 }
			.flatMap { try? JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
	}
}
