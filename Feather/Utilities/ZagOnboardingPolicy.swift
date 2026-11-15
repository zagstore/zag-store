import Foundation

/// Process-local launch gate. No installation history or persisted dismissal is evidence.
struct ZagOnboardingPolicy {
    enum Verification: Equatable { case verified, missing, invalid, failed, unknown, timedOut }
    enum Status: Equatable { case checking, verified, missing, invalid, failed, unknown, timedOut, skipped }
    private(set) var status: Status = .checking
    private(set) var generation = 0
    private(set) var started = false
    private(set) var splashFinished = false
    private var pendingURLs: [URL] = []

    var canEnterMain: Bool { status == .verified || status == .skipped }

    mutating func beginIfNeeded(hasRecord: Bool) -> Int? {
        guard !started else { return nil }
        started = true
        return retry(hasRecord: hasRecord)
    }

    mutating func retry(hasRecord: Bool) -> Int? {
        guard !canEnterMain else { return nil }
        generation += 1
        status = hasRecord ? .checking : .missing
        return hasRecord ? generation : nil
    }

    mutating func receive(_ result: Verification, generation token: Int) {
        guard token == generation, status == .checking else { return }
        switch result {
        case .verified: status = .verified
        case .missing: status = .missing
        case .invalid: status = .invalid
        case .failed: status = .failed
        case .unknown: status = .unknown
        case .timedOut: status = .timedOut
        }
    }

    mutating func skip() { generation += 1; status = .skipped }
    mutating func setupSucceeded() { generation += 1; status = .verified }
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
