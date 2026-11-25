#if canImport(SwiftUI)
import SwiftUI

// Option B — the standalone native Apple Account sign-in. This path drives the
// authoritative native engine (ZagAppleAuthMachine): its own on-device ADI
// anisette, its own GrandSlam SRP + interactive two-factor (via the existing
// ZagTwoFactorCoordinator), its own developer-session persistence, and the
// read-only Developer Services inventory (ZagNativeDeveloperPortal). It has NO
// dependency on ZagIsideloadAuthenticationService or a remote anisette server:
// the bridge (zag_bridge_*) is never touched here.
//
// The session token stays in the machine's own Keychain and is never exported
// to this model, to the directory, or to any caller. "Signed in" means the
// machine holds a valid developer session; its validity is re-checked through
// ZagAppleAuthMachine.developerHeaders(), never by holding the token.
//
// Device-only: ZagAppleAuthMachine.signInWith2FA is backed by the ZagAppleAuth
// xcframework, present only in the physical-iPhone build. Off-device the engine
// is `unavailable` and this model reports exactly that; the controller selects
// this native model only when ZagAppleAuthMachine.isLinked.

// MARK: - The native sign-in model

@MainActor
final class ZagNativeSignInModel: ObservableObject {
	@Published var appleID = ""
	@Published var password = ""
	@Published var code = ""
	@Published private(set) var phase: ZagNativeSignInPhase = .signedOut
	@Published private(set) var failure: ZagNativeSignInFailure?
	@Published private(set) var isBusy = false
	@Published private(set) var phoneChoices: [ZagTwoFactorCoordinator.PhoneChoice] = []
	@Published private(set) var teams: [ZagDeveloperTeam] = []
	@Published private(set) var notice: String?

	private let machine: ZagAppleAuthMachine
	private var coordinator = ZagTwoFactorCoordinator()
	private var stageObservation: Task<Void, Never>?
	private var runTask: Task<Void, Never>?

	init(machine: ZagAppleAuthMachine = ZagAppleAuthMachine.nativeAccount()) {
		self.machine = machine
	}

	var canSubmitCredentials: Bool {
		!isBusy && !appleID.isEmpty && password.count >= 4 && (phase == .signedOut || phase == .failed)
	}
	var canSubmitCode: Bool { !isBusy && phase == .awaitingCode && code.count >= 4 }

	/// Restores a prior signed-in state with no network: if the machine still
	/// holds a usable developer session, we are signed in. The token itself is
	/// never read into this model — only its validity.
	func restore() async {
		if await machine.developerHeaders() != nil {
			phase = .signedIn
			await refreshInventory()
		}
	}

	func signIn() async {
		guard canSubmitCredentials else { return }
		failure = nil
		notice = nil
		// Native Apple Account sign-in is a standard Zag Store feature. Pressing
		// Sign In is the owner's consent to authenticate and to the one-time
		// on-device ADI provisioning it needs. No campaign arming, expiry, nonce
		// or experiment build is involved. It stays standalone: on-device ADI
		// only, never a remote anisette server, and it reaches Apple's GrandSlam
		// and Developer Services read-only — it signs, installs, issues and
		// revokes nothing (irreversible certificate operations keep their own
		// separate consent elsewhere).
		isBusy = true
		phase = .authenticating
		coordinator = ZagTwoFactorCoordinator()
		observeStage()

		#if canImport(ZagAppleAuth)
		// On-device ADI provisioning. signInWith2FA requires a provisioned
		// machine; provisioning happens here, once, if it has not already.
		// Pressing Sign In is the consent. This contacts only Apple's ADI
		// endpoint to identify this iPhone — it signs, installs, issues and
		// revokes nothing — and it leaves all other app data intact.
		// Always refresh the on-device ADI session through the provisioning
		// transport (not the gated sign-in transport) before authenticating. This
		// rewrites the stored ADI state so the sign-in's own provisioning step
		// derives its one-time password locally and issues no gated network
		// request. A stale profile (e.g. upgraded from an earlier build) would
		// otherwise force that request onto the gated transport, where it is
		// refused before any password is sent. The round-trip is local and fast
		// once provisioned; the first time it establishes this iPhone's identity.
		let firstTime = !(await machine.isProvisioned())
		notice = firstTime ? "Setting up this iPhone with Apple (one-time)…" : "Preparing this iPhone…"
		do {
			_ = try await machine.anisetteHeaders(allowProvisioning: true)
			notice = nil
		} catch let error as ZagAppleAuthError {
			finish(failure: ZagNativeSignInClassifier.failure(error: error))
			return
		} catch {
			finish(failure: ZagNativeSignInFailure(message: "On-device setup with Apple could not complete.", recovery: .provisionADI))
			return
		}
		#endif

		let email = appleID
		let secret = password
		password = ""   // do not retain the plaintext past hand-off

		let report: ZagAppleAuthSignInReport
		do {
			report = try await machine.signInWith2FA(email: email, password: secret,
													 coordinator: coordinator,
													 allowNetwork: true,
													 includeDeveloperSession: true)
		} catch let error as ZagAppleAuthError {
			finish(failure: ZagNativeSignInClassifier.failure(error: error))
			return
		} catch {
			finish(failure: ZagNativeSignInFailure(message: "Sign-in could not complete.", recovery: .retry))
			return
		}

		if coordinator.didCancel {
			finish(failure: nil)   // user cancelled; quietly return to signed-out
			return
		}
		let developerOK = report.developerOutcome == .ok
		if let f = ZagNativeSignInClassifier.failure(report: report, developerOK: developerOK) {
			finish(failure: f)
			return
		}
		// Success: the session lives in the machine's Keychain. Read the
		// read-only inventory; absence of teams is not a sign-in failure.
		await refreshInventory()
		finishSignedIn()
	}

