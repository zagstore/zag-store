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

/// Installer callbacks can report progress, but only installed-identity
/// reconciliation is allowed to produce the completed action.
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
        case .awaitingHandoff: return "View Installation Steps"
        case .handedOff: return "Reopen After Installation..."
        case .awaitingVerification: return "Check Installation..."
        case .confirmed: return "Restart to Complete..."
        }
    }
    var status: String? {
        switch self {
        case .idle: return nil
        case .progress(let message, let measured):
            if let measured { return "\(message) \(Int(min(1, max(0, measured)) * 100))%" }
            return message
        case .awaitingHandoff: return "IPA verified - waiting for iOS handoff"
        case .handedOff: return "Update handed off to iOS. Reopen Zag Store after installation."
        case .awaitingVerification: return "Installation is unverified. Check iOS before trying again."
        case .confirmed: return "Update completed. Please restart Zag Store."
        }
    }
    var offersGuidance: Bool {
        switch self { case .awaitingHandoff, .handedOff, .awaitingVerification, .confirmed: return true; default: return false }
    }
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
        switch self { case .progress: return true; default: return false }
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
