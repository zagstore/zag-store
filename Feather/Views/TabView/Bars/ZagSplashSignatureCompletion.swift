import Foundation
import QuartzCore

/// A completed Core Animation reveal, not a wall-clock guess, acknowledges the
/// tagline. Interrupted animations leave the persisted message pending.
@MainActor final class ZagSplashSignatureCompletion: NSObject, CAAnimationDelegate {
    let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        Task { @MainActor [weak self] in self?.completion() }
    }
}
