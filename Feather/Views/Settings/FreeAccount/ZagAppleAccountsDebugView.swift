#if DEBUG
import SwiftUI

// Debug builds only: the Apple Accounts list over the real multi-account
// directory (ZagAccountDirectory) with simulated Apple services. Every
// action goes through the directory or the sign-in model, so account
// isolation is enforced where it is in production, not by this screen.
// Release builds compile none of this file and show no entry point.

/// Owns the simulated service and the directory, and mirrors their state.
@MainActor
final class ZagAppleAccountsLab: ObservableObject {
	struct Row: Identifiable, Equatable {
		let record: ZagAppleAccountRecord
		let state: ZagFreeAccountState?
		var id: UUID { record.id }
	}

	let clock = ZagSimulationClock()
	let service: ZagSimulatedAuthenticationService
	let directory: ZagAccountDirectory
	let diagnostics = ZagFreeAccountDiagnostics()
	/// The simulation's own Keychain service, never the production one.
	let secrets = ZagKeychainFreeAccountSecretStore(service: ZagFreeAccountSimulation.keychainService)

	@Published private(set) var rows: [Row] = []
	@Published private(set) var defaultScope: ZagSigningScope?
	/// Simulated installed apps (nothing is signed or installed here).
	@Published private(set) var ledger = ZagRefreshLedger()
	/// The running sign-in: a new account (nil target) or signing in again.
	@Published private(set) var signIn: ZagFreeAccountSignInModel?
	@Published private(set) var signInTarget: UUID?
	@Published var removal: ZagAccountRemovalPlan?
	@Published var notice: String?
	@Published private(set) var signingCheck: String?
	/// Stored Account Data, over this lab's directory.
	let storedData: ZagStoredAccountDataModel
	@Published var showsStoredData = false
	/// The simulated developer team of the tester's Personal Team, and a
	/// provisioner over it, for interrupting certificate requests.
	let portal: ZagSimulatedDeveloperPortal
	let provisioner: ZagFreeAccountProvisioner
	/// Teams with a certificate request whose outcome is unknown.
	@Published private(set) var unresolved: Set<ZagSigningScope> = []
	@Published private(set) var recovery: ZagCertificateRecoveryModel?
	@Published var showsRecovery = false
	private var simulatedApps = 0

	init() {
		service = ZagSimulatedAuthenticationService(scenario: .signInSucceeds, clock: clock)
		directory = ZagFreeAccountSimulation.makeDirectory(service: service, clock: clock, secrets: secrets, diagnostics: diagnostics)
		storedData = ZagStoredAccountDataModel(source: directory)
		let clock = clock
		portal = ZagSimulatedDeveloperPortal(team: "SIMTEAM001", clock: { clock.now })
		provisioner = ZagFreeAccountProvisioner(
			portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
			diagnostics: diagnostics, operationTimeout: 5, now: { clock.now }
		)
	}

	var now: Date { clock.now }

	func start() async {
		await directory.start()
		await reload()
	}

	func reload() async {
		let registry = await directory.registry
		var rows: [Row] = []
		for account in registry.accounts {
			rows.append(Row(record: account, state: await directory.state(of: account.id)))
		}
		self.rows = rows
		defaultScope = registry.defaultScope
		var unresolved: Set<ZagSigningScope> = []
		for account in registry.accounts {
			for team in account.teams where await provisioner.unresolvedCertificateRequest(accountID: account.id, team: team.identifier) != nil {
				unresolved.insert(ZagSigningScope(accountID: account.id, teamID: team.identifier))
			}
		}
		self.unresolved = unresolved
	}

	func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

	func apps(of account: UUID) -> [ZagSignedAppRecord] {
		ledger.apps(ownedBy: account).compactMap { ledger.records[$0] }
	}

	// MARK: Sign-in

	func beginAdd() async {
		signInTarget = nil
		signIn = ZagFreeAccountSignInModel(authenticator: await directory.newSignIn(), diagnostics: diagnostics)
	}

	func beginSignInAgain(_ id: UUID) async {
		guard let authenticator = await directory.authenticator(for: id) else { return }
		signInTarget = id
		let model = ZagFreeAccountSignInModel(authenticator: authenticator, diagnostics: diagnostics)
		await model.restore()
		// An expired session is cleared first, so the form is ready to sign in.
		if model.phase == .expired { await model.signOut() }
		signIn = model
	}

