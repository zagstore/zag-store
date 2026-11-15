import SwiftUI
import NimbleViews

/// Uses the existing certificate/account sheet header and shared glass buttons.
struct ZagLocalPairingConfirmationPopup: View {
    let confirm: () -> Void
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NBNavigationView("Forget Local Pairing?", displayMode: .inline) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Removes local pairing credentials. To fully unpair, also remove Zag Store in iOS Settings.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System pairing")
                            .font(.caption.weight(.semibold))
                        Text(ZagLocalPairingRemoval.systemRemovalInstructions)
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        // The shared sheet label has a fixed 50-point height.
                        // Native growing pills keep large accessibility text intact.
                        Button(role: .destructive, action: confirm) {
                            Text("Forget Local Pairing").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.red)
                        Button(action: cancel) {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.primary)
                    } else {
                        Button(role: .destructive, action: confirm) {
                            NBSheetButton(title: "Forget Local Pairing", style: .prominent)
                                .accentColor(.red)
                        }
                        .buttonStyle(.plain)
                        Button(action: cancel) {
                            NBSheetButton(title: "Cancel")
                                .accentColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: cancel) { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationCornerRadius(28)
        .presentationBackground(.ultraThinMaterial)
    }
}
