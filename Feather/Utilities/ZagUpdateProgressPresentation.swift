import Foundation
import CoreGraphics

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

/// The in-app operation's successful end (verified staging or a native
/// completion) selects the final capsule; installed-identity reconciliation
/// remains a separate, stronger proof for the one-shot splash.
enum ZagSelfUpdateActionState: Equatable {
    case idle
    case progress(message: String, fraction: Double?)
    case handedOff
    /// A failed or ambiguous attempt whose pending record is kept for launch
    /// verification. Terminal: the capsule returns, never as success.
    case awaitingVerification

    var title: String {
        switch self {
        case .idle: return "Update Now"
        case .progress(let message, _): return message
        case .awaitingVerification: return "Installation not verified. Reopen Zag Store to check."
        case .handedOff: return "Restart to Complete..."
        }
    }
    /// The line below the control: a stage message and, for byte transfers
    /// only, the measured percentage (shown with its own digit transition).
    var statusLine: ZagUpdateStatusLine? {
        switch self {
        case .idle, .awaitingVerification: return nil
        case .progress(let message, let measured):
            return ZagUpdateStatusLine(message: message, percent: measured.map(ZagUpdateProgressFormatting.percent))
        case .handedOff: return ZagUpdateStatusLine(message: "Update successful. Reopen Zag Store to complete.", percent: nil)
        }
    }
    var status: String? { statusLine?.text }
    /// Only `Update Now` acts. The final capsule is a statement: iOS offers no
    /// supported way for an app to close or relaunch itself.
    var isActionable: Bool { self == .idle }
    /// The website's signing-success treatment is reserved for the successful
    /// end of the in-app operation; never failed, cancelled or unverified states.
    var showsSuccess: Bool { self == .handedOff }

    /// Detailed explanations are for the existing developer diagnostics only.
    var guidance: String {
        switch self {
        case .handedOff:
            return "The signed IPA is staged on the device at its verified size and Zag Store then sends the Upgrade request, or the installer reported completion. This running app cannot verify its replacement. Close Zag Store in the App Switcher and open it again to verify the installed update."
        default:
            return "The earlier installation attempt is unverified. Check the Zag Store icon on the Home Screen. Wait if installation is in progress, then reopen Zag Store to verify the installed version. If it did not install, use Clear and Try Again in recovery."
        }
    }
    var showsProgress: Bool {
        if case .progress = self { return true }
        return false
    }
    var fraction: Double? {
        if case .progress(_, let fraction) = self { return fraction.map { min(1, max(0, $0)) } }
        return nil
    }
}

extension ZagSelfUpdateActionState {
    /// The control for a self-update with a pending installation record. The
    /// coordinator's handoff state decides the outcome; raw installer stages
    /// only describe progress while the attempt is in flight.
    static func pendingAttempt(handoff: ZagUpdateHandoffState, installerRunning: Bool,
                               installerTitle: String, installerFraction: Double?,
                               preparingMessage: String) -> ZagSelfUpdateActionState {
        // Verified staging (209) or a native completion ends the in-app
        // operation; iOS reports nothing further while Zag Store stays open.
        if handoff.isSuccessfulHandoff { return .handedOff }
        if handoff == .uncertain { return .awaitingVerification }
        if installerRunning { return .progress(message: installerTitle, fraction: installerFraction) }
        // Recorded, installer not yet started (or just returned): still busy.
        return .progress(message: preparingMessage, fraction: nil)
    }
}

/// Presentation facts only. The installer and its recovery policy remain authoritative.
enum ZagUpdateHandoffState: Equatable {
    case none
    case waiting
    /// Native 209 for this attempt: the device holds the complete signed IPA
    /// at its verified size and the Upgrade request follows. While Zag Store
    /// stays open iOS reports nothing further, so this is the successful end
    /// of the in-app operation. Not installed-executable proof.
    case stagedOnDevice
    case reportedComplete
    case uncertain

