#if canImport(SwiftUI)
import SwiftUI

/// A masked view of a candidate for display — never a full serial or fingerprint.
struct ZagReplacementCandidateView: Identifiable, Equatable {
	let id: String
	let maskedSerial: String
	let name: String
	let expires: Date?
	let isActiveProtected: Bool

	init(_ cert: ZagRevocableCertificate, activeGuard: ZagActiveCertificateGuard) {
		self.id = cert.id
		self.maskedSerial = "…" + String(cert.serialNumber.suffix(6))
		self.name = cert.name
		self.expires = cert.expiresAt
		self.isActiveProtected = activeGuard.classify(cert) == .activeProtected
	}
}

@MainActor
final class ZagCertificateReplacementModel: ObservableObject {
	@Published private(set) var inventory: [ZagReplacementCandidateView] = []
	@Published private(set) var rawInventory: [ZagRevocableCertificate] = []
	@Published private(set) var state: ZagCertificateReplacementState = .idle
	@Published private(set) var banner: String?
	@Published private(set) var busy = false

	/// A read-only session surfaces the inventory only; selection, revocation and
	/// CSR are not offered (and are blocked at the transport regardless).
	let readOnly: Bool

	private let driver: ZagCertificateReplacementDriver
	private let activeGuard: ZagActiveCertificateGuard
	/// The preserved device-generated CSR; supplied by the provisioner. The UI
	/// never sees the key — only this request object is passed through to submit.
	private let preservedCSR: (() -> ZagCertificateRequest?)?
	private let nativeScope: ZagSigningScope?
	var issuesCertificateHere: Bool { preservedCSR != nil }

	init(driver: ZagCertificateReplacementDriver, activeGuard: ZagActiveCertificateGuard,
		 readOnly: Bool = false, nativeScope: ZagSigningScope? = nil, preservedCSR: (() -> ZagCertificateRequest?)?) {
		self.driver = driver
		self.activeGuard = activeGuard
		self.readOnly = readOnly
		self.preservedCSR = preservedCSR
		self.nativeScope = nativeScope
	}

	func onAppear() async {
		if nativeScope == nil { await driver.recoverOnLaunch() }
		state = await driver.currentState()
		await refreshInventory()
	}

	func refreshInventory() async {
		guard !busy else { return }
		busy = true
		defer { busy = false }
		do {
			let certs = try await driver.inventory()
			rawInventory = certs
			inventory = certs.map { ZagReplacementCandidateView($0, activeGuard: activeGuard) }
			banner = nil
		} catch { banner = Self.describe(error) }
	}

	func select(_ view: ZagReplacementCandidateView) async {
		guard let cert = rawInventory.first(where: { $0.id == view.id }) else { return }
		do { try await driver.select(cert); state = await driver.currentState(); banner = nil }
		catch { banner = Self.describe(error) }
	}

	func confirmRevoke() async {
		guard !busy else { return }
		busy = true
		defer { busy = false }
		do {
			#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
			if let scope = nativeScope {
				try await ZagNativeAccountInstall.withExclusiveOperation {
					if case .selected(let target) = await driver.currentState(),
					   let identity = try Self.nativeIdentity(scope),
					   ZagActiveCertificateGuard.sameSerial(target.serialNumber, identity.serialNumber) {
						throw ZagReplacementError.targetNowActive
					}
					try await driver.confirmAndRevoke()
				}
			} else {
				try await driver.confirmAndRevoke()
			}
			#else
			try await driver.confirmAndRevoke()
			#endif
			banner = nil
		} catch {
			banner = Self.describe(error)
		}
		state = await driver.currentState()
	}

	func reconcile() async {
		guard !busy else { return }
		busy = true
		defer { busy = false }
		do { try await driver.reconcileAfterAmbiguousRevoke(); banner = nil }
		catch { banner = Self.describe(error) }
		state = await driver.currentState()
	}

	func authorizeAndSubmitCSR() async {
		guard let request = preservedCSR?() else { banner = "No preserved certificate request is available."; return }
		guard !busy else { return }
		busy = true
		defer { busy = false }
		do { _ = try await driver.authorizeAndSubmitCSR(request); banner = nil }
		catch { banner = Self.describe(error) }
		state = await driver.currentState()
	}

