import SwiftUI

/// A persistent button/surface in a stable slot. Its visible capsule compresses
/// into the original spectrum track and expands for every terminal outcome.
/// The status line below changes only after the capsule's geometry arrives.
struct ZagSelfUpdateActionControl: View {
    let state: ZagSelfUpdateActionState
    var disabled = false
    let action: () -> Void
    /// `Restart to Complete...`. Offered only by the successful handoff.
    var complete: (() -> Void)?
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionFontSize = 19.0

    /// The latest requested line and shape. Deferred work reads these, never
    /// `state`, which an `onChange` action or delayed block can see stale.
    @State private var targetLine: ZagUpdateStatusLine?
    @State private var targetProgress = false
    /// The line currently laid out; it trails `targetLine` through the choreography.
    @State private var shownLine: ZagUpdateStatusLine?
    @State private var lineVisible = false
    /// The `showsProgress` value whose geometry has arrived.
    @State private var settledMorph: Bool
    @State private var fadingOut = false
    @State private var awaitingReveal = false
    @State private var generation = 0
    @State private var completionRequested = false

    init(state: ZagSelfUpdateActionState, disabled: Bool = false,
         complete: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.state = state
        self.disabled = disabled
        self.complete = complete
        self.action = action
        // The first frame already shows the current line, with no layout jump.
        _targetLine = State(initialValue: state.statusLine)
        _targetProgress = State(initialValue: state.showsProgress)
        _shownLine = State(initialValue: state.statusLine)
        _lineVisible = State(initialValue: state.statusLine != nil)
        _settledMorph = State(initialValue: state.showsProgress)
    }

