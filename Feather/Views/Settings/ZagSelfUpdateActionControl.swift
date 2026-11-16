import SwiftUI

/// One button, label and capsule throughout the operation. The native progress
/// meter interpolates only between measured fractions, never predicted progress.
struct ZagSelfUpdateActionControl: View {
    let state: ZagSelfUpdateActionState
    var disabled = false
    let action: () -> Void
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionFontSize = 19.0

    private var theme: Color { ZagWideGamutTint.color(hex: themeColorHex) }
    private var morphAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.24) }

    var body: some View {
        Button(action: action) {
            Text(state.title)
                .font(state.showsProgress ? .footnote : .system(size: actionFontSize, weight: .semibold))
                .foregroundStyle(state.showsProgress ? Color.primary : Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, state.showsProgress ? 20 : 12)
                .frame(maxWidth: .infinity, minHeight: 54)
                .transaction { $0.animation = nil }
                .background {
                    ZStack {
                        Capsule().fill(theme)
                            .opacity(state.showsProgress ? 0 : 1)
                        Capsule().fill(.thinMaterial)
                            .opacity(state.showsProgress ? 1 : 0)
                    }
                    .animation(morphAnimation, value: state.showsProgress)
                }
                .overlay(alignment: .bottom) {
                    ProgressView(value: state.showsProgress ? state.fraction : 0)
                        .progressViewStyle(.linear)
                        .tint(theme)
                        .frame(height: 4)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                        .opacity(state.showsProgress ? 1 : 0)
                        .animation(morphAnimation, value: state.showsProgress)
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: state.fraction)
                        .accessibilityHidden(true)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled || state.showsProgress)
        .accessibilityLabel(state.title)
        .accessibilityValue(state.fraction.map { "\(Int($0 * 100)) percent" } ?? (state.showsProgress ? "In progress" : ""))
        .accessibilityHint(state == .confirmed ? "Shows instructions for closing and reopening Zag Store. Does not restart automatically." : "")
    }
}
