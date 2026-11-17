import Foundation

/// Serves scripted responses per HTTP method and records what was asked.
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var headers: [String: String]; var body = Data(); var redirect: URL? = nil; var fails = false }
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodyBytesSent = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let key = (request.httpMethod ?? "GET") + (request.value(forHTTPHeaderField: "Range") == nil ? "" : " ranged")
        guard var queue = Self.replies[key], !queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let reply = queue.removeFirst()
        Self.replies[key] = queue
        if reply.fails { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirect {
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            Self.bodyBytesSent += reply.body.count
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Tests {
    static func main() async {
        var passed = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            passed += 1
            print("PASS: \(label)")
        }

        // MARK: Size parsing and formatting
        let size = 59_528_098 as Int64
        check(ZagUpdateDownloadSize.parse(status: 200, contentLength: "59528098", contentRange: nil) == .bytes(size), "Content-Length gives the exact byte count")
        check(ZagUpdateDownloadSize.parse(status: 206, contentLength: "1", contentRange: "bytes 0-0/59528098") == .bytes(size), "ranged answer gives the total, not the range length")
        check(ZagUpdateDownloadSize.parse(status: 200, contentLength: nil, contentRange: nil) == .unknown, "missing Content-Length is unknown, never guessed")
        for bad in ["0", "-5", "", "abc", "12.5"] {
            check(ZagUpdateDownloadSize.parse(status: 200, contentLength: bad, contentRange: nil) == .unknown, "unusable Content-Length \(bad.debugDescription) is unknown")
        }
        check(ZagUpdateDownloadSize.parse(status: 206, contentLength: "1", contentRange: "bytes 0-0/*") == .unknown, "unknown total in Content-Range is unknown")
        check(ZagUpdateDownloadSize.parse(status: 404, contentLength: "9", contentRange: nil) == .fileUnavailable, "404 means the update file is missing")
        check(ZagUpdateDownloadSize.parse(status: 410, contentLength: nil, contentRange: nil) == .fileUnavailable, "410 means the update file is missing")
        for status in [301, 403, 416, 500, 503] {
            check(ZagUpdateDownloadSize.parse(status: status, contentLength: "100", contentRange: nil) == .unknown, "HTTP \(status) is unknown, not a size")
        }
        check(ZagUpdateDownloadSize.bytes(size).text == ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
              "formatted like the rest of Zag Store (ByteCountFormatter, file style)")
        check(ZagUpdateDownloadSize.unknown.text == "Download size unavailable" && ZagUpdateDownloadSize.fileUnavailable.text == "Update file unavailable"
              && ZagUpdateDownloadSize.checking.text == "Checking download size…", "missing-metadata texts")

        // MARK: Lookup over HTTP
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let url = URL(string: "https://github.com/zagorskey/zag-store-releases/releases/download/t/ZagStore.ipa")!
        let asset = URL(string: "https://release-assets.githubusercontent.com/asset")!
        func run(_ replies: [String: [StubProtocol.Reply]]) async -> ZagUpdateDownloadSize {
            StubProtocol.replies = replies
            StubProtocol.requests = []
            StubProtocol.bodyBytesSent = 0
            return await ZagUpdateDownloadSize.lookup(url, session: session, timeout: 5)
        }
        var result = await run(["HEAD": [.init(status: 302, headers: ["Location": asset.absoluteString], redirect: asset),
                                         .init(status: 200, headers: ["Content-Length": "59528098"])]])
        check(result == .bytes(size) && StubProtocol.requests.count == 2 && StubProtocol.requests.allSatisfy { $0.httpMethod == "HEAD" },
              "HEAD follows the release redirect and reads the asset's size")
        result = await run(["HEAD": [.init(status: 200, headers: [:])],
                            "GET ranged": [.init(status: 206, headers: ["Content-Range": "bytes 0-0/59528098", "Content-Length": "1"], body: Data([0x50]))]])
        check(result == .bytes(size) && StubProtocol.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-0",
              "missing Content-Length falls back to a one-byte ranged request")
        result = await run(["HEAD": [.init(status: 403, headers: [:])],
                            "GET ranged": [.init(status: 200, headers: ["Content-Length": "59528098"], body: Data(count: 1 << 20))]])
        check(result == .bytes(size), "a server that ignores the range still reports the size from its headers")
        check(StubProtocol.requests.count == 2, "at most one fallback request")
        result = await run(["HEAD": [.init(status: 404, headers: ["Content-Length": "9"])]])
        check(result == .fileUnavailable && StubProtocol.requests.count == 1, "a missing file is reported without a second request")
        result = await run(["HEAD": [.init(status: 200, headers: [:], fails: true)], "GET ranged": [.init(status: 200, headers: [:], fails: true)]])
        check(result == .unknown, "network failure is unknown, never a size")
        result = await run(["HEAD": [.init(status: 500, headers: [:])], "GET ranged": [.init(status: 500, headers: [:])]])
        check(result == .unknown, "server errors are unknown")

        // MARK: Status transitions
        typealias S = ZagSelfUpdateActionState
        func text(_ action: S, _ failure: ZagUpdateCardStatus.Failure? = nil, _ size: ZagUpdateDownloadSize = .bytes(size)) -> String {
            ZagUpdateCardStatus.text(action: action, failure: failure, size: size)
        }
        let formatted = ZagUpdateDownloadSize.bytes(size).text
        check(text(.idle) == formatted, "available: the download size")
        check(text(.idle, nil, .checking) == "Checking download size…" && text(.idle, nil, .unknown) == "Download size unavailable"
              && text(.idle, nil, .fileUnavailable) == "Update file unavailable", "available without a size: the honest missing-size text")
        check(text(.progress(message: "Downloading update...", fraction: 0.4)) == "Update requested...", "update requested while downloading")
        for message in ["Selecting signing certificate...", "Verifying IPA...", "Preparing signed update...", "Uploading..."] {
            check(text(.progress(message: message, fraction: nil)) == "Update requested...", "update requested during \(message)")
        }
        check(text(.handedOff) == "Update successful.", "completion pill: Update successful.")
        check(text(.awaitingVerification) == "Update not verified.", "unverified attempt is a failure, never success")
        check(text(.idle, .failed) == "Update failed." && text(.idle, .cancelled) == "Update cancelled.", "failures and cancellation")
        check(text(.progress(message: "Downloading update...", fraction: nil), .failed) == "Update requested...", "retry after failure: requested again")
        check(text(.idle, nil) == formatted, "after recovery the size returns")

        // The success text follows exactly the pill's success transition.
        let handoffs: [ZagUpdateHandoffState] = [.none, .waiting, .stagedOnDevice, .reportedComplete, .uncertain]
        for handoff in handoffs {
            for running in [false, true] {
                let state = S.pendingAttempt(handoff: handoff, installerRunning: running, installerTitle: "Installing...",
                                             installerFraction: 0.5, preparingMessage: "Preparing installation handoff...")
                let success = text(state) == "Update successful."
                check(success == state.showsSuccess && success == handoff.isSuccessfulHandoff,
                      "handoff \(handoff), installer running \(running): success text iff green pill")
            }
        }
        for state in [S.idle, .progress(message: "Downloading update...", fraction: 1), .awaitingVerification] {
            for failure in [nil, ZagUpdateCardStatus.Failure.failed, .cancelled] {
                check(text(state, failure) != "Update successful.", "no success text without the pill: \(state), \(String(describing: failure))")
            }
        }

        // MARK: Crossfade consistency
        var fade = ZagCrossfadeTextState("59.5 MB")
        check(!fade.request("59.5 MB") && fade.visible && !fade.fadingOut, "same text: no animation")
        check(fade.request("Update requested...") && !fade.visible && fade.fadingOut, "new text fades the old one out first")
        check(!fade.request("Update successful.") && fade.shown == "59.5 MB", "rapid change during fade-out only retargets")
        check(fade.fadeOutArrived() && fade.shown == "Update successful." && !fade.visible, "swap shows only the newest text, while invisible")
        check(!fade.fadeOutArrived(), "a stale completion cannot swap again")
        fade.reveal()
        check(fade.visible && fade.shown == "Update successful.", "newest text fades in")
        check(fade.request("Update failed.") && !fade.visible, "change during fade-in fades out from where it is")
        check(!fade.request("Update successful.") && fade.target == "Update successful.", "change back during fade-out retargets")
        check(fade.fadeOutArrived() && fade.shown == "Update successful.", "returning to the shown text ends on it")
        fade.reveal()
        var stale = ZagCrossfadeTextState("A")
        check(!stale.fadeOutArrived() && stale.visible && stale.shown == "A", "arrival without a fade changes nothing")
        _ = stale.request("B")
        stale.reveal()
        check(!stale.visible, "reveal is refused mid-fade-out")
        print("SUCCESS: \(passed) update card status checks passed")
    }
}
