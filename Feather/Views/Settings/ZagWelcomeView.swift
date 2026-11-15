import SwiftUI

struct ZagWelcomeView: View {
    let finish: () -> Void
    @ObservedObject private var pairing = ZagRPPairingCore.shared
    @AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                        .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Welcome to Zag Store")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Your apps. Your iPhone. Ready when you are.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        feature("Make this iPhone yours", icon: "link", detail: "RPPairing securely connects Zag Store to this iPhone so you can install and manage signed apps directly on your device.")
                        feature("Set up once", icon: "checkmark.shield", detail: "Your pairing credentials stay on this device and can be reused. The setup page guides you through pairing and the local VPN connection needed for installation.")
                        feature("Explore at your pace", icon: "safari", detail: "Browse sources and discover apps now. You can always set up pairing later in Settings → Installation.")
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))

                    VStack(spacing: 12) {
                        primaryAction
                        Button("Continue Without Pairing", action: finish)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.secondary)
                            .accessibilityHint("Open Zag Store. Pairing remains available in Settings.")
                    }
                }
                .frame(maxWidth: 560)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationDestination(isPresented: $showPairing) {
                InstallationView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Continue", action: finish)
                                .accessibilityHint("Open Zag Store. You can return to pairing in Settings.")
                        }
                    }
            }
        }
        .tint(ZagWideGamutTint.color(hex: tintHex))
        .onAppear {
            // The existing manager treats its saved record as persisted pairing.
            // Native setup writes it only after success, before emitting .paired.
            // This also covers termination between saving and dismissing welcome.
            if pairing.pairingFileExists { finish() }
        }
        .onReceive(pairing.$state) { state in finishIfPaired(state) }
    }

    @ViewBuilder private var primaryAction: some View {
        if #available(iOS 26, *) {
            Button { showPairing = true } label: {
                Text("Set Up Pairing").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.glassProminent)
        } else {
            Button { showPairing = true } label: {
                Text("Set Up Pairing").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.borderedProminent)
        }
    }

    private func feature(_ title: LocalizedStringKey, icon: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func finishIfPaired(_ state: ZagRPPairingCore.State) {
        // Opening setup, a saved file, a PIN or a failed attempt is not success.
        if case .paired = state, pairing.pairingFileExists { finish() }
    }
}