    /// A later installer error still replaces either state (`.uncertain`, or
    /// `.none` when the retry policy releases the pending record).
    var isSuccessfulHandoff: Bool { self == .stagedOnDevice || self == .reportedComplete }
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
    static let duration = 0.35
    static let x1 = 0.42
    static let y1 = 0.0
    static let x2 = 0.58
    static let y2 = 1.0
}

/// A status message plus an optional measured percentage. A new message (or a
/// percentage appearing/disappearing) is a stage change that crossfades; a new
/// percentage within the same stage only rolls its digits.
struct ZagUpdateStatusLine: Equatable {
    let message: String
    let percent: Int?

    var text: String { percent.map { "\(message) \($0)%" } ?? message }
    func isSameStage(as other: ZagUpdateStatusLine?) -> Bool {
        guard let other else { return false }
        return message == other.message && (percent == nil) == (other.percent == nil)
    }
}

/// Status-line choreography. Text below the control changes only after the
/// capsule geometry has arrived (tracked, not timed), then a short pause.
enum ZagUpdateStatusTiming {
    /// Intentional rest between geometry arrival and the new text.
    static let pauseAfterMorph = 0.065
    static let fadeOut = 0.08
    static let fadeIn = 0.13
    /// Sequential stage-change crossfade (fade-out, swap, fade-in).
    static var crossfade: Double { fadeOut + fadeIn }
}

/// Zag Store website signing-success colour: `--zds-green` in the BYOC
/// installer's `assets/digital-seal.css` (zagstore-byoc-installer),
/// `linear-gradient(100deg, #1fe27e 0%, #00c565 50%, #00a352 100%)` with a white
/// label. CSS hex values are sRGB.
enum ZagUpdateSuccessPalette {
    struct Stop: Equatable { let red: Int; let green: Int; let blue: Int; let location: Double }
    static let stops = [Stop(red: 0x1f, green: 0xe2, blue: 0x7e, location: 0),
                        Stop(red: 0x00, green: 0xc5, blue: 0x65, location: 0.5),
                        Stop(red: 0x00, green: 0xa3, blue: 0x52, location: 1)]
    static let angleDegrees = 100.0
    /// The website label's ink shadow, `rgba(4, 8, 32, .28)` and `.16`.
    static let labelInk = (red: 4, green: 8, blue: 32)

    /// CSS `linear-gradient(<angle>)` line for a box: through its centre, long
    /// enough that the end colours meet the corners (CSS Images 3).
    static func gradientLine(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = angleDegrees * .pi / 180
        let direction = CGPoint(x: sin(radians), y: -cos(radians))
        let half = (abs(rect.width * sin(radians)) + abs(rect.height * cos(radians))) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return (CGPoint(x: centre.x - direction.x * half, y: centre.y - direction.y * half),
                CGPoint(x: centre.x + direction.x * half, y: centre.y + direction.y * half))
    }
}

/// The website's success wave, in points: green arrives inside the same capsule
/// as one feathered front travelling left to right, with a soft crest of light
/// that exists only while it travels. Here it rides the capsule morph itself.
enum ZagUpdateSuccessWave {
    /// The wave layer extends this far beyond the capsule (`width: calc(100% + 140px)`).
    static let overhang = 140.0
    /// Opaque until `overhang` before the front, transparent `60` before it.
    static let featherStart = 140.0
    static let featherEnd = 60.0
    static let crestWidth = 150.0

    /// Left edge of the wave layer for a wave amount 0...1 (`translateX(-100% → 0)`).
    static func layerMinX(width: Double, amount: Double) -> Double {
        (min(1, max(0, amount)) - 1) * (width + overhang)
    }
    /// The crest is visible only mid-travel (`zds-crest` keyframes 0, 12%, 70%, 100%).
    static func crestOpacity(_ amount: Double) -> Double {
        let t = min(1, max(0, amount))
        if t < 0.12 { return t / 0.12 }
        if t <= 0.70 { return 1 }
        return max(0, (1 - t) / 0.30)
    }
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