    private var theme: Color { ZagWideGamutTint.color(hex: themeColorHex) }
    private var morphAnimation: Animation? { reduceMotion ? nil : .timingCurve(ZagUpdateMorphSpecification.x1, ZagUpdateMorphSpecification.y1,
                                                    ZagUpdateMorphSpecification.x2, ZagUpdateMorphSpecification.y2,
                                                    duration: ZagUpdateMorphSpecification.duration) }
    private var startsUpdate: Bool { state.isActionable && !disabled }
    /// The success capsule acts once its presentation has settled: geometry
    /// arrived and the success line shown. Same view, no visual change.
    private var completes: Bool {
        state.showsSuccess && complete != nil && settledMorph == state.showsProgress && lineVisible && !completionRequested
    }
    private var actionable: Bool { startsUpdate || completes }
    private var ink: Color {
        let ink = ZagUpdateSuccessPalette.labelInk
        return Color(.sRGB, red: Double(ink.red) / 255, green: Double(ink.green) / 255, blue: Double(ink.blue) / 255)
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                // Guard repeated/busy activation without applying a disabled
                // appearance filter to the luminous Canvas.
                if completes {
                    completionRequested = true
                    complete?()
                } else if startsUpdate {
                    action()
                }
            } label: {
                // A single stationary label. Busy-phase messages belong below
                // the bar; they never resize or slide the button's text baseline.
                Text(state.showsProgress ? "Update Now" : state.title)
                    .font(.system(size: actionFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    // The website's label ink on its success green.
                    .shadow(color: ink.opacity(state.showsSuccess ? 0.28 : 0), radius: 0.5, y: 1)
                    .shadow(color: ink.opacity(state.showsSuccess ? 0.16 : 0), radius: 8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .opacity(state.showsProgress ? 0 : 1)
                    // Reports when the capsule geometry has arrived, under the
                    // very same transaction and curve as the Canvas morph.
                    .modifier(ZagAnimationArrival(value: state.showsProgress ? 1 : 0) { morphArrived($0 == 1) })
                    .animation(morphAnimation, value: state.showsProgress)
                    .background {
                        ZagUpdateSpectrumSurface(morph: state.showsProgress ? 1 : 0,
                                                 progress: state.fraction ?? 1,
                                                 theme: theme, moving: state.showsProgress,
                                                 success: state.showsSuccess)
                            .animation(morphAnimation, value: state.showsProgress)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(actionable)
            .accessibilityRemoveTraits(state.isActionable || state.showsSuccess && complete != nil ? [] : .isButton)
            .accessibilityAddTraits(state.showsProgress ? .updatesFrequently
                                    : (state.isActionable || state.showsSuccess && complete != nil ? .isButton : .isStaticText))
            .accessibilityLabel(state.title)
            .accessibilityValue(state.fraction.map { "\(ZagUpdateProgressFormatting.percent($0)) percent" } ?? "")

            if let shownLine {
                ZagUpdateStatusText(line: shownLine)
                    // A new stage is a new text: digits roll only within a stage,
                    // never as a content transition from the previous message.
                    .id(shownLine.message)
                    .opacity(lineVisible ? 1 : 0)
                    .modifier(ZagAnimationArrival(value: lineVisible ? 1 : 0) { if $0 == 0 { fadeOutArrived() } })
                    .accessibilityHidden(!lineVisible)
            }
        }
        // One handler for both inputs, using the new values it is given.
        .onChange(of: ZagStatusTarget(line: state.statusLine, showsProgress: state.showsProgress)) { target in
            targetChanged(to: target)
        }
    }

    // MARK: Choreography

    private func targetChanged(to target: ZagStatusTarget) {
        let morphing = target.showsProgress != targetProgress
        targetLine = target.line
        targetProgress = target.showsProgress
        if !morphing, let line = target.line, line.isSameStage(as: shownLine), !fadingOut {
            // Same stage: only the measured percentage changes. Its digits roll
            // through their own implicit animation; no crossfade, no new reveal.
            shownLine = line
            return
        }
        // A new stage, or a morph starting: whatever is shown belongs to the old shape.
        beginStageChange()
        // Reduce Motion: the geometry changes in this update; nothing animates to observe.
        if morphing && morphAnimation == nil { morphArrived(target.showsProgress) }
    }

    /// Fade the old line out (if any), swap it while invisible, then reveal the
    /// new one once the geometry has settled.
    private func beginStageChange() {
        generation += 1
        awaitingReveal = true
        if shownLine != nil && lineVisible {
            fadingOut = true
            withAnimation(.easeIn(duration: ZagUpdateStatusTiming.fadeOut)) { lineVisible = false }
        } else if !fadingOut {
            swapLine()
        }
    }

    private func fadeOutArrived() {
        guard fadingOut, !lineVisible else { return }
        fadingOut = false
        swapLine()
    }

    private func swapLine() {
        // Lay out the incoming line while invisible. A line that is going away
        // keeps its (invisible) space until the geometry settles, so the card
        // never changes height mid-morph.
        noAnimation {
            if targetLine != nil || settledMorph == targetProgress { shownLine = targetLine }
            lineVisible = false
        }
        revealIfReady(pause: 0)
    }

    private func morphArrived(_ showsProgress: Bool) {
        guard showsProgress == targetProgress, settledMorph != showsProgress else { return }
        settledMorph = showsProgress
        revealIfReady(pause: ZagUpdateStatusTiming.pauseAfterMorph)
    }

    private func revealIfReady(pause: Double) {
        guard awaitingReveal, !fadingOut, settledMorph == targetProgress else { return }
        guard targetLine != nil else {
            // The outgoing line's space is released only now, after the geometry.
            noAnimation { shownLine = nil }
            awaitingReveal = false
            return
        }
        let expected = generation
        // Reads only @State storage, which stays current inside the deferred block.
        let reveal = {
            guard expected == generation, awaitingReveal, !fadingOut, shownLine != nil else { return }
            awaitingReveal = false
            // Percentages that arrived while hidden are shown without rolling.
            noAnimation { shownLine = targetLine }
            withAnimation(.easeOut(duration: ZagUpdateStatusTiming.fadeIn)) { lineVisible = true }
        }
        if pause > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: reveal)
        } else {
            reveal()
        }
    }

    /// Unanimated changes to the status line only. Not `disablesAnimations`:
    /// these run in the same update as the morph and must not suppress it.
    private func noAnimation(_ body: () -> Void) {
        withTransaction(Transaction(), body)
    }
}

private struct ZagStatusTarget: Equatable {
    let line: ZagUpdateStatusLine?
    let showsProgress: Bool
}

/// The status line: approved footnote typography, and a percentage that rolls
/// with the same native digit transition as the Sources app count.
private struct ZagUpdateStatusText: View {
    let line: ZagUpdateStatusLine

    var body: some View {
        // One concatenated Text, so wrapping matches a plain line; only the
        // changed digits roll because the message characters never change.
        (Text(line.message) + Text(line.percent.map { " \($0)%" } ?? "").monospacedDigit())
            .modifier(ZagNumericTextTransition(value: line.percent ?? 0))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Calls back when an animated value arrives at its target. SwiftUI sets
/// `animatableData` for every interpolated frame of a running animation and
/// finally to the exact target. Unanimated changes are not observed here, so
/// callers report those themselves. Callers must be idempotent.
struct ZagAnimationArrival: ViewModifier, Animatable {
    var animatableData: Double {
        didSet {
            guard animatableData == target else { return }
            let target = target, onArrival = onArrival
            DispatchQueue.main.async { onArrival(target) }
        }
    }
    private let target: Double
    private let onArrival: (Double) -> Void

    init(value: Double, onArrival: @escaping (Double) -> Void) {
        animatableData = value
        target = value
        self.onArrival = onArrival
    }

    func body(content: Content) -> some View { content }
}
