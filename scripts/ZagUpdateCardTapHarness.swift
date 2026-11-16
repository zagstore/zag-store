import SwiftUI

/// The release card's interactive row as the update screen builds it: a Form
/// section row holding the production update control and the production Learn
/// More link. Link activations are captured through `openURL`, so nothing leaves
/// the app; every action is recorded in an on-screen event log.
///
/// `ZAG_CARD_TERMINATE=1` wires the capsule to the production completion path
/// (`ZagUpdateCompletion.complete`, which calls `exit(0)`), after writing a
/// preferences marker that the relaunched app shows, to prove it survived.
@main
struct ZagUpdateCardTapHarness: App {
    init() {
        if ProcessInfo.processInfo.environment["ZAG_CARD_CLEAR_MARKER"] == "1" {
            UserDefaults.standard.removeObject(forKey: ZagUpdateCardTapHost.markerKey)
        }
    }
    var body: some Scene {
        WindowGroup { ZagUpdateCardTapHost() }
    }
}

struct ZagUpdateCardTapHost: View {
    @State private var events: [String] = []
    private let environment = ProcessInfo.processInfo.environment
    static let markerKey = "ZagUpdateCardTapHarness.marker"
    private let state: ZagSelfUpdateActionState = {
        switch ProcessInfo.processInfo.environment["ZAG_CARD_STATE"] {
        case "idle": return .idle
        case "progress": return .progress(message: "Transferring signed IPA...", fraction: 0.42)
        default: return .handedOff
        }
    }()

    private func complete() {
        guard environment["ZAG_CARD_TERMINATE"] == "1" else { events.append("complete"); return }
        // Written immediately before the exit, the latest a real write could be.
        UserDefaults.standard.set("written before exit", forKey: Self.markerKey)
        ZagUpdateCompletion.complete(actionState: state, handoff: .acceptedByInstaller, pendingRecorded: true)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Zag Store 1.0.0").font(.headline)
                    Divider()
                    ZagSelfUpdateActionControl(state: state, complete: complete) { events.append("update") }
                    ZagSelfUpdateLearnMoreLink(tint: .blue)
                }
            }
            Section {
                Text(events.isEmpty ? "none" : events.joined(separator: ","))
                    .accessibilityIdentifier("events")
                Text(UserDefaults.standard.string(forKey: Self.markerKey) ?? "no marker")
                    .accessibilityIdentifier("marker")
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
