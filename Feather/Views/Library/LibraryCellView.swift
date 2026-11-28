//
//  LibraryAppIconView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData
import NimbleExtensions
import NimbleViews
import NukeUI
import AltSourceKit

// MARK: - View

struct LibraryCellView: View {
	private static let activityDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "d MMM yyyy"
		return formatter
	}()
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	// Repository state is observed only by the badge and menu label below,
	// so a refreshed repository no longer re-renders every Apps row.

	var app: AppInfoPresentable
	var isManagedInstalled: Bool = false
	var availableUpdate: UpdateManager.AvailableUpdate? = nil
	var isRemoving: Bool = false
	var showsSeparator: Bool = true
	var onDeleteApp: ((AppInfoPresentable) -> Void)? = nil
	var onRemoveManagedApp: ((AppInfoPresentable) -> Void)? = nil
	var onRepositoryBadgeTap: ((AltSource) -> Void)? = nil
	var onSignedForInstall: ((String) -> Void)? = nil
	var onInstallCompleted: ((AppInfoPresentable) async -> Bool)? = nil
	var onInstallFailedAfterSigning: ((String) -> Void)? = nil
	var runningInstallation: ZagRunningInstallation? = nil
	var runningHasUpdate = false
	var onRunningUpdate: (() -> Void)? = nil

	@State private var showingRunningDetails = false
	@State private var isDeleteConfirmationPresented = false
	@State private var confirmSeparateSigning = false
	@State private var choosingSigningMethod = false
	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	@State private var _updatedNativeEntry: ZagNativeAppInventory.Entry?
	private var _nativeEntry: ZagNativeAppInventory.Entry? {
		if let updated = _updatedNativeEntry, updated.uuid == app.uuid { return updated }
		return ZagNativeAppInventory.entry(app)
	}
	#endif
	/// The authoritative per-job state; survives scrolling and Shortcuts handoffs.
	@ObservedObject private var jobs = ZagInstallJobs.shared
	@ObservedObject private var updateTransaction = ZagUpdateTransactionManager.shared

	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>

	private var _isNativeAccountApp: Bool {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		return _nativeEntry != nil
		#else
		return false
		#endif
	}

	// MARK: - Install job

	private var _jobKey: String { "library:\(app.uuid ?? "")" }

	private var isSigningImmediately: Bool {
		get { jobs.job(_jobKey)?.stage == .signing }
		nonmutating set {
			if newValue {
				// Sign-only jobs end without installing, so they offer no cancel.
				let installs = OptionsManager.shared.options.post_installAppAfterSigned
				if !jobs.begin(_jobKey, stage: .signing, offersCancel: installs) { jobs.advance(_jobKey, to: .signing) }
			} else if jobs.job(_jobKey)?.stage == .signing {
				jobs.finish(_jobKey)
			}
		}
	}

	private var isInstallingImmediately: Bool {
		get {
			guard let stage = jobs.job(_jobKey)?.stage else { return false }
			return stage != .signing
		}
		nonmutating set {
			if newValue {
				if !jobs.begin(_jobKey, stage: .packaging) { jobs.advance(_jobKey, to: .packaging) }
			} else if let stage = jobs.job(_jobKey)?.stage, stage != .signing {
				jobs.finish(_jobKey)
			}
		}
	}

	private static func _isCancellation(_ error: Error) -> Bool {
		error is ZagInstallCancelled || (error as? ZagMobileDataInstallError) == .cancelled
	}

	private var _jobCaption: String? {
		guard let job = jobs.job(_jobKey) else { return nil }
		if let caption = job.nativeCaption { return caption }
		switch job.stage {
		case .signing: return "Signing"
		case .installing: return "Installing"
		case .packaging, .preparingMobileDataFix, .restoringMobileData: return "Preparing"
		default: return nil
		}
	}

	// MARK: - Selections

	private var _isSelected: Bool {
		guard let uuid = app.uuid else {
			return false
		}
		return selectedAppUUIDs.contains(uuid)
	}

	private func _toggleSelection() {
		guard let uuid = app.uuid else {
			return
		}

		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}

	// MARK: - Body

	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active

		HStack(spacing: 18) {
			if isEditing, runningInstallation == nil {
				Button {
					_toggleSelection()
				} label: {
					Image(
						systemName:
							_isSelected
							? "checkmark.circle.fill"
							: "circle"
					)
					.foregroundColor(
						_isSelected
							? .accentColor
							: .secondary
					)
					.font(.title2)
				}
				.buttonStyle(.borderless)
			}

			HStack(spacing: 10) {
				ZStack(alignment: .bottomLeading) {
					FRAppIconView(
						app: runningInstallation == nil ? app : nil,
						size: 62
					)

					if runningInstallation == nil {
						ZagLibraryRepositoryBadge(bundleID: app.identifier, onTap: onRepositoryBadgeTap)
					}
				}

				NBTitleWithSubtitleView(
					title:
						app.name ??
						.localized("Unknown"),
					subtitle: _desc,
					linelimit: 0
				)
			}

			Spacer(minLength: 6)

			if !isEditing {
				if isRemoving {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text(.localized("Removing App")))
				} else {
					_buttonActions(for: app)
				}
			}
		}
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		.onReceive(ZagNativeAppInventory.changes) { id in
			if id == app.uuid { _updatedNativeEntry = ZagNativeAppInventory.entry(app) }
		}
		#endif
		.frame(height: isRegular ? nil : ZagListLayout.compactRowHeight)
		.padding(isRegular ? 12 : 0)
		.overlay(alignment: .bottom) {
			if showsSeparator {
				Rectangle()
					.fill(Color(uiColor: .separator))
					.frame(height: ZagListLayout.separatorHeight)
			}
		}
		.listRowInsets(
			isRegular
				? EdgeInsets()
				: EdgeInsets(top: 0, leading: ZagListLayout.horizontalInset, bottom: 0, trailing: ZagListLayout.horizontalInset)
		)
		.background(
			isRegular
				? RoundedRectangle(
					cornerRadius: 18,
					style: .continuous
				)
				.fill(
					_isSelected && isEditing
						? Color.accentColor.opacity(0.1)
						: Color(.quaternarySystemFill)
				)
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				if runningInstallation == nil { _toggleSelection() }
			} else {
				if runningInstallation != nil { showingRunningDetails = true }
				else { selectedInfoAppPresenting = AnyApp(base: app) }
			}
		}
		.sheet(isPresented: $showingRunningDetails) {
			if let runningInstallation { ZagRunningDetailsSheet(installation: runningInstallation) }
		}
		.swipeActions {
			if !isEditing, runningInstallation == nil {
				_swipeActions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)

				if runningInstallation != nil {
					if ZagBatchCoordinator.shared.canRefreshRunning() {
						Button("Refresh", systemImage: "arrow.clockwise") {
							Task { await ZagBatchCoordinator.shared.refreshRunning() }
						}
					}
					if runningHasUpdate { Button("Update", systemImage: "arrow.down.circle") { onRunningUpdate?() } }
				} else {
					ZagLibraryRepositorySourceLabel(bundleID: app.identifier)
					Divider()
					_contextActionsExtra(for: app)
					Divider()
					_actions(for: app)
				}
			}
		}
		.alert("Sign With a Different Apple ID?", isPresented: $confirmSeparateSigning) {
			Button("Choose Apple ID") { _signSeparateCopy() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("The new Apple ID signs a separate copy with different identifiers. The original stays installed. App data, App Groups and Keychain access may not carry over. iOS may require a free installation slot.")
		}
		.alert(.localized("Delete Stored Copy?"), isPresented: $isDeleteConfirmationPresented) {
			Button(.localized("Delete"), role: .destructive) {
				onDeleteApp?(app)
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(
				String(
					format: .localized("Delete %@ from Zag Store? This removes Zag Store's stored copy, but does not uninstall the app from your iPhone."),
					app.name ?? .localized("this app")
				)
			)
		}

	}

	// MARK: - Description

	private var _desc: String {
		let version = app.version
		if let running = app as? ZagRunningApp, let version, let build = running.build {
			return "\(version) (\(build))"
		}

		let storedDate: Date?
		if let signed = app as? Signed {
			storedDate = signed.date
		} else if let imported = app as? Imported {
			storedDate = imported.date
		} else {
			storedDate = nil
		}

		guard let storedDate else {
			return version ?? .localized("Unknown")
		}

		let calendar = Calendar.current
		let startOfToday = calendar.startOfDay(for: Date())
		let startOfStoredDate = calendar.startOfDay(for: storedDate)
		let dayDifference = calendar.dateComponents(
			[.day],
			from: startOfStoredDate,
			to: startOfToday
		).day

		let dateText: String
		switch dayDifference {
		case 0:
			dateText = "Today"
		case 1:
			dateText = "Yesterday"
		case 2:
			dateText = "Two Days Ago"
		case 3:
			dateText = "Three Days Ago"
		default:
			dateText = Self.activityDateFormatter.string(from: storedDate)
		}

		if let version, !version.isEmpty {
			return "\(dateText) • \(version)"
		}
		return dateText
	}
}

