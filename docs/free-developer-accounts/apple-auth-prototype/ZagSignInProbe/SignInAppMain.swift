import SwiftUI

// The sign-in experiment app. Two behaviours, selected at launch:
//
//  * Default launch — a secure entry screen to seed/clear the test Apple
//    Account credentials in the Keychain. No Apple contact.
//  * ZAG_RUN_SIGNIN=1 — the single authorised live attempt: fresh on-device
//    anisette, then one bounded GrandSlam SRP sign-in. Launch this only after
//    explicit authorization. A 2FA challenge is detected and reported, never
//    answered.
//
// The password is entered in a SecureField, stored only in the Keychain, used
// once, and never shown, logged, argv-passed or written to a result file.

// Experiment scopes. The Mac identity (E2) uses its own Keychain scope so the
// provisioned iPhone-labelled baseline (`device`) is never touched.
private let zagMacScope = "mac-experiment"
private let zagMacLegacyScope = "mac-legacy-experiment"

@main
struct ZagSignInProbeApp: App {
	var body: some Scene {
		WindowGroup {
			switch ProcessInfo.processInfo.environment {
			case let env where env["ZAG_RUN_SIGNIN"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: true) }, file: "zag_signin_result.json")
			case let env where env["ZAG_RUN_MAC_PROVISION"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.provision(platform: .mac, scope: zagMacScope) }, file: "zag_mac_provision.json")
			case let env where env["ZAG_RUN_MAC_SELFCHECK"] == "1":
				// Offline preflight: transport refused, zero Apple contact.
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: false, platform: .mac, scope: zagMacScope) }, file: "zag_mac_selfcheck.json")
			case let env where env["ZAG_RUN_MAC_SIGNIN"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: true, platform: .mac, scope: zagMacScope) }, file: "zag_mac_signin.json")
			case let env where env["ZAG_RUN_MACLEGACY_PROVISION"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.provision(platform: .macLegacy, scope: zagMacLegacyScope) }, file: "zag_maclegacy_provision.json")
			case let env where env["ZAG_RUN_MACLEGACY_SELFCHECK"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: false, platform: .macLegacy, scope: zagMacLegacyScope) }, file: "zag_maclegacy_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_SIGNIN"] == "1":
				// Hard ceiling of 3 GrandSlam requests (lookup/init/complete): no
				// 4th (2FA-delivery) request can fire.
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: true, platform: .macLegacy, scope: zagMacLegacyScope, maxRequests: 3) }, file: "zag_maclegacy_signin.json")
			case let env where env["ZAG_RUN_MACLEGACY_LOGIN_DEVSESSION_SELFCHECK"] == "1":
				// Offline preflight: fresh-login + developer-session, transport refused.
				TwoFactorRunView(platform: .macLegacy, scope: zagMacLegacyScope, file: "zag_maclegacy_login_devsession_selfcheck.json", allowNetwork: false, includeDeveloperSession: true)
			case let env where env["ZAG_RUN_MACLEGACY_LOGIN_DEVSESSION"] == "1":
				// Fresh interactive login, then an IMMEDIATE developer-session from the
				// just-authenticated in-memory session. No cert/device/App ID/profile/signing.
				TwoFactorRunView(platform: .macLegacy, scope: zagMacLegacyScope, file: "zag_maclegacy_login_devsession.json", allowNetwork: true, includeDeveloperSession: true)
			case let env where env["ZAG_RUN_MACLEGACY_TEAMS_SELFCHECK"] == "1":
				// Offline preflight: team discovery with no network (and/or no token).
				LiveRunView(task: { await ZagSignInExperimentRunner.runTeamDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: false) }, file: "zag_maclegacy_teams_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_TEAMS"] == "1":
				// Exactly ONE read-only team-discovery request using the persisted
				// developer token. No login, no token request, no account mutation.
				LiveRunView(task: { await ZagSignInExperimentRunner.runTeamDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: true) }, file: "zag_maclegacy_teams.json")
			case let env where env["ZAG_RUN_MACLEGACY_DEVICES_SELFCHECK"] == "1":
				// Offline preflight: device discovery with no network (and/or no token).
				LiveRunView(task: { await ZagSignInExperimentRunner.runDeviceDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: false) }, file: "zag_maclegacy_devices_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_DEVICES"] == "1":
				// Read-only device discovery: teams -> listDevices (<=2 requests). No
				// mutation. Determines whether this device is already registered.
				LiveRunView(task: { await ZagSignInExperimentRunner.runDeviceDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: true) }, file: "zag_maclegacy_devices.json")
			case let env where env["ZAG_RUN_MACLEGACY_CERTS_SELFCHECK"] == "1":
				// Offline preflight: certificate discovery with no network (and/or no token).
				LiveRunView(task: { await ZagSignInExperimentRunner.runCertificateDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: false) }, file: "zag_maclegacy_certs_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_CERTS"] == "1":
				// Read-only certificate discovery via /services/v1/ JSON: teams ->
				// certificates (<=2 requests). No mutation. Confirms the current
				// certificate count against the free-team limit before any CSR.
				LiveRunView(task: { await ZagSignInExperimentRunner.runCertificateDiscovery(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: true) }, file: "zag_maclegacy_certs.json")
			case let env where env["ZAG_RUN_MACLEGACY_CSR_SELFCHECK"] == "1":
				// Offline preflight: certificate issuance with no network and no mutation.
				LiveRunView(task: { await ZagSignInExperimentRunner.runCertificateIssuance(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: false, allowMutation: false) }, file: "zag_maclegacy_csr_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_CSR"] == "1":
				// Supervised FIRST MUTATION: issue one development certificate for a
				// new non-extractable Keychain key. The CSR is sent only after the
				// explicit consent screen is authorised.
				CertificateIssuanceRunView(platform: .macLegacy, scope: zagMacLegacyScope, file: "zag_maclegacy_csr.json")
			case let env where env["ZAG_RUN_MACLEGACY_DEVSESSION_SELFCHECK"] == "1":
				// Offline preflight: developer-session path, transport refused.
				LiveRunView(task: { await ZagSignInExperimentRunner.runDeveloperSession(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: false) }, file: "zag_maclegacy_devsession_selfcheck.json")
			case let env where env["ZAG_RUN_MACLEGACY_DEVSESSION"] == "1":
				// One developer-session exchange reusing the retained session.
				// No login, cert, device, App ID, profile or signing.
				LiveRunView(task: { await ZagSignInExperimentRunner.runDeveloperSession(platform: .macLegacy, scope: zagMacLegacyScope, allowNetwork: true) }, file: "zag_maclegacy_devsession.json")
			case let env where env["ZAG_RUN_MACLEGACY_2FA_SELFCHECK"] == "1":
				// Offline preflight: the 2FA harness with the transport refused.
				// No Apple contact; no consent/code gate is reached.
				TwoFactorRunView(platform: .macLegacy, scope: zagMacLegacyScope, file: "zag_maclegacy_2fa_selfcheck.json", allowNetwork: false)
			case let env where env["ZAG_RUN_MACLEGACY_2FA"] == "1":
				// Supervised, interactive 2FA completion. Disabled by default; one
				// bounded sequence (ceilings 5/2/1). Consent is required before any
				// delivery; a code is submitted only by a separate explicit action.
				TwoFactorRunView(platform: .macLegacy, scope: zagMacLegacyScope, file: "zag_maclegacy_2fa.json")
			default:
				CredentialEntryView()
			}
		}
	}
}

