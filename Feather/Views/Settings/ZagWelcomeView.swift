import SwiftUI

struct ZagWelcomeView: View {
    @ObservedObject var launch: ZagPairingLaunchCoordinator
    @AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to Zag Store")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Pair your iPhone to unlock direct app installation.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        feature("Quick setup", icon: "link", detail: "Connect securely using RPPairing.")
                        feature("Private & secure", icon: "checkmark.shield", detail: "Your pairing credentials stay on your device.")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if launch.policy.status == .checking {
                                ProgressView().accessibilityHidden(true)
                            }
                            Text(pairingStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if launch.policy.status != .checking {
                            Button("Retry Pairing Check") { launch.retry() }
                                .frame(minHeight: 44)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    primaryAction
                        .disabled(launch.policy.status == .checking)
                    Button { launch.skip() } label: {
                        Text("Continue Without Pairing")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Open Zag Store. Pairing remains available in Settings.")
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.regularMaterial)
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
        case .checking: return "Checking pairing…"
        case .missing: return "No pairing detected"
        case .invalid: return "Pairing needs attention"
        case .failed: return "Pairing verification failed"
        case .timedOut: return "Pairing check timed out"
        case .unknown: return "Pairing status unknown"
        case .verified: return "Pairing verified"
        case .skipped: return "Pairing skipped for this session"
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

}