// MARK: - Actions

extension LibraryCellView {
	@ViewBuilder
	private func _swipeActions(
		for app: AppInfoPresentable
	) -> some View {
		Button {
			isDeleteConfirmationPresented = true
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
		.tint(.red)

		if isManagedInstalled {
			Button {
				onRemoveManagedApp?(app)
			} label: {
				Label(
					isRemoving ? .localized("Removing…") : .localized("Remove App"),
					systemImage: isRemoving ? "hourglass" : "minus.circle"
				)
			}
			.tint(.red)
			.disabled(isRemoving)
		}
	}

	@ViewBuilder
	private func _actions(
		for app: AppInfoPresentable
	) -> some View {
		Button(
			.localized("Delete"),
			systemImage: "trash",
			role: .destructive
		) {
			isDeleteConfirmationPresented = true
		}

		if isManagedInstalled {
			Button(
				isRemoving ? .localized("Removing…") : .localized("Remove App"),
				systemImage: isRemoving ? "hourglass" : "minus.circle",
				role: .destructive
			) {
				onRemoveManagedApp?(app)
			}
			.disabled(isRemoving)
		}
	}

	@ViewBuilder
	private func _contextActions(
		for app: AppInfoPresentable
	) -> some View {
		Button(
			.localized("Get Info"),
			systemImage: "info.circle"
		) {
			if runningInstallation != nil { showingRunningDetails = true }
			else { selectedInfoAppPresenting = AnyApp(base: app) }
		}
	}

	@ViewBuilder
	private func _contextActionsExtra(
		for app: AppInfoPresentable
	) -> some View {
		if _isNativeAccountApp {
			if isManagedInstalled, let id = app.identifier, _signedAction(update: nil) == .open {
				Button("Open", systemImage: "app.badge.checkmark") { UIApplication.openApp(with: id) }
			}
			if isManagedInstalled {
				Button("Refresh", systemImage: "arrow.clockwise") { _startNative() }
			} else if _hasPendingNativeInstall, _signedAction(update: nil) == .install {
				Button("Install", systemImage: "square.and.arrow.down") { _startNative(installSaved: true) }
			}
			if _hasPendingNativeInstall {
				Button("Export IPA", systemImage: "square.and.arrow.up") { _exportNativeIPA() }
			}
			Button("Sign Separate Copy", systemImage: "person.crop.circle.badge.plus") { confirmSeparateSigning = true }
		} else if app.isSigned {
			if isManagedInstalled, let id = app.identifier, _signedAction(update: nil) == .open {
				Button(
					.localized("Open"),
					systemImage: "app.badge.checkmark"
				) {
					UIApplication.openApp(with: id)
				}
			} else if _signedAction(update: nil) == .install {
				Button(
					.localized("Install"),
					systemImage: "square.and.arrow.down"
				) {
					_installImmediately(app)
				}
			}

			if isManagedInstalled, _signedAction(update: nil) == .open {
				Button(
					.localized("Re-install"),
					systemImage: "square.and.arrow.down"
				) {
					_installImmediately(app)
				}
			}

			Button(
				.localized("Re-sign"),
				systemImage: "signature"
			) {
				_signImmediately(app)
			}

			Button(
				.localized("Export"),
				systemImage: "square.and.arrow.up"
			) {
				selectedInstallAppPresenting = AnyApp(
					base: app,
					archive: true
				)
			}
		} else {
			Button(
				.localized("Install"),
				systemImage: "square.and.arrow.down"
			) {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
		}
		Button("Customise", systemImage: "slider.horizontal.3") { selectedSigningAppPresenting = AnyApp(base: app) }
	}

	// MARK: - App Store Style Action

	@ViewBuilder
	private func _buttonActions(
		for app: AppInfoPresentable
	) -> some View {
		if app.isSigned {
			let status = runningInstallation
			let certificate = status == nil && !_isNativeAccountApp ? Storage.shared.getCertificate(from: app) : nil
			let update = isManagedInstalled ? availableUpdate : nil
			let certRevoked = certificate?.revoked == true
			let expiry = status != nil ? status?.expiry :
				(_isNativeAccountApp ? _nativeProfileExpiry : (ZagCertificateProfileReceipt.load(for: app)?.effectiveExpiration ?? certificate?.expiration))
			ZStack {
				// One control: Install contracts into the progress circle and
				// expands back into Install, Update or Open.
				ZagInstallControl(
					mode: status == nil ? _signedControlMode(update: update) : _runningControlMode,
					action: {
						if status == nil { _signedControlTap(update: update) }
						else if jobs.job(_jobKey) == nil {
							if runningHasUpdate { onRunningUpdate?() }
							else if ZagBatchCoordinator.shared.canRefreshRunning() {
								Task { await ZagBatchCoordinator.shared.refreshRunning() }
							} else { showingRunningDetails = true }
						}
					},
					cancelAction: _canCancelFromControl ? _requestCancel : nil
				)

				if let caption = status == nil ? _signedCaption(update: update) : _jobCaption {
					_progressCaption(caption)
				} else if certRevoked {
					Text(.localized("Revoked"))
						.font(
							.system(
								size: 10,
								weight: .regular
							)
						)
						.foregroundStyle(Color.red)
						.lineLimit(1)
						.offset(y: 24)
				} else if let expiry {
					_expiryCaption(expiry, appleID: status.map { $0.method == .personal } ?? _isNativeAccountApp,
						showIdentity: status?.method != .unknown)
				}
			}
			.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.compactRowHeight, alignment: .center)
			} else {
				ZStack {
					// One control: Sign contracts into the circle while signing
					// and installing, and expands back.
					ZagInstallControl(
						mode: _runningMode ?? .pill(ZagInstallPill(title: .localized("Sign"), accessibilityLabel: "Sign \(app.name ?? "app")")),
						action: { _signImmediately(app) },
						cancelAction: _canCancelFromControl ? _requestCancel : nil
					)

					if let caption = _jobCaption { _progressCaption(caption) }
				}
				.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.actionHeight)
			}
	}