	/// Called when the model reaches a final state: adopts a new account,
	/// or simply reloads after signing in again.
	func finishSignIn() async {
		guard let model = signIn else { return }
		if model.phase == .signedIn, signInTarget == nil {
			do {
				try await directory.adopt(model.authenticator)
			} catch {
				notice = "The account could not be added."
			}
		}
		if model.phase == .signedIn { signIn = nil }
		await reload()
	}

	func cancelSignIn() async {
		await signIn?.cancel()
		signIn = nil
		await reload()
	}

	// MARK: Account actions

	func setDefault(_ scope: ZagSigningScope) async {
		do { try await directory.setDefault(scope) } catch { notice = "That team is not part of the account." }
		await reload()
	}

	func signOut(_ id: UUID) async {
		do { try await directory.signOut(id) } catch { notice = "Sign-out could not remove the stored session. Try again." }
		await reload()
	}

	/// What signing would use for `scope` (nil: the default), through the
	/// directory's own rule: never another account.
	func checkSigning(_ scope: ZagSigningScope?) async {
		do {
			let chosen = try await directory.signingScope(explicit: scope)
			let team = await directory.registry.team(chosen)
			signingCheck = "Would sign with \(team?.name ?? chosen.teamID)."
		} catch let error as ZagAccountError {
			switch error {
			case .noSigningAccount: signingCheck = "No default account. Choose one to sign with."
			case .notSignedIn: signingCheck = "That account is signed out. Sign in again; no other account is used."
			default: signingCheck = "Signing is not possible with that choice."
			}
		} catch {
			signingCheck = "Signing is not possible with that choice."
		}
	}

	func prepareRemoval(_ id: UUID) async {
		removal = try? await directory.removalPlan(for: id, ledger: ledger)
	}

	func confirmRemoval(_ handling: ZagAccountRemovalPlan.AppHandling) async {
		guard let plan = removal else { return }
		var updated = ledger
		do {
			try await directory.remove(plan.confirm(handling), ledger: &updated)
			ledger = updated
		} catch {
			notice = "The account was not removed. Nothing was changed."
		}
		removal = nil
		await reload()
	}

	// MARK: Certificate request recovery

	/// The recovery screen's model for `scope`, authorised through the
	/// directory (so only while that account is signed in).
	func openRecovery(_ scope: ZagSigningScope) {
		let directory = directory
		recovery = ZagCertificateRecoveryModel(scope: scope, service: provisioner) { try await directory.authorize($0) }
		showsRecovery = true
	}

	func teamName(_ scope: ZagSigningScope) -> String {
		row(scope.accountID)?.record.team(scope.teamID)?.name ?? scope.teamID
	}

	func closeRecovery() async {
		showsRecovery = false
		recovery = nil
		await reload()
	}

	// MARK: Simulation

	/// Leaves items as an earlier installation would: one account with an
	/// ownership record (recoverable by signing in) and one without.
	func simulateEarlierInstallation() {
		let recoverable = UUID(), unowned = UUID()
		let record = ZagAccountOwnershipRecord(
			accountKey: ZagAppleAccountRecord.accountKey(for: "SIMULATED-EARLIER"),
			maskedAppleID: "e•••@example.invalid"
		)
		try? secrets.save(try JSONEncoder().encode(record), kind: .accountRecord, account: recoverable, team: nil)
		try? secrets.save(Data("simulated".utf8), kind: .session, account: recoverable, team: nil)
		try? secrets.save(Data("simulated".utf8), kind: .session, account: unowned, team: nil)
	}

	/// Signs a simulated app with the scope's team while Apple's answer to the
	/// certificate request is lost: the certificate is issued, the app never
	/// hears of it. A second attempt then stops as unresolved and sends nothing.
	@discardableResult
	func interruptCertificateRequest(_ scope: ZagSigningScope) async -> [ZagProvisioningFailure.Kind] {
		guard scope.teamID == portal.team, let authorization = try? await directory.authorize(scope) else { return [] }
		simulatedApps += 1
		let request = ZagProvisioningRequest(
			accountID: scope.accountID, team: scope.teamID,
			deviceUDID: "00000000-0000000000000000", deviceName: "Simulated iPhone",
			app: .init(originalBundleIdentifier: "com.example.interrupted\(simulatedApps)", name: "Interrupted", entitlements: (try? ZagEntitlementSet([:]))!),
			extensions: [], installedFreeAccountApps: []
		)
		await portal.fail(.submitCertificateRequest, with: .lostResponse)
		var kinds: [ZagProvisioningFailure.Kind] = []
		for _ in 0..<2 {
			if case .failure(let failure) = await provisioner.provision(request, authorization: authorization) { kinds.append(failure.kind) }
		}
		await reload()
		return kinds
	}

