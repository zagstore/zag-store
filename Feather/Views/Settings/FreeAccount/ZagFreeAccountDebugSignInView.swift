#if DEBUG
import SwiftUI

// Debug builds only: the Apple Account sign-in screen driven by the real
// authenticator against simulated services. Release builds compile none of
// this file and show no entry point.

/// Owns the simulated service, clock and sign-in model for the screen.
@MainActor
final class ZagFreeAccountDebugLab: ObservableObject {
	let clock = ZagSimulationClock()
	let service: ZagSimulatedAuthenticationService
	let model: ZagFreeAccountSignInModel
	@Published var scenario: ZagFreeAccountSimulation.Scenario = .trustedDeviceCode {
		didSet { Task { await service.setScenario(scenario) } }
	}

	init() {
		service = ZagSimulatedAuthenticationService(scenario: .trustedDeviceCode, clock: clock)
		let diagnostics = ZagFreeAccountDiagnostics()
		model = ZagFreeAccountSignInModel(
			authenticator: ZagFreeAccountSimulation.makeAuthenticator(service: service, clock: clock, diagnostics: diagnostics),
			diagnostics: diagnostics
		)
	}

	/// Changes the scenario and waits until the service uses it.
	func select(_ scenario: ZagFreeAccountSimulation.Scenario) async {
		await service.setScenario(scenario)
		self.scenario = scenario
	}

	func fillSyntheticAccount() {
		model.appleID = ZagFreeAccountSimulation.appleID
		model.password = ZagFreeAccountSimulation.password
	}

	/// Apple stops accepting the stored session (as after a password change).
	func revokeSession() async {
		await service.setRejectsSessions(true)
		await model.checkSession()
	}

	/// Jumps 31 days ahead and relaunches, past the 30-day session expiry.
	func relaunchAfter31Days() async {
		clock.advance(31 * 86_400)
		await model.restore()
	}
}

struct ZagFreeAccountDebugSignInView: View {
	@StateObject private var lab = ZagFreeAccountDebugLab()
	var runsDemo = false

	var body: some View {
		ZagFreeAccountDebugSignInContent(lab: lab, model: lab.model)
			.task {
				await lab.model.restore()
				if runsDemo { await ZagFreeAccountDebugDemo(lab: lab).run() }
			}
	}
}

private struct ZagFreeAccountDebugSignInContent: View {
	@ObservedObject var lab: ZagFreeAccountDebugLab
	@ObservedObject var model: ZagFreeAccountSignInModel
	@AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
	@FocusState private var focusedField: Field?

	private enum Field { case appleID, password }

	private var tint: Color { ZagWideGamutTint.color(hex: tintHex) }

