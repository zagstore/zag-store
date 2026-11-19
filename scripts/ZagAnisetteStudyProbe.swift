import Foundation

// One availability request for the anisette reliability study (stages 1-2,
// docs/free-developer-accounts/ANISETTE-STUDY.md), through the app's own
// transport: HTTPS only, allow-listed host, system TLS validation. It asks
// for /robots.txt, never an anisette endpoint, and keeps only the status
// and latency; the response body is discarded unread.
//
// Usage: probe <host>    prints: <status> <latency-ms> | error <category> <latency-ms>

@main struct ZagAnisetteStudyProbe {
	static func main() async {
		guard CommandLine.arguments.count == 2 else {
			print("error usage 0")
			exit(2)
		}
		let host = CommandLine.arguments[1].lowercased()
		guard let url = URL(string: "https://\(host)/robots.txt") else {
			print("error usage 0")
			exit(2)
		}
		let transport = ZagURLSessionTransport(policy: ZagTransportPolicy(allowedHosts: [host]))
		let started = Date()
		do {
			let response = try await transport.send(ZagHTTPRequest(url: url, timeout: 20))
			print("\(response.statusCode) \(milliseconds(since: started))")
		} catch let error as ZagTransportError {
			print("error \(category(error)) \(milliseconds(since: started))")
		} catch {
			print("error other \(milliseconds(since: started))")
		}
	}

	static func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

	static func category(_ error: ZagTransportError) -> String {
		switch error {
		case .timedOut: return "timeout"
		case .offline: return "offline"
		case .cancelled: return "cancelled"
		case .responseTooLarge: return "too-large"
		case .insecureURL, .hostNotAllowed, .invalidHeader, .invalidTimeout: return "policy"
		case .failed(let code): return "failed\(code)"
		}
	}
}
