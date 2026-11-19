import Foundation

/// One HTTPS request made for the free-account services (anisette providers
/// and, later, Apple). Services build these and send them through a
/// `ZagHTTPTransport`, so tests replace the network with a simulation.
struct ZagHTTPRequest: Sendable {
	var url: URL
	var method: String = "GET"
	var headers: [String: String] = [:]
	var body: Data?
	var timeout: TimeInterval = 20
}

struct ZagHTTPResponse: Sendable {
	let statusCode: Int
	let headers: [String: String]
	let body: Data
}

enum ZagTransportError: Error, Equatable, Sendable {
	case insecureURL
	case hostNotAllowed(String)
	case invalidHeader
	case invalidTimeout
	case timedOut
	case cancelled
	case offline
	case responseTooLarge
	/// Any other failure; the code is URLError's, never a message that could
	/// contain request data.
	case failed(code: Int)
}

protocol ZagHTTPTransport: Sendable {
	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse
}

/// Rules every request must meet before any transport sends it.
struct ZagTransportPolicy: Sendable {
	/// Lower-case host names. Redirects must stay within them too.
	let allowedHosts: Set<String>
	var maximumResponseBytes = 1 << 20
	var maximumTimeout: TimeInterval = 60

	init(allowedHosts: Set<String>) {
		self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
	}

	func validate(_ request: ZagHTTPRequest) throws {
		try validate(url: request.url)
		guard request.timeout > 0, request.timeout <= maximumTimeout else { throw ZagTransportError.invalidTimeout }
		for (name, value) in request.headers {
			let badName = name.isEmpty || name.contains(":") || name.unicodeScalars.contains { $0.value < 0x21 || $0.value > 0x7E }
			let badValue = value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
			if badName || badValue { throw ZagTransportError.invalidHeader }
		}
	}

	func validate(url: URL) throws {
		guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
			  let host = url.host?.lowercased(), !host.isEmpty else { throw ZagTransportError.insecureURL }
		guard allowedHosts.contains(host) else { throw ZagTransportError.hostNotAllowed(host) }
	}
}

/// URLSession without cookies, cache or stored credentials. Server trust is
/// left to the system: no delegate method overrides TLS validation. Redirects
/// are followed only to allowed HTTPS hosts.
final class ZagURLSessionTransport: NSObject, ZagHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
	let policy: ZagTransportPolicy
	private var session: URLSession!

	init(policy: ZagTransportPolicy) {
		self.policy = policy
		super.init()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		configuration.urlCredentialStorage = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.waitsForConnectivity = false
		configuration.timeoutIntervalForResource = policy.maximumTimeout
		session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		try policy.validate(request)
		var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
		urlRequest.httpMethod = request.method
		urlRequest.httpBody = request.body
		urlRequest.httpShouldHandleCookies = false
		for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
		do {
			let (data, response) = try await session.data(for: urlRequest)
			guard let http = response as? HTTPURLResponse else { throw ZagTransportError.failed(code: 0) }
			guard data.count <= policy.maximumResponseBytes else { throw ZagTransportError.responseTooLarge }
			var headers: [String: String] = [:]
			for (key, value) in http.allHeaderFields {
				if let key = key as? String, let value = value as? String { headers[key] = value }
			}
			return ZagHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
		} catch let error as ZagTransportError {
			throw error
		} catch is CancellationError {
			throw ZagTransportError.cancelled
		} catch let error as URLError {
			throw Self.map(error)
		}
	}

	static func map(_ error: URLError) -> ZagTransportError {
		switch error.code {
		case .timedOut: return .timedOut
		case .cancelled: return .cancelled
		case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
		default: return .failed(code: error.code.rawValue)
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		guard let url = request.url, (try? policy.validate(url: url)) != nil else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}
}

/// Runs `operation` with a deadline. On expiry the operation is cancelled and
/// `ZagTransportError.timedOut` is thrown.
enum ZagDeadline {
	static func run<T: Sendable>(
		seconds: TimeInterval,
		_ operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await operation() }
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
				throw ZagTransportError.timedOut
			}
			defer { group.cancelAll() }
			guard let first = try await group.next() else { throw ZagTransportError.cancelled }
			return first
		}
	}
}