struct LiveRunView: View {
	let task: () async -> [String: Any]
	let file: String
	@State private var status = "Running one authorised attempt…"
	var body: some View {
		Text(status)
			.padding()
			.task {
				let report = await task()
				ZagSignInExperimentRunner.emit(report, name: file)
				status = "Done: \(report["outcome"] ?? report["result"] ?? "—")"
			}
	}
}

/// The interactive 2FA screen. The sign-in runs in `.task`; the coordinator
/// publishes each decision point and this view resolves it. Consent is a
/// deliberate button press before any delivery; the code is entered in a
/// SecureField and submitted by a separate explicit action; Cancel is available
/// at every stage. The code is never shown back, logged or written to the file.
struct TwoFactorRunView: View {
	let platform: ZagAppleAuthPlatform
	let scope: String
	let file: String
	var allowNetwork: Bool = true
	var includeDeveloperSession: Bool = false
	@StateObject private var coordinator = ZagTwoFactorCoordinator()
	@State private var status = "Starting one supervised 2FA attempt…"
	@State private var code = ""

	var body: some View {
		VStack(spacing: 16) {
			Text(status).font(.footnote).multilineTextAlignment(.center)
			switch coordinator.stage {
			case .authenticating:
				ProgressView("Authenticating…")
			case .awaitingConsent:
				Text("Apple will send a verification code to your trusted device or phone number. No code is sent until you consent.")
					.font(.footnote).multilineTextAlignment(.center)
				HStack {
					Button("Cancel", role: .cancel) { coordinator.cancel() }
					Button("Consent & send code") { coordinator.resolveConsent(true) }
						.buttonStyle(.borderedProminent)
				}
			case .selectingPhone(let choices):
				Text("Choose a number to receive the SMS code:").font(.footnote)
				ForEach(choices) { c in
					Button(c.display) { coordinator.resolvePhone(c.id) }
				}
				Button("Cancel", role: .cancel) { coordinator.cancel() }
			case .awaitingCode:
				Text("Enter the 6-digit verification code.").font(.footnote)
				SecureField("Code", text: $code)
					.textContentType(.oneTimeCode)
					.keyboardType(.numberPad)
					.multilineTextAlignment(.center)
				HStack {
					Button("Cancel", role: .cancel) { coordinator.cancel() }
					Button("Submit code") { coordinator.submitCode(code); code = "" }
						.buttonStyle(.borderedProminent)
						.disabled(code.count != 6)
				}
			case .submitting:
				ProgressView("Completing…")
			case .idle, .finished, .cancelled:
				EmptyView()
			}
		}
		.padding()
		.task {
			let report = await ZagSignInExperimentRunner.runTwoFactor(platform: platform, scope: scope, coordinator: coordinator, allowNetwork: allowNetwork, includeDeveloperSession: includeDeveloperSession)
			ZagSignInExperimentRunner.emit(report, name: file)
			status = "Done: \(report["outcome"] ?? report["result"] ?? "—")"
		}
	}
}

