#if ZAG_ZSIGN_STRICT
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Drives the Zag Companion window from the core service. All signing/install
// work runs off the main actor; progress and results hop back to update the UI.
@MainActor
public final class ZagCompanionViewModel: ObservableObject {
	@Published public var devices: [ZagCompanionDevice] = []
	@Published public var selectedDevice: ZagCompanionDevice?
	@Published public var teams: [ZagCompanionTeam] = []
	@Published public var selectedTeam: ZagCompanionTeam?
	@Published public var ipaInfo: ZagCompanionIPAInfo?
	@Published public var progress = ZagCompanionProgress(.idle, "Ready.")
	@Published public var busy = false
	@Published public var allowNewProvisioning = false
	@Published public var managedApps: [ZagManagedApp] = []
	@Published public var lastError: String?
	@Published public var pairingCode = ""
	@Published public var pairingKey = ""

	private let service: ZagCompanionService

	public init() {
		let template = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("XcodePTTeamProbe")
		service = ZagCompanionService(config: ZagCompanionConfig(templateProjectURL: template))
		refreshDevices(); refreshTeams(); refreshManaged()
	}

	public func refreshDevices() {
		devices = (try? ZagDeviceControl.devices()) ?? []
		if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
			selectedDevice = devices.first { $0.connected } ?? devices.first
		}
	}
	public func refreshTeams() {
		teams = ZagCompanionProvisioning.availableTeams()
		if selectedTeam == nil { selectedTeam = teams.first { $0.isFree } ?? teams.first }
	}
	public func refreshManaged() { managedApps = service.registry.all() }

	public func chooseIPA() {
		let panel = NSOpenPanel()
		if let ipaType = UTType(filenameExtension: "ipa") { panel.allowedContentTypes = [ipaType] }
		panel.allowsOtherFileTypes = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.prompt = "Select IPA"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		lastError = nil
		Task.detached { [service] in
			let info = try? ZagIPA.info(url)
			await MainActor.run {
				if let info { self.ipaInfo = info; self.progress = ZagCompanionProgress(.idle, "Ready to install \(info.displayName) (\(info.bundleIdentifier)).") }
				else { self.lastError = "Could not read that IPA." }
			}
			_ = service
		}
	}

	public func install() {
		guard let ipa = ipaInfo?.url, let device = selectedDevice, let team = selectedTeam else { return }
		run { try self.service.install(ipa: ipa, on: device, team: team, allowNewProvisioning: self.allowNewProvisioning, progress: self.report) }
	}
	public func renew(_ app: ZagManagedApp) {
		guard let device = selectedDevice ?? devices.first(where: { $0.udid == app.deviceUDID }),
			  let team = selectedTeam ?? teams.first(where: { $0.identifier == app.teamIdentifier }) else { return }
		run { try self.service.renew(app, on: device, team: team, allowNewProvisioning: self.allowNewProvisioning, progress: self.report) }
	}
	public func launch(_ app: ZagManagedApp) {
		guard let device = selectedDevice ?? devices.first(where: { $0.udid == app.deviceUDID }) else { return }
		run { try ZagDeviceControl.launch(bundleID: app.bundleIdentifier, on: device); return nil }
	}

	public func startPairing() {
		pairingCode = ZagCompanionPairing.newPairingCode()
		pairingKey = ((try? ZagCompanionPairing.identity().publicKey.base64EncodedString()) ?? "").prefix(16) + "…"
	}

	// MARK: - plumbing

	private nonisolated func report(_ p: ZagCompanionProgress) { Task { @MainActor in self.progress = p } }

	private func run(_ work: @escaping () throws -> ZagManagedApp?) {
		busy = true; lastError = nil
		Task.detached {
			do { _ = try work() ; await MainActor.run { self.finish(nil) } }
			catch { await MainActor.run { self.finish(error) } }
		}
	}
	private func finish(_ error: Error?) {
		busy = false; refreshManaged()
		if let error { lastError = "\(error)"; progress = ZagCompanionProgress(.failed, "Failed.") }
	}
}
#endif
