import AppKit
import SwiftUI

/// Uses the production Canvas drawing function, not a replacement illustration.
/// Deterministic samples verify actual pixels; device frame timing needs Instruments.
@main struct ZagUpdateMorphRenderingTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1; print("PASS: \(label)")
        }
        func render(morph: Double, progress: Double = 0.55, phase: Double = 0.15, transparent: Bool = false,
                    success: Bool = false) -> [UInt8] {
            let surface = ZagUpdateSpectrumSurface(morph: morph, progress: progress, theme: .blue, moving: false, success: success)
            let view = Canvas { context, size in
                surface.draw(in: &context, size: size, phase: phase)
            }.frame(width: 360, height: 54).background(transparent ? Color.clear : Color.black).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = renderer.cgImage!
            var rgba = [UInt8](repeating: 0, count: 360 * 54 * 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 360, height: 54, bitsPerComponent: 8,
                    bytesPerRow: 360 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 360, height: 54))
            }
            return rgba
        }
        func brightness(_ image: [UInt8], x: Int, y: Int) -> Int {
            let i = (y * 360 + x) * 4
            return Int(image[i]) + Int(image[i+1]) + Int(image[i+2])
        }
        var previousHeight = 55
        for amount in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let image = render(morph: amount)
            let lit = (0..<54).filter { brightness(image, x: 180, y: $0) > 80 }
            check(!lit.isEmpty, "morph \(amount) retains a visible body")
            let height = lit.last! - lit.first! + 1
            check(height <= previousHeight, "morph \(amount) compresses continuously")
            previousHeight = height
            check(abs(Double(lit.first! + lit.last!) / 2 - 26.5) <= 1, "morph \(amount) keeps its vertical centre")
            check(brightness(image, x: 2, y: 27) > 30 && brightness(image, x: 357, y: 27) > 30,
                  "morph \(amount) retains the track width")
        }
        let track = render(morph: 1)
        let flow = render(morph: 1, phase: 0.65)
        check(track != flow, "decorative five-second flow changes pixels without changing progress")
        let full = render(morph: 1, progress: 1)
        check(brightness(track, x: 270, y: 27) < brightness(full, x: 270, y: 27),
              "unfilled and filled regions remain visually distinct")
        let i = (27 * 360 + 170) * 4
        check(Int(track[i]) + Int(track[i+2]) > Int(track[i+1]) * 2, "original violet/pink spectrum remains vivid")
        check(render(morph: 0, progress: 0.1) == render(morph: 0, progress: 1),
              "idle/retry capsule is full-width blue independently of old progress")
        for amount in [0.0, 0.5, 1.0] {
            let rgba = render(morph: amount, progress: 1, transparent: true)
            check(rgba[(27 * 360 + 120) * 4 + 3] == 255,
                  "filled region stays fully opaque at morph \(amount) on a transparent canvas")
        }
        let earlier = render(morph: 1, progress: 1, phase: 0.15)
        let later = render(morph: 1, progress: 1, phase: 0.25)
        func colourDistance(_ a: [UInt8], x: Int, _ b: [UInt8], otherX: Int) -> Int {
            (0..<3).reduce(0) { $0 + abs(Int(a[(27 * 360 + x) * 4 + $1]) - Int(b[(27 * 360 + otherX) * 4 + $1])) }
        }
        check(colourDistance(earlier, x: 100, later, otherX: 136) < 12,
              "the same gradient feature travels right as phase increases")
        check(colourDistance(earlier, x: 100, later, otherX: 64) > 20,
              "gradient motion is not a leftward visual reversal")
        let bluePixel = (27 * 360 + 144) * 4
        let components = (0..<3).map { Int(earlier[bluePixel + $0]) }
        check(components.max()! - components.min()! > 200, "subtle gloss preserves strong spectrum saturation")
        var isolatedSurface = ZagUpdateSpectrumSurface(morph: 0.35, progress: 0.1, theme: .blue, moving: true)
        let geometryBeforeProgress = isolatedSurface.animatableData
        isolatedSurface.progress = 0.85
        check(isolatedSurface.animatableData == geometryBeforeProgress, "incoming percentages cannot retarget the Canvas geometry animation channel")
        // Website success green, rendered by the production drawing function.
        func pixel(_ image: [UInt8], x: Int, y: Int = 27) -> [Int] { (0..<3).map { Int(image[(y * 360 + x) * 4 + $0]) } }
        func expectedGreen(x: Double, y: Double, width: Double) -> [Double] {
            let layer = CGRect(x: 0, y: 0, width: width + ZagUpdateSuccessWave.overhang, height: 54)
            let line = ZagUpdateSuccessPalette.gradientLine(in: layer)
            let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
            let t = ((x - line.start.x) * dx + (y - line.start.y) * dy) / (dx * dx + dy * dy)
            let stops = ZagUpdateSuccessPalette.stops
            let upper = stops.firstIndex { $0.location >= t } ?? stops.count - 1
            let a = stops[max(0, upper - 1)], b = stops[upper]
            let f = b.location == a.location ? 0 : (t - a.location) / (b.location - a.location)
            return [Double(a.red) + (Double(b.red) - Double(a.red)) * f, Double(a.green) + (Double(b.green) - Double(a.green)) * f,
                    Double(a.blue) + (Double(b.blue) - Double(a.blue)) * f]
        }
        let resting = render(morph: 0, progress: 1, success: true)
        for x in [40, 180, 320] {
            let actual = pixel(resting, x: x), expected = expectedGreen(x: Double(x) + 0.5, y: 27.5, width: 360)
            // The website's sheen adds at most a few percent of white at mid-height.
            check(zip(actual, expected).allSatisfy { abs(Double($0) - $1) <= 12 },
                  "resting success capsule is the website gradient at x=\(x): \(actual) vs \(expected.map { Int($0.rounded()) })")
        }
        check(render(morph: 0, progress: 1, transparent: true, success: true)[(27 * 360 + 180) * 4 + 3] == 255,
              "the success capsule is fully opaque")
        let midWave = render(morph: 0.5, progress: 1, success: true)
        func isGreen(_ p: [Int]) -> Bool { p[1] > p[0] + 80 && p[1] > p[2] + 40 }
        check(isGreen(pixel(midWave, x: 40)) && !isGreen(pixel(midWave, x: 330)),
              "mid-morph, green has arrived from the left while the spectrum remains on the right")
        let greenCoverage = [1.0, 0.75, 0.5, 0.25, 0.0].map { morph -> Int in
            let image = render(morph: morph, progress: 1, success: true)
            return (0..<360).filter { isGreen(pixel(image, x: $0)) }.count
        }
        check(zip(greenCoverage, greenCoverage.dropFirst()).allSatisfy { $0 <= $1 } && greenCoverage.first == 0 && greenCoverage.last! >= 356,
              "green coverage grows continuously with the returning morph: \(greenCoverage)")
        check(!isGreen(pixel(render(morph: 0, progress: 1), x: 180)) && isGreen(pixel(resting, x: 180)),
              "only the success state paints green; the ordinary capsule keeps its theme")
        let suite = "ZagStore.morph-rendering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var controlHeights: [Int] = []
        for state in [ZagSelfUpdateActionState.idle, .progress(message: "Downloading update...", fraction: 0.55),
                      .progress(message: "Preparing signed update...", fraction: nil),
                      .handedOff, .awaitingVerification] {
            let content = ZagSelfUpdateActionControl(state: state, disabled: !state.isActionable) {}
                .frame(width: 350)
                .defaultAppStorage(defaults)
            let image = ImageRenderer(content: content).cgImage!
            controlHeights.append(image.height)
            check(image.width == 350, "full control retains reference width in \(state.title)")
        }
        check(controlHeights[0] == 54, "idle capsule has no hidden status reservation before Learn More")
        check(controlHeights.allSatisfy { (54...125).contains($0) }, "busy and terminal controls fit their visible status without oversized reserved space")
        let compactCard = VStack(spacing: 18) {
            ZagSelfUpdateActionControl(state: .idle) {}.defaultAppStorage(defaults)
            Text("Learn More").frame(maxWidth: .infinity, minHeight: 44)
        }.frame(width: 350)
        check(ImageRenderer(content: compactCard).cgImage!.height == 116,
              "capsule-to-Learn-More layout retains the original 18-point stack gap")
        let accessible = ZagSelfUpdateActionControl(state: .handedOff) {}
            .frame(width: 260).defaultAppStorage(defaults).dynamicTypeSize(.accessibility3)
        let accessibleImage = ImageRenderer(content: accessible).cgImage!
        check(accessibleImage.width == 260 && accessibleImage.height > controlHeights[0],
              "smaller width and accessibility text can grow without fixed-height clipping")
        print("SUCCESS: \(checks) actual Canvas rendering checks passed")
    }
}