/// The supervised certificate-issuance screen. It shows the explicit consent
/// screen FIRST (what will be created, in which team, and the consequences).
/// Only when the user authorises is `.submitCSR` consented and the one bounded
/// issuance sequence run; Cancel contacts Apple for nothing.
struct CertificateIssuanceRunView: View {
	let platform: ZagAppleAuthPlatform
	let scope: String
	let file: String
	@State private var consent = ZagMutationConsentCoordinator()
	@State private var stage = Stage.consent
	@State private var status = ""

	enum Stage: Equatable { case consent, running, done }

	var body: some View {
		VStack(spacing: 16) {
			switch stage {
			case .consent:
				ZagAccountMutationConsentView(
					plan: [.submitCSR],
					onAuthorize: {
						consent.authorize([.submitCSR])
						stage = .running
						Task { await run(allowMutation: consent.mayPerform(.submitCSR)) }
					},
					onCancel: {
						stage = .done
						ZagSignInExperimentRunner.emit(["mode": "live-csr", "outcome": "cancelled", "request_count": 0], name: file)
						status = "Cancelled. Nothing was sent to Apple."
					})
			case .running:
				ProgressView("Issuing one development certificate…")
			case .done:
				Text(status).font(.footnote).multilineTextAlignment(.center)
			}
		}
		.padding()
	}

	private func run(allowMutation: Bool) async {
		let report = await ZagSignInExperimentRunner.runCertificateIssuance(
			platform: platform, scope: scope, allowNetwork: true, allowMutation: allowMutation)
		ZagSignInExperimentRunner.emit(report, name: file)
		status = "Done: \(report["outcome"] ?? "—")"
		stage = .done
	}
}

struct CredentialEntryView: View {
	@State private var email = ""
	@State private var password = ""
	@State private var status = "No live request is made here."
	private let store = ZagSignInCredentialStore()

	var body: some View {
		Form {
			Section("Test Apple Account (stored in Keychain only)") {
				TextField("Apple ID email", text: $email)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				SecureField("Password", text: $password)
			}
			Section {
				Button("Store securely") {
					do { try store.save(ZagSignInCredential(email: email, password: password)); password = ""; status = "Stored." }
					catch { status = "Could not store." }
				}
				Button("Clear stored credentials", role: .destructive) { store.clear(); status = "Cleared." }
				Button(store.load() == nil ? "No credential stored" : "Credential present") { }.disabled(true)
			}
			Section { Text(status).font(.footnote) }
		}
	}
}