	/// Certificate requests the simulated team has received.
	func certificateSubmissions() async -> Int {
		await portal.calls.filter { $0 == .submitCertificateRequest }.count
	}

	/// Records a simulated installed app for the scope (nothing is signed).
	func addSimulatedApp(_ scope: ZagSigningScope) {
		guard let team = rows.first(where: { $0.id == scope.accountID })?.record.team(scope.teamID) else { return }
		simulatedApps += 1
		let lifetime = ZagTeamLimits.forTeam(team.kind).profileLifetime
		let signedAt = now.addingTimeInterval(-Double(simulatedApps) * 86_400)
		ledger.record(ZagSignedAppRecord(
			bundleIdentifier: "com.example.simulated\(simulatedApps).\(scope.teamID)",
			originalBundleIdentifier: "com.example.simulated\(simulatedApps)",
			signedAt: signedAt,
			profileExpiresAt: signedAt.addingTimeInterval(lifetime),
			certificateExpiresAt: signedAt.addingTimeInterval(365 * 86_400),
			owner: ZagAppOwnership(scope: scope, teamKind: team.kind, certificateSerial: "SIMULATED", profileUUID: UUID().uuidString)
		))
	}

	/// Apple stops accepting one account's session (as after a password change).
	func revokeSession(_ id: UUID, appleID: String) async {
		await service.setRejectsSessions(true, forAppleID: appleID)
		_ = await directory.authenticator(for: id)?.validateStoredSession()
		await service.setRejectsSessions(false, forAppleID: appleID)
		await reload()
	}

	/// Jumps 31 days ahead and relaunches, past the 30-day session expiry.
	func relaunchAfter31Days() async {
		clock.advance(31 * 86_400)
		await start()
	}
}

struct ZagAppleAccountsDebugView: View {
	@StateObject private var lab = ZagAppleAccountsLab()
	@State private var started = false
	var runsDemo = false

	var body: some View {
		// Started once: the task runs again whenever a pushed page pops.
		ZagAppleAccountsList(lab: lab)
			.task {
				guard !started else { return }
				started = true
				await lab.start()
				// Not tied to this view's lifetime, which ends while a page is pushed.
				if runsDemo { Task { await ZagAppleAccountsDebugDemo(lab: lab).run() } }
			}
	}
}

private struct ZagAppleAccountsList: View {
	@ObservedObject var lab: ZagAppleAccountsLab
	@AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
	private var tint: Color { ZagWideGamutTint.color(hex: tintHex) }

	var body: some View {
		Form {
			Section {
				ZagAppleAccountsHeader(count: lab.rows.count, tint: tint)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
			}

			Section {
				if lab.rows.isEmpty {
					Text("No accounts yet").foregroundStyle(.secondary)
				}
				ForEach(lab.rows) { row in
					NavigationLink {
						ZagAppleAccountDetail(lab: lab, accountID: row.id, tint: tint)
					} label: {
						ZagAppleAccountRow(row: row, defaultScope: lab.defaultScope, now: lab.now)
					}
					.accessibilityIdentifier("accounts.row.\(row.record.maskedAppleID)")
				}
				Button {
					Task { await lab.beginAdd() }
				} label: {
					Label("Add Apple Account", systemImage: "person.crop.circle.badge.plus")
				}
				.accessibilityIdentifier("accounts.add")
			} header: {
				Text("Accounts")
			} footer: {
				Text("Each account keeps its own session, signing keys and apps. Apps are always refreshed by the account and team that signed them.")
			}

			Section {
				NavigationLink {
					ZagLabStoredAccountData(lab: lab)
				} label: {
					Label("Stored Account Data", systemImage: "externaldrive.badge.person.crop")
				}
				.accessibilityIdentifier("accounts.storedData")
			} footer: {
				Text("Keychain items Zag Store kept for accounts no longer in this list, such as after reinstalling.")
			}

			Section {
				Button {
					Task { await lab.checkSigning(nil) }
				} label: {
					Label("Check Default Signing", systemImage: "signature")
				}
				if let check = lab.signingCheck {
					Text(check).font(.footnote).foregroundStyle(.secondary)
						.accessibilityIdentifier("accounts.signingCheck")
				}
			} header: {
				Text("Signing")
			}

			if let notice = lab.notice {
				Section {
					Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
				}
			}

			Section {
				Button {
					Task { await lab.relaunchAfter31Days() }
				} label: {
					Label("Relaunch 31 Days Later", systemImage: "calendar.badge.clock")
				}
			} header: {
				Label("Simulation", systemImage: "testtube.2")
			} footer: {
				Text("Debug build only. Nothing leaves this device: Apple and anisette are simulated. Only \(ZagFreeAccountSimulation.accountDomain) addresses are accepted, with the password \"\(ZagFreeAccountSimulation.password)\" (try tester@, second@ and paid@). Never enter a real Apple Account here.")
			}
		}
		.navigationTitle("Apple Accounts")
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.navigationDestination(isPresented: $lab.showsStoredData) { ZagLabStoredAccountData(lab: lab) }
		.navigationDestination(isPresented: Binding(get: { lab.showsRecovery && lab.recovery != nil }, set: { if !$0 { Task { await lab.closeRecovery() } } })) {
			if let model = lab.recovery { ZagCertificateRecoveryView(model: model, teamName: lab.teamName(model.scope)) }
		}
		.sheet(isPresented: Binding(
			get: { lab.signIn != nil },
			set: { presented in if !presented, lab.signIn != nil { Task { await lab.cancelSignIn() } } }
		)) {
			if let model = lab.signIn {
				ZagAppleAccountSignInSheet(lab: lab, model: model, tint: tint)
			}
		}
	}
}

