#if ZAG_LIVE_EXPERIMENT
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import Zip

// G5: the experiment's one screen (plan §3.3, checklist N6). Only an
// experiment build compiles it. It runs the campaign's single attempt: the
// owner's confirmations, sign-in, the P3 read-back, then one test app
// provisioned, signed and installed, and the report export. Every live step
// still goes through the campaign's checks; this screen adds none of its own.

@MainActor
final class ZagLiveExperimentModel: ObservableObject {
	@Published private(set) var durability: ZagLiveExperimentCampaign.Durability?
	@Published private(set) var state: ZagCampaignState?
	@Published var confirmations = Set<String>()
	@Published private(set) var preflight: ZagExperimentReadback?
	@Published private(set) var outcome: String?
	@Published private(set) var isBusy = false
	@Published var exported: [URL] = []
	@Published private(set) var exportProblem: String?
	@Published var testApp: URL?

	/// Made once the directory exists (it is an actor).
	@Published private(set) var signIn: ZagFreeAccountSignInModel?
	private let directory: ZagAccountDirectory
	private let secrets = ZagKeychainFreeAccountSecretStore(service: ZagLiveExperiment.accountNamespace)
	private var configuration: ZagAccountDirectory.Configuration
	private static var launched: ZagLiveExperimentCampaign.Durability?

	static let confirmationsRequired: [(String, String)] = [
		("A1", "Created for this experiment; never the personal account; never used to sign apps"),
		("A2", "No payment method; not in the Apple Developer Program"),
		("A3", "2FA on, with a trusted device the owner controls; recovery confirmed"),
		("A4", "Account details kept on paper only"),
		("A5", "Expected: no certificates, App IDs or registered devices"),
		("A6", "This iPhone only, this campaign only"),
	]

	init() {
		var configuration = ZagAccountDirectory.Configuration()
		configuration.namespace = ZagLiveExperiment.accountNamespace
		configuration.makeService = { ZagIsideloadAuthenticationService() }
		configuration.localState = ZagBridgeAnisetteLocalState()
		self.configuration = configuration
		directory = ZagAccountDirectory(
			anisette: ZagBridgeAnisetteSource(),
			secrets: ZagKeychainFreeAccountSecretStore(service: ZagLiveExperiment.accountNamespace),
			preferences: ZagUserDefaultsPreferences(),
			configuration: configuration
		)
	}

	var campaign: ZagLiveExperimentCampaign { ZagLiveExperiment.campaign }
	var constants: ZagCampaignConstants { .compiled }
	var allConfirmed: Bool { Set(Self.confirmationsRequired.map(\.0)).isSubset(of: confirmations) }
	var canRun: Bool { durability == .armed && state == .armed && allConfirmed && !isBusy }

	/// The launch checks run once per process, when this screen first opens
	/// (`FeatherApp.swift` is not changed by the experiment).
	func appear() async {
		if Self.launched == nil {
			Self.launched = campaign.launch()
			_ = ZagIsideloadBridge.configureFromCampaign()
			recordIdentity()
		}
		durability = Self.launched
		state = campaign.state
		if signIn == nil {
			signIn = ZagFreeAccountSignInModel(authenticator: await directory.newSignIn(), diagnostics: ZagFreeAccountDiagnostics())
		}
	}

	private func recordIdentity() {
		ZagLiveExperiment.logger?.record("build.identity", fields: [
			"campaignID": .string(constants.campaignID),
			"branchSHA8": .string(String(ZagLiveExperimentCampaignConstants.branchSHA.prefix(8))),
			"bridgeLibSHA8": .string(String(ZagLiveExperimentCampaignConstants.bridgeLibSHA.prefix(8))),
			"zsignSHA8": .string(String(ZagLiveExperimentCampaignConstants.zsignSHA.prefix(8))),
			"installID8": .string(ZagLiveExperiment.logger?.installID8 ?? "00000000"),
			"conditions": .list(["ZAG_APPLE_BRIDGE", "ZAG_LIVE_EXPERIMENT", "ZAG_ZSIGN_STRICT"]),
			"debugCompiled": .string("false"),
		])
	}

	/// P3: the device's profiles must be readable before anything live.
	func readPreflight() async {
		isBusy = true
		defer { isBusy = false }
		let read = await ZagRPPairingFreeAccountInstaller.readProfiles()
		switch read {
		case .success(let profiles):
			preflight = .verified
			ZagLiveExperiment.logger?.record("readback.preflight", fields: ["result": .string("verified"), "installedProfileCount": .int(min(profiles.count, 500))])
		case .failure:
			preflight = .unavailable
			ZagLiveExperiment.logger?.record("readback.preflight", outcome: "failed", fields: ["result": .string("unavailable"), "unavailableReason": .string("misagent")])
			campaign.halt(.readbackPreflight)
		}
		state = campaign.state
	}

