import Foundation

/// Process-local launch gate. No installation history or persisted dismissal is evidence.
///
/// Three separate facts: `hasSavedPairing` (a record exists: earlier setup,
/// never current authentication), `isPairingVerified` (a live check passed
/// this session) and `isConnectionUnavailable` (the last check could not
/// reach the device, e.g. LocalDevVPN off; says nothing about the pairing).
/// `canEnterMain` is presentation only: device operations keep their own live
/// verification and must never rely on it.
struct ZagOnboardingPolicy {
    enum Verification: Equatable { case verified, missing, invalid, failed, unknown, timedOut }
    enum Status: Equatable { case checking, verified, missing, invalid, failed, unknown, timedOut, skipped }
    private(set) var status: Status = .checking
    private(set) var generation = 0
    private(set) var started = false
    private(set) var splashFinished = false
    private(set) var hasSavedPairing = false
    /// Once open, the main interface stays open for the rest of the session.
    private(set) var canEnterMain = false
    private var pendingURLs: [URL] = []

    var isPairingVerified: Bool { status == .verified }
    var isConnectionUnavailable: Bool { status == .unknown || status == .timedOut || status == .failed }

    mutating func beginIfNeeded(hasRecord: Bool) -> Int? {
        guard !started else { return nil }
        started = true
        // Only the first-run welcome needs a missing record; a failed live
        // probe never sends a paired iPhone back to it.
        if hasRecord { canEnterMain = true }
        return retry(hasRecord: hasRecord)
    }

    mutating func retry(hasRecord: Bool) -> Int? {
        guard status != .verified, status != .skipped else { return nil }
        generation += 1
        hasSavedPairing = hasRecord
        status = hasRecord ? .checking : .missing
        return hasRecord ? generation : nil
    }

    mutating func receive(_ result: Verification, generation token: Int) {
        guard token == generation, status == .checking else { return }
        switch result {
        case .verified: status = .verified; canEnterMain = true
        case .missing: status = .missing
        case .invalid: status = .invalid
        case .failed: status = .failed
        case .unknown: status = .unknown
        case .timedOut: status = .timedOut
        }
    }

    /// The record was removed while the app runs: no longer verified, and any
    /// in-flight result is discarded. The open interface stays open.
    mutating func pairingRemoved() {
        generation += 1
        hasSavedPairing = false
        status = .missing
    }

    mutating func skip() { generation += 1; status = .skipped; canEnterMain = true }
    mutating func setupSucceeded() { generation += 1; hasSavedPairing = true; status = .verified; canEnterMain = true }
    mutating func finishSplash() { splashFinished = true }
    mutating func enqueue(_ url: URL) {
        guard pendingURLs.count < 16, url.absoluteString.utf8.count <= 4 * 1024 * 1024 else { return }
        pendingURLs.append(url)
    }
    mutating func takeURLs() -> [URL] {
        guard canEnterMain, splashFinished else { return [] }
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }
}