private struct ZagAppleAccountsHeader: View {
	let count: Int
	let tint: Color

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: "person.2.crop.square.stack")
				.font(.system(size: 30))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(tint)
				.frame(width: 44)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text(count == 1 ? "1 Account" : "\(count) Accounts").font(.headline)
					ZagSimulatedBadge()
				}
				Text("Free and paid Apple Accounts, side by side. Signing out of one never affects another.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.padding(16)
		.zagFreeAccountGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
	}
}

private struct ZagSimulatedBadge: View {
	var body: some View {
		Text("SIMULATED")
			.font(.caption2.weight(.bold))
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.foregroundStyle(.orange)
			.background(Color.orange.opacity(0.15), in: Capsule())
	}
}

/// Session status, in words and colour.
private struct ZagAccountStatus {
	let title: String
	let colour: Color
	let symbol: String

	init(_ state: ZagFreeAccountState?, now: Date) {
		switch state {
		case .signedIn(let session) where session.isExpired(at: now):
			self.init(title: "Session Expired", colour: .orange, symbol: "exclamationmark.circle.fill")
		case .signedIn:
			self.init(title: "Signed In", colour: .green, symbol: "checkmark.circle.fill")
		case .sessionExpired:
			self.init(title: "Session Expired", colour: .orange, symbol: "exclamationmark.circle.fill")
		case .authenticating, .awaitingTwoFactor:
			self.init(title: "Signing In…", colour: .blue, symbol: "clock.fill")
		case .failed:
			self.init(title: "Sign-In Failed", colour: .red, symbol: "xmark.circle.fill")
		case .signedOut, nil:
			self.init(title: "Signed Out", colour: .secondary, symbol: "minus.circle.fill")
		}
	}

	private init(title: String, colour: Color, symbol: String) {
		self.title = title
		self.colour = colour
		self.symbol = symbol
	}
}

private struct ZagAppleAccountRow: View {
	let row: ZagAppleAccountsLab.Row
	let defaultScope: ZagSigningScope?
	let now: Date

	var body: some View {
		let status = ZagAccountStatus(row.state, now: now)
		HStack(spacing: 12) {
			Image(systemName: "person.crop.circle.fill")
				.font(.system(size: 30))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(row.record.maskedAppleID)
						.font(.body.weight(.semibold))
						.lineLimit(1)
						.truncationMode(.middle)
					if defaultScope?.accountID == row.id {
						Text("DEFAULT")
							.font(.caption2.weight(.bold))
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.foregroundStyle(.tint)
							.background(Color.accentColor.opacity(0.15), in: Capsule())
							.fixedSize()
					}
				}
				Text(row.record.teams.map(\.name).joined(separator: ", "))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 8)
			Label(status.title, systemImage: status.symbol)
				.labelStyle(.iconOnly)
				.foregroundStyle(status.colour)
				.accessibilityLabel(status.title)
		}
	}
}

private struct ZagAppleAccountDetail: View {
	@ObservedObject var lab: ZagAppleAccountsLab
	let accountID: UUID
	let tint: Color
	@Environment(\.dismiss) private var dismiss
	@State private var simulatedAppleID = ""

	var body: some View {
		if let row = lab.row(accountID) {
			content(row)
		} else {
			Text("This account was removed.").foregroundStyle(.secondary)
				.onAppear { dismiss() }
		}
	}

