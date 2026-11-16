import SwiftUI

/// A persistent button/surface in a stable slot. Its visible capsule compresses
/// into the original spectrum track and expands for every actionable outcome.
struct ZagSelfUpdateActionControl: View {
    let state: ZagSelfUpdateActionState
    var disabled = false
    let action: () -> Void
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionFontSize = 19.0

    private var theme: Color { ZagWideGamutTint.color(hex: themeColorHex) }
    private var morphAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.42) }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                // A single stationary label. Busy-phase messages belong below
                // the bar; they never resize or slide the button's text baseline.
                Text(state.showsProgress ? "Update Now" : state.title)
                    .font(.system(size: actionFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .opacity(state.showsProgress ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state.showsProgress)
                    .background {
                        ZagUpdateSpectrumSurface(morph: state.showsProgress ? 1 : 0,
                                                 progress: state.fraction ?? 1,
                                                 theme: theme, moving: state.showsProgress)
                            .animation(morphAnimation, value: state.showsProgress)
                            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: state.fraction)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state.showsProgress || (disabled && !state.offersGuidance))
            .accessibilityLabel(state.title)
            .accessibilityValue(state.fraction.map { "\(Int($0 * 100)) percent" } ?? "")
            .accessibilityHint(state.offersGuidance ? "Shows manual installation and reopening instructions. Does not restart automatically." : "")

            // Reserve the same status area in idle, busy and terminal states.
            // Dynamic Type can grow it, without changing the capsule's centre.
            ZStack(alignment: .top) {
                Text("Update handed off to iOS. Reopen Zag Store after installation.")
                    .hidden().accessibilityHidden(true)
                Text(state.status ?? " ")
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transaction { $0.animation = nil }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.status ?? "")
            .accessibilityHidden(state.status == nil)
        }
    }
}
