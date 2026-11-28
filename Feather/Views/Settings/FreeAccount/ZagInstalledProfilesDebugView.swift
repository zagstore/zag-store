#if DEBUG || ZAG_LIVE_EXPERIMENT
import SwiftUI

// Debug builds only: reads the provisioning profiles installed on this
// iPhone through RPPairing (misagent, read only; draft PR #25) and checks
// Zag Store's own embedded profile against them with the same
// ZagInstalledProfileCheck the free-account installer uses. Nothing is
// installed, removed or changed. Nothing here is logged; profile UUIDs are
// shortened on screen and the copyable summary holds no identifiers.
// Device identifiers listed inside profiles are never read out.

/// One installed profile, reduced to what the test needs.
struct ZagInstalledProfileSummary: Identifiable, Equatable {
	let id: Int
	let byteCount: Int
	let uuid: String?
	let team: String?
	let appID: String?
	let expires: Date?
	let platforms: [String]
	let deviceCount: Int?
	let allDevices: Bool
	let isThisApp: Bool

	var readable: Bool { uuid != nil }

	init(index: Int, data: Data, embeddedUUID: String?) {
		id = index
		byteCount = data.count
		let profile = try? Certificate.decode(profileData: data)
		uuid = profile?.UUID
		team = profile?.TeamIdentifier.first
		appID = profile?.Entitlements?["application-identifier"]?.value as? String
		expires = profile?.ExpirationDate
		platforms = profile?.Platform ?? []
		deviceCount = profile?.ProvisionedDevices?.count
		allDevices = profile?.ProvisionsAllDevices ?? false
		isThisApp = profile != nil && profile?.UUID == embeddedUUID
	}
}

enum ZagInstalledProfilesRedaction {
	/// "1A2B3C4D…9F0E": enough to tell profiles apart on screen.
	static func short(_ value: String) -> String {
		value.count > 12 ? "\(value.prefix(8))…\(value.suffix(4))" : value
	}
}

@MainActor
final class ZagInstalledProfilesProbe: ObservableObject {
	enum Phase: Equatable {
		case idle
		case reading
		case done(Date)
		case failed(String)
	}

	@Published private(set) var phase: Phase = .idle
	@Published private(set) var profiles: [ZagInstalledProfileSummary] = []
	@Published private(set) var match: ZagInstallVerification?
	@Published private(set) var alteredExpiry: ZagInstallVerification?
	@Published private(set) var missingProfile: ZagInstallVerification?

	/// This app's own embedded profile: the expected one.
	let embedded: Certificate? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
		.flatMap { try? Data(contentsOf: $0) }
		.flatMap { try? Certificate.decode(profileData: $0) }

	var expectation: ZagInstallExpectation? {
		guard let embedded, let bundleID = Bundle.main.bundleIdentifier else { return nil }
		return ZagInstallExpectation(
			bundleIdentifier: bundleID,
			profileUUID: embedded.UUID,
			profileExpiresAt: embedded.ExpirationDate,
			certificateExpiresAt: embedded.ExpirationDate,
			signerCommonName: nil,
			teamIdentifier: embedded.TeamIdentifier.first
		)
	}

	func read() {
		guard phase != .reading else { return }
		phase = .reading
		ZagRPPairingCore.shared.readInstalledProfiles(deviceIP: ZagDeviceLink.peerAddress) { [weak self] result in
			Task { @MainActor in self?.finish(result) }
		}
	}