	var body: some View {
		Form {
			Section {
				ZagFreeAccountStatusCard(model: model, tint: tint)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
			}

			switch model.phase {
			case .signedIn, .expired:
				sessionSection
			default:
				credentialsSection
			}

			if let notice = model.notice {
				Section {
					Label(notice, systemImage: "exclamationmark.circle")
						.foregroundStyle(.orange)
						.accessibilityIdentifier("freeAccount.notice")
				}
			}

			simulationSection
			diagnosticsSection
		}
		.navigationTitle("Apple Account")
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.sheet(isPresented: Binding(
			get: { model.prompt != nil },
			set: { presented in
				if !presented, model.prompt != nil { Task { await model.cancel() } }
			}
		)) {
			ZagFreeAccountCodeSheet(model: model, tint: tint)
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var credentialsSection: some View {
		Section {
			TextField("Apple Account", text: $model.appleID, prompt: Text("name\(ZagFreeAccountSimulation.accountDomain)"))
				.textContentType(nil)
				.keyboardType(.emailAddress)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.focused($focusedField, equals: .appleID)
				.submitLabel(.next)
				.onSubmit { focusedField = .password }
				.disabled(model.isBusy)
				.accessibilityIdentifier("freeAccount.appleID")
			SecureField("Password", text: $model.password)
				.textContentType(nil)
				.privacySensitive()
				.focused($focusedField, equals: .password)
				.submitLabel(.go)
				.onSubmit { Task { await model.signIn() } }
				.disabled(model.isBusy)
				.accessibilityIdentifier("freeAccount.password")
		} header: {
			Text("Sign In")
		}

		Section {
			if model.isBusy {
				HStack(spacing: 12) {
					ProgressView()
					Text("Signing In…").foregroundStyle(.secondary)
					Spacer()
					Button("Cancel", role: .cancel) { Task { await model.cancel() } }
						.accessibilityIdentifier("freeAccount.cancel")
				}
			} else {
				ZagFreeAccountPrimaryButton(title: model.phase == .failed ? "Try Again" : "Sign In", enabled: model.canSubmitCredentials) {
					focusedField = nil
					Task { await model.signIn() }
				}
				.listRowBackground(Color.clear)
				.listRowInsets(EdgeInsets())
			}
		} footer: {
			Text("Your password is used only while signing in and is never stored. Only the session is kept, in this device's Keychain.")
		}
	}

	@ViewBuilder
	private var sessionSection: some View {
		if let session = model.state.session {
			Section {
				LabeledContent("Apple Account", value: session.maskedAppleID)
				LabeledContent("Team", value: session.team.name)
				LabeledContent("Team ID", value: session.team.identifier)
				if let expiresAt = session.expiresAt {
					LabeledContent("Session Expires") {
						Text(expiresAt, style: .date)
					}
				}
			} header: {
				Text("Account")
			}

			if model.phase == .expired {
				Section {
					ZagFreeAccountPrimaryButton(title: "Sign In Again", enabled: true) {
						Task { await model.signOut() }
					}
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets())
				}
			}

			Section {
				if model.phase != .expired {
					Button {
						Task { await model.checkSession() }
					} label: {
						Label("Check Session", systemImage: "arrow.triangle.2.circlepath")
					}
					.disabled(model.isBusy)
				}
				Button(role: .destructive) {
					Task { await model.signOut() }
				} label: {
					Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
				}
				.accessibilityIdentifier("freeAccount.signOut")
			} footer: {
				Text("Signing out removes the session from this device's Keychain.")
			}
		}
	}

	private var simulationSection: some View {
		Section {
			Picker("Apple Responds", selection: $lab.scenario) {
				ForEach(ZagFreeAccountSimulation.Scenario.allCases) { scenario in
					Text(scenario.title).tag(scenario)
				}
			}
			.disabled(model.isBusy)
			Button {
				lab.fillSyntheticAccount()
			} label: {
				Label("Fill Test Account", systemImage: "person.text.rectangle")
			}
			.disabled(model.isBusy || model.phase == .signedIn)
			Button {
				Task { await lab.revokeSession() }
			} label: {
				Label("Revoke Session", systemImage: "xmark.seal")
			}
			.disabled(model.phase != .signedIn || model.isBusy)
			Button {
				Task { await lab.relaunchAfter31Days() }
			} label: {
				Label("Relaunch 31 Days Later", systemImage: "calendar.badge.clock")
			}
			.disabled(model.phase != .signedIn || model.isBusy)
		} header: {
			Label("Simulation", systemImage: "testtube.2")
		} footer: {
			Text("Debug build only. Nothing leaves this device: Apple and anisette are simulated. Only \(ZagFreeAccountSimulation.accountDomain) addresses are accepted, with the password \"\(ZagFreeAccountSimulation.password)\" and the code \(ZagFreeAccountSimulation.verificationCode). Never enter a real Apple Account here.")
		}
	}

	private var diagnosticsSection: some View {
		Section {
			if model.diagnosticEntries.isEmpty {
				Text("No events yet").foregroundStyle(.secondary)
			}
			ForEach(Array(model.diagnosticEntries.suffix(8).reversed().enumerated()), id: \.offset) { _, entry in
				VStack(alignment: .leading, spacing: 2) {
					Text(entry.message).font(.footnote)
					Text(entry.at, style: .time).font(.caption2).foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Diagnostics")
		} footer: {
			Text("Redacted. Passwords, codes and session tokens are never recorded.")
		}
	}
}

// MARK: - Components

private struct ZagFreeAccountStatusCard: View {
	@ObservedObject var model: ZagFreeAccountSignInModel
	let tint: Color

	private var symbol: String {
		switch model.phase {
		case .signedOut: return "person.crop.circle.badge.plus"
		case .working: return "person.crop.circle.badge.clock"
		case .awaitingCode: return "lock.shield"
		case .signedIn: return "person.crop.circle.badge.checkmark"
		case .expired: return "person.crop.circle.badge.exclamationmark"
		case .failed: return "person.crop.circle.badge.xmark"
		}
	}

	private var colour: Color {
		switch model.phase {
		case .signedIn: return .green
		case .expired: return .orange
		case .failed: return .red
		default: return tint
		}
	}

	private var title: String {
		if model.isBusy, model.phase != .awaitingCode { return "Signing In…" }
		switch model.phase {
		case .signedOut: return "Not Signed In"
		case .working: return "Signing In…"
		case .awaitingCode: return "Verification Required"
		case .signedIn: return "Signed In"
		case .expired: return "Session Expired"
		case .failed: return "Sign-In Failed"
		}
	}

	private var detail: String {
		switch model.state {
		case .signedOut: return "Sign in with a free Apple Account to sign apps with your Personal Team."
		case .authenticating: return "Contacting the simulated Apple service."
		case .awaitingTwoFactor: return "Enter the verification code to finish signing in."
		case .signedIn(let session): return "\(session.maskedAppleID) · \(session.team.name)"
		case .sessionExpired: return "Apple no longer accepts this session. Sign in again to keep signing apps."
		case .failed(let failure): return "\(failure.message) \(failure.recovery)."
		}
	}

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: symbol)
				.font(.system(size: 34, weight: .regular))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(colour)
				.frame(width: 44)
				.contentTransition(.opacity)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text(title).font(.headline)
					Text("SIMULATED")
						.font(.caption2.weight(.bold))
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.foregroundStyle(.orange)
						.background(Color.orange.opacity(0.15), in: Capsule())
				}
				Text(detail)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.padding(16)
		.zagFreeAccountGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.animation(.snappy, value: model.phase)
		.accessibilityElement(children: .combine)
		.accessibilityIdentifier("freeAccount.status")
	}
}