	static func inventory(team: String, expectedScope: ZagSigningScope? = nil) -> ZagCertificateReplacementModel {
		let consent = ZagMutationConsentCoordinator()
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		if let token = ZagDeveloperTokenStore().load(scope: "device"), token.isUsable(at: Date()),
		   case let scope = ZagSigningAuthorization.nativeAccount(token: token, teamID: team).scope,
		   expectedScope == nil || expectedScope == scope {
			let activeGuard = ZagActiveCertificateGuard(activeSHA1: nil, activeSerial: (try? nativeIdentity(scope))?.serialNumber)
			let portal = ZagNativeAccountInstall.portal(token: token, consent: consent)
			let driver = ZagCertificateReplacementDriver(
				portal: portal, consent: consent, activeGuard: activeGuard,
				journal: ZagInMemoryReplacementJournal(), team: team
			)
			return ZagCertificateReplacementModel(driver: driver, activeGuard: activeGuard, nativeScope: scope, preservedCSR: nil)
		}
		#endif
		let activeGuard = ZagActiveCertificateGuard(activeSHA1: nil, activeSerial: nil)
		#if canImport(ZagAppleAuth)
		let portal: ZagReplacementPortal = expectedScope == nil ? ZagNativeDeveloperPortal.readOnlyInventory() : ZagDisabledReplacementPortal()
		#else
		let portal: ZagReplacementPortal = ZagDisabledReplacementPortal()
		#endif
		let driver = ZagCertificateReplacementDriver(portal: portal, consent: consent,
			activeGuard: activeGuard, journal: ZagInMemoryReplacementJournal(), team: team)
		return ZagCertificateReplacementModel(driver: driver, activeGuard: activeGuard, readOnly: true, preservedCSR: nil)
	}

	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	private static func nativeIdentity(_ scope: ZagSigningScope) throws -> ZagSigningIdentity? {
		guard let data = try ZagNativeAccountInstall.secrets.load(.signingPrivateKey, account: scope.accountID, team: scope.teamID) else {
			return nil
		}
		return try JSONDecoder().decode(ZagSigningIdentity.self, from: data)
	}
	#endif

	static func describe(_ error: Error) -> String {
		guard let e = error as? ZagReplacementError else { return error.localizedDescription }
		switch e {
		case .notSelectable:          return "That step is not available from the current state."
		case .targetNoLongerPresent:  return "That certificate is no longer listed; the list was refreshed. Nothing was changed."
		case .fingerprintMismatch:    return "The certificate on file no longer matches what you selected. Revocation was refused. Nothing was changed."
		case .targetNowActive:        return "That certificate is now the one used for local signing, which is protected. Nothing was changed."
		case .listingUnavailable:     return "The certificate list could not be read, so no change was made."
		case .consentMissing:         return "The authorization for this step was not given."
		case .repeatedConflict:       return "Apple still reports an existing or pending certificate after the change. Freeing a slot did not resolve it."
		case .certificateLimitReached:return "Apple reports a certificate limit on this account."
		case .ambiguousRevoke:        return "The revocation result is unclear. Re-check the certificate list before doing anything else."
		case .ambiguousSubmission:    return "The request result is unclear. Re-check the certificate list before doing anything else."
		case .sessionRejected:        return "The Apple session was rejected. Sign in again."
		case .network(let reason):
			return reason.map { "The certificate list could not be read (\($0)). Nothing was changed." }
				?? "A network problem occurred. Nothing was changed."
		}
	}
}

