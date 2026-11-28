import Foundation
import SwiftUI
import Sparkle

/// Sparkle is never started in a development build or without a valid update trust key.
/// The desktop appcast and key must be independent from Zag Store's iOS beta channel.
@MainActor
final class InstallerUpdates: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    let configured: Bool
    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = info["ZagUpdatesReady"] as? Bool == true
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        let feedString = info["SUFeedURL"] as? String ?? ""
        let feed = URL(string: feedString)
        let validKey = Data(base64Encoded: publicKey)?.count == 32
        let validFeed = feed?.scheme == "https" && feed?.host != nil
        configured = enabled && validKey && validFeed

        if configured {
            let updater = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
            )
            controller = updater
            updater.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        } else {
            controller = nil
        }
    }

    var updater: SPUUpdater? { controller?.updater }

    func checkNow(installerBusy: Bool) {
        guard !installerBusy, canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func checkOnLaunchIfAllowed(installerBusy: Bool) {
        guard !installerBusy, let updater = controller?.updater,
              updater.automaticallyChecksForUpdates else { return }
        // Sparkle recommends calling this only immediately after startup.
        // Sparkle itself handles subsequent daily checks.
        updater.checkForUpdatesInBackground()
    }
}

struct InstallerUpdateSettingsView: View {
    @ObservedObject var updates: InstallerUpdates
    @ObservedObject var installer: InstallerController
    @State private var automaticChecks: Bool
    @State private var automaticDownloads: Bool

    init(updates: InstallerUpdates, installer: InstallerController) {
        self.updates = updates
        self.installer = installer
        _automaticChecks = State(initialValue: updates.updater?.automaticallyChecksForUpdates ?? true)
        _automaticDownloads = State(initialValue: updates.updater?.automaticallyDownloadsUpdates ?? false)
    }

    var body: some View {
        Form {
            Section("zLoader Updates") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                LabeledContent("Channel", value: "Beta")
                Toggle("Automatically check for updates", isOn: $automaticChecks)
                    .disabled(!updates.configured)
                    .onChange(of: automaticChecks) { _, value in
                        updates.updater?.automaticallyChecksForUpdates = value
                    }
                Toggle("Automatically download updates", isOn: $automaticDownloads)
                    .disabled(!updates.configured || !automaticChecks)
                    .onChange(of: automaticDownloads) { _, value in
                        updates.updater?.automaticallyDownloadsUpdates = value
                    }
                Button("Check for Updates Now") {
                    updates.checkNow(installerBusy: installer.busy)
                }
                .disabled(installer.busy || !updates.canCheckForUpdates)
            }
            if !updates.configured {
                Section {
                    Label("Signed desktop updates are being prepared. Update checks are unavailable in this development build.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Desktop updates are independent of Zag Store for iOS. Update installation is not enabled during development.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
        .formStyle(.grouped)
        .frame(width: 510, height: 350)
    }
}