	private var _hasPendingNativeInstall: Bool {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		return _nativeEntry?.pendingInstall != nil
		#else
		return false
		#endif
	}

	private var _nativeProfileExpiry: Date? {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		return _nativeEntry?.installation.record.expiresAt
		#else
		return nil
		#endif
	}

	private var _runningControlMode: ZagInstallControlMode {
		let title = runningHasUpdate ? "Update" : ZagBatchCoordinator.shared.canRefreshRunning() ? "Refresh" : "Manage"
		return _runningMode ?? .pill(.init(title: title, accessibilityLabel: "\(title) Zag Store"))
	}

	private var _runningMode: ZagInstallControlMode? {
		guard let job = jobs.job(_jobKey) else { return nil }
		return job.nativeCaption != nil && job.progress > 0 ? .progress(job.progress, .none) : .spinner(.none)
	}

	private func _progressCaption(_ caption: String) -> some View {
		Text(caption).font(.system(size: 9, weight: .medium))
			.foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.82).frame(width: ZagListLayout.actionWidth, height: 11).offset(y: 26)
	}

	private func _expiryCaption(_ expiry: Date, appleID: Bool, showIdentity: Bool = true) -> some View {
		let now = Date()
		let info = expiry.expirationInfo(from: now)
		let color: Color
		if appleID {
			switch ZagAppleIDProfileValidity(expiresAt: expiry, now: now) {
			case .valid: color = .green
			case .soon: color = .orange
			case .urgent, .expired: color = .red
			}
		} else { color = info.color }
		return HStack(alignment: .firstTextBaseline, spacing: 2) {
			Group {
				if showIdentity {
					if appleID { ZagAppleIDMark() }
					else { Image(systemName: "shield").accessibilityHidden(true) }
				}
			}
			.alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 0.75 }
			Text(info.formatted)
		}
		.font(.system(size: 8, weight: .regular))
		.foregroundStyle(color)
		.lineLimit(1)
		.offset(y: 26)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(showIdentity ? "\(appleID ? "Apple ID" : "Certificate"), \(info.formatted)" : info.formatted))
	}

	private func _exportNativeIPA() {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		Task { @MainActor in
			do {
				let url = try await ZagNativeAppInventory.prepareIPAExport(app)
				let directory = url.deletingLastPathComponent()
				guard let presenter = UIApplication.topViewController() else {
					try? FileManager.default.removeItem(at: directory)
					return
				}
				let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
				controller.completionWithItemsHandler = { _, _, _, _ in
					try? FileManager.default.removeItem(at: directory)
				}
				controller.popoverPresentationController?.sourceView = presenter.view
				controller.popoverPresentationController?.sourceRect = CGRect(
					x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
				presenter.present(controller, animated: true)
			} catch {
				UIAlertController.showAlertWithOk(title: "Export Failed", message: error.localizedDescription)
			}
		}
		#endif
	}

	private func _signSeparateCopy() {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		guard let entry = _nativeEntry, let owner = entry.installation.record.owner,
			  jobs.begin(_jobKey, stage: .signing) else { return }
		Task { @MainActor in
			defer { jobs.finish(_jobKey) }
			do {
				let account = try await ZagAppleIDSigningSelection.resolve(exclude: owner.scope.accountID)
				_ = try await ZagNativeAccountInstall.signSeparateCopy(entry, using: account, job: _jobKey)
			} catch is ZagInstallCancelled {
			} catch { ZagNativeAccountInstall.showInlineFailure(error) }
		}
		#endif
	}

	private func _startNative(installSaved: Bool = false) {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		guard jobs.begin(_jobKey, stage: installSaved ? .packaging : .signing) else { return }
		Task { @MainActor in
			defer { withAnimation(.easeInOut(duration: 0.25)) { jobs.finish(_jobKey) } }
			do {
				if installSaved, let entry = _nativeEntry {
					try await ZagNativeAccountInstall.installSaved(entry: entry, job: _jobKey)
				} else {
					let options = OptionsManager.shared.appleIDSigningDefaults
					let result = try await ZagNativeAccountInstall.runInline(app, job: _jobKey, options: options, renew: _isNativeAccountApp)
					if !app.isSigned, options.deleteImportAfterSigning, !jobs.isCancelRequested(_jobKey) {
						Storage.shared.deleteApp(for: app)
					}
					if case .verified = result { try? ZagRPPairingCore.shared.refreshInstalledApps() }
				}
			} catch is ZagInstallCancelled {
			} catch {
				ZagNativeAccountInstall.showInlineFailure(error, fallback: installSaved ? .installation : _isNativeAccountApp ? .refresh : .signing,
					retry: { _startNative(installSaved: installSaved) }) { selectedSigningAppPresenting = AnyApp(base: app) }
			}
		}
		#else
		UIAlertController.showAlertWithOk(title: "Apple Account", message: "Apple Account signing is unavailable in this build.")
		#endif
	}

	// MARK: - Install control

	private func _signedAction(update: UpdateManager.AvailableUpdate?) -> ZagAppRowAction {
		let certificate = Storage.shared.getCertificate(from: app)
		let expiry = _isNativeAccountApp ? _nativeProfileExpiry : (ZagCertificateProfileReceipt.load(for: app)?.effectiveExpiration ?? certificate?.expiration)
		// An imported signed archive may predate certificate metadata; preserve
		// the existing explicit Install path when its validity is unknown.
		let launchable = certificate?.revoked != true && expiry.map { $0 > Date() } != false
		return ZagAppRowAction.resolve(installed: isManagedInstalled && app.identifier != nil,
			hasUpdate: update != nil, signed: app.isSigned, launchable: launchable, canRefresh: app.isSigned)
	}

	private func _signedControlMode(update: UpdateManager.AvailableUpdate?) -> ZagInstallControlMode {
		if let running = _runningMode { return running }
		if let update {
			let stage = updateTransaction.stage(for: update)
			if let job = jobs.job(ZagUpdateTransactionManager.jobID(update)), job.nativeCaption != nil, job.progress > 0 {
				return .progress(job.progress, .none)
			}
			if let stage, !isFailedUpdateStage(stage) { return .spinner(.none) }
		}
		let title = _signedAction(update: update).rawValue
		return .pill(ZagInstallPill(title: .localized(title), accessibilityLabel: "\(title) \(app.name ?? "app")"))
	}

	private func _signedControlTap(update: UpdateManager.AvailableUpdate?) {
		switch _signedAction(update: update) {
		case .update: if let update { _startInstalledUpdate(update) }
		case .open: if let id = app.identifier { UIApplication.openApp(with: id) }
		case .install:
			if _isNativeAccountApp { _startNative(installSaved: _hasPendingNativeInstall) }
			else { _installImmediately(app) }
		case .refresh:
			if _isNativeAccountApp { _startNative() }
			else { selectedSigningAppPresenting = AnyApp(base: app) }
		case .sign: _signImmediately(app)
		}
	}

	private func _signedCaption(update: UpdateManager.AvailableUpdate?) -> String? {
		if let caption = _jobCaption { return caption }
		if let update {
			if let caption = jobs.job(ZagUpdateTransactionManager.jobID(update))?.nativeCaption { return caption }
			let caption = updateStageCaption(updateTransaction.stage(for: update))
			return caption.isEmpty ? nil : caption
		}
		return nil
	}
	private var _canCancelFromControl: Bool {
		guard let job = jobs.job(_jobKey) else { return false }
		return job.offersCancel && job.stage.allowsCancel && !job.cancelRequested
	}

	private func _requestCancel() {
		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
		let response = jobs.requestCancel(_jobKey)
		ZagLogger.shared.info("Library Install", "Cancel requested: \(app.name ?? "app") | \(response)")
	}

	private func isFailedUpdateStage(_ stage: ZagUpdateTransactionManager.Stage) -> Bool {
		if case .failed = stage { return true }
		return false
	}

	private func updateStageCaption(_ stage: ZagUpdateTransactionManager.Stage?) -> String {
		switch stage {
		case .downloading: return .localized("Downloading")
		case .importing, .signing, .readyToInstall: return .localized("Preparing")
		case .installing: return .localized("Installing")
		default: return ""
		}
	}

	private func _startInstalledUpdate(_ update: UpdateManager.AvailableUpdate) {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		updateTransaction.prepare(update) { result in
			switch result {
			case .success(let signedUUID):
				Task { @MainActor in
					do {
						guard try await updateTransaction.installPreparedUpdate(signedUUID: signedUUID) else { return }
						try? ZagRPPairingCore.shared.refreshInstalledApps()
					} catch {
						updateTransaction.failInstallation(update: update, error: error)
						#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
						ZagNativeAccountInstall.showInlineFailure(error, fallback: .installation)
						#else
						UIAlertController.showAlertWithOk(title: .localized("Installation Failed"), message: error.localizedDescription)
						#endif
					}
				}
			case .failure(let error):
				#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
				if !(error is ZagInstallCancelled) { ZagNativeAccountInstall.showInlineFailure(error) }
				#else
				UIAlertController.showAlertWithOk(title: .localized("Update Failed"), message: error.localizedDescription)
				#endif
			}
		}
	}

	private func _installImmediately(
		_ app: AppInfoPresentable,
		importedAfterSigning: AppInfoPresentable? = nil
	) {
		// In a Sign -> Install transaction the signing stage has already
		// switched this row into its Installing... state.
		if importedAfterSigning == nil {
			guard !isInstallingImmediately else { return }

			withAnimation(.easeInOut(duration: 0.25)) {
				isInstallingImmediately = true
			}
		}

		UIImpactFeedbackGenerator(style: .light).impactOccurred()

		let key = _jobKey
		Task { @MainActor in
			do {
				let archiveHandler = ArchiveHandler(app: app)
				try await archiveHandler.move()
				let packageURL = try await archiveHandler.archive()

				defer {
					try? FileManager.default.removeItem(
						at: packageURL.deletingLastPathComponent()
					)
				}
				// Safe point: packaging finished.
				try jobs.checkpoint(key)
				jobs.advance(key, to: .preparingMobileDataFix)

				// Mobile Data Fix wraps the existing installer when Mobile Data blocks it.
				let coordinator = ZagMobileDataInstallCoordinator.shared
				try await coordinator.install(jobID: app.uuid ?? UUID().uuidString, bundleID: app.identifier, cancelRequested: { jobs.isCancelRequested(key) }) {
					// Last safe point; after this the installer must finish.
					try jobs.beginInstalling(key)
					defer { if coordinator.usingMobileDataFix { jobs.advance(key, to: .restoringMobileData) } }
					try await withCheckedThrowingContinuation {
						(continuation: CheckedContinuation<Void, Error>) in

						do {
							try ZagRPPairingCore.shared.installGate4IPA(
								at: packageURL,
								deviceIP: ZagDeviceLink.peerAddress,
								retryTransientFailures: true,
								completion: { result in
									continuation.resume(with: result)
								}
							)
						} catch {
							continuation.resume(throwing: error)
						}
					}
				}

				let confirmed = await onInstallCompleted?(app) ?? false

				if confirmed {
					try? await Task.sleep(nanoseconds: 550_000_000)

					withAnimation(.easeInOut(duration: 0.35)) {
						isInstallingImmediately = false

						if let importedAfterSigning {
							Storage.shared.deleteApp(for: importedAfterSigning)
						}
					}
				} else {
					withAnimation(.easeInOut(duration: 0.25)) {
						isInstallingImmediately = false
					}

					if let importedAfterSigning {
						Storage.shared.deleteApp(for: importedAfterSigning)
					}
				}
			} catch where Self._isCancellation(error) {
				// Cancelled before installation: keep the Signed record and,
				// in a Sign -> Install transaction, the Imported record too.
				withAnimation(.easeInOut(duration: 0.25)) {
					isInstallingImmediately = false
				}
				if importedAfterSigning != nil, let signedUUID = app.uuid {
					onInstallFailedAfterSigning?(signedUUID)
				}
				ZagLogger.shared.info("Library Install", "Cancelled before installation: \(app.name ?? "app")")
			} catch {
				withAnimation(.easeInOut(duration: 0.25)) {
					isInstallingImmediately = false
				}

				// Signing succeeded but installation did not. Remove the
				// Imported staging row and leave the Signed result available
				// so installation can be retried from Signed.
				if let importedAfterSigning {
					if let signedUUID = app.uuid {
						onInstallFailedAfterSigning?(signedUUID)
					}
					Storage.shared.deleteApp(for: importedAfterSigning)
				}

				#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
				ZagNativeAccountInstall.showInlineFailure(error, fallback: .installation)
				#else
				UIAlertController.showAlertWithOk(
					title: .localized("Installation Failed"),
					message: error.localizedDescription,
					isCancel: true
				)
				#endif
			}
		}
	}

	private func _signImmediately(_ app: AppInfoPresentable) {
		guard !jobs.isActive(_jobKey), !choosingSigningMethod else { return }
		choosingSigningMethod = true
		Task { @MainActor in
			defer { choosingSigningMethod = false }
			guard let method = await ZagCertificateSelection.chooseMethod() else { return }
			if method == .freeAppleAccount { _startNative(); return }
			guard let certificate = ZagCertificateSelection.activeCertificate() else {
				UIAlertController.showAlertWithOk(title: .localized("No Certificate"),
					message: "Select an imported certificate in Settings.", isCancel: true)
				return
			}
			withAnimation(.easeInOut(duration: 0.25)) { isSigningImmediately = true }

			var options = OptionsManager.shared.options

			if
				options.ppqProtection,
				let identifier = app.identifier,
				certificate.ppQCheck
			{
				options.appIdentifier = "\(identifier).\(options.ppqString)"
			}
			if
				let identifier = app.identifier,
				let mappedIdentifier = options.identifiers[identifier]
			{
				options.appIdentifier = mappedIdentifier
			}
			if
				let name = app.name,
				let mappedName = options.displayNames[name]
			{
				options.appName = mappedName
			}

			UIImpactFeedbackGenerator(style: .light).impactOccurred()

			var signedUUID: String?

			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: certificate,
				signedUUID: { signedUUID = $0 }
			) { error in
				if let error {
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
					}

					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: error.localizedDescription,
						isCancel: true
					)
					return
				}

				if options.post_installAppAfterSigned {
					guard
						let signedUUID,
						let signed = _signedApp(uuid: signedUUID)
					else {
						withAnimation(.easeInOut(duration: 0.25)) {
							isSigningImmediately = false
						}

						UIAlertController.showAlertWithOk(
							title: .localized("Installation Failed"),
							message: .localized("Signing completed, but Zag Store could not locate the signed app."),
							isCancel: true
						)
						return
					}

					// Safe point: signing committed the Signed record. A cancel
					// keeps it and the Imported record, and installs nothing.
					if jobs.isCancelRequested(_jobKey) {
						withAnimation(.easeInOut(duration: 0.25)) {
							isSigningImmediately = false
						}
						ZagLogger.shared.info("Library Install", "Cancelled after signing: \(app.name ?? "app")")
						return
					}

					onSignedForInstall?(signedUUID)

					// Keep the Imported row in place. Only its operational
					// state changes from Signing... to Installing...
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
						isInstallingImmediately = true
					}

					_installImmediately(
						signed,
						importedAfterSigning: app.isSigned ? nil : app
					)
				} else {
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
					}

					if options.post_deleteAppAfterSigned && !app.isSigned {
						Storage.shared.deleteApp(for: app)
					}
				}
			}
		}
	}

	private func _signedApp(uuid: String) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

}