struct ZagCertificateReplacementView: View {
	@StateObject var model: ZagCertificateReplacementModel
	var onRevoked: (() -> Void)? = nil
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		List {

			if let banner = model.banner {
				Section { Text(banner).font(.footnote).foregroundStyle(.orange) }
			}
			if model.readOnly {
				inventorySection
			} else {
			switch model.state {
			case .idle, .selected, .abandoned:
				inventorySection
				if case .selected(let t) = model.state { revokeConfirmationSection(target: t) }
			case .revokeConfirmed, .revoking:
				Section { ProgressView("Revoking…") }
			case .revoked:
				if model.issuesCertificateHere {
					csrAuthorizationSection
				} else {
					Section { Label("Certificate revoked. Return to Sign App to request a certificate and continue.", systemImage: "checkmark.seal") }
				}
			case .revokeHalted(_, let reason):
				reconciliationSection(reason: reason)
			case .csrAuthorized, .submitting:
				Section { ProgressView("Submitting the certificate request…") }
			case .completed:
				Section { Label("A new certificate was requested. Verify it before signing.", systemImage: "checkmark.seal") }
			case .submissionUnconfirmed:
				Section {
					Label("The request outcome is unconfirmed.", systemImage: "questionmark.circle")
					Text("Re-check the certificate list; do not submit again until it is reconciled.").font(.footnote).foregroundStyle(.secondary)
				}
			}
			}
		}
		.navigationTitle("Development Certificates")
		.task { await model.onAppear() }
		.onChange(of: model.state) { state in
			guard case .revoked = state, let onRevoked else { return }
			dismiss()
			onRevoked()
		}
	}

	private var inventorySection: some View {
		Section("Development certificates") {
			if model.busy && model.inventory.isEmpty {
				ProgressView("Loading certificates…")
			} else if model.inventory.isEmpty && model.banner == nil {
				Text("No certificates are listed.").foregroundStyle(.secondary)
			}
			if !model.rawInventory.isEmpty {
				let available = model.rawInventory.filter { $0.sha1 != nil }.count
				Text("Apple supplied certificate data for \(available) of \(model.rawInventory.count) entries in this list.")
					.font(.footnote).foregroundStyle(.secondary)
			}
			ForEach(model.inventory) { cert in
				VStack(alignment: .leading, spacing: 4) {
					HStack {
						Text(cert.name).font(.subheadline.weight(.medium))
						if cert.isActiveProtected {
							Text("IN USE — PROTECTED").font(.caption2.weight(.bold)).foregroundStyle(.green)
						}
					}
					Text("Serial \(cert.maskedSerial)").font(.caption).foregroundStyle(.secondary)
					if let exp = cert.expires { Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
					if !cert.isActiveProtected {
						Text("Revoking this certificate may prevent apps signed with it from opening.")
							.font(.caption2).foregroundStyle(.orange)
						if !model.readOnly {
							Button("Select for replacement") { Task { await model.select(cert) } }
								.buttonStyle(.bordered).controlSize(.small)
						}
					}
				}
			}
			Button { Task { await model.refreshInventory() } } label: { Label("Refresh list", systemImage: "arrow.clockwise") }
				.disabled(model.busy)
		}
	}

	private func revokeConfirmationSection(target: ZagReplacementTarget) -> some View {
		Section("Confirm revocation") {
			Text("Revoking certificate …\(String(target.serialNumber.suffix(6))) is permanent. Apps signed with it may stop opening.")
				.font(.footnote)
			Button(role: .destructive) { Task { await model.confirmRevoke() } } label: {
				Text("Revoke this certificate")
			}.disabled(model.busy)
		}
	}

	private var csrAuthorizationSection: some View {
		Section("Request a new certificate") {
			Text("The certificate was revoked. Requesting a new one is a separate, explicit step and uses the signing key already on this iPhone. It may still be refused if Apple considers the account at its limit.")
				.font(.footnote)
			Button { Task { await model.authorizeAndSubmitCSR() } } label: {
				Text("Authorize and request a certificate")
			}.disabled(model.busy)
		}
	}

	private func reconciliationSection(reason: ZagReplacementHalt) -> some View {
		Section("Re-check required") {
			Text(reason == .revokeFailed
				 ? "The revocation was refused. Nothing changed."
				 : "The revocation result is unclear. Re-check the certificate list before doing anything else — do not request a certificate until this is resolved.")
				.font(.footnote)
			if reason != .revokeFailed {
				Button { Task { await model.reconcile() } } label: { Label("Re-check the certificate list", systemImage: "arrow.clockwise") }
					.disabled(model.busy)
			}
		}
	}
}
#endif
