#if canImport(SwiftUI)
import SwiftUI
import UIKit

struct ZagAppleSigningSettingsView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
	@ObservedObject private var pairing = ZagRPPairingCore.shared
	@State private var catalog = ZagNativeAppleIDCatalog()
	@State private var removing: ZagNativeAppleID?
	@State private var failure: String?

	var body: some View {
		List {
			if ZagAppleAuthMachine.isLinked {
				Section("Apple IDs") {
					ForEach(catalog.accounts) { account in
						NavigationLink {
							ZagAppleIDAccountDetail(account: account)
								.onDisappear { reload() }
						} label: {
							ZagAppleIDAccountLabel(account: account, isDefault: account.id == catalog.defaultID)
						}
						.contextMenu {
							Button("Set as Default") { perform { try ZagNativeAppleIDs.shared.setDefault(account.id) } }
							if ZagNativeAppleIDs.shared.connectedToken(account.id) != nil {
								Button("Sign Out") { perform { try ZagNativeAppleIDs.shared.signOut(account.id) } }
							}
							Button("Remove Apple ID", role: .destructive) { removing = account }
						}
					}
					NavigationLink {
						ZagAppleIDAuthenticationView(account: nil)
							.onDisappear { reload() }
					} label: { Label("Add Apple ID", systemImage: "plus.circle") }
				}
				Section("Device") {
					Label(pairing.hasSavedPairing ? "Installation pairing saved" : "Set up installation pairing",
						  systemImage: pairing.hasSavedPairing ? "checkmark.circle.fill" : "iphone")
				}
			} else {
				Label("Apple ID signing requires an iPhone build with the native engine.", systemImage: "info.circle")
			}
		}
		.navigationTitle("Apple IDs & Signing")
		.tint(Color(hex: themeColorHex))
		.onAppear { reload() }
		.alert("Remove Apple ID?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
			Button("Remove", role: .destructive) { perform { try ZagNativeAppleIDs.shared.remove(account.id) } }
			Button("Cancel", role: .cancel) {}
		} message: { account in
			Text("Apps signed by \(account.label) stay installed. Add this Apple ID again to renew them. If it was the default, the first remaining Apple ID becomes the default.")
		}
		.alert("Apple ID", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK", role: .cancel) {}
		} message: { Text(failure ?? "") }
	}

	private func reload() { perform {} }
	private func perform(_ action: () throws -> Void) {
		do { try action(); catalog = try ZagNativeAppleIDs.shared.catalog() }
		catch { failure = error.localizedDescription }
	}
}

private struct ZagAppleIDAccountLabel: View {
	let account: ZagNativeAppleID
	let isDefault: Bool
	var body: some View {
		let connected = ZagNativeAppleIDs.shared.connectedToken(account.id) != nil
		Label {
			VStack(alignment: .leading, spacing: 3) {
				Text(account.label)
				Text([connected ? "Signed in" : "Sign-in required", isDefault ? "Default" : nil,
					  account.teams.first?.name].compactMap { $0 }.joined(separator: " · "))
					.font(.caption).foregroundStyle(.secondary)
			}
		} icon: {
			Image(systemName: connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
				.foregroundStyle(connected ? Color.green : Color.accentColor)
		}
	}
}

private struct ZagAppleIDAccountDetail: View {
	let account: ZagNativeAppleID
	@State private var failure: String?
	@State private var catalog = ZagNativeAppleIDCatalog()

	var body: some View {
		List {
			Section {
				ZagAppleIDAccountLabel(account: catalog.accounts.first(where: { $0.id == account.id }) ?? account,
					isDefault: catalog.defaultID == account.id)
				Button("Set as Default") {
					do { try ZagNativeAppleIDs.shared.setDefault(account.id); reload() }
					catch { failure = error.localizedDescription }
				}
				.disabled(catalog.defaultID == account.id)
				NavigationLink("Authentication") {
					ZagAppleIDAuthenticationView(account: catalog.accounts.first(where: { $0.id == account.id }) ?? account)
						.onDisappear { reload() }
				}
			}
			#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
			if let current = catalog.accounts.first(where: { $0.id == account.id }),
			   ZagNativeAppleIDs.shared.connectedToken(account.id) != nil {
				Section("Developer Teams") {
					ForEach(current.teams, id: \.identifier) { team in
						NavigationLink {
							ZagCertificateReplacementView(model: .inventory(team: team.identifier,
								expectedScope: .init(accountID: account.id, teamID: team.identifier)))
						} label: {
							LabeledContent(team.name, value: team.identifier)
						}
					}
				}
			}
			#endif
			if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
		}
		.navigationTitle("Apple ID")
		.onAppear { reload() }
	}
	private func reload() {
		do { catalog = try ZagNativeAppleIDs.shared.catalog() }
		catch { failure = error.localizedDescription }
	}
}

struct ZagAppleIDAuthenticationView: View {
	@StateObject private var model: ZagNativeSignInModel
	var onAuthenticated: (@MainActor (UUID) -> Void)?
	init(account: ZagNativeAppleID?, onAuthenticated: (@MainActor (UUID) -> Void)? = nil) {
		_model = StateObject(wrappedValue: ZagNativeSignInModel(account: account))
		self.onAuthenticated = onAuthenticated
	}