// MARK: - Repository Origin

/// Resolves the repository an installed app came from, using provenance
/// recorded by repository reconciliation. It never rescans every app in every
/// repository, so its cost does not grow with the catalogue.
enum ZagLibraryRepositoryOrigin {
	static func resolve(
		bundleID: String?,
		in sources: [AltSource: ASRepository]
	) -> (AltSource, ASRepository)? {
		guard let bundleID, !bundleID.isEmpty else { return nil }
		let origins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String]
		guard let origin = origins?[bundleID] else { return nil }
		return sources.first(where: { storedSource, repository in
			storedSource.sourceURL?.absoluteString == origin ||
			repository.id == origin ||
			repository.website?.absoluteString == origin ||
			repository.name == origin
		})
	}

	static func iconURL(
		bundleID: String?,
		origin: (AltSource, ASRepository)?
	) -> URL? {
		if let iconURL = origin?.1.currentIconURL {
			return iconURL
		}
		guard let bundleID, !bundleID.isEmpty else { return nil }
		let icons = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOriginIcons"
		) as? [String: String]
		guard let value = icons?[bundleID] else { return nil }
		return URL(string: value)
	}
}

/// The small repository badge on an Apps row. It observes repository state
/// itself, so a repository refresh re-renders only this badge.
private struct ZagLibraryRepositoryBadge: View {
	let bundleID: String?
	let onTap: ((AltSource) -> Void)?
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared

