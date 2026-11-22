import SwiftUI
import UniformTypeIdentifiers

/// Connect a user-owned paid Apple Developer account with an App Store Connect
/// API key: import the `.p8`, enter the Key ID and Issuer ID, and see whether
/// the key is connected.
///
/// This screen is presented only when `developerAccountEnabled` is set (every
/// release build leaves it off), and its model refuses to do anything when the
/// gate is closed, so the feature stays inaccessible until it is turned on.
struct ZagDeveloperAccountOnboardingView: View {
	@ObservedObject var model: ZagDeveloperAccountOnboardingModel
	@State private var isImporting = false

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

			Section {
				if case .connected = model.phase {
					Button("Disconnect", role: .destructive) { model.disconnect() }
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
		}
		.navigationTitle("Developer Account")
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
		case .connected(let keyID, _):
			Label("Connected · Key \(keyID)", systemImage: "checkmark.seal.fill")
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
