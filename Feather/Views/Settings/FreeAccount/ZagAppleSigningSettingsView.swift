#if canImport(SwiftUI)
import SwiftUI
import UIKit

struct ZagAppleSigningSettingsView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
	@ObservedObject private var pairing = ZagRPPairingCore.shared
	@State private var catalog = ZagNativeAppleIDCatalog()
	@State private var failure: String?
	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	@State private var deviceCount: Int?
	@State private var checkingDevice = false
	@State private var checkingSelf = false
	@State private var selfInventoryRevision = 0
	#endif

	var body: some View {
		List {
			if ZagAppleAuthMachine.isLinked {
				Section("Apple IDs") {
					ForEach(catalog.accounts) { account in
						NavigationLink {
							ZagAppleIDAccountDetail(account: account)
								.onDisappear { reload() }
						} label: {
							ZagAppleIDAccountLabel(account: account, isActive: account.id == catalog.activeID)
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
				#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
				Section {
					let _ = selfInventoryRevision
					let receipt = Bundle.main.bundleIdentifier.flatMap { ZagNativeAppInventory.entry(bundleIdentifier: $0) }
					let expiry = receipt.flatMap { entry -> Date? in
						let identity = entry.installation.executableIdentity
						guard entry.pendingInstall == nil, entry.installation.record.expiryVerified == true,
							  identity?.version == Bundle.main.version,
							  identity?.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
						return entry.installation.record.expiresAt
					}
					LabeledContent("Verified expiration", value: expiry?.formatted() ?? "Unknown")
					Button(checkingSelf ? "Verifying" : "Verify This Installation") {
						checkingSelf = true
						Task {
							defer { checkingSelf = false; selfInventoryRevision += 1 }
							do { try await ZagNativeAccountInstall.verifyRunningInstallation() }
							catch { failure = "Zag Store could not verify this installation. Check pairing and sign in with the original Apple ID." }
						}
					}
					.disabled(checkingSelf || !pairing.hasSavedPairing)
				} header: {
					Text("Zag Store Renewal")
				} footer: {
					Text("Verified Personal Team installations can renew through Refresh All. If Zag Store has expired, use the original signer and bundle identifier to recover access. A different signing identity may affect local data and Keychain access.")
				}
				Section {
					LabeledContent("Verified free-profile apps", value: deviceCount.map(String.init) ?? "Unknown")
					LabeledContent("Installation capacity", value: "Unknown")
					LabeledContent("Available slots", value: "Unknown")
					Button(checkingDevice ? "Checking" : "Check Device") {
						checkingDevice = true
						Task {
							defer { checkingDevice = false }
							do { deviceCount = try await ZagAppleIDCapacity.synchronizeDevice() }
							catch { deviceCount = nil; failure = "Check installation pairing and the device connection, then try again." }
						}
					}
					.disabled(checkingDevice || !pairing.hasSavedPairing)
				} header: {
					Text("Device Capacity")
				} footer: {
					Text("This count covers apps Zag Store can verify. iOS decides whether another app can be installed.")
				}
				#endif
			} else {
				Label("Apple ID signing requires an iPhone build with the native engine.", systemImage: "info.circle")
			}
		}
		.navigationTitle("Apple IDs")
		.tint(Color(hex: themeColorHex))
		.onAppear { reload() }
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		.onReceive(ZagNativeAppInventory.changes) { _ in selfInventoryRevision += 1; deviceCount = nil }
		#endif
		.alert("Apple ID", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK", role: .cancel) {}
		} message: { Text(failure ?? "") }
	}

	private func reload() {
		do { catalog = try ZagNativeAppleIDs.shared.catalog() }
		catch { failure = error.localizedDescription }
	}
}

private struct ZagAppleIDAccountLabel: View {
	let account: ZagNativeAppleID
	let isActive: Bool
	var body: some View {
		let connected = ZagNativeAppleIDs.shared.connectedToken(account.id) != nil
		Label {
			VStack(alignment: .leading, spacing: 3) {
				Text(account.label)
				HStack(spacing: 0) {
					Text(connected ? (isActive ? "Active" : "Signed in") : "Sign-in required")
						.foregroundStyle(connected && isActive ? Color.green : Color.secondary)
					if let team = account.teams.first?.name {
						Text(" · " + team).foregroundStyle(.secondary)
					}
				}
				.font(.caption)
			}
		} icon: {
			Image(systemName: connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
				.foregroundStyle(connected ? Color.green : Color.accentColor)
		}
	}
}

private struct ZagAppleIDAccountDetail: View {
	let account: ZagNativeAppleID
	@Environment(\.dismiss) private var dismiss
	@State private var confirmingSignOut = false
	@State private var failure: String?
	@State private var catalog = ZagNativeAppleIDCatalog()

	var body: some View {
		List {
			Section {
				ZagAppleIDAccountLabel(account: catalog.accounts.first(where: { $0.id == account.id }) ?? account,
					isActive: catalog.activeID == account.id)
				if catalog.activeID != account.id, ZagNativeAppleIDs.shared.connectedToken(account.id) != nil {
					Button("Activate") {
						do { try ZagNativeAppleIDs.shared.activate(account.id); reload() }
						catch { failure = error.localizedDescription }
					}
				}
				NavigationLink(ZagNativeAppleIDs.shared.connectedToken(account.id) == nil ? "Sign In Again" : "Authentication") {
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
				ForEach(current.teams, id: \.identifier) { team in
					ZagAppleIDTeamCapacity(account: account.id, team: team)
				}
			}
			#endif
			Section {
				Button("Sign Out", role: .destructive) { confirmingSignOut = true }
			}
			if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
		}
		.navigationTitle("Apple ID")
		.onAppear { reload() }
		.alert("Sign Out?", isPresented: $confirmingSignOut) {
			Button("Sign Out", role: .destructive) {
				do {
					try ZagNativeAppleIDs.shared.signOut(account.id)
					ZagAppleIDExpirationNotifications.shared.reconcile()
					dismiss()
				}
				catch { failure = error.localizedDescription }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Apps signed by this Apple ID stay installed. To renew them, sign back in with the same Apple ID.")
		}
	}
	private func reload() {
		do { catalog = try ZagNativeAppleIDs.shared.catalog() }
		catch { failure = error.localizedDescription }
	}
}

#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
private struct ZagAppleIDTeamCapacity: View {
	let account: UUID
	let team: ZagDeveloperTeam
	@State private var snapshot: ZagAppleIDCapacity.TeamSnapshot?
	@State private var syncing = false
	@State private var failure: String?

	private var scope: ZagSigningScope { .init(accountID: account, teamID: team.identifier) }

	var body: some View {
		Section {
			if let snapshot {
				LabeledContent("Registered App IDs", value: String(snapshot.activeAppIDCount))
				if team.kind == .personalFree, let capacity = ZagTeamLimits.free.appIDs {
					LabeledContent("App ID capacity", value: String(capacity))
					ProgressView(value: Double(min(snapshot.activeAppIDCount, capacity)), total: Double(capacity))
						.accessibilityLabel("App ID capacity used")
				} else {
					LabeledContent("App ID capacity", value: "Unknown")
				}
				LabeledContent("Next App ID expiry", value: snapshot.nextAppIDExpiry?.formatted() ?? "Unknown")
				LabeledContent("Registered devices", value: String(snapshot.deviceCount))
				LabeledContent("Development certificates", value: String(snapshot.certificateExpirations.count))
				ForEach(Array(snapshot.certificateExpirations.enumerated()), id: \.offset) { _, expiry in
					LabeledContent("Certificate expiry", value: expiry.formatted())
				}
				LabeledContent("Last synchronized", value: snapshot.synchronizedAt.formatted())
			} else {
				LabeledContent("Developer inventory", value: "Unknown")
			}
			LabeledContent("Associated apps", value: String(
				ZagNativeAppInventory.verifiedInstalledEntries().filter { $0.installation.record.owner?.scope == scope }.count))
			Button(syncing ? "Synchronizing" : "Refresh Capacity") {
				syncing = true
				Task {
					defer { syncing = false }
					do { snapshot = try await ZagAppleIDCapacity.synchronize(scope); failure = nil }
					catch { failure = (error as? ZagPortalOperationFailure)?.underlying == .sessionRejected
						? "Sign in again to refresh this team." : "Couldn’t refresh this team. Try again later." }
				}
			}
			.disabled(syncing)
			if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
		} header: {
			Text("\(team.name) Capacity")
		}
		.onAppear { snapshot = ZagAppleIDCapacity.cached(scope) }
	}
}
#endif

struct ZagAppleIDAuthenticationView: View {
	@StateObject private var model: ZagNativeSignInModel
	var onAuthenticated: (@MainActor (UUID) -> Void)?
	private let requiresOriginalAccount: Bool
	init(account: ZagNativeAppleID?, requiresOriginalAccount: Bool = false, onAuthenticated: (@MainActor (UUID) -> Void)? = nil) {
		_model = StateObject(wrappedValue: ZagNativeSignInModel(account: account))
		self.onAuthenticated = onAuthenticated
		self.requiresOriginalAccount = requiresOriginalAccount
	}

	var body: some View {
		ZagNativeAccountSignInContent(model: model, showsSignOut: false, requiresOriginalAccount: requiresOriginalAccount)
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
		if required == nil, exclude == nil, let active = catalog.activeID,
		   directory.connectedToken(active) != nil { return active }
		guard interactive, let presenter = await availablePresenter() else {
			throw ZagNativeAppleIDs.Failure.unavailable
		}
		let available = catalog.accounts.filter {
			$0.id != exclude && (exclude == nil || directory.connectedToken($0.id) != nil)
		}
		guard exclude == nil || !available.isEmpty else { throw ZagNativeAppleIDs.Failure.unavailable }
		let account = try required.map { try directory.accountForAuthentication($0) }
		return try await withCheckedThrowingContinuation { continuation in
			var finished = false
			@MainActor func finish(_ id: UUID?) {
				guard !finished else { return }
				finished = true
				let result = Result<UUID, Error> {
					guard let id else { throw ZagInstallCancelled() }
					guard id != exclude, required == nil || required == id,
						  directory.connectedToken(id) != nil else { throw ZagNativeAppleIDs.Failure.wrongAccount }
					if required == nil, exclude == nil, try directory.catalog().activeID == nil {
						try directory.activate(id)
					}
					return id
				}
				presenter.dismiss(animated: true) { continuation.resume(with: result) }
			}
			let host = UIHostingController(rootView: ZagAppleIDSelectionView(accounts: available,
				activeID: catalog.activeID, required: account, forceChoice: exclude != nil, finish: finish))
			host.isModalInPresentation = true
			presenter.present(host, animated: true)
		}
	}
}

private struct ZagAppleIDSelectionView: View {
	let accounts: [ZagNativeAppleID]
	let activeID: UUID?
	let required: ZagNativeAppleID?
	let forceChoice: Bool
	let finish: @MainActor (UUID?) -> Void
	@State private var selected: UUID?
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"

	var body: some View {
		NavigationStack {
			Group {
				if let required {
					ZagAppleIDAuthenticationView(account: required, requiresOriginalAccount: true, onAuthenticated: finish)
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
									ZagAppleIDAccountLabel(account: account, isActive: account.id == activeID)
									Spacer()
									if (selected ?? activeID) == account.id { Image(systemName: "checkmark") }
								}
							}
							.buttonStyle(.plain)
						}
						if let account = accounts.first(where: { $0.id == (selected ?? activeID) }) {
							if ZagNativeAppleIDs.shared.connectedToken(account.id) != nil {
								Button(activeID == nil && !forceChoice ? "Activate and Continue" : "Continue") { finish(account.id) }
							} else {
								NavigationLink("Authenticate Selected Apple ID") {
									ZagAppleIDAuthenticationView(account: account, onAuthenticated: finish)
								}
							}
						}
						if !forceChoice {
							NavigationLink("Add Apple ID") {
								ZagAppleIDAuthenticationView(account: nil, onAuthenticated: finish)
							}
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
