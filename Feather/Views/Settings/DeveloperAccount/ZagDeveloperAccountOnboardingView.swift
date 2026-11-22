import SwiftUI
import UniformTypeIdentifiers

/// Connect a user-owned paid Apple Developer account with an App Store Connect
/// API key: import the `.p8`, enter the Key ID, Issuer ID and Team ID, and see
/// how far the key is proven (validated, then provisioning verified).
///
/// This screen is presented only when `developerAccountEnabled` is set (every
/// release build leaves it off), and its model refuses to do anything when the
/// gate is closed, so the feature stays inaccessible until it is turned on.
struct ZagDeveloperAccountOnboardingView: View {
	@ObservedObject var model: ZagDeveloperAccountOnboardingModel
	/// Installing with the connected account. Absent, the screen only connects.
	var installer: ZagDeveloperAccountInstallModel?
	var apps: () -> [ZagDeveloperAccountApp] = { [] }
	var device: () -> ZagTargetDevice? = { nil }
	@State private var isImporting = false
	@State private var confirmingRemoval = false

	private var p8Types: [UTType] {
		[UTType(filenameExtension: "p8") ?? .data, .data]
	}

	var body: some View {
		Form {
			Section {
				statusRow
			} header: {
				Text("Connection")
			} footer: {
				Text("Your key is a team key with the Admin role. It stays on this device and is never uploaded to Zag Store.")
			}

			Section {
				Button {
					isImporting = true
				} label: {
					HStack {
						Text("API Key (.p8)")
						Spacer()
						Text(model.importedKeyFileName ?? "Import")
							.foregroundStyle(.secondary)
					}
				}
				LabeledContent("Key ID") {
					TextField("ABCDE12345", text: $model.keyID)
						.textInputAutocapitalization(.characters)
						.disableAutocorrection(true)
						.multilineTextAlignment(.trailing)
				}
				LabeledContent("Issuer ID") {
					TextField("00000000-0000-0000-0000-000000000000", text: $model.issuerID)
						.textInputAutocapitalization(.never)
						.disableAutocorrection(true)
						.multilineTextAlignment(.trailing)
				}
				LabeledContent("Team ID") {
					TextField("ABCDE12345", text: $model.teamID)
						.textInputAutocapitalization(.characters)
						.disableAutocorrection(true)
						.multilineTextAlignment(.trailing)
				}
			} header: {
				Text("Key")
			} footer: {
				Text("Create the key in App Store Connect under Users and Access → Integrations → App Store Connect API (Team Keys).")
			}

			if model.isConnected, let installer {
				ZagDeveloperAccountInstallSection(installer: installer, apps: apps, device: device) {
					model.refreshStatus()
				}
			}

			Section {
				if model.isConnected {
					Button("Disconnect Key", role: .destructive) { model.disconnect() }
				} else {
					Button {
						Task { await model.connect() }
					} label: {
						HStack {
							Text("Connect")
							if model.isBusy { Spacer(); ProgressView() }
						}
					}
					.disabled(!model.canConnect)
				}
			}

			// Always offered: a disconnected account can still hold this
			// device's signing identity and Keychain key.
			Section {
				Button("Remove Developer Account", role: .destructive) { confirmingRemoval = true }
			}
		}
		.navigationTitle("Developer Account")
		.confirmationDialog("Remove Developer Account?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
			Button("Remove", role: .destructive) { model.removeAccount() }
		} message: {
			Text("Removes the API key and this device's signing certificate key. Apps already installed keep working until their profiles expire. Nothing is changed in your Apple Developer account.")
		}
		.fileImporter(isPresented: $isImporting, allowedContentTypes: p8Types) { result in
			guard case .success(let url) = result else { return }
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
				model.importKey(contents: "", fileName: url.lastPathComponent)
				return
			}
			model.importKey(contents: contents, fileName: url.lastPathComponent)
		}
		.onAppear { model.restore() }
	}

	@ViewBuilder private var statusRow: some View {
		switch model.phase {
		case .idle:
			Label("Not connected", systemImage: "circle.dashed")
				.foregroundStyle(.secondary)
		case .validating:
			Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
		case .credentialsValidated(let keyID, _):
			VStack(alignment: .leading, spacing: 2) {
				Label(ZagDeveloperAccountStatus.credentialsValidatedText, systemImage: "checkmark.circle")
					.foregroundStyle(.orange)
				Text("Key \(keyID). Zag Store has not yet created anything with it; the first install confirms it can provision.")
					.font(.footnote).foregroundStyle(.secondary)
			}
		case .provisioningVerified(let keyID):
			Label("Provisioning verified · Key \(keyID)", systemImage: "checkmark.seal.fill")
				.foregroundStyle(.green)
		case .needsAttention(let message):
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
		case .failed(let message):
			Label(message, systemImage: "xmark.octagon.fill")
				.foregroundStyle(.red)
		}
	}
}

/// Pick a Library app and install it with the connected account.
private struct ZagDeveloperAccountInstallSection: View {
	@ObservedObject var installer: ZagDeveloperAccountInstallModel
	let apps: () -> [ZagDeveloperAccountApp]
	let device: () -> ZagTargetDevice?
	let finished: () -> Void
	@State private var choices: [ZagDeveloperAccountApp] = []
	@State private var selection: String?

	var body: some View {
		Section {
			Picker("App", selection: $selection) {
				Text("Choose…").tag(String?.none)
				ForEach(choices, id: \.url.path) { app in
					Text(app.name).tag(Optional(app.url.path))
				}
			}
			.disabled(installer.isRunning)
			if installer.isRunning {
				HStack {
					ProgressView()
					Text("Provisioning, signing and installing…").foregroundStyle(.secondary)
					Spacer()
					Button("Cancel", role: .cancel) { installer.cancel() }
				}
			} else {
				Button("Install with Developer Account") {
					guard let app = choices.first(where: { $0.url.path == selection }) else { return }
					installer.start(app, on: device())
				}
				.disabled(selection == nil)
			}
			if case .finished(let message, let succeeded) = installer.phase {
				Label(message, systemImage: succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
					.foregroundStyle(succeeded ? .green : .orange)
			}
		} header: {
			Text("Install")
		} footer: {
			Text("Registers this iPhone, creates or reuses a development certificate, bundle ID and profile in your team, then signs on this device and installs over the existing pairing.")
		}
		.onAppear { choices = apps() }
		.onChange(of: installer.phase) { phase in
			if case .finished = phase { finished() }
		}
	}
}
