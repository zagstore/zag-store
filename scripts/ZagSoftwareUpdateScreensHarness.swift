import SwiftUI

// Hosts the production up-to-date state and More Details for simulator
// captures (scripts/capture-zag-software-update-screens.sh). The settings
// section above mirrors ZagSelfUpdateStatusView's; everything below it is the
// production code. SIMCTL_CHILD_ZAG_SCREEN picks the screen.

@main
struct ZagSoftwareUpdateScreensHarness: App {
    var body: some Scene {
        WindowGroup { HarnessRoot() }
    }
}

private let harnessEnvironment = ProcessInfo.processInfo.environment
private let release = ZagInstalledRelease(
    version: "1.0.0", build: "4", channel: harnessEnvironment["ZAG_CHANNEL"] ?? "beta",
    installedAt: harnessEnvironment["ZAG_LEGACY"] == "1" ? nil : Date().addingTimeInterval(-3600),
    whatsNew: harnessEnvironment["ZAG_LEGACY"] == "1" ? nil
        : ZagUpdateReleaseNotes.whatsNew(from: harnessEnvironment["ZAG_NOTES"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) })
)

private struct HarnessRoot: View {
    @State private var details = harnessEnvironment["ZAG_SCREEN"] == "details"
    @State private var layout = ZagUpToDateLayout()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { EmptyView() } label: {
                        HStack { Text("Automatic Updates"); Spacer(); Text("On").foregroundStyle(.secondary) }
                    }
                    NavigationLink { EmptyView() } label: {
                        HStack { Text("Release Channel"); Spacer(); Text("Beta").foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Section {
                    ZagSoftwareUpToDateView(release: release) { details = true }
                        .zagUpToDateRow(layout)
                }
            }
            .listSectionSpacing(.custom(16))
            .zagUpToDateForm($layout)
            .navigationDestination(isPresented: $details) { ZagInstalledVersionView(release: release) }
            .navigationTitle("Zag Store Update")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
