#if ZAG_ZSIGN_STRICT
import SwiftUI

struct ContentView: View {
	@EnvironmentObject var model: ZagCompanionViewModel

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				header
				deviceSection
				teamSection
				appSection
				installSection
				if let error = model.lastError { errorBanner(error) }
				managedSection
				pairingSection
			}
			.padding(22)
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("Zag Companion").font(.largeTitle.bold())
			Text("Provision, sign, install and renew iOS apps with a free Apple Account.")
				.font(.callout).foregroundStyle(.secondary)
		}
	}

	private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(title).font(.headline)
			content()
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
	}

	private var deviceSection: some View {
		card("1 · Device") {
			HStack {
				Picker("iPhone", selection: Binding(
					get: { model.selectedDevice?.id ?? "" },
					set: { id in model.selectedDevice = model.devices.first { $0.id == id } })) {
					ForEach(model.devices) { d in
						Text("\(d.name)\(d.connected ? "" : " (not connected)")").tag(d.id)
					}
					if model.devices.isEmpty { Text("No device").tag("") }
				}
				Button("Refresh") { model.refreshDevices() }
			}
			if let d = model.selectedDevice {
				Label(d.connected ? "Connected · \(d.model)" : "Not connected",
					  systemImage: d.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
					.foregroundStyle(d.connected ? .green : .orange).font(.caption)
			}
		}
	}

	private var teamSection: some View {
		card("2 · Signing team") {
			HStack {
				Picker("Team", selection: Binding(
					get: { model.selectedTeam?.identifier ?? "" },
					set: { id in model.selectedTeam = model.teams.first { $0.identifier == id } })) {
					ForEach(model.teams) { t in Text("\(t.name)\(t.isFree ? " · Free" : "")").tag(t.identifier) }
					if model.teams.isEmpty { Text("No team").tag("") }
				}
				Button("Refresh") { model.refreshTeams() }
			}
			if let t = model.selectedTeam {
				Text(t.isFree ? "Free Personal Team: 7-day profiles, per-device, one App ID per app."
							  : "Paid team.").font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	private var appSection: some View {
		card("3 · App") {
			HStack {
				Button("Select IPA…") { model.chooseIPA() }
				if let info = model.ipaInfo {
					VStack(alignment: .leading) {
						Text(info.displayName).bold()
						Text("\(info.bundleIdentifier) · \(info.version)").font(.caption).foregroundStyle(.secondary)
					}
				} else { Text("No IPA selected").foregroundStyle(.secondary) }
			}
		}
	}

	private var installSection: some View {
		card("4 · Install") {
			Toggle("Allow new Apple-side provisioning (registers device, uses a free-team slot)",
				   isOn: $model.allowNewProvisioning)
				.font(.caption)
			HStack(spacing: 12) {
				Button { model.install() } label: { Label("Install with Zag Companion", systemImage: "iphone.and.arrow.forward") }
					.buttonStyle(.borderedProminent)
					.disabled(model.busy || model.ipaInfo == nil || model.selectedDevice?.connected != true || model.selectedTeam == nil)
				if model.busy { ProgressView().controlSize(.small) }
			}
			HStack(spacing: 6) {
				stageDot
				Text(model.progress.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
			}
		}
	}

	private var stageDot: some View {
		let color: Color = {
			switch model.progress.stage {
			case .done: return .green; case .failed: return .red; case .idle: return .secondary; default: return .blue
			}
		}()
		return Circle().fill(color).frame(width: 9, height: 9)
	}

	private func errorBanner(_ error: String) -> some View {
		Text(error).font(.caption).foregroundStyle(.red)
			.padding(10).frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
	}

	private var managedSection: some View {
		card("Managed apps · renewal") {
			if model.managedApps.isEmpty {
				Text("Apps you install appear here for renewal.").font(.caption).foregroundStyle(.secondary)
			} else {
				ForEach(model.managedApps) { app in
					HStack {
						VStack(alignment: .leading) {
							Text(app.displayName).bold()
							Text("\(app.bundleIdentifier) · \(app.deviceName)").font(.caption).foregroundStyle(.secondary)
							Text(app.isExpired ? "Expired" : "Expires in \(app.daysUntilExpiry) day(s)")
								.font(.caption2).foregroundStyle(app.needsRenewalSoon ? .orange : .secondary)
						}
						Spacer()
						Button("Renew") { model.renew(app) }.disabled(model.busy)
						Button("Launch") { model.launch(app) }.disabled(model.busy)
					}
					.padding(.vertical, 4)
					Divider()
				}
			}
		}
	}

	private var pairingSection: some View {
		card("Zag Store pairing (foundation — remote install disabled)") {
			Label("Remote install from the phone is disabled in v0.1 until mutual authentication, transcript binding, code expiry, attempt limits, replay protection and an encrypted transport are implemented and tested.",
				  systemImage: "lock.fill")
				.font(.caption).foregroundStyle(.secondary)
			HStack {
				Button("Show pairing code") { model.startPairing() }
				if !model.pairingCode.isEmpty {
					Text("Code \(model.pairingCode) · key \(model.pairingKey)").font(.system(.caption, design: .monospaced))
				}
			}
		}
	}
}
#endif
