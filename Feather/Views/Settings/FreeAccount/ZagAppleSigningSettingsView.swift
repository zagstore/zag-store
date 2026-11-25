#if canImport(SwiftUI)
import SwiftUI

// "Apple Account & Signing" — the single native home for signing apps with a
// free Apple Account entirely on this iPhone. A clean, native Settings surface:
// account, certificate, device and signing method. No experimental scaffolding,
// readiness ladders or developer-only diagnostics; provisioning and the
// developer session are handled by the sign-in flow itself, not exposed as
// separate steps here. Debug/inspection screens exist only in DEBUG builds.
//
// Honesty is still a hard requirement: nothing is reported as signed in,
// provisioned or installed until it is actually true (the rows read real
// on-device state), and every irreversible certificate operation keeps its own
// explicit confirmation inside ZagCertificateReplacementView.

struct ZagAppleSigningSettingsView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
	private var tint: Color { Color(hex: themeColorHex) }

	/// Real on-device state, read in `.task` (the machine's provisioning check is
	/// actor-isolated). Both default to a conservative "not yet" so the screen
	/// never implies a session or profile exists before it does.
	@State private var signedIn = false
	@State private var provisioned = false

	/// Whether this build links the native engine. Device builds do; the
	/// simulator does not, in which case the whole feature is unavailable.
	private var engineLinked: Bool { ZagAppleAuthMachine.isLinked }

	var body: some View {
		List {
			overviewSection
			if engineLinked {
				accountSection
				certificateSection
				deviceSection
				signingMethodSection
			} else {
				unavailableSection
			}
			safetySection
		}
		.navigationTitle("Apple Account & Signing")
		.task { await refresh() }
	}

	private func refresh() async {
		guard engineLinked else { signedIn = false; provisioned = false; return }
		provisioned = await ZagAppleAuthMachine.nativeAccount().isProvisioned()
		signedIn = ZagDeveloperTokenStore().hasToken(scope: "device")
	}

	// MARK: Overview

	private var overviewSection: some View {
		Section {
			HStack(spacing: 12) {
				Image(systemName: "key.horizontal.fill")
					.font(.title2).foregroundStyle(tint).frame(width: 30)
				VStack(alignment: .leading, spacing: 3) {
					Text("Native signing").font(.headline)
					Text("Sign apps with your own free Apple Account, entirely on this iPhone — no Mac and no external signing service.")
						.font(.footnote).foregroundStyle(.secondary)
				}
			}
		} footer: {
			Text("Your Apple Account password, two-factor codes, signing key and app contents stay on this iPhone and are never logged. Nothing is sent to Apple, signed or installed until you ask for it.")
		}
	}

	// MARK: Apple Account

	private var accountSection: some View {
		Section("Apple Account") {
			NavigationLink(destination: ZagAppleAccountSignInView().zagSettingsDestinationAvatar()) {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text(signedIn ? "Apple Account" : "Sign in with your Apple Account")
						Text(signedIn ? "Signed in on this iPhone. Tap to manage the session."
									  : "Use your free Apple Account and two-factor code.")
							.font(.caption).foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
						.foregroundStyle(signedIn ? .green : tint)
				}
			}
			.accessibilityIdentifier("settings.appleSigning.connect")
		}
	}

	// MARK: Signing certificate (+ consent-gated replacement)

	private var certificateSection: some View {
		Section {
			NavigationLink(destination: ZagCertificateReplacementView(model: ZagCertificateReplacementModel.gatedPreview()).zagSettingsDestinationAvatar()) {
				Label("Signing certificate", systemImage: "checkmark.seal")
			}
		} header: {
			Text("Certificate")
		} footer: {
			Text("A development certificate for this iPhone's signing key. If your account already holds the maximum (Apple error 7460), you can replace one — always with a separate confirmation, and the certificate currently in use is always protected.")
		}
	}

	// MARK: Device

	private var deviceSection: some View {
		Section {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				// Green only when sign-in has verified this device with Apple
				// end-to-end. A stored ADI profile on its own is NOT a success: it
				// may be stale or rejected, so it is shown as neutral, not green.
				Image(systemName: signedIn ? "checkmark.circle.fill" : "iphone")
					.foregroundStyle(signedIn ? .green : tint).frame(width: 24)
				VStack(alignment: .leading, spacing: 2) {
					Text("Device provisioning").font(.subheadline.weight(.medium))
					Text(deviceDetail).font(.caption).foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Device")
		} footer: {
			Text("Being set up on this iPhone is local state only. It is confirmed with Apple — and this device registered to your account — when you sign in, never from stored state alone.")
		}
	}

	private var deviceDetail: String {
		if signedIn {
			return "Verified with Apple during sign-in. A free-account profile lasts 7 days and is renewed where permitted."
		}
		return provisioned
			? "A setup profile is stored on this iPhone, but it is confirmed only when you sign in — stored setup alone is not a guarantee."
			: "Set up automatically the first time you sign in. A free-account profile lasts 7 days."
	}

	// MARK: Signing method (explicit choice; existing methods preserved)

	private var signingMethodSection: some View {
		Section {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Image(systemName: "key.horizontal").foregroundStyle(tint).frame(width: 24)
				VStack(alignment: .leading, spacing: 2) {
					Text(ZagSigningMethod.freeAppleAccount.title).font(.subheadline.weight(.medium))
					Text(ZagSigningMethod.freeAppleAccount.summary).font(.caption).foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Signing method")
		} footer: {
			Text("Native Apple Account signing is offered alongside — never instead of — AppTesters, Imported Certificate, BYOC and Developer Account. It signs through the on-device signer and never redirects an install you did not choose.")
		}
	}

	// MARK: Unavailable (engine not linked, e.g. simulator)

	private var unavailableSection: some View {
		Section {
			Label("Native signing is unavailable in this build.", systemImage: "exclamationmark.triangle")
				.font(.footnote).foregroundStyle(.secondary)
		} footer: {
			Text("This build does not link the on-device Apple engine (for example, the simulator). Use the iPhone build to sign with a free Apple Account.")
		}
	}

	// MARK: Safety / isolation

	private var safetySection: some View {
		Section {
			Label("Keeps its own Keychain state in Zag Store's access group.", systemImage: "lock.shield")
				.font(.footnote)
			Label("Never reads or modifies another app's signing key or certificate.", systemImage: "hand.raised")
				.font(.footnote)
		}
	}
}
#endif