	/// Step 9: the one test app, for the signed-in account and this iPhone.
	func run() async {
		guard canRun, preflight == .verified, let source = testApp else { return }
		isBusy = true
		defer {
			isBusy = false
			state = campaign.state
		}
		guard case .paired(_, _, let udid) = ZagRPPairingCore.shared.state, !udid.isEmpty else {
			outcome = "Pair this iPhone first (Settings › Pairing)."
			return
		}
		guard let app = try? unpack(source) else {
			outcome = "The test app could not be opened."
			return
		}
		guard let account = await directory.registry.accounts.first?.id else {
			outcome = "Sign in first."
			return
		}
		let keys = configuration.signingKeys
		let provisioner = ZagFreeAccountProvisioner(
			portal: ZagIsideloadDeveloperPortal(account: account, secrets: secrets),
			keys: ZagKeychainSigningKeyFactory(keys: keys),
			secrets: secrets,
			account: account
		)
		let lifecycle = ZagFreeAccountLifecycle(
			directory: directory, provisioner: provisioner,
			adapter: ZagFreeAccountSigningAdapter(signer: ZagZsignCodeSigner(), keychainKeys: keys),
			installer: ZagExperimentInstaller(), secrets: secrets
		)
		guard let entitlements = try? ZagEntitlementSet([:]) else { return }
		let component = ZagProvisioningRequest.Component(
			originalBundleIdentifier: ZagLiveExperiment.testBundleIdentifier, name: "Zag Live Test", entitlements: entitlements
		)
		var ledger = ZagRefreshLedger()
		let result = await lifecycle.install(
			app: component, scope: nil, device: ZagTargetDevice(udid: udid, name: "iPhone"),
			appAt: app, ledger: &ledger, now: Date()
		)
		switch result {
		case .installed: outcome = "Installed and verified from the device. Open the test app, then confirm below."
		case .installedUnverified: outcome = "Installed, but not verified from the device. This is not a pass."
		case .failed(let reason): outcome = "Stopped: \(reason)."
		case .notStarted: outcome = "Not started."
		}
	}

	func confirmLaunch(_ launched: Bool) {
		ZagLiveExperiment.logger?.record("install.launch", fields: ["confirmedByOwner": .bool(launched)])
		if !launched { campaign.halt(.launchFailed) }
		state = campaign.state
	}

	func stop() {
		campaign.halt(.ownerUnrecognised)
		state = campaign.state
	}

	/// The report: validated, then written as JSON and Markdown for the
	/// share sheet. Nothing is sent anywhere by the app.
	func export() {
		guard let logger = ZagLiveExperiment.logger else { return }
		let header = ZagExperimentReport.Header(
			campaignID: constants.campaignID, installID8: logger.installID8,
			branchSHA8: String(ZagLiveExperimentCampaignConstants.branchSHA.prefix(8)),
			bridgeLibSHA8: String(ZagLiveExperimentCampaignConstants.bridgeLibSHA.prefix(8)),
			zsignSHA8: String(ZagLiveExperimentCampaignConstants.zsignSHA.prefix(8)),
			ipaSHA8: testApp.flatMap(Self.sha8) ?? "00000000",
			startedAtUTC: Date(), iOS: Self.iOSVersion, device: "iPhone",
			gates: ZagLiveExperimentCampaignConstants.gates,
			providerHost: constants.providerHost ?? "", serialPolicy: constants.deviceSerialPolicy,
			conditions: ["ZAG_APPLE_BRIDGE", "ZAG_LIVE_EXPERIMENT", "ZAG_ZSIGN_STRICT"]
		)
		let report = ZagExperimentReport(header: header, events: logger.events, privateKeyExportCalls: logger.privateKeyExportCalls)
		switch report.export(provider: constants.providerHost) {
		case .success(let files):
			let directory = FileManager.default.temporaryDirectory
			let json = directory.appendingPathComponent("\(report.fileStem).json")
			let markdown = directory.appendingPathComponent("\(report.fileStem).md")
			do {
				try files.json.write(to: json)
				try Data(files.markdown.utf8).write(to: markdown)
				exported = [json, markdown]
				exportProblem = nil
			} catch {
				exportProblem = "The report could not be written."
			}
		case .failure(.blocked(let rule)):
			exportProblem = "Export blocked by rule \(rule). The report was not written."
		case .failure(.passed):
			exportProblem = "The report was not written."
		}
	}

	private static var iOSVersion: String {
		let version = ProcessInfo.processInfo.operatingSystemVersion
		return "\(version.majorVersion).\(version.minorVersion)"
	}