	@ViewBuilder
	private func content(_ row: ZagAppleAccountsLab.Row) -> some View {
		let status = ZagAccountStatus(row.state, now: lab.now)
		let signedIn = status.title == "Signed In"
		Form {
			Section {
				LabeledContent("Apple Account", value: row.record.maskedAppleID)
				LabeledContent("Status") {
					Label(status.title, systemImage: status.symbol).foregroundStyle(status.colour)
				}
				.accessibilityIdentifier("account.status")
				if let expiresAt = row.state?.session?.expiresAt {
					LabeledContent("Session Expires") { Text(expiresAt, style: .date) }
				}
				LabeledContent("Last Signed In") { Text(row.record.lastAuthenticatedAt, style: .date) }
				if !signedIn {
					ZagFreeAccountPrimaryButton(title: "Sign In Again", enabled: true) {
						Task { await lab.beginSignInAgain(accountID) }
					}
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets())
					.accessibilityIdentifier("account.signInAgain")
				}
			} header: {
				Text("Account")
			} footer: {
				Text(signedIn ? "Signing with this account works while its session is valid." : "Apps signed by this account wait until it is signed in again. No other account is used for them.")
			}

			ForEach(row.record.teams, id: \.identifier) { team in
				teamSection(row: row, team: team, signedIn: signedIn)
			}

			Section {
				if signedIn {
					Button(role: .destructive) {
						Task { await lab.signOut(accountID) }
					} label: {
						Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
					}
					.accessibilityIdentifier("account.signOut")
				}
				Button(role: .destructive) {
					Task { await lab.prepareRemoval(accountID) }
				} label: {
					Label("Remove Account…", systemImage: "trash")
				}
				.accessibilityIdentifier("account.remove")
			} footer: {
				Text("Signing out removes only this account's session; its signing keys and apps stay. Removing deletes everything this account stored on this device. Certificates are never revoked.")
			}

			Section {
				TextField("Simulated address", text: $simulatedAppleID, prompt: Text("tester\(ZagFreeAccountSimulation.accountDomain)"))
					.keyboardType(.emailAddress)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button {
					Task { await lab.revokeSession(accountID, appleID: simulatedAppleID) }
				} label: {
					Label("Revoke This Session", systemImage: "xmark.seal")
				}
				.disabled(!signedIn || !simulatedAppleID.hasSuffix(ZagFreeAccountSimulation.accountDomain))
			} header: {
				Label("Simulation", systemImage: "testtube.2")
			}
		}
		.navigationTitle(row.record.maskedAppleID)
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.confirmationDialog(
			"Remove \(lab.removal?.maskedAppleID ?? "")?",
			isPresented: Binding(get: { lab.removal?.accountID == accountID }, set: { if !$0 { lab.removal = nil } }),
			titleVisibility: .visible
		) {
			let count = lab.removal?.dependentApps.count ?? 0
			if count > 0 {
				Button("Remove, Keep Apps Until They Expire", role: .destructive) { Task { await lab.confirmRemoval(.keepUntilExpiry) } }
				Button("Remove and Forget Its Apps", role: .destructive) { Task { await lab.confirmRemoval(.forgetRecords) } }
			} else {
				Button("Remove Account", role: .destructive) { Task { await lab.confirmRemoval(.keepUntilExpiry) } }
			}
			Button("Cancel", role: .cancel) { lab.removal = nil }
		} message: {
			let count = lab.removal?.dependentApps.count ?? 0
			Text(count == 0
				 ? "Its session and signing keys are deleted from this device."
				 : "\(count) installed \(count == 1 ? "app was" : "apps were") signed by this account. They will not be refreshed by any other account and stop working when they expire.")
		}
	}

	@ViewBuilder
	private func teamSection(row: ZagAppleAccountsLab.Row, team: ZagDeveloperTeam, signedIn: Bool) -> some View {
		let scope = ZagSigningScope(accountID: accountID, teamID: team.identifier)
		let limits = ZagTeamLimits.forTeam(team.kind)
		let apps = lab.apps(of: accountID).filter { $0.owner?.scope == scope }
		Section {
			LabeledContent("Team ID", value: team.identifier)
			LabeledContent("Type", value: team.hasFreeLimits ? "Free" : "Paid")
			LabeledContent("Profiles Last", value: "\(Int(limits.profileLifetime / 86_400)) days")
			if lab.defaultScope == scope {
				Label("Default for Signing", systemImage: "checkmark.circle.fill").foregroundStyle(tint)
			} else {
				Button {
					Task { await lab.setDefault(scope) }
				} label: {
					Label("Use by Default", systemImage: "star")
				}
				.accessibilityIdentifier("team.setDefault.\(team.identifier)")
			}
			Button {
				Task { await lab.checkSigning(scope) }
			} label: {
				Label("Check Signing With This Team", systemImage: "signature")
			}
			if lab.unresolved.contains(scope) {
				Button {
					lab.openRecovery(scope)
				} label: {
					Label("Certificate Request Unresolved", systemImage: "questionmark.diamond").foregroundStyle(.orange)
				}
				.accessibilityIdentifier("team.certificateUnresolved.\(team.identifier)")
			}
			ForEach(apps, id: \.bundleIdentifier) { app in
				ZagOwnedAppRow(app: app, now: lab.now)
			}
			Button {
				lab.addSimulatedApp(scope)
			} label: {
				Label("Add Simulated App", systemImage: "plus.app")
			}
			if team.identifier == lab.portal.team, signedIn {
				Button {
					Task { await lab.interruptCertificateRequest(scope) }
				} label: {
					Label("Lose a Certificate Response (Simulation)", systemImage: "wifi.exclamationmark")
				}
			}
		} header: {
			Text(team.name)
		} footer: {
			Text(team.hasFreeLimits
				 ? "Free teams: 3 apps per device across all free accounts, 10 App IDs a week, profiles for 7 days."
				 : "Paid teams: profiles for up to a year; 100 devices per type each membership year.")
		}
	}
}