	func submitCode() async {
		guard canSubmitCode else { return }
		let entered = code
		code = ""
		coordinator.submitCode(entered)
	}

	func grantConsent(_ granted: Bool) { coordinator.resolveConsent(granted) }
	func selectPhone(_ id: Int64?) { coordinator.resolvePhone(id) }

	func requestCodeBySMS() {
		// The engine follows the account's configured method automatically; an
		// explicit SMS request is surfaced only when Apple offered a choice.
		notice = "Apple decides the delivery method for this account."
	}

	func cancel() {
		coordinator.cancel()
		runTask?.cancel()
		finish(failure: nil)
	}

	func signOut() async {
		// Leaves the machine profile intact (that is the ADI provisioning, not
		// the session). Only the developer token is forgotten, which is what
		// developerHeaders() checks — so the model reads as signed out. The
		// model always uses the default "device" scope machine.
		try? ZagDeveloperTokenStore().delete(scope: "device")
		teams = []
		notice = nil
		phase = .signedOut
	}

	// MARK: - Internals

	private func observeStage() {
		stageObservation?.cancel()
		let coordinator = self.coordinator
		stageObservation = Task { @MainActor [weak self] in
			for await stage in coordinator.$stage.values {
				guard let self else { return }
				// Only reflect live intermediate stages, and never override a
				// terminal phase: once signIn() has finished (success or failure)
				// a late/buffered stage value must not resurrect "Signing in…"
				// alongside the result. finish()/finishSignedIn() cancel this
				// task; this guard closes the buffered-value race on top of that.
				if Task.isCancelled || self.phase == .failed || self.phase == .signedIn { continue }
				switch stage {
				case .idle:            self.phase = .signedOut
				case .authenticating:  self.phase = .authenticating
				case .awaitingConsent: self.phase = .awaitingConsent
				case .selectingPhone:  self.phase = .selectingPhone
				case .awaitingCode:    self.phase = .awaitingCode
				case .submitting:      self.phase = .submitting
				case .finished, .cancelled: continue
				}
				if case .selectingPhone(let choices) = stage { self.phoneChoices = choices }
			}
		}
	}

	private func refreshInventory() async {
		// The read-only Developer Services inventory exists only in the native
		// (xcframework) build; off-device there is nothing to read.
		#if canImport(ZagAppleAuth)
		let native = ZagNativeDeveloperPortal.readOnlyInventory(machine: machine)
		if let discovered = try? await native.teams() {
			teams = discovered.map {
				ZagDeveloperTeam(identifier: $0.teamID, name: $0.name,
								 kind: $0.type == nil || $0.type == "individual" ? .personalFree : .individualPaid)
			}
		}
		#endif
	}

	private func finish(failure: ZagNativeSignInFailure?) {
		isBusy = false
		stageObservation?.cancel()
		notice = nil
		self.failure = failure
		phase = failure == nil ? .signedOut : .failed
	}

	private func finishSignedIn() {
		isBusy = false
		stageObservation?.cancel()
		notice = nil
		failure = nil
		phase = .signedIn
	}
}

// MARK: - The native sign-in screen

struct ZagNativeAccountSignInContent: View {
	@ObservedObject var model: ZagNativeSignInModel
	@FocusState private var focus: Field?
	private enum Field { case appleID, password }