	private static func sha8(_ url: URL) -> String? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(8))
	}

	/// The test IPA's `.app`, unpacked into a fresh temporary directory.
	private func unpack(_ ipa: URL) throws -> URL {
		let work = FileManager.default.temporaryDirectory.appendingPathComponent("ZagLiveTest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
		let accessing = ipa.startAccessingSecurityScopedResource()
		defer { if accessing { ipa.stopAccessingSecurityScopedResource() } }
		try Zip.unzipFile(ipa, destination: work, overwrite: true, password: nil)
		let payload = work.appendingPathComponent("Payload")
		guard let app = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return app
	}
}

struct ZagLiveExperimentView: View {
	@StateObject private var model = ZagLiveExperimentModel()
	@State private var choosingApp = false
	@State private var sharing = false

	var body: some View {
		Form {
			Section {
				VStack(alignment: .leading, spacing: 4) {
					Text("LIVE TEST").font(.headline).foregroundStyle(.red)
					Text("\(model.constants.campaignID) · \(String(ZagLiveExperimentCampaignConstants.branchSHA.prefix(8)))").font(.caption.monospaced())
					Text("State: \(model.state?.rawValue ?? "none") · Launch: \(model.durability?.rawValue ?? "…")").font(.caption)
				}
			} footer: {
				Text("Arming (E5): open this screen once, delete Zag Store, reinstall the same build, and open it again. Only then does the state read armed.")
			}

			Section("Owner confirmations") {
				ForEach(ZagLiveExperimentModel.confirmationsRequired, id: \.0) { item in
					Toggle(isOn: Binding(
						get: { model.confirmations.contains(item.0) },
						set: { if $0 { model.confirmations.insert(item.0) } else { model.confirmations.remove(item.0) } }
					)) {
						Text("\(item.0): \(item.1)").font(.footnote)
					}
				}
			}

			if let signIn = model.signIn {
				ZagLiveExperimentSignInSection(signIn: signIn, enabled: model.canRun)
			}

			Section {
				Button("Read Installed Profiles (P3)") { Task { await model.readPreflight() } }
					.disabled(model.isBusy)
				if let preflight = model.preflight { Text("Read-back: \(preflight.rawValue)").font(.footnote) }
				Button(model.testApp == nil ? "Choose Test App…" : "Test App: \(model.testApp!.lastPathComponent)") { choosingApp = true }
				Button("Provision, Sign and Install") { Task { await model.run() } }
					.disabled(!model.canRun || model.preflight != .verified || model.testApp == nil || model.signIn?.phase != .signedIn)
				if let outcome = model.outcome { Text(outcome).font(.footnote) }
				Button("The test app opened") { model.confirmLaunch(true) }
				Button("The test app did not open") { model.confirmLaunch(false) }
			} header: {
				Text("Run")
			}

			Section {
				Button("Stop the Campaign", role: .destructive) { model.stop() }
				Button("Export Report") {
					model.export()
					sharing = !model.exported.isEmpty
				}
				if let problem = model.exportProblem { Text(problem).font(.footnote).foregroundStyle(.red) }
			} footer: {
				Text("Stopping is permanent for this campaign. The report holds no account details and is shared only by you.")
			}
		}
		.navigationTitle("Live Test")
		.task { await model.appear() }
		.fileImporter(isPresented: $choosingApp, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
			model.testApp = try? result.get()
		}
		.sheet(isPresented: $sharing) {
			ZagLiveExperimentShareSheet(items: model.exported)
		}
	}
}

/// Sign-in through the experiment's own account directory. The password and
/// code fields are the sign-in model's; nothing here stores them.
private struct ZagLiveExperimentSignInSection: View {
	@ObservedObject var signIn: ZagFreeAccountSignInModel
	let enabled: Bool

	var body: some View {
		Section("Sign in") {
			switch signIn.phase {
			case .signedIn:
				Label("Signed in", systemImage: "checkmark.circle")
			case .awaitingCode:
				SecureField("Verification code", text: $signIn.code)
					.textContentType(.oneTimeCode).keyboardType(.numberPad)
				Button("Submit Code") { Task { await signIn.submitCode() } }
			default:
				TextField("Apple Account", text: $signIn.appleID)
					.textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
				SecureField("Password", text: $signIn.password)
					.textContentType(.password)
				Button("Sign In") { Task { await signIn.signIn() } }
					.disabled(!enabled || signIn.isBusy)
			}
			if let notice = signIn.notice { Text(notice).font(.footnote) }
		}
	}
}

private struct ZagLiveExperimentShareSheet: UIViewControllerRepresentable {
	let items: [URL]
	func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