/// The production Stored Account Data screen over the lab's directory, with
/// a simulation button that leaves items as an earlier installation would.
private struct ZagLabStoredAccountData: View {
	@ObservedObject var lab: ZagAppleAccountsLab

	var body: some View {
		ZagStoredAccountDataView(model: lab.storedData) {
			Button {
				lab.simulateEarlierInstallation()
				Task { await lab.storedData.load() }
			} label: {
				Label("Leave Items From an Earlier Installation (Simulation)", systemImage: "testtube.2")
			}
		}
	}
}

private struct ZagOwnedAppRow: View {
	let app: ZagSignedAppRecord
	let now: Date

	var body: some View {
		let urgency = app.urgency(at: now)
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(app.originalBundleIdentifier).font(.subheadline)
				Text(app.ownerRemovedAt != nil ? "No longer refreshed" : "Expires \(app.expiresAt.formatted(.relative(presentation: .named)))")
					.font(.caption)
					.foregroundStyle(urgency >= .urgent ? .orange : .secondary)
			}
			Spacer()
			Image(systemName: urgency == .expired ? "exclamationmark.triangle.fill" : "app.badge.checkmark")
				.foregroundStyle(urgency == .expired ? .red : .secondary)
		}
	}
}

/// Adding an account or signing in again, through the same sign-in model
/// as the single-account screen; the code prompt is its sheet.
private struct ZagAppleAccountSignInSheet: View {
	@ObservedObject var lab: ZagAppleAccountsLab
	@ObservedObject var model: ZagFreeAccountSignInModel
	let tint: Color

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Apple Account", text: $model.appleID, prompt: Text("name\(ZagFreeAccountSimulation.accountDomain)"))
						.textContentType(nil)
						.keyboardType(.emailAddress)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.disabled(model.isBusy)
						.accessibilityIdentifier("accounts.signIn.appleID")
					SecureField("Password", text: $model.password)
						.textContentType(nil)
						.privacySensitive()
						.disabled(model.isBusy)
						.accessibilityIdentifier("accounts.signIn.password")
				} header: {
					HStack { Text("Apple Account"); ZagSimulatedBadge() }
				} footer: {
					Text("Your password is used only while signing in and is never stored. Simulated: only \(ZagFreeAccountSimulation.accountDomain) addresses work.")
				}
				if let failure = model.failure {
					Section {
						Label("\(failure.message) \(failure.recovery).", systemImage: "exclamationmark.circle").foregroundStyle(.red)
					}
				}
				if let notice = model.notice {
					Section { Text(notice).foregroundStyle(.orange) }
				}
				Section {
					if model.isBusy {
						HStack(spacing: 12) { ProgressView(); Text("Signing In…").foregroundStyle(.secondary) }
					} else {
						ZagFreeAccountPrimaryButton(title: "Sign In", enabled: model.canSubmitCredentials) {
							Task {
								await model.signIn()
								await lab.finishSignIn()
							}
						}
						.listRowBackground(Color.clear)
						.listRowInsets(EdgeInsets())
					}
				}
			}
			.navigationTitle(lab.signInTarget == nil ? "Add Apple Account" : "Sign In Again")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { Task { await lab.cancelSignIn() } }
				}
			}
			.sheet(isPresented: Binding(
				get: { model.prompt != nil },
				set: { presented in if !presented, model.prompt != nil { Task { await model.cancel() } } }
			), onDismiss: { Task { await lab.finishSignIn() } }) {
				ZagFreeAccountCodeSheet(model: model, tint: tint)
			}
		}
		.presentationDetents([.large])
	}
}

