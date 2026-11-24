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

@main
struct ZagSignInProbeApp: App {
	var body: some Scene {
		WindowGroup {
			switch ProcessInfo.processInfo.environment {
			case let env where env["ZAG_RUN_SIGNIN"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: true) }, file: "zag_signin_result.json")
			case let env where env["ZAG_RUN_MAC_PROVISION"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.provision(platform: .mac, scope: zagMacScope) }, file: "zag_mac_provision.json")
			case let env where env["ZAG_RUN_MAC_SIGNIN"] == "1":
				LiveRunView(task: { await ZagSignInExperimentRunner.run(live: true, platform: .mac, scope: zagMacScope) }, file: "zag_mac_signin.json")
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
