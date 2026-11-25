#if canImport(SwiftUI)
import SwiftUI

// User-facing native workflow for certificate replacement. Experimental and
// gated (ZAG_CERT_REPLACEMENT_EXPERIMENT): it drives ZagCertificateReplacementDriver,
// which is itself live only behind the disabled portal. Every screen is derived
// from the coordinator state, so the UI can never present a step the state
// machine has not reached. The two mutations are two separate buttons, each
// behind its own confirmation; the UI never claims replacement is guaranteed to
// resolve 7460.

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
	private let preservedCSR: () -> ZagCertificateRequest?

	init(driver: ZagCertificateReplacementDriver, activeGuard: ZagActiveCertificateGuard,
		 readOnly: Bool = false, preservedCSR: @escaping () -> ZagCertificateRequest?) {
		self.driver = driver
		self.activeGuard = activeGuard
		self.readOnly = readOnly
		self.preservedCSR = preservedCSR
	}

	func onAppear() async {
		await driver.recoverOnLaunch()
		state = await driver.currentState()
		await refreshInventory()
	}

	func refreshInventory() async {
		busy = true; defer { busy = false }
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
		busy = true; defer { busy = false }
		do { try await driver.confirmAndRevoke(); banner = nil }
		catch { banner = Self.describe(error) }
		state = await driver.currentState()
	}

	func reconcile() async {
		busy = true; defer { busy = false }
		do { try await driver.reconcileAfterAmbiguousRevoke(); banner = nil }
		catch { banner = Self.describe(error) }
		state = await driver.currentState()
	}

	func authorizeAndSubmitCSR() async {
		guard let request = preservedCSR() else { banner = "No preserved certificate request is available."; return }
		busy = true; defer { busy = false }
		do { _ = try await driver.authorizeAndSubmitCSR(request); banner = nil }
		catch { banner = Self.describe(error) }
		state = await driver.currentState()
	}

	/// The gated Settings entry point. In the default experimental build the
	/// portal is the DISABLED portal (no live contact possible). When the
	/// read-only live flag is set and the Apple-auth bridge is present, the
	/// portal is the native read-only portal: inventory can run, but revoke and
	/// CSR are blocked at the transport boundary. The screen is marked read-only
	/// so it never offers a mutation.
	static func gatedPreview(team: String = "") -> ZagCertificateReplacementModel {
		let guard0 = ZagActiveCertificateGuard(activeSHA1: nil, activeSerial: nil)
		let portal: ZagReplacementPortal
		var readOnly = false
		#if canImport(ZagAppleAuth)
		// The native bridge is linked (standard device build): connect to the REAL
		// developer-services portal, wrapped in the read-only transport so the
		// certificate inventory is live-capable while every mutating endpoint
		// (revoke, CSR) is blocked below the UI — not merely hidden. The portal
		// also fails closed without a signed-in developer session, so opening this
		// screen never mutates Apple state. This replaces the former disabled
		// preview: the inventory is connected to real services, read-only.
		portal = ZagNativeDeveloperPortal.readOnlyInventory()
		readOnly = true
		#else
		// No native bridge (e.g. a simulator build): a disabled portal that cannot
		// reach Apple at all.
		portal = ZagDisabledReplacementPortal()
		#endif
		let driver = ZagCertificateReplacementDriver(
			portal: portal, consent: ZagMutationConsentCoordinator(),
			activeGuard: guard0, journal: ZagInMemoryReplacementJournal(), team: team)
		return ZagCertificateReplacementModel(driver: driver, activeGuard: guard0, readOnly: readOnly, preservedCSR: { nil })
	}

	static func describe(_ error: Error) -> String {
		guard let e = error as? ZagReplacementError else { return "The step could not be completed." }
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
		case .network:                return "A network problem occurred. Nothing was changed."
		}
	}
}

struct ZagCertificateReplacementView: View {
	@StateObject var model: ZagCertificateReplacementModel

	var body: some View {
		List {
			disclaimerSection
			if model.readOnly {
				Section {
					Label("Read-only session", systemImage: "lock.shield")
					Text("This session can only read the certificate list. Revoking a certificate and requesting a new one are disabled and cannot be sent — not just hidden here, but blocked before any request leaves this iPhone.")
						.font(.footnote).foregroundStyle(.secondary)
				}
			}
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
				csrAuthorizationSection
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
		.navigationTitle(model.readOnly ? "Certificate inventory" : "Replace a certificate")
		.task { await model.onAppear() }
	}

	private var disclaimerSection: some View {
		Section {
			Text("Some Apple Accounts already have the maximum number of development certificates. Replacing one may let a new request succeed, but it is not guaranteed to — Apple may still refuse. Nothing is revoked or requested without your explicit confirmation at each step.")
				.font(.footnote).foregroundStyle(.secondary)
		}
	}

	private var inventorySection: some View {
		Section("Development certificates") {
			if model.inventory.isEmpty { Text("No certificates are listed.").foregroundStyle(.secondary) }
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
						Text("This iPhone has no key for this certificate; its usage is unknown. Revoking it may break any app or workflow that relies on it.")
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
			Text("You chose certificate …\(String(target.serialNumber.suffix(6))). This will permanently revoke it. Because this iPhone has no key for it and its usage is unknown, anything still relying on it will stop working. This cannot be undone.")
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