// MARK: - Launch hook and scripted demo

/// `-ZagAppleAccountsDebugDemo` opens the screen at launch and plays the
/// scripted walkthrough used for screenshots and the simulator UI test.
struct ZagAppleAccountsDebugLaunchHook: ViewModifier {
	@State private var presented = ProcessInfo.processInfo.arguments.contains("-ZagAppleAccountsDebugDemo")

	func body(content: Content) -> some View {
		content.fullScreenCover(isPresented: $presented) {
			NavigationStack {
				ZagAppleAccountsDebugView(runsDemo: true)
			}
		}
	}
}

/// Drives the lab through the same calls the screen's buttons make, with
/// synthetic accounts only, writing STEP/PASS/FAIL lines to a log in the
/// app's temporary directory.
@MainActor
struct ZagAppleAccountsDebugDemo {
	static let logName = "zag-apple-accounts-demo.log"
	let lab: ZagAppleAccountsLab

	private func append(_ line: String) {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.logName)
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile()
			handle.write(Data(line.utf8))
			try? handle.close()
		} else {
			try? Data(line.utf8).write(to: url)
		}
	}

	private func step(_ name: String, hold seconds: Double = 2) async {
		append("STEP \(name) accounts=\(lab.rows.count)\n")
		try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}

	private func check(_ ok: Bool, _ label: String) { append("\(ok ? "PASS" : "FAIL") \(label)\n") }

	private func add(_ appleID: String) async -> UUID? {
		await lab.beginAdd()
		guard let model = lab.signIn else { return nil }
		model.appleID = appleID
		model.password = ZagFreeAccountSimulation.password
		await model.signIn()
		await lab.finishSignIn()
		let masked = model.state.session?.maskedAppleID
		return lab.rows.first { $0.record.maskedAppleID == masked }?.id
	}

	private func signedIn(_ id: UUID) -> Bool {
		if case .signedIn? = lab.row(id)?.state { return true }
		return false
	}

	func run() async {
		try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(Self.logName))
		// Start from no simulated accounts (earlier runs are removed through the directory).
		for row in lab.rows {
			await lab.prepareRemoval(row.id)
			await lab.confirmRemoval(.forgetRecords)
		}
		await step("01-empty")

		guard let free = await add(ZagFreeAccountSimulation.appleID),
			  let second = await add("second\(ZagFreeAccountSimulation.accountDomain)"),
			  let paid = await add("paid\(ZagFreeAccountSimulation.accountDomain)") else {
			check(false, "three simulated accounts are added")
			return append("DONE\n")
		}
		check(lab.rows.count == 3 && [free, second, paid].allSatisfy(signedIn), "three accounts are signed in at once")
		check(lab.row(paid)?.record.teams.count == 2, "the paid account shows both of its teams")
		await step("02-three-accounts")

		await lab.checkSigning(nil)
		check(lab.defaultScope == ZagSigningScope(accountID: free, teamID: "SIMTEAM001") && lab.signingCheck?.contains("Personal Team") == true,
			  "the first account added is the default until another is chosen")
		await lab.setDefault(ZagSigningScope(accountID: paid, teamID: "SIMORG0001"))
		await lab.checkSigning(nil)
		check(lab.defaultScope == ZagSigningScope(accountID: paid, teamID: "SIMORG0001") && lab.signingCheck?.contains("Organisation") == true,
			  "a team of the paid account is the default")
		await step("03-default-team")

		lab.addSimulatedApp(ZagSigningScope(accountID: free, teamID: "SIMTEAM001"))
		lab.addSimulatedApp(ZagSigningScope(accountID: second, teamID: "SIMTEAM002"))
		lab.addSimulatedApp(ZagSigningScope(accountID: paid, teamID: "SIMORG0001"))
		check(lab.apps(of: free).count == 1 && lab.apps(of: second).count == 1 && lab.apps(of: paid).count == 1, "each account lists only its own apps")
		await step("04-apps-per-account")

		await lab.signOut(paid)
		await lab.checkSigning(nil)
		check(!signedIn(paid) && signedIn(free) && signedIn(second), "signing out of one account leaves the others signed in")
		check(lab.signingCheck?.contains("signed out") == true, "a signed-out default is not replaced by another account")
		await step("05-signed-out-default")

		await lab.beginSignInAgain(paid)
		if let model = lab.signIn {
			model.appleID = "paid\(ZagFreeAccountSimulation.accountDomain)"
			model.password = ZagFreeAccountSimulation.password
			await step("06-sign-in-again", hold: 1.5)
			await model.signIn()
			await lab.finishSignIn()
		}
		check(signedIn(paid) && lab.rows.count == 3, "signing in again restores the same account, not a new one")
		await step("07-signed-in-again")

		await lab.prepareRemoval(second)
		check(lab.removal?.dependentApps.count == 1, "removal lists the account's installed apps for confirmation")
		await step("08-removal-confirmation")
		await lab.confirmRemoval(.keepUntilExpiry)
		let kept = lab.ledger.records.values.first { $0.owner?.scope.accountID == second }
		check(lab.row(second) == nil && kept?.ownerRemovedAt != nil && signedIn(free) && signedIn(paid),
			  "removal deletes only that account; its app keeps its owner and stops refreshing")
		await step("09-removed")

		// Stored Account Data: clear leftovers of earlier runs, then leave items
		// as an earlier installation would.
		let stored = lab.storedData
		await stored.load()
		if let earlier = stored.data, !earlier.isEmpty {
			stored.prepareRemoval(accounts: earlier.accounts, scopes: earlier.localStateScopes)
			await stored.confirmRemoval()
		}
		lab.simulateEarlierInstallation()
		lab.showsStoredData = true
		await stored.load()
		let found = stored.data?.accounts ?? []
		check(found.count == 2 && found.filter(\.isRecoverable).map(\.maskedAppleID) == ["e•••@example.invalid"] && lab.rows.count == 2,
			  "stored data lists items no account owns, recoverable and not, and nothing is removed by listing")
		await step("10-stored-account-data")
		if let unowned = found.first(where: { !$0.isRecoverable }) {
			stored.prepareRemoval(accounts: [unowned], scopes: [])
			await stored.confirmRemoval()
		}
		let left = stored.data?.accounts ?? []
		check(left.count == 1 && left.first?.isRecoverable == true && signedIn(free) && signedIn(paid),
			  "only the confirmed item is removed; the accounts are untouched")
		if let rest = stored.data {
			stored.prepareRemoval(accounts: rest.accounts, scopes: rest.localStateScopes)
			await stored.confirmRemoval()
		}
		lab.showsStoredData = false
		try? await Task.sleep(nanoseconds: 800_000_000)

		// A certificate request whose answer is lost, on the tester's Personal Team.
		let personal = ZagSigningScope(accountID: free, teamID: "SIMTEAM001")
		let kinds = await lab.interruptCertificateRequest(personal)
		let sent = await lab.certificateSubmissions()
		check(kinds == [.network, .certificateRequestUnresolved] && sent == 1 && lab.unresolved == [personal],
			  "a lost certificate response leaves the request unresolved; signing again stops and sends nothing")
		lab.openRecovery(personal)
		guard let recovery = lab.recovery else {
			check(false, "the recovery screen opens")
			return append("DONE\n")
		}
		await recovery.load()
		await recovery.checkAgain()
		await recovery.checkAgain()
		let afterChecks = await lab.certificateSubmissions()
		check(recovery.checks == 2 && recovery.outcome == .unresolved && recovery.request != nil && afterChecks == 1,
			  "Check Again only reads the certificate list: still unresolved, nothing requested, however often")
		await step("11-certificate-unresolved")
		recovery.requestAbandon()
		check(recovery.phase == .confirmingAbandon && recovery.request != nil, "abandoning asks for confirmation first")
		await step("12-abandon-confirmation")
		await recovery.confirmAbandon()
		let afterAbandon = await lab.certificateSubmissions()
		check(recovery.outcome == .abandoned && recovery.request == nil && afterAbandon == 1 && recovery.message?.contains("certificate slot") == true,
			  "after confirmation the request is abandoned, nothing is revoked or requested, and the occupied slot is reported")
		await step("13-certificate-abandoned")
		await lab.closeRecovery()
		check(lab.unresolved.isEmpty, "the team no longer shows an unresolved request")
		try? await Task.sleep(nanoseconds: 800_000_000)

		await lab.relaunchAfter31Days()
		check(!signedIn(free) && !signedIn(paid) && lab.rows.count == 2, "after the sessions expire, every account needs signing in again")
		await step("14-expired-after-relaunch")
		append("DONE\n")
	}
}
#endif
