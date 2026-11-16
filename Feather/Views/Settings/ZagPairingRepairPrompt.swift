import SwiftUI

/// Shown in the main interface when a live check rejects the saved pairing
/// (unreadable record, or the iPhone no longer accepts it). Never shown for an
/// unreachable device, and never removes credentials: Repair opens the
/// existing pairing setup.
private struct ZagPairingRepairPrompt: ViewModifier {
    @ObservedObject private var pairing = ZagRPPairingLaunchService.shared
    @State private var showsWarning = false
    @State private var showsRepair = false

    func body(content: Content) -> some View {
        content
            .onReceive(pairing.$currentVerification.removeDuplicates()) { verification in
                if verification == .invalid { showsWarning = true }
            }
            .alert("Pairing Needs Repair", isPresented: $showsWarning) {
                Button("Repair Pairing") { showsRepair = true }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("This iPhone did not accept Zag Store's saved pairing. You can keep browsing; pair again to install apps directly. Nothing has been removed.")
            }
            .sheet(isPresented: $showsRepair) {
                NavigationStack {
                    InstallationView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showsRepair = false }
                            }
                        }
                }
            }
    }
}

extension View {
    func zagPairingRepairPrompt() -> some View {
        modifier(ZagPairingRepairPrompt())
    }
}