	var body: some View {
		Form {
			statusSection
			switch model.phase {
			case .signedIn: sessionSection
			default:        credentialsSection
			}
			if let failure = model.failure { failureSection(failure) }
			else if let notice = model.notice {
				Section { Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
			}
			disclaimerSection
		}
		.sheet(isPresented: Binding(
			get: { model.phase == .awaitingCode || model.phase == .awaitingConsent || model.phase == .selectingPhone },
			set: { shown in if !shown { Task { model.cancel() } } }
		)) { interactiveSheet }
	}

	private var statusSection: some View {
		Section {
			HStack(spacing: 12) {
				Image(systemName: statusIcon).font(.title2).foregroundStyle(statusColor).frame(width: 30)
				VStack(alignment: .leading, spacing: 2) {
					Text(statusTitle).font(.headline)
					Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
				}
				if model.isBusy { Spacer(); ProgressView() }
			}
		}
	}

	private var credentialsSection: some View {
		Section("Sign in with your Apple Account") {
			TextField("Apple Account", text: $model.appleID)
				.keyboardType(.emailAddress).textContentType(.username)
				.textInputAutocapitalization(.never).autocorrectionDisabled()
				.focused($focus, equals: .appleID).submitLabel(.next)
				.onSubmit { focus = .password }
			SecureField("Password", text: $model.password)
				.textContentType(.password)
				.focused($focus, equals: .password).submitLabel(.go)
				.onSubmit { if model.canSubmitCredentials { Task { await model.signIn() } } }
			Button {
				focus = nil
				Task { await model.signIn() }
			} label: {
				HStack { Spacer(); Text("Sign In").fontWeight(.semibold); Spacer() }
			}
			.disabled(!model.canSubmitCredentials)
		}
	}

	private func failureSection(_ failure: ZagNativeSignInFailure) -> some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text(failure.message).font(.footnote)
					if !failure.recoveryText.isEmpty {
						Text(failure.recoveryText).font(.caption).foregroundStyle(.secondary)
					}
					if let detail = failure.detail, !detail.isEmpty {
						Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
					}
				}
			} icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
		} header: { Text("Why sign-in did not complete") }
	}

	private var sessionSection: some View {
		Section("Session") {
			Label("Signed in. The developer session is held in this iPhone's Keychain.", systemImage: "checkmark.seal")
				.font(.footnote).foregroundStyle(.green)
			if !model.teams.isEmpty {
				ForEach(model.teams, id: \.identifier) { team in
					LabeledContent(team.name, value: team.identifier).font(.footnote)
				}
			}
			Button(role: .destructive) { Task { await model.signOut() } } label: { Text("Sign Out") }
				.disabled(model.isBusy)
		}
	}

	private var disclaimerSection: some View {
		Section {} footer: {
			Text("Your Apple Account password, two-factor codes and developer token stay on this iPhone and are never logged. Authentication is performed on-device; nothing is revoked, signed or installed from this screen.")
		}
	}

	@ViewBuilder private var interactiveSheet: some View {
		NavigationStack {
			Form {
				switch model.phase {
				case .awaitingConsent:
					Section {
						Text("Apple will send a verification code to your trusted devices or phone number.").font(.footnote)
						Button("Send Code") { model.grantConsent(true) }
					}
				case .selectingPhone:
					Section("Choose where to receive the code") {
						ForEach(model.phoneChoices) { choice in
							Button(choice.display) { model.selectPhone(choice.id) }
						}
					}
				case .awaitingCode:
					Section {
						TextField("Verification code", text: $model.code)
							.keyboardType(.numberPad).textContentType(.oneTimeCode)
					} header: { Text("Two-Factor") }
				default:
					EmptyView()
				}
			}
			.navigationTitle("Verification")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
				if model.phase == .awaitingCode {
					ToolbarItem(placement: .confirmationAction) {
						Button("Verify") { Task { await model.submitCode() } }.disabled(!model.canSubmitCode)
					}
				}
			}
		}
		.presentationDetents([.medium])
	}

	private var statusIcon: String {
		switch model.phase {
		case .signedIn:   return "person.crop.circle.badge.checkmark"
		case .failed:     return "person.crop.circle.badge.exclamationmark"
		case .awaitingCode, .awaitingConsent, .selectingPhone: return "ellipsis.bubble"
		default:          return "person.crop.circle"
		}
	}
	private var statusColor: Color {
		switch model.phase {
		case .signedIn: return .green
		case .failed:   return .orange
		default:        return .accentColor
		}
	}
	private var statusTitle: String {
		switch model.phase {
		case .signedOut:       return "Not signed in"
		case .authenticating:  return "Signing in…"
		case .awaitingConsent: return "Confirm delivery"
		case .selectingPhone:  return "Choose a number"
		case .awaitingCode:    return "Enter your code"
		case .submitting:      return "Verifying…"
		case .signedIn:        return "Signed in"
		case .failed:          return "Sign-in failed"
		}
	}
	private var statusDetail: String {
		switch model.phase {
		case .signedIn: return "Personal Team and certificate inventory are available."
		case .failed:   return model.failure?.message ?? "Sign-in did not complete."
		default:        return "Native on-device authentication — no external server is used."
		}
	}
}
#endif
