import Foundation
import CryptoKit

private final class StreamFixtureProtocol: URLProtocol {
    static let payload = Data(repeating: 0x5a, count: 512 * 1024)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "update.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let known = request.url?.path != "/unknown"
        let status = request.url?.path == "/rejected" ? 403 : 200
        let headers = known ? ["Content-Length": String(Self.payload.count)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            for offset in stride(from: 0, to: Self.payload.count, by: 4096) {
                client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<min(offset + 4096, Self.payload.count)))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ZagUpdateByteProgress] = []
    private var onMain = false
    func append(_ progress: ZagUpdateByteProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(progress)
        onMain = onMain || Thread.isMainThread
    }
    func snapshot() -> ([ZagUpdateByteProgress], Bool) {
        lock.lock(); defer { lock.unlock() }
        return (values, onMain)
    }
}

@main struct StreamingProgressTests {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS: \(label)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let digest = SHA256.hash(data: StreamFixtureProtocol.payload).map { String(format: "%02x", $0) }.joined()
        for path in ["known", "unknown"] {
            let file = folder.appendingPathComponent(path)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let capture = ProgressCapture()
            try await ZagPackageIntegrity.download(URL(string: "https://update.test/\(path)")!, expectedSHA256: digest,
                                                   session: session, to: file, progress: { capture.append($0) })
            let (values, onMain) = capture.snapshot()
            check(try Data(contentsOf: file) == StreamFixtureProtocol.payload, "\(path) streams the exact verified bytes")
            check(values.first?.received == 0 && values.last?.received == Int64(StreamFixtureProtocol.payload.count), "\(path) publishes real first/final byte counts")
            check(zip(values, values.dropFirst()).allSatisfy { $0.received <= $1.received }, "\(path) byte publications never move backwards")
            check(!onMain, "\(path) receiver writes/hashes and publishes on the delegate queue, not the UI thread")
            if path == "known" {
                check(values.last?.fraction == 1 && values.last?.expected == Int64(StreamFixtureProtocol.payload.count), "known length provides an accurate fraction")
            } else {
                check(values.allSatisfy { $0.fraction == nil }, "unknown length never fabricates a percentage")
            }
            try await ZagPackageIntegrity.verifyInBackground(file, expectedSHA256: digest)
            check(true, "\(path) cached verification uses the same SHA-256")
        }
        let mismatch = folder.appendingPathComponent("mismatch")
        FileManager.default.createFile(atPath: mismatch.path, contents: nil)
        do {
            try await ZagPackageIntegrity.download(URL(string: "https://update.test/known")!, expectedSHA256: String(repeating: "0", count: 64), session: session, to: mismatch)
            preconditionFailure("Wrong digest accepted")
        } catch ZagPackageIntegrity.Failure.checksumMismatch { check(true, "progress does not bypass checksum rejection") }
        let rejected = folder.appendingPathComponent("rejected")
        FileManager.default.createFile(atPath: rejected.path, contents: nil)
        do {
            try await ZagPackageIntegrity.download(URL(string: "https://update.test/rejected")!, expectedSHA256: digest, session: session, to: rejected)
            preconditionFailure("HTTP refusal accepted")
        } catch { check(true, "non-200 download remains rejected") }
        let cancelled = folder.appendingPathComponent("cancelled")
        FileManager.default.createFile(atPath: cancelled.path, contents: nil)
        let task = Task {
            try await ZagPackageIntegrity.download(URL(string: "https://update.test/known")!, expectedSHA256: digest, session: session, to: cancelled)
        }
        task.cancel()
        do {
            try await task.value
            preconditionFailure("Cancelled work accepted")
        } catch { check(true, "cancelled preparation cannot report successful download") }
        print("SUCCESS: \(checks) real streaming/progress checks passed")
    }
}