	private func finish(_ result: Result<[Data], Error>) {
		switch result {
		case .failure(let error):
			profiles = []
			match = nil
			alteredExpiry = nil
			missingProfile = nil
			phase = .failed(error.localizedDescription)
		case .success(let data):
			profiles = data.enumerated().map { ZagInstalledProfileSummary(index: $0.offset, data: $0.element, embeddedUUID: embedded?.UUID) }
			if let expectation {
				match = ZagInstalledProfileCheck.verify(expectation, installedProfiles: data)
				// Negative controls: the same check must refuse a wrong expiry
				// and a profile that is not installed.
				let altered = ZagInstallExpectation(
					bundleIdentifier: expectation.bundleIdentifier,
					profileUUID: expectation.profileUUID,
					profileExpiresAt: expectation.profileExpiresAt.addingTimeInterval(86_400),
					certificateExpiresAt: expectation.certificateExpiresAt,
					signerCommonName: nil,
					teamIdentifier: expectation.teamIdentifier
				)
				alteredExpiry = ZagInstalledProfileCheck.verify(altered, installedProfiles: data)
				let missing = ZagInstallExpectation(
					bundleIdentifier: expectation.bundleIdentifier,
					profileUUID: UUID().uuidString,
					profileExpiresAt: expectation.profileExpiresAt,
					certificateExpiresAt: expectation.certificateExpiresAt,
					signerCommonName: nil,
					teamIdentifier: expectation.teamIdentifier
				)
				missingProfile = ZagInstalledProfileCheck.verify(missing, installedProfiles: data)
			}
			phase = .done(Date())
		}
	}

	/// Pass or fail per test item, with no identifiers, for the owner's report.
	var summary: String {
		let readable = profiles.filter(\.readable)
		func field(_ present: (ZagInstalledProfileSummary) -> Bool) -> String { "\(readable.filter(present).count)/\(readable.count)" }
		var lines = ["Zag Store installed-profile read-back test"]
		switch phase {
		case .idle, .reading: lines.append("Not finished")
		case .failed(let message):
			lines.append("Read failed: \(message)")
			#if ZAG_LIVE_EXPERIMENT
			lines.append("G5 read-back: unavailable (the device's profiles could not be read)")
			#endif
		case .done:
			lines.append("Profiles returned: \(profiles.count); readable: \(readable.count); unreadable: \(profiles.count - readable.count)")
			lines.append("Fields present: UUID \(field { $0.uuid != nil }), team \(field { $0.team != nil }), App ID \(field { $0.appID != nil }), expiry \(field { $0.expires != nil })")
			lines.append("Embedded profile present in app: \(embedded == nil ? "no" : "yes")")
			lines.append("This app's profile among installed: \(profiles.contains(where: \.isThisApp) ? "yes" : "no")")
			lines.append("Match: \(Self.describe(match))")
			lines.append("Control, altered expiry (expect mismatch): \(Self.describe(alteredExpiry))")
			lines.append("Control, absent profile (expect not verified): \(Self.describe(missingProfile))")
			#if ZAG_LIVE_EXPERIMENT
			// G5 (checklist M10): the four results, kept distinct.
			lines.append("G5 read-back: \(match.map { ZagExperimentReadback.classify($0, readSucceeded: true).rawValue } ?? "not run")")
			#endif
		}
		return lines.joined(separator: "\n")
	}

	static func describe(_ result: ZagInstallVerification?) -> String {
		switch result {
		case .none: return "not run"
		case .verified: return "VERIFIED"
		case .unverifiable(let reason): return "NOT VERIFIED (\(reason))"
		case .mismatch(let what): return "MISMATCH (\(what))"
		case .notInstalled, .signedOnly: return "NOT INSTALLED"
		}
	}
}

struct ZagInstalledProfilesDebugView: View {
	@StateObject private var probe = ZagInstalledProfilesProbe()