	var body: some View {
		let origin = ZagLibraryRepositoryOrigin.resolve(
			bundleID: bundleID,
			in: sourcesViewModel.sources
		)
		if let repositoryIconURL = ZagLibraryRepositoryOrigin.iconURL(
			bundleID: bundleID,
			origin: origin
		) {
			Button {
				guard let source = origin?.0 else { return }
				UIImpactFeedbackGenerator(style: .light).impactOccurred()
				onTap?(source)
			} label: {
				LazyImage(url: repositoryIconURL) { state in
					if let image = state.image {
						image
							.appIconStyle(
								size: 20,
								isCircle: true,
								background: Color(
									uiColor: .secondarySystemBackground
								)
							)
							.offset(x: 46, y: 4)
					}
				}
			}
			.buttonStyle(.plain)
			.accessibilityLabel(
				Text("\(origin?.1.name ?? "Repository") repository")
			)
			.accessibilityHint(
				Text("Opens this app's source repository")
			)
			.accessibilityAddTraits(.isButton)
		}
	}
}

/// The "Source:" item in an Apps row's context menu.
private struct ZagLibraryRepositorySourceLabel: View {
	let bundleID: String?
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared

	var body: some View {
		if let repositoryName = ZagLibraryRepositoryOrigin.resolve(
			bundleID: bundleID,
			in: sourcesViewModel.sources
		)?.1.name {
			Label(
				"Source: \(repositoryName)",
				systemImage: "shippingbox"
			)
			.disabled(true)

			Divider()
		}
	}
}


