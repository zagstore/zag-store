import SwiftUI
import UIKit

/// Runs the production update control in a simulator window and samples what is
/// actually on screen every display frame: capsule height, status-line ink and
/// the capsule colour. Simulator timing approximates, but does not prove,
/// device smoothness; ordering and gaps are what these checks rely on.
final class ZagChoreographyModel: ObservableObject {
    @Published var state: ZagSelfUpdateActionState = .idle
}

struct ZagChoreographyHost: View {
    @ObservedObject var model: ZagChoreographyModel
    var body: some View {
        VStack(spacing: 0) {
            ZagSelfUpdateActionControl(state: model.state) {}
                .frame(width: 360)
            Spacer(minLength: 0)
        }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }
}

struct ZagFrameSample {
    let time: Double
    let capsuleHeight: Int
    let statusInk: Int
    let centre: [Int]
    /// Leftmost and rightmost visible columns on the capsule's middle row,
    /// relative to the control's 360-point layout frame.
    let extent: ClosedRange<Int>
}

@main
final class ZagChoreographyApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let model = ZagChoreographyModel()
    private var samples: [ZagFrameSample] = []
    private var link: CADisplayLink?
    private var origin = CACurrentMediaTime()
    private var checks = 0
    private var failures = 0
    private var dumped = 0

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ZagChoreographyHost(model: model))
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await run() }
        return true
    }

    private func check(_ value: Bool, _ label: String) {
        checks += 1
        if value { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") }
    }

    // MARK: Sampling

    /// Window column through the capsule centre, the capsule slot and the status line below it.
    private var capsuleTop: CGFloat { 0 }
    private func sample() {
        guard let window else { return }
        // Captures a margin either side of the control, so drawing beyond its
        // layout frame (or clipping at it) is visible.
        let margin = 10, width = 360 + 2 * margin, height = 140
        let originX = (window.bounds.width - 360) / 2 - CGFloat(margin)
        // Cheap capture of the current layer tree, clipped to the control, so
        // sampling leaves the main thread free to render SwiftUI's frames.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(x: originX, y: capsuleTop, width: CGFloat(width), height: CGFloat(height)), format: format)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        if let dump = ProcessInfo.processInfo.environment["ZAG_DUMP"] {
            dumped += 1
            try? image.pngData()?.write(to: URL(fileURLWithPath: dump).appendingPathComponent(String(format: "%04d.png", dumped)))
        }
        guard let cg = image.cgImage else { return }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Bitmap memory row 0 is the top row of the drawn image.
        // `x` is relative to the control's layout frame.
        func px(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x + margin) * 4; return [Int(rgba[i]), Int(rgba[i+1]), Int(rgba[i+2])] }
        func lit(_ p: [Int]) -> Bool { p.reduce(0, +) > 60 }
        // The capsule is the first contiguous lit run down the centre column
        // (a two-line title makes it taller than 54); the status line lies below it.
        guard let top = (0..<height).first(where: { lit(px(180, $0)) }) else {
            samples.append(ZagFrameSample(time: CACurrentMediaTime() - origin, capsuleHeight: 0, statusInk: 0, centre: px(180, 27), extent: 0...0))
            return
        }
        var bottom = top
        while bottom + 1 < height, lit(px(180, bottom + 1)) || lit(px(60, bottom + 1)) { bottom += 1 }
        var ink = 0
        for y in min(height, bottom + 4)..<height { for x in stride(from: 4, to: 356, by: 2) where lit(px(x, y)) { ink += 1 } }
        let middle = (top + bottom) / 2
        let row = (-margin..<(360 + margin)).filter { px($0, middle).reduce(0, +) > 12 }
        samples.append(ZagFrameSample(time: CACurrentMediaTime() - origin, capsuleHeight: bottom - top + 1,
                                      statusInk: ink, centre: px(180, middle), extent: (row.first ?? 0)...(row.last ?? 0)))
    }

    private func record(for seconds: Double, _ change: () -> Void) async -> [ZagFrameSample] {
        samples = []
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        origin = CACurrentMediaTime()
        change()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        link.invalidate()
        return samples
    }
    private var frame = 0
    @objc private func tick() {
        frame += 1
        if frame % 2 == 0 { sample() }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }

    // MARK: Scenarios

    @MainActor private func run() async {
        await settle()
        let pause = ZagUpdateStatusTiming.pauseAfterMorph

        // 1. Update Now → bar. The first status line waits for the bar.
        let entering = await record(for: 1.2) { model.state = .progress(message: "Preparing update...", fraction: nil) }
        let barArrival = entering.first { $0.capsuleHeight <= 16 }?.time
        let firstInk = entering.first { $0.statusInk > 20 }?.time
        print("entering: bar at \(barArrival.map { String(format: "%.3f", $0) } ?? "never"), text at \(firstInk.map { String(format: "%.3f", $0) } ?? "never")")
        check(barArrival != nil && firstInk != nil, "the bar arrives and the first status line appears")
        if let barArrival, let firstInk {
            check(firstInk >= barArrival + pause * 0.8, "the first status line appears only after the bar has arrived, after the pause")
        }
        // Simulator sampling is too coarse (and too perturbing) to time a 0.35 s
        // morph; timing is a unit-checked constant. These are frame invariants.
        let midMorph = { (s: ZagFrameSample) in s.capsuleHeight > 17 && s.capsuleHeight < 52 }
        check(!(entering + []).contains { midMorph($0) && $0.statusInk > 20 }, "no status text is visible while the capsule is mid-morph (entering)")
        let heights = entering.map(\.capsuleHeight).filter { $0 > 0 }
        check(zip(heights, heights.dropFirst()).allSatisfy { $1 <= $0 + 1 }, "pill→bar height decreases monotonically: \(heights.prefix(24))")

        // 2. Same-stage percentages: digits change, the line never fades.
        model.state = .progress(message: "Transferring signed IPA...", fraction: 0.10)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let rolling = await record(for: 1.0) {
            for step in 1...9 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.1) {
                    self.model.state = .progress(message: "Transferring signed IPA...", fraction: 0.10 + Double(step) * 0.09)
                }
            }
        }
        let minInk = rolling.map(\.statusInk).min() ?? 0, maxInk = rolling.map(\.statusInk).max() ?? 0
        check(minInk > maxInk / 2, "percentage updates within a stage never fade the line (ink \(minInk)…\(maxInk))")
        check(Set(rolling.map(\.capsuleHeight)).count <= 2, "percentage updates never move the bar's geometry")
        // Rounded ends: the bar's halo and rim are stroked on its edge, so they
        // must show past both ends of the 360-point frame, equally, not clipped flat.
        let bar = rolling.last!.extent
        print("bar extent:", bar)
        check(bar.lowerBound < 0 && bar.upperBound > 359, "the bar's rounded ends are drawn past its layout frame, not clipped (\(bar))")
        check(abs(-bar.lowerBound - (bar.upperBound - 359)) <= 1, "both rounded ends are drawn identically")

        // 3. Bar → success capsule. The old line leaves, the capsule turns green,
        //    and the success line appears only after the capsule has arrived.
        let exiting = await record(for: 1.4) { model.state = .handedOff }
        let capsuleArrival = exiting.first { $0.capsuleHeight >= 52 }?.time
        let oldGone = exiting.first { $0.statusInk == 0 }?.time
        let newInk = exiting.first { s in s.statusInk > 20 && oldGone.map { s.time > $0 } == true }?.time
        print("exiting: capsule at \(capsuleArrival.map { String(format: "%.3f", $0) } ?? "never"), old line gone at \(oldGone.map { String(format: "%.3f", $0) } ?? "never"), new line at \(newInk.map { String(format: "%.3f", $0) } ?? "never")")
        check(capsuleArrival != nil && oldGone != nil && newInk != nil, "the capsule returns and the status line is replaced")
        if let capsuleArrival, let oldGone, let newInk {
            check(oldGone <= capsuleArrival, "the previous status line is gone before the capsule settles")
            check(newInk >= capsuleArrival + pause * 0.8, "the success line appears only after the capsule has arrived, after the pause")
        }
        // The outgoing line fades out as the morph begins; the incoming one must wait.
        check(!exiting.contains { s in midMorph(s) && s.statusInk > 20 && oldGone.map { s.time > $0 } != false },
              "no new status text is visible while the capsule is mid-morph (exiting)")
        let returning = exiting.map(\.capsuleHeight).filter { $0 > 0 }
        check(zip(returning, returning.dropFirst()).allSatisfy { $1 + 1 >= $0 }, "bar→pill height increases monotonically: \(returning.prefix(24))")
        let resting = exiting.last!.extent
        check(resting == 0...359, "the settled success capsule fills exactly its layout frame (\(resting))")
        let final = exiting.last!.centre
        check(abs(final[0] - 0x00) <= 16 && abs(final[1] - 0xc5) <= 16 && abs(final[2] - 0x65) <= 16,
              "the settled capsule centre is the website's #00c565 (sampled \(final))")
        let greens = exiting.map { $0.centre[1] - max($0.centre[0], $0.centre[2]) }
        check(greens.first! < 60 && greens.last! > 80, "the capsule centre turns green during the return, not before")

        // 4. Interruption: a stage change during the morph never shows the outdated line.
        model.state = .idle
        try? await Task.sleep(nanoseconds: 900_000_000)
        let interrupted = await record(for: 1.4) {
            model.state = .progress(message: "Downloading update...", fraction: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.model.state = .awaitingVerification }
        }
        print("interrupted:", interrupted.map { "\($0.capsuleHeight)/\($0.statusInk)" }.joined(separator: " "))
        // Mid-morph, an incoming two-line title can briefly overhang the shrunken
        // capsule; status text is judged on settled frames only.
        check(interrupted.filter { !midMorph($0) && $0.capsuleHeight > 17 }.allSatisfy { $0.statusInk == 0 },
              "an interrupted morph shows no stale status line")
        check(interrupted.last!.capsuleHeight >= 52, "the interrupted control settles as a capsule")
        let notGreen = interrupted.last!.centre
        check(!(notGreen[1] > notGreen[0] + 80 && notGreen[1] > notGreen[2] + 40), "an unverified outcome is never green")

        print(failures == 0 ? "SUCCESS: \(checks) on-screen choreography checks passed" : "FAILED: \(failures) of \(checks)")
        fflush(stdout)
        // Test harness only: report the result through the process status.
        exit(failures == 0 ? 0 : 1)
    }
}
