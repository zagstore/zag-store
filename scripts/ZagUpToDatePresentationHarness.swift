import SwiftUI

// First-presentation and navigation regression for Software Update's
// up-to-date state. Mirrors the app's path: a large sheet holding a
// NavigationStack, into which Software Update (a refreshable Form with the
// Automatic Updates / Release Channel section above the state) is pushed. The
// driver pushes it, opens More Details, goes back, leaves and pushes it again,
// and logs the placement after each step. Run by
// scripts/test-zag-up-to-date-presentation.sh; production views, no device.

private let release = ZagInstalledRelease(version: "1.0.0", build: "4", channel: "nightly",
                                          installedAt: Date(), whatsNew: nil)

/// Where the state is, all in global coordinates.
struct Placement: Equatable {
    var sectionBottom: CGFloat = 0
    var visibleBottom: CGFloat = 0
    var contentMid: CGFloat = 0
    /// iOS Settings: centred between the section and the bottom, 3 pt below.
    var expectedMid: CGFloat { (sectionBottom + visibleBottom) / 2 + ZagUpToDateLayout.belowCentre }
}

@MainActor final class Probe: ObservableObject {
    var placement = Placement()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("presentation.log")
    init() { try? FileManager.default.removeItem(at: url) }

    func log(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func record(_ step: String) {
        let p = placement
        log(String(format: "STEP %@ section=%.2f bottom=%.2f mid=%.2f expected=%.2f",
                   step, p.sectionBottom, p.visibleBottom, p.contentMid, p.expectedMid))
    }

    /// The state must not move once the push has settled: samples every 50 ms.
    func sample(_ step: String, seconds: Double) async {
        var mids: [CGFloat] = []
        for _ in 0..<Int(seconds / 0.05) {
            mids.append(placement.contentMid)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log(String(format: "SAMPLES %@ min=%.2f max=%.2f", step, mids.min() ?? 0, mids.max() ?? 0))
    }
}

private struct SectionBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct VisibleBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ContentMidKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SoftwareUpdatePage: View {
    @ObservedObject var probe: Probe
    @Binding var details: Bool
    @State private var layout = ZagUpToDateLayout()

    var body: some View {
        Form {
            Section {
                NavigationLink { EmptyView() } label: {
                    HStack { Text("Automatic Updates"); Spacer(); Text("On").foregroundStyle(.secondary) }
                }
                NavigationLink { EmptyView() } label: {
                    HStack { Text("Release Channel"); Spacer(); Text("Nightly").foregroundStyle(.secondary) }
                }
                .listRowBackground(GeometryReader { geometry in
                    Color(uiColor: .secondarySystemGroupedBackground)
                        .preference(key: SectionBottomKey.self, value: geometry.frame(in: .global).maxY)
                })
            }
            Section {
                ZagSoftwareUpToDateView(release: release) { details = true }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ContentMidKey.self, value: geometry.frame(in: .global).midY)
                        }
                    }
                    .zagUpToDateRow(layout)
            }
        }
        .listSectionSpacing(.custom(ZagUpToDateLayout.sectionSpacing))
        .refreshable {}
        .zagUpToDateForm($layout)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: VisibleBottomKey.self, value: geometry.frame(in: .global).maxY)
            }
        }
        .onPreferenceChange(SectionBottomKey.self) { probe.placement.sectionBottom = $0 }
        .onPreferenceChange(VisibleBottomKey.self) { probe.placement.visibleBottom = $0 }
        .onPreferenceChange(ContentMidKey.self) { probe.placement.contentMid = $0 }
        .navigationDestination(isPresented: $details) { ZagInstalledVersionView(release: release) }
        .navigationTitle("Software Update")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct Account: View {
    @StateObject private var probe = Probe()
    @State private var path: [Int] = []
    @State private var details = false

    var body: some View {
        NavigationStack(path: $path) {
            List { NavigationLink("Software Update", value: 1) }
                .navigationTitle("Account")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Int.self) { _ in SoftwareUpdatePage(probe: probe, details: $details) }
        }
        .task { await drive() }
    }

    /// The user's taps, each after the previous transition has finished.
    private func drive() async {
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        await wait(1.5)
        path = [1]
        await wait(0.7)
        await probe.sample("first", seconds: 1.5)
        probe.record("first")
        details = true
        await wait(1.5)
        details = false
        await wait(1.5)
        probe.record("back")
        path = []
        await wait(1.5)
        path = [1]
        await wait(0.7)
        await probe.sample("second", seconds: 1.5)
        probe.record("second")
        probe.log("DONE")
    }
}

@main
struct ZagUpToDatePresentationHarness: App {
    @State private var sheet = true
    var body: some Scene {
        WindowGroup {
            TabView { Text("Library").tabItem { Label("Library", systemImage: "square.grid.2x2") } }
                .sheet(isPresented: $sheet) { Account().presentationDetents([.large]) }
        }
    }
}
