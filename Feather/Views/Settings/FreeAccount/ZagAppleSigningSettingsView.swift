#if canImport(SwiftUI)
import SwiftUI

// First-class "Apple Account & Signing" home for Zag Store's native standalone
// signing feature. It is the single coherent entry point for the native engine
// that already lives in Feather/Utilities/FreeAccount — Apple-Account
// authentication, Personal-Team selection, certificate inventory and the
// consent-gated 7460 replacement workflow, device provisioning, on-device
// (non-extractable) signing through Zsign, signature verification and the
// installation handoff.
//
// Honesty is a hard requirement of this screen (see the task boundaries and
// ZagCertificateReplacementView): it must NEVER imply that provisioning or
// signing has succeeded before it is verified live. So every live-capable row
// is explicitly labelled with the build's actual mode:
//   • Offline            — no native bridge linked; live Apple contact impossible.
//   • Read-only (live)   — the bridge is linked and the first live session is
//                          limited to the certificate inventory; every mutating
//                          Developer Services endpoint is blocked at the
//                          transport (ZagReadOnlyTransport), not merely hidden.
// Mutations (revoke, CSR) remain behind their own separate confirmations and are
// never performed automatically.

struct ZagAppleSigningSettingsView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
	private var tint: Color { Color(hex: themeColorHex) }

	/// True when this build links the real native Apple-auth module, i.e. a live
	/// path is compiled in. The shipping build does not link it, so this is false
	/// and the feature is offline by design.
	private var bridgeLinked: Bool {
		#if canImport(ZagAppleAuth)
		return true
		#else
		return false
		#endif
	}

	// With the native bridge linked (the standard device build), the certificate
	// inventory is connected to the real developer-services portal through the
	// read-only transport: inventory can run live, every mutation is blocked.
	// Without the bridge (e.g. simulator) the feature is fully offline.
	private var modeTitle: String { bridgeLinked ? "Read-only (live inventory)" : "Offline" }
	private var modeColor: Color { bridgeLinked ? .orange : .secondary }

	var body: some View {
		List {
			overviewSection
			accountSection
			certificateSection
			provisioningSection
			signingSection
			signingMethodSection
			safetySection
		}
		.navigationTitle("Apple Account & Signing")
	}

	// MARK: Overview / honest status

	private var overviewSection: some View {
		Section {
			HStack(spacing: 12) {
				Image(systemName: "key.horizontal.fill")
					.font(.title2).foregroundStyle(tint)
					.frame(width: 30)
				VStack(alignment: .leading, spacing: 3) {
					Text("Native signing").font(.headline)
					Text("Sign apps with your own free Apple Account, entirely on this iPhone — no Mac and no external signing service.")
						.font(.footnote).foregroundStyle(.secondary)
				}
			}
			LabeledContent {
				Text(modeTitle).font(.subheadline.weight(.medium)).foregroundStyle(modeColor)
			} label: {
				Label("Current mode", systemImage: "dot.radiowaves.left.and.right")
			}
		} footer: {
			Text("This feature is experimental. Nothing is sent to Apple, no certificate is created or revoked, and no app is signed or installed until you explicitly authorise each step. Steps that have not been verified against Apple are shown as experimental and never reported as complete.")
		}
	}

	// MARK: Apple Account

	/// The native Apple-auth module is linked (device builds link it by default).
	private var machineLinked: Bool { ZagAppleAuthMachine.isLinked }
	/// The on-device anisette/ADI provider is enabled in this build. Off in
	/// production until the live sign-in gate passes; without it, sign-in has no
	/// anisette source and cannot obtain a GrandSlam session.
	private var adiEnabled: Bool { ZagAppleAuthADI.isEnabled }
	/// Whether sign-in can run live in this build: both gates must be satisfied.
	private var signInLive: Bool { machineLinked && adiEnabled }

	private var accountSection: some View {
		Section {
			gateRow("Native module linked", ok: machineLinked,
					detail: machineLinked ? "The on-device Apple-auth engine is compiled into this build."
										  : "This build (e.g. simulator) does not link the engine.")
			gateRow("On-device sign-in enabled", ok: adiEnabled,
					detail: adiEnabled ? "The on-device anisette/ADI provider is active."
									   : "Not enabled in this build; sign-in has no anisette source yet.")
			NavigationLink(destination: ZagAppleAccountSignInView().zagSettingsDestinationAvatar()) {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Connect Apple Account")
						Text(signInLive ? "Sign in with your free Apple Account (password + two-factor)."
										: "Opens the real sign-in; live auth needs the on-device-sign-in build.")
							.font(.caption).foregroundStyle(.secondary)
					}
				} icon: { Image(systemName: "person.crop.circle") }
			}
			.accessibilityIdentifier("settings.appleSigning.connect")
			statusRow(icon: "person.2", title: "Personal Team",
					  detail: "Discovered from the signed-in account; a free account has one Personal Team.",
					  state: .pending)
			#if DEBUG
			NavigationLink(destination: ZagFreeAccountDebugSignInView().zagSettingsDestinationAvatar()) {
				Label("Open sign-in (simulated)", systemImage: "person.badge.key")
			}
			#endif
		} header: {
			Text("Apple Account")
		} footer: {
			Text(signInLive
				 ? "Signing in obtains and persists a developer session (x-apple-gs-token) in Zag Store's own Keychain. Passwords, two-factor codes and tokens are never logged."
				 : "The developer-session token path is implemented (sign-in → token store → developer headers → inventory). It is not a platform limitation: enabling the on-device sign-in build plus a one-time account provisioning is what remains before a live session can be obtained here.")
		}
	}

	private func gateRow(_ title: String, ok: Bool, detail: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Image(systemName: ok ? "checkmark.circle.fill" : "circle")
				.foregroundStyle(ok ? .green : .secondary).frame(width: 24)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.subheadline.weight(.medium))
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	// MARK: Signing certificate (+ 7460 replacement)

	private var certificateSection: some View {
		Section {
			statusRow(icon: "checkmark.seal", title: "Signing certificate",
					  detail: "A development certificate for this iPhone's non-extractable signing key.",
					  state: .pending)
			// The one native workflow wired in every build: the certificate
			// inventory and the consent-gated 7460 replacement. Backed by the
			// disabled portal unless a live bridge build enables the read-only
			// inventory; revoke and CSR are always separately confirmed and are
			// blocked at the transport in a read-only session.
			NavigationLink(destination: ZagCertificateReplacementView(model: ZagCertificateReplacementModel.gatedPreview()).zagSettingsDestinationAvatar()) {
				Label(bridgeLinked ? "Certificate inventory" : "Certificate inventory & replacement",
					  systemImage: "arrow.triangle.2.circlepath")
			}
		} header: {
			Text("Certificate")
		} footer: {
			Text("Some Apple Accounts already hold the maximum number of development certificates (Apple error 7460). Replacing one may let a new request succeed, but Apple may still refuse — it is never guaranteed, and the certificate in use is always protected.")
		}
	}

	// MARK: Device provisioning

	private var provisioningSection: some View {
		Section {
			statusRow(icon: "iphone", title: "Device registration",
					  detail: "This iPhone is registered with your account during provisioning.",
					  state: .pending)
			statusRow(icon: "doc.badge.gearshape", title: "Provisioning profile",
					  detail: "A free-account profile lasts 7 days and is renewed automatically where permitted.",
					  state: .pending)
			#if DEBUG || ZAG_LIVE_EXPERIMENT
			NavigationLink(destination: ZagInstalledProfilesDebugView().zagSettingsDestinationAvatar()) {
				Label("Installed profiles (read only)", systemImage: "lock.doc")
			}
			#endif
		} header: {
			Text("Device provisioning")
		}
	}

	// MARK: Signing & installation workflow

	private var signingSection: some View {
		Section {
			workflowRow(1, "Download the IPA", "From your chosen source.")
			workflowRow(2, "Verify the source artifact", "Before anything is signed.")
			workflowRow(3, "Provision a signing identity", "Reusing this iPhone's key; a new certificate only with your consent.")
			workflowRow(4, "Sign locally with Zsign", "On this iPhone; the private key never leaves the Keychain.")
			workflowRow(5, "Verify the signed IPA", "Independently of the signing library.")
			workflowRow(6, "Install and report", "Through Zag Store's existing installation, preserving current options.")
		} header: {
			Text("Signing & installation")
		} footer: {
			Text("Your Apple Account credentials, signing keys and app contents never leave this iPhone. Live signing and installation require a native-bridge build and separate authorisation; until then these steps are experimental.")
		}
	}

	// MARK: Signing method (explicit, user-selectable; existing methods preserved)

	/// The current readiness of the native method, from the real availability
	/// model. Conservative free-account state (signed-out) until a live session
	/// exists, so it honestly reports the next required step rather than success.
	private var nativeMethodStatus: String {
		let none = ZagSigningMethodAvailability.ImportedCertificates(total: 0, usable: 0, nearestExpiry: nil)
		switch ZagSigningMethodAvailability.status(of: .freeAppleAccount, imported: none, freeAccount: .signedOut) {
		case .ready(let d):          return d
		case .actionRequired(let m): return m
		case .external(let m):       return m
		}
	}

	private var signingMethodSection: some View {
		Section {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Image(systemName: "key.horizontal").foregroundStyle(tint).frame(width: 24)
				VStack(alignment: .leading, spacing: 2) {
					Text(ZagSigningMethod.freeAppleAccount.title).font(.subheadline.weight(.medium))
					Text(ZagSigningMethod.freeAppleAccount.summary).font(.caption).foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				Text(nativeMethodStatus).font(.caption2).foregroundStyle(.orange)
					.multilineTextAlignment(.trailing)
			}
		} header: {
			Text("Signing method")
		} footer: {
			Text("Native Apple Account signing is an explicit choice, offered alongside — never instead of — AppTesters, Imported Certificate, BYOC and Developer Account. It routes an install through the on-device signer (ZagFreeAccountSigningAdapter) and the provisioning coordinator; it runs only after you sign in and a signing identity is provisioned, and it never redirects an install you did not choose.")
		}
	}

	// MARK: Safety / isolation

	private var safetySection: some View {
		Section {
			Label("This feature keeps its own Keychain state in Zag Store's own access group.", systemImage: "lock.shield")
				.font(.footnote)
			Label("It does not read or migrate any other app's signing key or certificate request.", systemImage: "hand.raised")
				.font(.footnote)
		} footer: {
			Text("A signing identity created here is isolated to Zag Store. Identities held by other apps (for example a separate development prototype) are not accessible and are never modified.")
		}
	}

	// MARK: Row helpers

	private enum RowState { case pending, experimental }

	private func statusRow(icon: String, title: String, detail: String, state: RowState) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.subheadline.weight(.medium))
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
			Spacer(minLength: 8)
			switch state {
			case .pending:
				Text("Not set up").font(.caption2).foregroundStyle(.secondary)
			case .experimental:
				Text("Experimental").font(.caption2.weight(.bold)).foregroundStyle(.orange)
			}
		}
	}

	private func workflowRow(_ n: Int, _ title: String, _ detail: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text("\(n)")
				.font(.caption.weight(.bold)).foregroundStyle(tint)
				.frame(width: 20, height: 20)
				.background(tint.opacity(0.12), in: Circle())
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.subheadline)
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}
#endif
