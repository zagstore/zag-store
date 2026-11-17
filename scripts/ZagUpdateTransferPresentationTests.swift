import Foundation
import Combine

@main struct TransferPresentationTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS: \(label)") }
        let core = ZagRPPairingCore()
        let screen = ZagUpdateInstallerPresentation(core: core)
        var screenChanges = 0
        var fractions: [Double] = []
        let rootSubscription = screen.objectWillChange.sink { screenChanges += 1 }
        let progressSubscription = screen.progress.$fraction.compactMap { $0 }.sink { fractions.append($0) }
        var coreChanges = 0
        var exactSamples: [Int] = []
        let coreSubscription = core.objectWillChange.sink { coreChanges += 1 }
        let exactSubscription = core.gate4StatePublisher.sink { if case .uploading(let p) = $0 { exactSamples.append(p) } }
        core.emit(.uploading(0))
        for percent in 1...100 { core.emit(.uploading(percent)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(screenChanges == 1, "101 authoritative transfer callbacks invalidate the screen only for the stage change")
        check(exactSamples == Array(0...100), "every exact native percentage still reaches the update presentation, in order")
        check(coreChanges == 11, "whole-core observers (tab bar, Library) are invalidated 11 times, not 101, for one transfer")
        check(core.gate4State == .uploading(100), "the stored native state is exact, never a coarsened value")
        let policy = ZagGate4PublicationPolicy.self
        check(!policy.invalidatesViews(fromPercent: 41, toPercent: 49), "percentages within one ten-point step do not invalidate views")
        check(policy.invalidatesViews(fromPercent: 49, toPercent: 50), "crossing a ten-point boundary invalidates views")
        check(policy.invalidatesViews(fromPercent: 5, toPercent: 15) && policy.invalidatesViews(fromPercent: 95, toPercent: 100),
              "installer jumps and the final 100 percent always invalidate views")
        withExtendedLifetime((coreSubscription, exactSubscription)) {}
        check(screen.progress.authoritativePercent == 100 && screen.progress.fraction == 1, "coalescing retains the final real transfer sample")
        check(fractions.count <= 4, "burst percentages coalesce to a bounded number of control-only publications")
        check(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "published transfer samples remain monotonic")
        core.emit(.uploading(50)); core.emit(.uploading(100))
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(screenChanges == 1 && screen.progress.fraction == 1, "duplicate and regressive samples do not invalidate the screen or move progress backwards")
        core.emit(.staged)
        check(screen.stage == .staged && screen.progress.fraction == nil, "staging ends transfer percentages without fabricating installer completion")
        core.emit(.progress(12))
        check(screen.progress.fraction == 0.12, "installation starts a distinct measured phase, not stale transfer 100 percent")
        core.emit(.progress(32)); core.emit(.failed("fixture failure"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(screen.progress.fraction == nil, "queued percentages cannot resurrect a failed phase")
        core.emit(.uploading(7))
        check(screen.progress.fraction == 0.07, "a new attempt resets safely to its own first measured sample")
        core.emit(.uploading(120)); core.emit(.uploading(-1))
        check(screen.progress.authoritativePercent == 7, "out-of-range native measurements are not invented or clamped into completion")
        core.emit(.complete)
        check(screen.stage == .complete && screen.progress.fraction == nil, "native completion is a stage event, not a fabricated 100 percent")
        withExtendedLifetime((rootSubscription, progressSubscription)) {}
        print("SUCCESS: \(checks) transfer observation/coalescing checks passed")
    }
}