private struct ZagFreeAccountPrimaryButton: View {
	let title: String
	let enabled: Bool
	let action: () -> Void

	var body: some View {
		if #available(iOS 26, *) {
			Button(action: action) {
				Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
			}
			.buttonStyle(.glassProminent)
			.disabled(!enabled)
		} else {
			Button(action: action) {
				Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
			}
			.buttonStyle(.borderedProminent)
			.disabled(!enabled)
		}
	}
}

private struct ZagFreeAccountCodeSheet: View {
	@ObservedObject var model: ZagFreeAccountSignInModel
	let tint: Color
	@FocusState private var focused: Bool

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				if let prompt = model.prompt {
					Image(systemName: "lock.shield")
						.font(.system(size: 44))
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(tint)
					Text(prompt.message)
						.multilineTextAlignment(.center)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					TextField("Code", text: $model.code)
						.keyboardType(.numberPad)
						.textContentType(.oneTimeCode)
						.font(.system(size: 30, weight: .semibold, design: .monospaced))
						.multilineTextAlignment(.center)
						.padding(.vertical, 12)
						.zagFreeAccountGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
						.focused($focused)
						.disabled(model.isBusy)
						.accessibilityIdentifier("freeAccount.code")
					if prompt.isRetry {
						Text("That code was not accepted. \(prompt.attemptsRemaining) \(prompt.attemptsRemaining == 1 ? "attempt" : "attempts") left.")
							.font(.footnote)
							.foregroundStyle(.red)
					}
					if let notice = model.notice {
						Text(notice).font(.footnote).foregroundStyle(.orange)
					}
					if model.isBusy {
						ProgressView("Verifying…")
					} else {
						ZagFreeAccountPrimaryButton(title: "Verify", enabled: model.canSubmitCode) {
							Task { await model.submitCode() }
						}
						if let alternative = prompt.alternativeAction {
							Button(alternative) { Task { await model.requestCodeBySMS() } }
								.font(.subheadline)
						}
					}
				}
				Spacer(minLength: 0)
			}
			.padding(24)
			.navigationTitle(model.prompt?.title ?? "Verification Code")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { Task { await model.cancel() } }
						.accessibilityIdentifier("freeAccount.codeCancel")
				}
			}
			.onAppear { focused = true }
		}
		.presentationDetents([.medium, .large])
		.interactiveDismissDisabled()
	}
}

private extension View {
	@ViewBuilder
	func zagFreeAccountGlass<S: Shape>(in shape: S) -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(.regular, in: shape)
		} else {
			self.background(.ultraThinMaterial, in: shape)
		}
	}
}

// MARK: - Launch hook and scripted demo

/// `-ZagFreeAccountDebugSignIn` opens the screen at launch;
/// `-ZagFreeAccountDebugDemo` also plays the scripted walkthrough used for
/// screenshots and the simulator UI test.
struct ZagFreeAccountDebugLaunchHook: ViewModifier {
	@State private var presented = ProcessInfo.processInfo.arguments.contains("-ZagFreeAccountDebugSignIn")
		|| ProcessInfo.processInfo.arguments.contains("-ZagFreeAccountDebugDemo")

	func body(content: Content) -> some View {
		content.fullScreenCover(isPresented: $presented) {
			NavigationStack {
				ZagFreeAccountDebugSignInView(runsDemo: ProcessInfo.processInfo.arguments.contains("-ZagFreeAccountDebugDemo"))
					.toolbar {
						ToolbarItem(placement: .topBarTrailing) {
							Button { presented = false } label: { Image(systemName: "xmark") }
								.accessibilityLabel("Close")
						}
					}
			}
		}
	}
}

/// Plays the flow through the same model calls the buttons make, typing
/// synthetic values only. Each step is written to a log in the app's
/// temporary directory so the UI test can take a screenshot and check it.
@MainActor
struct ZagFreeAccountDebugDemo {
	static let logName = "zag-free-account-demo.log"
	let lab: ZagFreeAccountDebugLab
	private var model: ZagFreeAccountSignInModel { lab.model }

