import SwiftUI

// Minimal, isolated iOS app for the Xcode Personal Team provisioning experiment.
// It exists only to make Xcode issue a free-account development certificate and
// provisioning profile for a unique experimental bundle ID. It is not part of
// Zag Store and shares no bundle ID, certificate or configuration with it.
@main
struct PTTeamProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
            Text("PT Team Probe")
                .font(.title2).bold()
            Text("Free-account provisioning experiment")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