private struct ZagRunningDetailsSheet: View {
	@ObservedObject var installation: ZagRunningInstallation
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List {
				Section {
					HStack(spacing: 12) {
						FRAppIconView(app: nil, size: 62)
						VStack(alignment: .leading) {
							Text("Zag Store").font(.headline)
							Text("\(installation.runningApp.version ?? "Unknown") (\(installation.runningApp.build ?? "Unknown"))").foregroundStyle(.secondary)
						}
					}
					LabeledContent("Signing Method", value: installation.method == .imported ? "Certificate" : installation.method.rawValue)
					if let pair = installation.importedCertificate,
					   let name = pair.nickname ?? Storage.shared.getProvisionFileDecoded(for: pair)?.Name {
						LabeledContent("Certificate", value: name)
					}
					if let expiry = installation.expiry {
						LabeledContent("Expiration", value: expiry.formatted(date: .abbreviated, time: .omitted))
						LabeledContent("Validity") { Text(expiry.expirationInfo(from: Date()).formatted).foregroundStyle(expiry.expirationInfo(from: Date()).color) }
					}
				}
				if let recovery = installation.recovery {
					Section { Text(recovery).foregroundStyle(.secondary)
						Button("Verify Installation") { Task { await installation.inspect(verifyPersonal: true, retry: true) } }.disabled(installation.inspecting)
					}
				}
				if ZagBatchCoordinator.shared.canRefreshRunning() {
					Section { Button("Refresh") { Task { await ZagBatchCoordinator.shared.refreshRunning() } } }
				}
			}
			.navigationTitle("Zag Store")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close") } }
		}
	}
}