	var body: some View {
		List {
			Section {
				VStack(alignment: .leading, spacing: 10) {
					Label("Read Only", systemImage: "lock.doc")
						.font(.headline)
					Text("Lists the provisioning profiles iOS reports as installed, then checks this app's own profile against them. Nothing on the iPhone is changed.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
					Button {
						probe.read()
					} label: {
						HStack {
							if probe.phase == .reading { ProgressView() }
							Text(probe.phase == .reading ? "Reading…" : "Read Installed Profiles")
								.fontWeight(.semibold)
						}
						.frame(maxWidth: .infinity, minHeight: 44)
					}
					.buttonStyle(.borderedProminent)
					.disabled(probe.phase == .reading)
				}
				.padding(16)
				.zagFreeAccountGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
				.listRowInsets(EdgeInsets())
				.listRowBackground(Color.clear)
			}

			if case .failed(let message) = probe.phase {
				Section("Result") {
					Label(message, systemImage: "exclamationmark.triangle")
						.foregroundStyle(.red)
				}
			}

			Section {
				if let embedded = probe.embedded {
					LabeledContent("Profile", value: ZagInstalledProfilesRedaction.short(embedded.UUID))
					LabeledContent("Team", value: embedded.TeamIdentifier.first ?? "not present")
					LabeledContent("Expires", value: embedded.ExpirationDate.formatted(date: .abbreviated, time: .shortened))
				} else {
					Text("This build has no embedded profile, so there is nothing to match.")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Expected (This App)")
			}

			if case .done = probe.phase {
				Section {
					_result("Match", probe.match, expect: .verified)
					_result("Altered expiry", probe.alteredExpiry, expect: .mismatch)
					_result("Absent profile", probe.missingProfile, expect: .unverifiable)
				} header: {
					Text("Check")
				} footer: {
					Text("The two controls feed the same check deliberately wrong expectations; it must refuse both.")
				}

				Section {
					if probe.profiles.isEmpty {
						Text("iOS returned no profiles.").foregroundStyle(.secondary)
					}
					ForEach(probe.profiles) { profile in
						_row(profile)
					}
				} header: {
					Text("Installed Profiles (\(probe.profiles.count))")
				} footer: {
					Text("Device lists inside profiles are counted, never shown.")
				}

				Section {
					Text(probe.summary)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
					Button {
						UIPasteboard.general.string = probe.summary
					} label: {
						Label("Copy Summary", systemImage: "doc.on.doc")
					}
				} header: {
					Text("Summary for the Report")
				} footer: {
					Text("Contains no profile, team or device identifiers.")
				}
			}
		}
		.navigationTitle("Installed Profiles")
	}

	private enum Expected { case verified, mismatch, unverifiable }

	private func _result(_ title: String, _ result: ZagInstallVerification?, expect: Expected) -> some View {
		let ok: Bool
		switch (result, expect) {
		case (.verified?, .verified), (.mismatch?, .mismatch), (.unverifiable?, .unverifiable): ok = true
		default: ok = false
		}
		return LabeledContent {
			Text(ZagInstalledProfilesProbe.describe(result))
				.font(.caption)
				.multilineTextAlignment(.trailing)
		} label: {
			Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
				.foregroundStyle(ok ? .green : .red)
		}
	}

	private func _row(_ profile: ZagInstalledProfileSummary) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(profile.uuid.map(ZagInstalledProfilesRedaction.short) ?? "Unreadable profile")
					.font(.system(.subheadline, design: .monospaced))
				if profile.isThisApp {
					Text("THIS APP")
						.font(.caption2.weight(.bold))
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(.tint.opacity(0.2), in: Capsule())
				}
			}
			if profile.readable {
				Group {
					Text("Team: \(profile.team ?? "not present")")
					Text("App ID: \(profile.appID ?? "not present")")
						.lineLimit(1)
						.truncationMode(.middle)
					Text("Expires: \(profile.expires?.formatted(date: .abbreviated, time: .shortened) ?? "not present")")
					Text("Platform: \(profile.platforms.isEmpty ? "not present" : profile.platforms.joined(separator: ", ")) · Devices: \(profile.allDevices ? "all" : profile.deviceCount.map(String.init) ?? "not present")")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			} else {
				Text("\(profile.byteCount) bytes; not a readable profile")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}
#if !DEBUG
// The experiment build (no DEBUG) lacks the Debug sign-in screen's modifier.
private extension View {
	@ViewBuilder
	func zagFreeAccountGlass<S: Shape>(in shape: S) -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(.regular, in: shape)
		} else {
			self.background(.ultraThinMaterial, in: shape)
		}
	}
}
#endif
#endif
