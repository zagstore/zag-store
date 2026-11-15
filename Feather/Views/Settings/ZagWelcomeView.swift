import SwiftUI

struct ZagWelcomeView: View {
    @ObservedObject var launch: ZagPairingLaunchCoordinator
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
                        Text("Pair your iPhone to install apps directly.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        feature("Quick setup", icon: "link", detail: "Connect securely with RPPairing.")
                        feature("Private & secure", icon: "checkmark.shield", detail: "Your pairing stays on this iPhone.")
                        feature("Explore at your pace", icon: "safari", detail: "Or continue now and pair later.")
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))

                    VStack(spacing: 12) {
                        Text(pairingStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if launch.policy.status == .checking {
                            ProgressView("Checking pairing…")
                        } else {
                            Button("Retry Pairing Check") { launch.retry() }
                                .frame(minHeight: 44)
                        }
                        primaryAction
                            .disabled(launch.policy.status == .checking)
                        Button("Continue Without Pairing") { launch.skip() }
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
                            Button("Continue Without Pairing") { launch.skip() }
                                .accessibilityHint("Open Zag Store. You can return to pairing in Settings.")
                        }
                    }
            }
        }
        .tint(ZagWideGamutTint.color(hex: tintHex))
    }

    private var pairingStatus: String {
        switch launch.policy.status {
        case .checking: return "Checking whether pairing is ready on this iPhone. You can continue while setup is unavailable."
        case .missing: return "No pairing record is saved. Set up pairing to install apps directly on this iPhone."
        case .invalid: return "The saved pairing credentials could not be accepted. Open setup to pair this iPhone again."
        case .failed: return "Pairing could not be verified. Check the local VPN connection and device permissions, then retry."
        case .timedOut: return "The pairing check timed out. Your pairing status is unknown. Check the connection and retry, or continue for now."
        case .unknown: return "Pairing status is unknown. Retry the check, open setup, or continue for now."
        case .verified: return "Pairing verified."
        case .skipped: return "You can set up pairing later in Settings → Installation."
        }
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

}
