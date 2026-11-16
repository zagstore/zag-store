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
        case .idle: return "Preparing Update…"
        case .downloading: return "Downloading update…"
        case .verifying: return "Verifying IPA…"
        case .importing: return "Verifying and importing IPA…"
        case .signing: return "Signing and validating update…"
        case .readyForHandoff: return "Preparing installation handoff…"
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
    case awaitingVerification
    case confirmed

    var title: String {
        switch self {
        case .idle: return "Update Now"
        case .progress(let message, _): return message
        case .awaitingVerification: return "Reopen Zag Store to verify installation"
        case .confirmed: return "Restart to Complete..."
        }
    }
    var showsProgress: Bool {
        switch self { case .progress, .awaitingVerification: return true; default: return false }
    }
    var fraction: Double? {
        if case .progress(_, let fraction) = self { return fraction.map { min(1, max(0, $0)) } }
        return nil
    }
}
