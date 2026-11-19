import SwiftUI

// Apple Accounts recovery screens, compiled in every build. Release builds
// show them only when `ZagAppleAccountsFeature.isEnabled` (off in this
// version); Debug builds reach them from the simulated Apple Accounts screen.

/// Settings → Apple Accounts → Stored Account Data, for Release builds: the
/// production directory, created when the screen opens.
struct ZagStoredAccountDataScreen: View {
	@StateObject private var model = ZagStoredAccountDataModel(source: ZagAppleAccountsFeature.makeDirectory())

	var body: some View {
		ZagStoredAccountDataView(model: model) { EmptyView() }
	}
}

/// Zag Store's own Keychain items (and anisette state) that belong to no
/// account in the list. Shows which can be recovered by signing in again and
/// which can only be removed; removes only what the user confirms, after the
/// directory checks each item again. Never runs by itself.
struct ZagStoredAccountDataView<Extra: View>: View {
	@ObservedObject var model: ZagStoredAccountDataModel
	@ViewBuilder var extra: () -> Extra

	var body: some View {
		let data = model.data
		let recoverable = data?.accounts.filter(\.isRecoverable) ?? []
		let unowned = data?.accounts.filter { !$0.isRecoverable } ?? []
		let scopes = data?.localStateScopes ?? []
		Form {
			if model.failed {
				Section {
					Label("Stored account data could not be read. Nothing was removed.", systemImage: "exclamationmark.circle")
						.foregroundStyle(.orange)
				}
			} else if data?.isEmpty ?? true {
				Section {
					Text(data == nil ? "Checking…" : "No stored data outside your accounts.").foregroundStyle(.secondary)
				}
			}
			if !recoverable.isEmpty {
				Section {
					ForEach(recoverable, id: \.id) { account in
						item(account.maskedAppleID ?? "Apple Account", detail: "Sign in to this Apple Account again to recover its signing keys.") {
							model.prepareRemoval(accounts: [account], scopes: [])
						}
					}
				} header: {
					Text("Recoverable")
				} footer: {
					Text("Signing in again restores these accounts with their keys, so their apps keep the same certificate.")
				}
			}
			if !unowned.isEmpty {
				Section {
					ForEach(unowned, id: \.id) { account in
						item("Unidentified account", detail: "No record says which Apple Account this was. It can only be removed.") {
							model.prepareRemoval(accounts: [account], scopes: [])
						}
					}
				} header: {
					Text("Not Recoverable")
				}
			}
			if !scopes.isEmpty {
				Section {
					ForEach(scopes, id: \.self) { scope in
						item("Sign-in device data", detail: "Anisette state no account uses.") {
							model.prepareRemoval(accounts: [], scopes: [scope])
						}
					}
				} header: {
					Text("Anisette State")
				}
			}
			if let data, !data.isEmpty {
				Section {
					Button(role: .destructive) {
						model.prepareRemoval(accounts: data.accounts, scopes: data.localStateScopes)
					} label: {
						Label("Remove All Listed…", systemImage: "trash").foregroundStyle(.red)
					}
					.accessibilityIdentifier("storedData.removeAll")
				}
			}
			if let result = model.result {
				Section { Text(result).font(.footnote).accessibilityIdentifier("storedData.result") }
			}
			Section {
				extra()
			} footer: {
				Text("Nothing here is removed automatically. Each item is checked again just before removal; one that changed is kept. Certificates are never revoked.")
			}
		}
		.navigationTitle("Stored Account Data")
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.task { await model.load() }
		.confirmationDialog(
			"Remove Stored Data?",
			isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
			titleVisibility: .visible
		) {
			Button("Remove", role: .destructive) { Task { await model.confirmRemoval() } }
			Button("Cancel", role: .cancel) { model.cancelRemoval() }
		} message: {
			Text(model.pendingRemoval?.accounts.contains(where: \.isRecoverable) == true
				 ? "A recoverable account's signing keys are deleted and cannot be recovered by signing in. Its certificates are not revoked."
				 : "These items are deleted from this device. Certificates are not revoked.")
		}
	}

	private func item(_ title: String, detail: String, remove: @escaping () -> Void) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.body.weight(.semibold))
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
			Button(role: .destructive, action: remove) {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.accessibilityLabel("Remove")
		}
	}
}

/// A certificate request whose answer was lost and cannot be confirmed from
/// Apple's certificate list. Check Again only reads that list; Abandon gives
/// the request up after confirmation. Nothing is requested again, revoked or
/// retried in the background.
struct ZagCertificateRecoveryView: View {
	@ObservedObject var model: ZagCertificateRecoveryModel
	var teamName: String

	var body: some View {
		Form {
			Section {
				HStack(alignment: .top, spacing: 12) {
					Image(systemName: model.request == nil ? "checkmark.seal" : "questionmark.diamond")
						.font(.system(size: 28))
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(model.request == nil ? .green : .orange)
					VStack(alignment: .leading, spacing: 4) {
						Text(model.request == nil ? "No Unresolved Request" : "Certificate Request Unresolved").font(.headline)
						Text("A certificate request for \(teamName) was sent, but its answer was lost. Apple may have issued a certificate. Zag Store stops requesting certificates for this team until this is settled.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				if let request = model.request {
					LabeledContent("Sent") { Text(request.startedAt, style: .date) }
					LabeledContent("Attempts", value: "\(request.attempts)")
				}
			}

			Section {
				if model.phase == .checking {
					HStack(spacing: 12) {
						ProgressView()
						Text("Checking Apple's certificate list…").foregroundStyle(.secondary)
						Spacer()
						Button("Cancel") { model.cancelCheck() }
							.accessibilityIdentifier("certificateRecovery.cancelCheck")
					}
				} else {
					Button {
						Task { await model.checkAgain() }
					} label: {
						Label("Check Again", systemImage: "arrow.clockwise")
					}
					.disabled(model.request == nil || model.phase != .idle)
					.accessibilityIdentifier("certificateRecovery.checkAgain")
				}
				Button(role: .destructive) {
					model.requestAbandon()
				} label: {
					Label("Abandon Request…", systemImage: "xmark.bin").foregroundStyle(.red)
				}
				.disabled(model.request == nil || model.phase != .idle)
				.accessibilityIdentifier("certificateRecovery.abandon")
			} footer: {
				Text("Check Again only reads the certificate list; it never requests a certificate. Zag Store never revokes a certificate and never retries this in the background.")
			}

			if let message = model.message {
				Section {
					Label(message, systemImage: model.isSettled ? "checkmark.circle" : "exclamationmark.circle")
						.foregroundStyle(model.isSettled ? Color.primary : Color.orange)
						.accessibilityIdentifier("certificateRecovery.result")
				} header: {
					Text("Result")
				}
			}
		}
		.navigationTitle("Certificate Request")
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.task { await model.load() }
		.confirmationDialog(
			"Abandon This Certificate Request?",
			isPresented: Binding(get: { model.phase == .confirmingAbandon }, set: { if !$0 { model.cancelAbandon() } }),
			titleVisibility: .visible
		) {
			Button("Abandon Request", role: .destructive) { Task { await model.confirmAbandon() } }
			Button("Cancel", role: .cancel) { model.cancelAbandon() }
		} message: {
			Text("Apple may already have issued a certificate for this request. If it did, that certificate keeps using one of the team's certificate slots until it expires or you revoke it. Zag Store will not revoke it. The next signing requests a new certificate.")
		}
	}
}