	private func step(_ name: String, hold seconds: Double = 2.5) async {
		let line = "STEP \(name) phase=\(model.phase) busy=\(model.isBusy) prompt=\(model.prompt != nil) passwordField=\(model.password.isEmpty ? "empty" : "filled") codeField=\(model.code.isEmpty ? "empty" : "filled")\n"
		append(line)
		try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}

	private func check(_ ok: Bool, _ label: String) { append("\(ok ? "PASS" : "FAIL") \(label)\n") }

	private func append(_ line: String) {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.logName)
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile()
			handle.write(Data(line.utf8))
			try? handle.close()
		} else {
			try? Data(line.utf8).write(to: url)
		}
	}

	private func type(_ text: String, into keyPath: ReferenceWritableKeyPath<ZagFreeAccountSignInModel, String>) async {
		for character in text {
			model[keyPath: keyPath].append(character)
			try? await Task.sleep(nanoseconds: 35_000_000)
		}
	}

	/// No Keychain item or preference may hold the password or a code.
	private func nothingSecretStored() -> Bool {
		let defaults = UserDefaults.standard.dictionaryRepresentation().description
		let secrets = ZagKeychainFreeAccountSecretStore(service: ZagFreeAccountSimulation.keychainService)
		let session = UserDefaults.standard.data(forKey: ZagFreeAccountSimulation.sessionKey)
			.flatMap { try? JSONDecoder().decode(ZagFreeAccountSession.self, from: $0) }
		let stored = session.flatMap { try? secrets.load(.session, account: $0.accountID) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
		return [ZagFreeAccountSimulation.password, ZagFreeAccountSimulation.verificationCode, "111111"].allSatisfy {
			!defaults.contains($0) && !stored.contains($0)
		}
	}

	func run() async {
		try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(Self.logName))
		if model.phase != .signedOut { await model.signOut() }
		await step("01-signed-out")

		// Wrong password.
		await lab.select(.trustedDeviceCode)
		await type(ZagFreeAccountSimulation.appleID, into: \.appleID)
		await type("wrong-password", into: \.password)
		await step("02-credentials-entered", hold: 1.5)
		await model.signIn()
		check(model.failure?.kind == .invalidCredentials && model.password.isEmpty, "incorrect password fails and clears the field")
		await step("03-incorrect-password")

		// Correct password, then a wrong code, then the right one.
		await type(ZagFreeAccountSimulation.password, into: \.password)
		await model.signIn()
		check(model.phase == .awaitingCode && model.prompt?.alternativeAction != nil, "verification code requested")
		await step("04-code-requested")
		await type("111111", into: \.code)
		await model.submitCode()
		check(model.prompt?.isRetry == true && model.prompt?.attemptsRemaining == 2 && model.code.isEmpty, "wrong code keeps the prompt with 2 attempts left")
		await step("05-code-retry")
		await type(ZagFreeAccountSimulation.verificationCode, into: \.code)
		await step("06-code-entered", hold: 1)
		await model.submitCode()
		check(model.phase == .signedIn && model.state.session?.team.kind == .personalFree, "signed in with the Personal Team")
		check(nothingSecretStored(), "no password or code in preferences or the Keychain")
		await step("07-signed-in")

		// Apple revokes the session.
		await lab.revokeSession()
		check(model.phase == .expired, "a revoked session shows as expired")
		await step("08-session-revoked")

		// Sign out.
		await model.signOut()
		check(model.phase == .signedOut && UserDefaults.standard.data(forKey: ZagFreeAccountSimulation.sessionKey) == nil, "sign-out removes the session")
		await step("09-signed-out-again")

		// Cancel at the code prompt.
		await type(ZagFreeAccountSimulation.password, into: \.password)
		await model.signIn()
		await step("10-code-requested-again", hold: 1.5)
		await model.cancel()
		check(model.failure?.kind == .cancelled && model.prompt == nil, "cancelling at the code prompt ends sign-in")
		await step("11-cancelled")

		// Sign in directly, then relaunch after the session's expiry.
		await lab.select(.signInSucceeds)
		await type(ZagFreeAccountSimulation.password, into: \.password)
		await model.signIn()
		await step("12-signed-in-direct", hold: 1.5)
		await lab.relaunchAfter31Days()
		check(model.phase == .expired, "a session past its expiry is expired after relaunch")
		await step("13-expired-after-relaunch")
		await model.signOut()

		// A failure Apple could return.
		await lab.select(.accountLocked)
		await type(ZagFreeAccountSimulation.password, into: \.password)
		await model.signIn()
		check(model.failure?.kind == .accountLocked, "a locked account explains what to do")
		await step("14-account-locked")
		await lab.select(.trustedDeviceCode)
		append("DONE\n")
	}
}
#endif
