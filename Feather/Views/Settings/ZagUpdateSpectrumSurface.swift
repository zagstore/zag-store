import SwiftUI

/// The original cyan/blue/violet/pink palette and five-second angular rim,
/// rendered in one small Canvas. Only this subtree ticks; network publications
/// and the surrounding card do not drive decorative motion.
struct ZagUpdateSpectrumSurface: View, Animatable {
    var morph: Double
    var progress: Double
    let theme: Color
    let moving: Bool

    // Cached Gradient values: no gradient-stop allocation on each display tick.
    private static let spectrum = Gradient(colors: ZagSelfUpdateSpectrum.colors)
    private static let flowingSpectrum = Gradient(colors:
        Array(ZagSelfUpdateSpectrum.colors.dropLast()) + ZagSelfUpdateSpectrum.colors)
    private static let gloss = Gradient(colors: [.white.opacity(0.12), .white.opacity(0.02), .clear])
    private static let halo = Gradient(colors: [.cyan.opacity(0.12), .purple.opacity(0.10), .pink.opacity(0.12)])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var animatableData: AnimatablePair<Double, Double> {
        get { .init(morph, progress) }
        set { morph = newValue.first; progress = newValue.second }
    }

    private var animates: Bool {
        ZagUpdateDecorationPolicy.animates(progress: moving, active: scenePhase == .active,
                                           reduceMotion: reduceMotion, lowPower: lowPower)
    }

    var body: some View {
        // No fixed 60 Hz cap: the system chooses display cadence, including
        // ProMotion. Power-saving, inactive and Reduce Motion states pause it.
        TimelineView(.animation(paused: !animates)) { timeline in
            // This tiny vector track presents with the current display frame;
            // it needs no additional asynchronous presentation queue.
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size,
                     phase: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityHidden(true)
    }

    /// `morph` is interpolated, not used to exchange two shapes. The same path
    /// compresses from the button's full height to 14 pt about its vertical centre.
    func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let amount = min(1, max(0, morph))
        let height = ZagUpdateControlGeometry.height(slotHeight: size.height, morph: amount)
        let rect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        let path = Path(roundedRect: rect, cornerRadius: height / 2)
        let fillFraction = ZagUpdateControlGeometry.filledFraction(progress: progress, morph: amount)
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fillFraction, height: rect.height)
        let fill = Path(roundedRect: fillRect, cornerRadius: height / 2)

        // The blue body remains visible throughout compression. Only its fill
        // transforms; there is no view opacity swap or second progress control.
        if amount < 1 { context.fill(path, with: .color(theme.opacity(1 - amount))) }
        context.fill(path, with: .color(.primary.opacity(0.10 * amount)))
        // The filled region always has an opaque backing, including intermediate
        // morph frames. Only its colour blends, never its overall alpha.
        if amount < 1 { context.fill(fill, with: .color(theme)) }
        // At full progress morphology the spectrum itself is opaque, so avoid
        // repainting an invisible blue backing on every decorative frame.
        guard amount > 0 else { return }

        // Cheap, bounded halo strokes replace per-frame blur/shadow filters.
        var light = context
        light.opacity = amount
        light.stroke(path, with: .linearGradient(Self.halo, startPoint: .zero,
                     endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 5)

        // Repeat the same spectrum twice so the five-second flow has no seam.
        // Increasing phase moves the spectrum's coordinate system to the right.
        // A two-cycle strip covers the track at both ends of the seamless wrap.
        let start = CGPoint(x: rect.width * (phase - 1), y: rect.midY)
        let end = CGPoint(x: rect.width * (phase + 1), y: rect.midY)
        light.fill(fill, with: .linearGradient(Self.flowingSpectrum, startPoint: start, endPoint: end))
        light.fill(fill, with: .linearGradient(Self.gloss,
                   startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        light.stroke(path, with: .conicGradient(Self.spectrum,
                     center: CGPoint(x: rect.midX, y: rect.midY), angle: .degrees(phase * 360)), lineWidth: 1.5)
    }
}
