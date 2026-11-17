import Foundation
import CryptoKit

/// SHA-256 verification of a package file against a signed digest.
///
/// The importer calls this on its own private working copy, the exact file
/// it then extracts, so the verified bytes are the imported bytes.
enum ZagPackageIntegrity {
	enum Failure: Error, LocalizedError {
		case checksumMismatch
		case unexpectedResponse

		var errorDescription: String? {
			switch self {
			case .checksumMismatch: "The package does not match its signed SHA-256."
			case .unexpectedResponse: "The package download did not return HTTP 200."
			}
		}
	}

	/// Streams the file in 1 MiB chunks so large IPAs are not held in memory.
	static func sha256(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	static func verify(_ url: URL, expectedSHA256: String) throws {
		guard try sha256(of: url).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			throw Failure.checksumMismatch
		}
	}

    static func sha256InBackground(of url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) { try sha256(of: url) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// Cached packages can be large. Keep bounded-memory verification off the UI
    /// actor and propagate parent cancellation to the hashing worker.
    static func verifyInBackground(_ url: URL, expectedSHA256: String) async throws {
        let worker = Task.detached(priority: .utility) {
            try verify(url, expectedSHA256: expectedSHA256)
        }
        try await withTaskCancellationHandler {
            try await worker.value
            try Task.checkCancellation()
        } onCancel: {
            worker.cancel()
        }
    }

	/// Streams `url` into `file`, which the caller creates and owns, hashing
	/// each chunk as it is written, and throws unless the body matches
	/// `expectedSHA256`. Memory use is bounded by URLSession's chunk size.
	/// Nothing else is written: no download task, so no temporary file that
	/// outlives a dropped connection. Cancelling the calling task cancels the
	/// request. On any error `file` holds unverified bytes and must be removed.
	static func download(
		_ url: URL,
		expectedSHA256: String,
		session: URLSession,
		to file: URL,
        progress: (@Sendable (ZagUpdateByteProgress) -> Void)? = nil
	) async throws {
		let handle = try FileHandle(forWritingTo: file)
		defer { try? handle.close() }
		let receiver = StreamingReceiver(handle: handle, progress: progress)
		let task = session.dataTask(with: url)
		task.delegate = receiver
		let digest = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				receiver.continuation = continuation
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
		try Task.checkCancellation()
		try handle.synchronize()
		guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			throw Failure.checksumMismatch
		}
	}

	/// URLSession calls these serially on its delegate queue.
	private final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
		private let handle: FileHandle
		private var hasher = SHA256()
		private var failure: Error?
		var continuation: CheckedContinuation<String, Error>?
        private let progress: (@Sendable (ZagUpdateByteProgress) -> Void)?
        private var received: Int64 = 0
        private var expected: Int64?
        private var sampler = ZagUpdateProgressSampler()

        init(handle: FileHandle, progress: (@Sendable (ZagUpdateByteProgress) -> Void)?) {
            self.handle = handle
            self.progress = progress
        }

        private func publishProgress(finished: Bool = false) {
            guard let value = sampler.receive(bytes: received, expected: expected,
                                              now: ProcessInfo.processInfo.systemUptime,
                                              finished: finished) else { return }
            progress?(value)
        }

		func urlSession(
			_ session: URLSession,
			dataTask: URLSessionDataTask,
			didReceive response: URLResponse,
			completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
		) {
			guard (response as? HTTPURLResponse)?.statusCode == 200 else {
				failure = Failure.unexpectedResponse
				completionHandler(.cancel)
				return
			}
            expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            publishProgress()
			completionHandler(.allow)
		}

		func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
			guard failure == nil else { return }
			do {
				try handle.write(contentsOf: data)
				hasher.update(data: data)
                received += Int64(data.count)
                publishProgress()
			} catch {
				failure = error
				dataTask.cancel()
			}
		}

		func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
			if let error = failure ?? error {
				continuation?.resume(throwing: error)
			} else {
                publishProgress(finished: true)
				continuation?.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
			}
			continuation = nil
		}
	}
}
