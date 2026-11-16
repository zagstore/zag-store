import SwiftUI

/// The release card's interactive row as the update screen builds it: a Form
/// section row holding the production update control and the production Learn
/// More link. Link activations are captured through `openURL`, so nothing leaves
/// the app; every action is recorded in an on-screen event log.
@main
struct ZagUpdateCardTapHarness: App {
    var body: some Scene {
        WindowGroup { ZagUpdateCardTapHost() }
    }
}

struct ZagUpdateCardTapHost: View {
    @State private var events: [String] = []
    private let state: ZagSelfUpdateActionState = {
        switch ProcessInfo.processInfo.environment["ZAG_CARD_STATE"] {
        case "idle": return .idle
        case "progress": return .progress(message: "Transferring signed IPA...", fraction: 0.42)
        default: return .handedOff
        }
    }()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Zag Store 1.0.0").font(.headline)
                    Divider()
                    ZagSelfUpdateActionControl(state: state) { events.append("update") }
                    ZagSelfUpdateLearnMoreLink(tint: .blue)
                }
            }
            Section {
                Text(events.isEmpty ? "none" : events.joined(separator: ","))
                    .accessibilityIdentifier("events")
                Button("Reset") { events = [] }
                    .accessibilityIdentifier("reset")
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            events.append(url == ZagSelfUpdateLearnMoreLink.destination ? "learnMore" : "url")
            return .handled
        })
    }
}
