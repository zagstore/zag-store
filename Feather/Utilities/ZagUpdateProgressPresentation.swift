import Foundation

/// Bytes received from URLSession, not an estimate of verification/installation.
struct ZagUpdateByteProgress: Equatable, Sendable {
    let received: Int64
    let expected: Int64?

    var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

/// Owned by one streaming receiver and used only on its serial delegate queue.
/// Bounds UI publications while retaining the first and final byte measurements.
struct ZagUpdateProgressSampler {
    private var lastPublication: TimeInterval?
    private var received: Int64 = 0
    private var lastPublished: ZagUpdateByteProgress?
    let interval: TimeInterval

    init(interval: TimeInterval = 0.1) { self.interval = interval }

    mutating func receive(bytes: Int64, expected: Int64?, now: TimeInterval,
                          finished: Bool = false) -> ZagUpdateByteProgress? {
        received = max(received, max(0, bytes))
        let value = ZagUpdateByteProgress(received: received, expected: expected.flatMap { $0 > 0 ? $0 : nil })
        guard value != lastPublished else { return nil }
        guard finished || lastPublication == nil || now - lastPublication! >= interval else { return nil }
        lastPublication = now
        lastPublished = value
        return value
    }
}

/// Percentages apply only to an actual byte-transfer phase.
enum ZagUpdatePreparationState: Equatable {
    case idle
    case downloading(ZagUpdateByteProgress)
    case verifying
    case importing
    case signing
    case readyForHandoff

    var message: String {
        switch self {
        case .idle: return "Preparing update..."
        case .downloading: return "Downloading update..."
        case .verifying: return "Verifying IPA..."
        case .importing: return "Verifying and importing IPA..."
        case .signing: return "Preparing signed update..."
        case .readyForHandoff: return "Preparing installation handoff..."
        }
    }
    var fraction: Double? {
        if case .downloading(let bytes) = self { return bytes.fraction }
        return nil
    }
}

/// A successful installer return enables completion UI; installed-identity
/// reconciliation remains a separate, stronger proof for the one-shot splash.
enum ZagSelfUpdateActionState: Equatable {
    case idle
    case progress(message: String, fraction: Double?)
    case awaitingHandoff
    case handedOff
    case awaitingVerification
    case confirmed

    var title: String {
        switch self {
        case .idle: return "Update Now"
        case .progress(let message, _): return message
        case .awaitingHandoff: return "IPA verified - waiting for iOS handoff"
        case .awaitingVerification: return "Installation not verified. Reopen Zag Store to check."
        case .handedOff, .confirmed: return "Restart to Complete..."
        }
    }
    var status: String? {
        switch self {
        case .idle: return nil
        case .progress(let message, let measured):
            if let measured { return "\(message) \(ZagUpdateProgressFormatting.percent(measured))%" }
            return message
        case .awaitingHandoff: return "Signed IPA transferred. Reopen Zag Store after iOS finishes installing."
        case .awaitingVerification: return "Installation not verified. Reopen Zag Store to check."
        case .handedOff, .confirmed: return "Update successful. Reopen Zag Store to complete."
        }
    }
    var offersGuidance: Bool {
        switch self { case .handedOff, .confirmed: return true; default: return false }
    }
    /// Short manual steps shown inline after an explicit tap, never a modal.
    var reopenInstruction: String {
        if self == .confirmed {
            return "Close Zag Store in the App Switcher, then open it again."
        }
        return "After iOS finishes installing, close Zag Store in the App Switcher and reopen it."
    }

    /// Detailed explanations are for the existing developer diagnostics only.
    var guidance: String {
        switch self {
        case .confirmed:
            return "The installed replacement is verified. iOS cannot restart Zag Store automatically. Open the App Switcher, swipe up Zag Store, then open it again."
        case .handedOff:
            return "The installer reported a successful handoff, but this running app cannot verify its replacement. Wait for installation to finish on the Home Screen. Then open Zag Store again to verify the installed update. If needed, close it in the App Switcher first."
        case .awaitingHandoff:
            return "The signed IPA is transferred and verified. The installation service has not yet confirmed completion. Check the Zag Store icon on the Home Screen and wait while it installs. Reopen after installation. If nothing changes, use the existing recovery tools; do not start another update while this attempt is pending."
        default:
            return "The earlier installation attempt is unverified. Check the Zag Store icon on the Home Screen. Wait if installation is in progress, then reopen Zag Store to verify the installed version. If it did not install, use Clear and Try Again in recovery."
        }
    }
    var showsProgress: Bool {
        switch self { case .progress, .awaitingHandoff, .awaitingVerification: return true; default: return false }
    }
    var fraction: Double? {
        if case .progress(_, let fraction) = self { return fraction.map { min(1, max(0, $0)) } }
        return nil
    }
}

/// Presentation facts only. The installer and its recovery policy remain authoritative.
enum ZagUpdateHandoffState: Equatable {
    case none
    case waiting
    case reportedComplete
    case uncertain
}

/// The outer slot never changes height. Only the capsule inside it compresses;
/// the same normalized value also controls its fill and corner radius.
enum ZagUpdateControlGeometry {
    static let trackHeight = 14.0
    static func height(slotHeight: Double, morph: Double) -> Double {
        let amount = min(1, max(0, morph))
        return slotHeight + (trackHeight - slotHeight) * amount
    }
    static func filledFraction(progress: Double?, morph: Double) -> Double {
        let fraction = min(1, max(0, progress ?? 1))
        return 1 + (fraction - 1) * min(1, max(0, morph))
    }
}

/// Decorative cadence is unrelated to transfer bytes and never advances them.
enum ZagUpdateDecorationPolicy {
    static func animates(progress: Bool, active: Bool, reduceMotion: Bool, lowPower: Bool) -> Bool {
        progress && active && !reduceMotion && !lowPower
    }
}

/// Symmetric cubic timing shared by both directions. Percentages never select
/// or restart this specification.
enum ZagUpdateMorphSpecification {
    static let duration = 0.42
    static let x1 = 0.42
    static let y1 = 0.0
    static let x2 = 0.58
    static let y2 = 1.0
}

/// Retargeted measured progress, independent from capsule geometry and the
/// decorative five-second clock. Never extrapolates beyond an observed target.
struct ZagUpdateVisualProgress {
    private var start: Double
    private var target: Double
    private var startedAt: TimeInterval
    private let duration: TimeInterval = 0.1

    init(_ value: Double, at time: TimeInterval) {
        start = value; target = value; startedAt = time
    }
    func value(at time: TimeInterval) -> Double {
        let elapsed = min(1, max(0, (time - startedAt) / duration))
        return start + (target - start) * elapsed
    }
    mutating func update(_ value: Double, at time: TimeInterval, immediate: Bool) {
        start = (immediate || value < target) ? value : self.value(at: time)
        target = value
        startedAt = time
    }
}

/// Preserve integer installer percentages through Double round trips without
/// rounding an incomplete byte transfer up to 100 percent.
enum ZagUpdateProgressFormatting {
    static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        let bounded = min(1, max(0, fraction))
        if bounded == 1 { return 100 }
        return min(99, Int((bounded * 100).nextUp.rounded(.down)))
    }
}
