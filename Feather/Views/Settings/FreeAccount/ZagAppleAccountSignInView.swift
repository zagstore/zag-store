#if canImport(SwiftUI)
import SwiftUI

// The real, production-reachable native Apple Account sign-in for the normal
// Zag Store device build (not DEBUG, not an experiment build). It drives the
// existing engine end to end — ZagAccountDirectory → ZagFreeAccountAuthenticator
// (GrandSlam) → ZagBridgeAnisetteSource (on-device anisette) →
// ZagIsideloadAuthenticationService — through the shared ZagFreeAccountSignInModel.
// Sessions and the developer token are persisted by the engine in Zag Store's
// own Keychain items; this screen holds no secret of its own and logs nothing.
//
// When the native bridge is not linked (e.g. a simulator build), the stack
// cannot be constructed; the screen then states exactly that rather than
// pretending to offer a sign-in it cannot perform.

/// Owns the real sign-in model. The model is built asynchronously because the
/// directory is an actor (`newSignIn()` is async), so it is created in `prepare()`
/// from `.task`, not in `init`.
@MainActor
final class ZagAppleAccountSignInController: ObservableObject {
	@Published private(set) var model: ZagFreeAccountSignInModel?
	@Published private(set) var nativeModel: ZagNativeSignInModel?
	@Published private(set) var unavailableReason: String?

	#if ZAG_APPLE_BRIDGE
	private let directory: ZagAccountDirectory?
	/// Option B: when the native engine (ZagAppleAuth xcframework) is linked,
	/// Zag Store authenticates entirely on-device through ZagAppleAuthMachine —
	/// no ZagAccountDirectory, no ZagIsideloadAuthenticationService, no remote
	/// anisette. The bridge path is retained only for builds that do not link
	/// the native engine (e.g. the simulator), where it reports unavailable.
	private let useNative: Bool

	init() {
		if ZagAppleAuthMachine.isLinked {
			useNative = true
			directory = nil
		} else {
			useNative = false
			var configuration = ZagAccountDirectory.Configuration()
			configuration.namespace = "ZagStore.accounts"
			configuration.makeService = { ZagIsideloadAuthenticationService() }
			configuration.localState = ZagBridgeAnisetteLocalState()
			directory = ZagAccountDirectory(
				anisette: ZagBridgeAnisetteSource(),
				secrets: ZagKeychainFreeAccountSecretStore(),
				preferences: ZagUserDefaultsPreferences(),
				configuration: configuration
			)
		}
	}

	func prepare() async {
		if useNative {
			guard nativeModel == nil else { return }
			let m = ZagNativeSignInModel()
			nativeModel = m
			await m.restore()   // on-device session check, no network
		} else {
			guard model == nil, let directory else { return }
			let m = ZagFreeAccountSignInModel(
				authenticator: await directory.newSignIn(),
				diagnostics: ZagFreeAccountDiagnostics()
			)
			model = m
			await m.restore()
		}
	}
	#else
	init() {}
	func prepare() async {
		unavailableReason = "Native sign-in needs a device build with the Apple engine linked. This build does not link it."
	}
	#endif
}

struct ZagAppleAccountSignInView: View {
	@StateObject private var controller = ZagAppleAccountSignInController()

	var body: some View {
		Group {
			if let native = controller.nativeModel {
				ZagNativeAccountSignInContent(model: native)
			} else if let model = controller.model {
				ZagAppleAccountSignInContent(model: model)
			} else {
				List {
					Section {
						Label(controller.unavailableReason ?? "Preparing…",
							  systemImage: controller.unavailableReason == nil ? "hourglass" : "exclamationmark.triangle")
							.font(.footnote).foregroundStyle(.secondary)
					} footer: {
						Text("The sign-in engine, anisette provider and developer-token store are all present; a one-time account provisioning and your interactive sign-in are what remain before a live session can be obtained.")
					}
				}
			}
		}
		.navigationTitle("Apple Account")
		.navigationBarTitleDisplayMode(.inline)
		.task { await controller.prepare() }
	}
}

private struct ZagAppleAccountSignInContent: View {
	@ObservedObject var model: ZagFreeAccountSignInModel
	@AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
	@FocusState private var focus: Field?
	private enum Field { case appleID, password }
	private var tint: Color { Color(hex: tintHex) }

	/// Whether this build can actually perform live sign-in. False in the shipping
	/// AppTesters build by design — surfacing it stops the dead-end where tapping
	/// Sign In could only ever return "Failed".
	private var liveAuthAvailable: Bool {
		#if ZAG_APPLE_BRIDGE
		return ZagLiveAuthentication.isEnabled && ZagIsideloadBridge.liveCompiled
		#else
		return false
		#endif
	}