	var body: some View {
		ZagNativeAccountSignInContent(model: model)
			.navigationTitle("Apple ID")
			.task { await model.restore() }
			.onChange(of: model.phase) { phase in
				if phase == .signedIn, let id = model.accountID { onAuthenticated?(id) }
			}
			.onDisappear {
				if model.isBusy { model.cancel() }
			}
	}
}
#endif

#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
/// Presents the same account labels and authentication form as Settings.
/// A choice is returned to this operation only.
@MainActor
enum ZagAppleIDSigningSelection {
	private static func availablePresenter() async -> UIViewController? {
		// Always Ask can still be dismissing when the account picker is requested.
		for _ in 0..<20 {
			guard let presenter = UIApplication.topViewController() else { return nil }
			if !(presenter is UIAlertController), !presenter.isBeingDismissed,
			   presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil { return presenter }
			do { try await Task.sleep(nanoseconds: 50_000_000) }
			catch { return nil }
		}
		return nil
	}

	static func team(from teams: [ZagNativeDeveloperTeam], required: String?) async throws -> ZagNativeDeveloperTeam {
		if let team = ZagNativeDeveloperTeam.personalTeam(in: teams, expectedID: required) { return team }
		let eligible = teams.filter(\.isPersonalTeam)
		guard required == nil, !eligible.isEmpty,
			  let presenter = await availablePresenter() else {
			throw ZagNativeAccountInstall.Failure.personalTeam
		}
		return try await withCheckedThrowingContinuation { continuation in
			let alert = UIAlertController(title: "Personal Team", message: nil, preferredStyle: .actionSheet)
			var offered: Set<String> = []
			for team in eligible where offered.insert(team.teamID).inserted {
				alert.addAction(UIAlertAction(title: "\(team.name) (\(team.teamID))", style: .default) { _ in
					continuation.resume(returning: team)
				})
			}
			alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(throwing: ZagInstallCancelled()) })
			alert.popoverPresentationController?.sourceView = presenter.view
			alert.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
			presenter.present(alert, animated: true)
		}
	}

	static func resolve(required: UUID? = nil, interactive: Bool = true, exclude: UUID? = nil) async throws -> UUID {
		let directory = ZagNativeAppleIDs.shared
		let catalog = try directory.catalog()
		if let required, directory.connectedToken(required) != nil { return required }
		let available = catalog.accounts.filter { $0.id != exclude }
		if required == nil, available.count == 1, exclude == nil,
		   let only = available.first, directory.connectedToken(only.id) != nil { return only.id }
		if !interactive {
			guard let selected = required ?? catalog.defaultID, directory.connectedToken(selected) != nil else {
				throw ZagNativeAppleIDs.Failure.unavailable
			}
			return selected
		}
		guard let presenter = await availablePresenter() else {
			throw ZagNativeAppleIDs.Failure.unavailable
		}
		let account = required.flatMap { required in catalog.accounts.first { $0.id == required } }
		if required != nil && account == nil { throw ZagNativeAppleIDs.Failure.unavailable }
		return try await withCheckedThrowingContinuation { continuation in
			var finished = false
			@MainActor func finish(_ id: UUID?) {
				guard !finished else { return }
				finished = true
				presenter.dismiss(animated: true) {
					if let id { continuation.resume(returning: id) }
					else { continuation.resume(throwing: ZagInstallCancelled()) }
				}
			}
			let host = UIHostingController(rootView: ZagAppleIDSelectionView(accounts: available,
				defaultID: catalog.defaultID, required: account, forceChoice: exclude != nil, finish: finish))
			host.isModalInPresentation = true
			presenter.present(host, animated: true)
		}
	}
}

private struct ZagAppleIDSelectionView: View {
	let accounts: [ZagNativeAppleID]
	let defaultID: UUID?
	let required: ZagNativeAppleID?
	let forceChoice: Bool
	let finish: @MainActor (UUID?) -> Void
	@State private var selected: UUID?
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"

	var body: some View {
		NavigationStack {
			Group {
				if let required {
					ZagAppleIDAuthenticationView(account: required, onAuthenticated: finish)
				} else if accounts.isEmpty {
					ZagAppleIDAuthenticationView(account: nil, onAuthenticated: finish)
				} else if accounts.count == 1 && !forceChoice, let account = accounts.first {
					ZagAppleIDAuthenticationView(account: account, onAuthenticated: finish)
				} else {
					List {
						ForEach(accounts) { account in
							Button {
								selected = account.id
							} label: {
								HStack {
									ZagAppleIDAccountLabel(account: account, isDefault: account.id == defaultID)
									Spacer()
									if (selected ?? defaultID) == account.id { Image(systemName: "checkmark") }
								}
							}
							.buttonStyle(.plain)
						}
						if let account = accounts.first(where: { $0.id == (selected ?? defaultID) }) {
							if ZagNativeAppleIDs.shared.connectedToken(account.id) != nil {
								Button("Continue") { finish(account.id) }
							} else {
								NavigationLink("Authenticate Selected Apple ID") {
									ZagAppleIDAuthenticationView(account: account, onAuthenticated: finish)
								}
							}
						}
						NavigationLink("Add Apple ID") {
							ZagAppleIDAuthenticationView(account: nil, onAuthenticated: finish)
						}
					}
					.navigationTitle("Choose Apple ID")
				}
			}
			.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } } }
		}
		.tint(Color(hex: themeColorHex))
	}
}
#endif
