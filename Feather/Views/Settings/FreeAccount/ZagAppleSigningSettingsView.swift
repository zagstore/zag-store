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

	private var accountSection: some View {
		Section("Apple Account") {
			statusRow(icon: "person.crop.circle", title: "Connect Apple Account",
					  detail: bridgeLinked ? "Sign in to your free Apple Account." : "Available in a native-bridge build.",
					  state: .experimental)
			statusRow(icon: "person.2", title: "Personal Team",
					  detail: "Selected after sign-in; a free account has one Personal Team.",
					  state: .pending)
			#if DEBUG
			NavigationLink(destination: ZagFreeAccountDebugSignInView().zagSettingsDestinationAvatar()) {
				Label("Open sign-in (simulated)", systemImage: "person.badge.key")
			}
			#endif
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
