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
	@ObservedObject private var pairing = ZagRPPairingCore.shared
	@State private var signedIn = false
	/// The Personal Team id, discovered from the same authenticated session the
	/// sign-in screen uses. The certificate inventory lists against this team;
	/// an empty team is rejected (401/403) by Apple's services.
	@State private var teamID = ""

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
		.navigationTitle("Apple Accounts & Signing")
		.task { await refresh() }
	}

	private func refresh() async {
		guard engineLinked else { signedIn = false; teamID = ""; return }
		signedIn = ZagDeveloperTokenStore().load(scope: "device")?.isUsable(at: Date()) == true
		guard signedIn else { teamID = ""; return }
		// Same authenticated native machine + persisted developer session as the
		// sign-in screen's Personal Team retrieval, so the certificate inventory
		// lists against the real team rather than an empty (rejected) one.
		#if canImport(ZagAppleAuth)
		teamID = (try? await ZagNativeDeveloperPortal.readOnlyInventory().teams().first(where: \.isPersonalTeam))?.teamID ?? ""
		#endif
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
		Section("Apple Accounts") {
			NavigationLink {
				ZagAppleAccountSignInView().zagSettingsDestinationAvatar()
					.onDisappear { Task { await refresh() } }
			} label: {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text(signedIn ? "Manage Apple Account" : "Sign in with your Apple Account")
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
			if signedIn && !teamID.isEmpty {
				NavigationLink(destination: ZagCertificateReplacementView(model: ZagCertificateReplacementModel.inventory(team: teamID)).zagSettingsDestinationAvatar()) {
					Label("Signing certificate", systemImage: "checkmark.seal")
				}
			} else {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Signing certificate").foregroundStyle(.secondary)
						Text("Connect a Personal Team to view your certificates.").font(.caption).foregroundStyle(.secondary)
					}
				} icon: { Image(systemName: "checkmark.seal").foregroundStyle(.secondary) }
			}
		} header: {
			Text("Certificate")
		} footer: {
			Text("Zag Store reuses the development certificate that matches this iPhone’s signing key. Revocation requires confirmation.")
		}
	}

	// MARK: Device

	private var deviceSection: some View {
		Section {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Image(systemName: pairing.hasSavedPairing ? "checkmark.circle.fill" : "iphone")
					.foregroundStyle(pairing.hasSavedPairing ? .green : tint).frame(width: 24)
				VStack(alignment: .leading, spacing: 2) {
					Text("Installation pairing").font(.subheadline.weight(.medium))
					Text(deviceDetail).font(.caption).foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("Device")
		} footer: {
			Text("Zag Store registers the paired iPhone with your Personal Team when you sign an app.")
		}
	}

	private var deviceDetail: String {
		if let identity = pairing.pairedIdentity, pairing.hasSavedPairing { return "\(identity.name) is paired for installation." }
		if pairing.hasSavedPairing { return "Pairing is saved. Zag Store will read this iPhone’s identifier when you install." }
		return "Set up pairing in Settings to install signed apps."
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
			Text("Choose Free Apple Account on the Sign App screen.")
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
