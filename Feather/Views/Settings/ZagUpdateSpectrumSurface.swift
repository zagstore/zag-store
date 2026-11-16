import SwiftUI

/// The original cyan/blue/violet/pink palette and five-second angular rim,
/// rendered in one small Canvas. Only this subtree ticks; network publications
/// and the surrounding card do not drive decorative motion.
struct ZagUpdateSpectrumSurface: View, Animatable {
    var morph: Double
    var progress: Double
    let theme: Color
    let moving: Bool
    /// The successful handoff: the returning capsule becomes the website's
    /// signing-success green. Its wave rides `morph`, so it settles exactly
    /// when the geometry does and needs no clock of its own.
    var success = false

    // Cached Gradient values: no gradient-stop allocation on each display tick.
    private static let spectrum = Gradient(colors: ZagSelfUpdateSpectrum.colors)
    private static let flowingSpectrum = Gradient(colors:
        Array(ZagSelfUpdateSpectrum.colors.dropLast()) + ZagSelfUpdateSpectrum.colors)
    private static let gloss = Gradient(colors: [.white.opacity(0.12), .white.opacity(0.02), .clear])
    private static let halo = Gradient(colors: [.cyan.opacity(0.12), .purple.opacity(0.10), .pink.opacity(0.12)])
    private static let success = Gradient(stops: ZagUpdateSuccessPalette.stops.map {
        .init(color: Color(.sRGB, red: Double($0.red) / 255, green: Double($0.green) / 255,
                           blue: Double($0.blue) / 255), location: $0.location)
    })
    private static let crest = Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                .init(color: .white.opacity(0.24), location: 0.52),
                                                .init(color: .white.opacity(0), location: 1)])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visualProgress: ZagUpdateVisualProgress
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    init(morph: Double, progress: Double, theme: Color, moving: Bool, success: Bool = false) {
        self.morph = morph; self.progress = progress; self.theme = theme; self.moving = moving; self.success = success
        _visualProgress = State(initialValue: ZagUpdateVisualProgress(progress, at: Date.timeIntervalSinceReferenceDate))
    }

    // Geometry has precisely one animation channel. Measured progress is not
    // animatableData and can never retarget the in-flight capsule morph.
    var animatableData: Double {
        get { morph }
        set { morph = newValue }
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
                drawExtended(in: &context, canvasSize: size,
                             phase: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5,
                             displayedProgress: (reduceMotion || lowPower) ? progress : visualProgress.value(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
        // The Canvas reaches past the control's layout frame so the strokes
        // centred on the capsule's edge are not cut off; layout is unchanged.
        .padding(-Self.drawingOutset)
        .onChange(of: progress) { value in
            visualProgress.update(value, at: Date.timeIntervalSinceReferenceDate,
                                  immediate: reduceMotion || lowPower)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityHidden(true)
    }

    /// The halo (5 pt) and rim (1.5 pt) are stroked centred on the capsule's
    /// edge, so half of each lies outside the layout frame. A Canvas draws only
    /// inside its own bounds, which cut both rounded ends of the bar flat.
    static let drawingOutset = 4.0

    /// Draws into a Canvas that extends `drawingOutset` beyond the layout frame
    /// on every side; the shape keeps the layout frame's exact geometry.
    func drawExtended(in context: inout GraphicsContext, canvasSize: CGSize, phase: Double, displayedProgress: Double? = nil) {
        let outset = Self.drawingOutset
        context.translateBy(x: outset, y: outset)
        draw(in: &context, size: CGSize(width: canvasSize.width - 2 * outset, height: canvasSize.height - 2 * outset),
             phase: phase, displayedProgress: displayedProgress)
    }

    /// `morph` is interpolated, not used to exchange two shapes. The same path
    /// compresses from the button's full height to 14 pt about its vertical centre.
    func draw(in context: inout GraphicsContext, size: CGSize, phase: Double, displayedProgress: Double? = nil) {
        let amount = min(1, max(0, morph))
        let height = ZagUpdateControlGeometry.height(slotHeight: size.height, morph: amount)
        let rect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        let path = Path(roundedRect: rect, cornerRadius: height / 2)
        let fillFraction = ZagUpdateControlGeometry.filledFraction(progress: displayedProgress ?? progress, morph: amount)
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fillFraction, height: rect.height)
        let fill = Path(roundedRect: fillRect, cornerRadius: height / 2)

        if success {
            drawSuccess(in: &context, path: path, rect: rect, fill: fill, size: size, amount: amount, phase: phase)
            return
        }
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

    /// The spectrum stays fully opaque beneath while the website's green
    /// arrives over it as one feathered front with a passing crest of light,
    /// never as a muddy blend of the two. At rest the capsule is pure green.
    private func drawSuccess(in context: inout GraphicsContext, path: Path, rect: CGRect, fill: Path,
                             size: CGSize, amount: Double, phase: Double) {
        let wave = 1 - amount
        if wave < 1 {
            context.fill(fill, with: .linearGradient(Self.flowingSpectrum,
                         startPoint: CGPoint(x: rect.width * (phase - 1), y: rect.midY),
                         endPoint: CGPoint(x: rect.width * (phase + 1), y: rect.midY)))
        }
        let layerWidth = rect.width + ZagUpdateSuccessWave.overhang
        let layer = CGRect(x: ZagUpdateSuccessWave.layerMinX(width: rect.width, amount: wave),
                           y: rect.minY, width: layerWidth, height: rect.height)
        context.drawLayer { green in
            green.clip(to: path)
            let line = ZagUpdateSuccessPalette.gradientLine(in: layer)
            green.fill(Path(layer), with: .linearGradient(Self.success, startPoint: line.start, endPoint: line.end))
            green.blendMode = .destinationIn
            green.fill(Path(layer), with: .linearGradient(Gradient(stops: [
                .init(color: .black, location: (layerWidth - ZagUpdateSuccessWave.featherStart) / layerWidth),
                .init(color: .clear, location: (layerWidth - ZagUpdateSuccessWave.featherEnd) / layerWidth)]),
                startPoint: CGPoint(x: layer.minX, y: 0), endPoint: CGPoint(x: layer.maxX, y: 0)))
        }
        let crestOpacity = ZagUpdateSuccessWave.crestOpacity(wave)
        if crestOpacity > 0 {
            var crest = context
            crest.clip(to: path)
            crest.opacity = crestOpacity
            let band = CGRect(x: layer.maxX - ZagUpdateSuccessWave.crestWidth, y: rect.minY,
                              width: ZagUpdateSuccessWave.crestWidth, height: rect.height)
            crest.fill(Path(band), with: .linearGradient(Self.crest, startPoint: CGPoint(x: band.minX, y: 0),
                                                          endPoint: CGPoint(x: band.maxX, y: 0)))
        }
        // The website's resting sheen, then the receding rim of the progress bar.
        context.fill(path, with: .linearGradient(Self.gloss,
                     startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        guard amount > 0 else { return }
        var light = context
        light.opacity = amount
        light.stroke(path, with: .linearGradient(Self.halo, startPoint: .zero,
                     endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 5)
        light.stroke(path, with: .conicGradient(Self.spectrum,
                     center: CGPoint(x: rect.midX, y: rect.midY), angle: .degrees(phase * 360)), lineWidth: 1.5)
    }
}