	var body: some View {
		Form {
			statusSection
			if !liveAuthAvailable { unavailableBanner }
			switch model.phase {
			case .signedIn, .expired: sessionSection
			default:                  credentialsSection
			}
			if let failure = model.failure { failureSection(failure) }
			else if let notice = model.notice {
				Section { Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
			}
			if !model.diagnosticEntries.isEmpty { diagnosticsSection }
			disclaimerSection
		}
		.sheet(isPresented: Binding(
			get: { model.prompt != nil },
			set: { shown in if !shown, model.prompt != nil { Task { await model.cancel() } } }
		)) {
			codeSheet
		}
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
		Section("Sign in") {
			TextField("Apple Account", text: $model.appleID)
				.keyboardType(.emailAddress).textContentType(.username)
				.textInputAutocapitalization(.never).autocorrectionDisabled()
				.focused($focus, equals: .appleID).submitLabel(.next)
				.onSubmit { focus = .password }
			SecureField("Password", text: $model.password)
				.textContentType(.password)
				.focused($focus, equals: .password).submitLabel(.go)
				.onSubmit { if model.canSubmitCredentials && liveAuthAvailable { Task { await model.signIn() } } }
			Button {
				focus = nil
				Task { await model.signIn() }
			} label: {
				HStack { Spacer(); Text("Sign In").fontWeight(.semibold); Spacer() }
			}
			.disabled(!model.canSubmitCredentials || !liveAuthAvailable)
		}
	}

	private var unavailableBanner: some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Sign-in unavailable in this build").font(.subheadline.weight(.medium))
					Text("Native Apple Account sign-in is not enabled in this build. It requires the supervised live-test build; until then, sign-in here cannot reach Apple. You can still install apps with an imported certificate.")
						.font(.caption).foregroundStyle(.secondary)
				}
			} icon: { Image(systemName: "lock.slash").foregroundStyle(.orange) }
		}
	}

	private func failureSection(_ failure: ZagFreeAccountFailure) -> some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text(failure.message).font(.footnote)
					Text(failure.recovery).font(.caption).foregroundStyle(.secondary)
				}
			} icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
		} header: {
			Text("Why sign-in did not complete")
		}
	}

	private var diagnosticsSection: some View {
		Section {
			ForEach(Array(model.diagnosticEntries.suffix(6).enumerated()), id: \.offset) { _, entry in
				Text(entry.message).font(.caption2.monospaced()).foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
		} header: {
			Text("Diagnostics (no secrets)")
		} footer: {
			Text("Local only. Identifies the stage that failed — bridge, anisette/ADI, GrandSlam, two-factor, token or Keychain — without recording passwords, codes, tokens or device identifiers.")
		}
	}

	private var sessionSection: some View {
		Section("Session") {
			if model.phase == .expired {
				Label("This session has expired. Sign in again.", systemImage: "clock.badge.exclamationmark")
					.font(.footnote).foregroundStyle(.orange)
			} else {
				Label("Signed in. A developer session is held in Zag Store's Keychain.", systemImage: "checkmark.seal")
					.font(.footnote).foregroundStyle(.green)
			}
			Button(role: .destructive) { Task { await model.signOut() } } label: {
				Text("Sign Out")
			}.disabled(model.isBusy)
		}
	}

	private var disclaimerSection: some View {
		Section {
			EmptyView()
		} footer: {
			Text("Your Apple Account password, two-factor codes and developer tokens stay on this iPhone and are never logged. Signing in may contact Apple to authenticate; nothing is revoked, signed or installed from this screen.")
		}
	}

	private var codeSheet: some View {
		NavigationStack {
			Form {
				if let prompt = model.prompt {
					Section {
						Text(prompt.message).font(.footnote).foregroundStyle(.secondary)
						TextField("Code", text: $model.code)
							.keyboardType(.numberPad).textContentType(.oneTimeCode)
						if let alt = prompt.alternativeAction {
							Button(alt) { Task { await model.requestCodeBySMS() } }.disabled(model.isBusy)
						}
					} header: {
						Text(prompt.title)
					} footer: {
						if prompt.attemptsRemaining > 0 && prompt.isRetry {
							Text("\(prompt.attemptsRemaining) attempts remaining.")
						}
					}
				}
			}
			.navigationTitle("Two-Factor")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { Task { await model.cancel() } }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Verify") { Task { await model.submitCode() } }.disabled(!model.canSubmitCode)
				}
			}
		}
		.presentationDetents([.medium])
	}

	// MARK: Status derivation

	private var statusIcon: String {
		switch model.phase {
		case .signedIn:   return "person.crop.circle.badge.checkmark"
		case .expired:    return "person.crop.circle.badge.clock"
		case .failed:     return "person.crop.circle.badge.exclamationmark"
		case .awaitingCode: return "ellipsis.bubble"
		default:          return "person.crop.circle"
		}
	}
	private var statusColor: Color {
		switch model.phase {
		case .signedIn: return .green
		case .failed, .expired: return .orange
		default: return tint
		}
	}
	private var statusTitle: String {
		switch model.phase {
		case .signedOut:    return "Not signed in"
		case .working:      return "Signing in…"
		case .awaitingCode: return "Enter your code"
		case .signedIn:     return "Signed in"
		case .expired:      return "Session expired"
		case .failed:       return "Sign-in failed"
		}
	}
	private var statusDetail: String {
		switch model.phase {
		case .signedIn: return "Personal Team and certificate inventory are available."
		case .failed:   return model.failure?.message ?? model.notice ?? "Sign-in did not complete."
		default:
			return liveAuthAvailable ? "Use your free Apple Account; two-factor is handled here."
									 : "This build cannot sign in to Apple; see below."
		}
	}
}
#endif
