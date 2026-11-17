import Foundation

/// The update file's size as its server reports it. Signed v2 metadata has no
/// size field (its payload's field set is fixed), so the size is read from the
/// release download's HTTP headers; the download itself is still verified
/// against the signed SHA-256.
enum ZagUpdateDownloadSize: Equatable {
    case checking
    case bytes(Int64)
    /// The server answered that the file does not exist (404 or 410).
    case fileUnavailable
    /// No trustworthy size: network failure, no length or an unexpected answer.
    case unknown

    var text: String {
        switch self {
        case .checking: return "Checking download size…"
        case .bytes(let bytes): return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .fileUnavailable: return "Update file unavailable"
        case .unknown: return "Download size unavailable"
        }
    }

    /// One response, after redirects. A full answer gives `Content-Length`; a
    /// ranged one gives the total after the slash in `Content-Range`.
    static func parse(status: Int, contentLength: String?, contentRange: String?) -> ZagUpdateDownloadSize {
        switch status {
        case 200:
            if let value = contentLength.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), value > 0 {
                return .bytes(value)
            }
        case 206:
            if let total = contentRange?.split(separator: "/").last,
               let value = Int64(total.trimmingCharacters(in: .whitespaces)), value > 0 {
                return .bytes(value)
            }
        case 404, 410:
            return .fileUnavailable
        default:
            break
        }
        return .unknown
    }

    /// `HEAD` first. Without a usable length, a one-byte ranged `GET` whose
    /// body is never read: the task is cancelled once the headers arrive, even
    /// if the server ignores the range. Redirects are followed by URLSession.
    static func lookup(_ url: URL, session: URLSession = .shared, timeout: TimeInterval = 15) async -> ZagUpdateDownloadSize {
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        head.httpMethod = "HEAD"
        let first: ZagUpdateDownloadSize
        if let response = try? await session.data(for: head).1 as? HTTPURLResponse {
            first = parse(response)
        } else {
            first = .unknown
        }
        guard first == .unknown, !Task.isCancelled else { return first }
        var ranged = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: ranged) else { return .unknown }
        bytes.task.cancel()
        return (response as? HTTPURLResponse).map(parse) ?? .unknown
    }

    private static func parse(_ response: HTTPURLResponse) -> ZagUpdateDownloadSize {
        parse(status: response.statusCode,
              contentLength: response.value(forHTTPHeaderField: "Content-Length"),
              contentRange: response.value(forHTTPHeaderField: "Content-Range"))
    }
}

/// The update card's secondary line: a function of the same action state that
/// drives the update control, so it cannot disagree with the pill.
enum ZagUpdateCardStatus {
    enum Failure: Equatable { case failed, cancelled }

    static func text(action: ZagSelfUpdateActionState, failure: Failure?, size: ZagUpdateDownloadSize) -> String {
        switch action {
        // The same transition that turns the control into the green
        // `Restart to Complete...` pill: verified staging or native completion.
        case .handedOff: return "Update successful."
        case .awaitingVerification: return "Update not verified."
        case .progress: return "Update requested..."
        case .idle:
            switch failure {
            case .failed: return "Update failed."
            case .cancelled: return "Update cancelled."
            case nil: return size.text
            }
        }
    }
}

/// Crossfade bookkeeping for a line of text: fade the shown text out, swap it
/// while invisible, fade the newest requested text in. A fade-out that arrives
/// after newer requests always shows the newest, never an older one.
struct ZagCrossfadeTextState: Equatable {
    private(set) var shown: String
    private(set) var target: String
    private(set) var visible = true
    private(set) var fadingOut = false

    init(_ text: String) {
        shown = text
        target = text
    }

    /// Returns true when a fade-out should start now.
    mutating func request(_ text: String) -> Bool {
        target = text
        if fadingOut { return false }
        if text == shown && visible { return false }
        fadingOut = true
        visible = false
        return true
    }

    /// The fade-out finished: swap to the newest text while invisible.
    /// Returns true when it should now fade in (`reveal`).
    mutating func fadeOutArrived() -> Bool {
        guard fadingOut, !visible else { return false }
        fadingOut = false
        shown = target
        return true
    }

    mutating func reveal() {
        guard !fadingOut else { return }
        visible = true
    }
}
