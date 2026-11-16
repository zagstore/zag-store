import SwiftUI

/// A persistent button/surface in a stable slot. Its visible capsule compresses
/// into the original spectrum track and expands for every actionable outcome.
struct ZagSelfUpdateActionControl: View {
    let state: ZagSelfUpdateActionState
    var disabled = false
    let action: () -> Void
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsReopenInstructions = false
    @AccessibilityFocusState private var instructionsFocused: Bool
    @ScaledMetric(relativeTo: .headline) private var actionFontSize = 19.0

    private var theme: Color { ZagWideGamutTint.color(hex: themeColorHex) }
    private var morphAnimation: Animation? { reduceMotion ? nil : .timingCurve(ZagUpdateMorphSpecification.x1, ZagUpdateMorphSpecification.y1,
                                                    ZagUpdateMorphSpecification.x2, ZagUpdateMorphSpecification.y2,
                                                    duration: ZagUpdateMorphSpecification.duration) }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                // Guard repeated/busy activation without applying a disabled
                // appearance filter to the luminous Canvas.
                guard !state.showsProgress, !disabled || state.offersGuidance else { return }
                if state.offersGuidance {
                    showsReopenInstructions = true
                } else {
                    action()
                }
            } label: {
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
                    .animation(morphAnimation, value: state.showsProgress)
                    .background {
                        ZagUpdateSpectrumSurface(morph: state.showsProgress ? 1 : 0,
                                                 progress: state.fraction ?? 1,
                                                 theme: theme, moving: state.showsProgress)
                            .animation(morphAnimation, value: state.showsProgress)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!state.showsProgress && (!disabled || state.offersGuidance))
            .accessibilityRemoveTraits(state.showsProgress ? .isButton : [])
            .accessibilityAddTraits(state.showsProgress ? .updatesFrequently : .isButton)
            .accessibilityLabel(state.title)
            .accessibilityValue(state.fraction.map { "\(ZagUpdateProgressFormatting.percent($0)) percent" } ?? "")
            .accessibilityHint(state.offersGuidance ? "Shows short manual steps below. Cannot close or restart the app." : "")

            if let status = state.status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .transaction { $0.animation = nil }
            }
            if showsReopenInstructions && state.offersGuidance {
                Text(state.reopenInstruction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($instructionsFocused)
                    .onAppear { instructionsFocused = true }
            }
        }
        .onChange(of: state.offersGuidance) { offersGuidance in
            if !offersGuidance { showsReopenInstructions = false }
        }
    }
}
