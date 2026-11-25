#if canImport(ZagAppleAuth)
import ZagAppleAuth
#endif
import Foundation
import Security
import os

/// On-device Apple *machine* identity (anisette / ADI) via the vendored
/// apple-auth Mac-algorithm implementation (`AppleAuthCore/apple-auth`). This
/// type owns the machine identity only — the ADI provisioning profile and its
/// device identifiers. It never holds an Apple Account password, session token,
/// DSID or signing key; those live in the account secret store
/// (`ZagFreeAccountSecretKind.session` / `.signingPrivateKey`), keyed by
/// account. Machine and account secrets never mix.
///
/// Provisioning (the one-time `lookup → midStartProvisioning →
/// midFinishProvisioning` exchange) reaches Apple only when explicitly allowed;
/// deriving fresh anisette headers from an already-provisioned profile is local
/// and never contacts Apple. No Android library, Unicorn, desktop companion or
/// external anisette server is involved at runtime.

enum ZagAppleAuthError: Error, Equatable, Sendable {
	case unavailable          // the ZagAppleAuth module is not linked in this build
	case notProvisioned       // no profile and provisioning not allowed
	case provisioningFailed(Int)
	case transportBlocked
	case malformedHeaders
	case keychain(OSStatus)
}

/// Persisted machine state (the apple-auth client snapshot) in the
/// this-device-only Keychain, never synchronised, never restored to another
/// device. Keyed by a machine *scope* (default `"device"`), separate from the
/// account secret store's service.
struct ZagAppleAuthMachineStore: Sendable {
	let service: String
	init(service: String = "app.zagstore.anisette.appleauth.v1") { self.service = service }

	private func query(_ scope: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: scope,
		 kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
	}

	func load(scope: String) throws -> Data? {
		var q = query(scope)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		let status = SecItemCopyMatching(q as CFDictionary, &out)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw ZagAppleAuthError.keychain(status) }
		return out as? Data
	}

	func save(_ data: Data, scope: String) throws {
		var add = query(scope)
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecSuccess { return }
		guard status == errSecDuplicateItem else { throw ZagAppleAuthError.keychain(status) }
		let update = [kSecValueData as String: data,
					  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
		let s = SecItemUpdate(query(scope) as CFDictionary, update as CFDictionary)
		guard s == errSecSuccess else { throw ZagAppleAuthError.keychain(s) }
	}

	func delete(scope: String) throws {
		let s = SecItemDelete(query(scope) as CFDictionary)
		guard s == errSecSuccess || s == errSecItemNotFound else { throw ZagAppleAuthError.keychain(s) }
	}
}

/// A URLSession transport restricted to Apple provisioning endpoints: HTTPS
/// only, `*.apple.com` only, at most three requests, no redirects, no retries,
/// no background. When `allowNetwork` is false it refuses every request, which
/// guarantees no Apple contact while still letting an already-provisioned
/// profile derive headers locally.
final class ZagAppleAuthTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	let allowNetwork: Bool
	private let lock = NSLock()
	private var count = 0
	private(set) var log: [String] = []
	/// Per-request diagnostics: the HTTP status and an allowlisted, sanitized
	/// subset of response-header metadata. Raw headers and bodies are never kept.
	private(set) var httpTrace: [(status: Int, metadata: [String: String])] = []
	private let maxRequests: Int
	/// HTTP methods the transport will issue. The SRP-only sign-in keeps the
	/// strict GET/POST set; the 2FA flow additionally needs PUT (SMS delivery).
	private let allowedMethods: Set<String>
	/// When set, requests are bounded by separate per-class ceilings instead of a
	/// single cap, and every verification-initiation request is gated on consent.
	private let twoFactorPolicy: ZagTwoFactorPolicy?
	/// Blocking consent gate: asked before the first verification-initiation
	/// request, returns whether the user consented to delivery. nil denies.
	private let consentGate: (() -> Bool)?
	private var classCounts: [ZagAppleAuthRequestClass: Int] = [:]

	init(allowNetwork: Bool, maxRequests: Int = 3,
		 allowedMethods: Set<String> = ["GET", "POST"],
		 twoFactorPolicy: ZagTwoFactorPolicy? = nil,
		 consentGate: (() -> Bool)? = nil) {
		self.allowNetwork = allowNetwork
		self.maxRequests = maxRequests
		self.allowedMethods = allowedMethods
		self.twoFactorPolicy = twoFactorPolicy
		self.consentGate = consentGate
	}

	/// Per-class accepted-request counts, for the sanitized report. No URL,
	/// header or body is retained — only how many of each class were allowed.
	var acceptedByClass: [String: Int] { lock.withLock {
		var out: [String: Int] = [:]
		for (k, v) in classCounts { out[k.rawValue] = v }
		return out
	} }

	/// Why requests were refused (class + reason only), for diagnosing where a
	/// bounded sequence stopped. No URL, header or body.
	private(set) var refusals: [(cls: String, reason: String)] = []
	var refusalList: [[String: String]] { lock.withLock { refusals.map { ["class": $0.cls, "reason": $0.reason] } } }

	/// The only response headers ever recorded — non-sensitive, for diagnosing a
	/// 503/429 (transient vs persistent). Lower-cased for case-insensitive match.
	static let allowedResponseHeaders: Set<String> = ["retry-after"]

	/// Sanitizes an allowlisted header value: strips control characters (so a
	/// value cannot inject newlines or escapes into the report), collapses
	/// whitespace, length-bounds it, and returns nil when absent or empty. The
	/// raw header is never stored.
	static func sanitizeHeaderValue(_ raw: String?, limit: Int = 64) -> String? {
		guard let raw else { return nil }
		let decontrolled = String(String.UnicodeScalarView(raw.unicodeScalars.map {
			($0.value < 0x20 || $0.value == 0x7F) ? UnicodeScalar(0x20)! : $0
		}))
		let collapsed = decontrolled.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
		if collapsed.isEmpty { return nil }
		return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
	}

	/// Whether any request actually went to Apple (distinguishes a transport
	/// failure from a server rejection).
	var reachedApple: Bool { lock.withLock { count > 0 } }

	/// How many requests actually went to Apple. For the sign-in sequence this
	/// identifies the stage a rejection occurred at (1 = lookup, 2 = SRP init,
	/// 3 = SRP complete) without exposing any request content.
	var requestCount: Int { lock.withLock { count } }

	/// How many times a request was refused because the ceiling was reached — a
	/// positive signal that the library tried to issue a further request (e.g. a
	/// 2FA-initiation request after SRP completion) that we deliberately blocked,
	/// as opposed to a transport/network failure on an accepted request.
	private var ceilingRefusals = 0
	var hitCeiling: Bool { lock.withLock { ceilingRefusals > 0 } }

	private lazy var session: URLSession = {
		let cfg = URLSessionConfiguration.ephemeral
		cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		cfg.httpShouldSetCookies = false
		cfg.timeoutIntervalForRequest = 30
		cfg.waitsForConnectivity = false
		return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
	}()

	func urlSession(_ s: URLSession, task: URLSessionTask,
					willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
					completionHandler: @escaping (URLRequest?) -> Void) {
		completionHandler(nil)   // never follow a redirect
	}

	func perform(url: String, method: String, headers: [String: String], body: Data) -> (Int, Data, [[String]])? {
		guard allowNetwork else { lock.lock(); log.append("BLOCKED (offline)"); refusals.append(("transport", "offline")); lock.unlock(); return nil }
		guard let u = URL(string: url), u.scheme == "https", let host = u.host, host.hasSuffix(".apple.com") else {
			lock.lock(); log.append("REFUSED (host/scheme)"); refusals.append(("transport", "host-or-scheme")); lock.unlock(); return nil
		}
		guard allowedMethods.contains(method) else {
			lock.lock(); log.append("REFUSED (method)"); refusals.append(("transport", "method-\(method.lowercased())")); lock.unlock(); return nil
		}
		if let policy = twoFactorPolicy {
			let hasCodeHeader = headers.contains { $0.key.lowercased() == "security-code" }
			let cls = ZagAppleAuthRequestClass.classify(url: url, method: method, hasSecurityCodeHeader: hasCodeHeader)
			// Consent gate (outside the lock, as it blocks on the UI): every
			// verification-initiation request requires explicit consent. The first
			// non-GsService2 request of the login is always one of these, so no
			// delivery/verification request can fire without consent.
			if cls == .verificationInitiation, !(consentGate?() ?? false) {
				lock.lock(); ceilingRefusals += 1; refusals.append((cls.rawValue, "no-consent")); log.append("REFUSED (no consent)"); lock.unlock(); return nil
			}
			lock.lock()
			let already = classCounts[cls] ?? 0
			guard already < policy.ceiling(for: cls), count < maxRequests else {
				ceilingRefusals += 1; refusals.append((cls.rawValue, "class-ceiling")); log.append("REFUSED (\(cls.rawValue) ceiling)"); lock.unlock(); return nil
			}
			classCounts[cls] = already + 1
			count += 1
			lock.unlock()
		} else {
			lock.lock()
			guard count < maxRequests else { ceilingRefusals += 1; log.append("REFUSED (ceiling)"); lock.unlock(); return nil }
			count += 1
			lock.unlock()
		}
		var req = URLRequest(url: u)
		req.httpMethod = method
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		if method != "GET" { req.httpBody = body }
		let sem = DispatchSemaphore(value: 0)
		var out: (Int, Data, [[String]])?
		var captured: [String: String] = [:]
		session.dataTask(with: req) { data, resp, _ in
			defer { sem.signal() }
			guard let http = resp as? HTTPURLResponse else { return }
			var pairs: [[String]] = []
			for (k, v) in http.allHeaderFields { pairs.append([String(describing: k), String(describing: v)]) }
			// Record ONLY allowlisted, sanitized response metadata for diagnostics.
			// The full header set (`pairs`) is handed to apple-auth transiently
			// for the protocol but is never persisted.
			for name in ZagAppleAuthTransport.allowedResponseHeaders {
				if let v = ZagAppleAuthTransport.sanitizeHeaderValue(http.value(forHTTPHeaderField: name)) { captured[name] = v }
			}
			out = (http.statusCode, data ?? Data(), pairs)
		}.resume()
		sem.wait()
		lock.lock()
		log.append("\(method) \(host) -> \(out.map { String($0.0) } ?? "err")")
		if let out { httpTrace.append((status: out.0, metadata: captured)) }
		lock.unlock()
		return out
	}
}

#if canImport(ZagAppleAuth)
private let zagAppleAuthTransportCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<aauth_http_request>?, UnsafeMutablePointer<aauth_http_response>?) -> Int32 = { ctx, request, response in
	guard let ctx, let request, let response else { return 1 }
	let t = Unmanaged<ZagAppleAuthTransport>.fromOpaque(ctx).takeUnretainedValue()
	let r = request.pointee
	let url = r.url.map { String(cString: $0) } ?? ""
	let method = r.method.map { String(cString: $0) } ?? "GET"
	var headers: [String: String] = [:]
	if let hj = r.headers_json, let d = String(cString: hj).data(using: .utf8),
	   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
		for (k, v) in obj { headers[k] = String(describing: v) }
	}
	var body = Data()
	if let b = r.body, r.body_size > 0 { body = Data(bytes: b, count: r.body_size) }
	guard let (status, respBody, pairs) = t.perform(url: url, method: method, headers: headers, body: body) else { return 1 }
	response.pointee.status = status
	var bodyBuf = aauth_client_buffer()
	if aauth_client_buffer_alloc(respBody.count, &bodyBuf) == AAUTH_OK, let dst = bodyBuf.data { respBody.copyBytes(to: dst, count: respBody.count) }
	response.pointee.body = bodyBuf
	let hdr = (try? JSONSerialization.data(withJSONObject: pairs)) ?? Data("[]".utf8)
	var hdrBuf = aauth_client_buffer()
	if aauth_client_buffer_alloc(hdr.count, &hdrBuf) == AAUTH_OK, let dst = hdrBuf.data { hdr.copyBytes(to: dst, count: hdr.count) }
	response.pointee.headers_json = hdrBuf
	return 0
}
#endif

/// The device environment the machine presents. Both run apple-auth's Mac ADI
/// algorithm (`ProfilePlatform::mac`); they differ only in the client-info
/// string and device fields, so `mac` is the internally-consistent pairing
/// (macOS client-info + Mac algorithm) and `iphone` is the hybrid (iPhone
/// client-info + Mac algorithm) used for the provisioned baseline profile.
enum ZagAppleAuthPlatform: String, Sendable, Equatable {
	case iphone
	case mac
	/// Mac ADI algorithm/identity exactly like `.mac`, but presenting the legacy
	/// `Mac OS X;` client-info that Apple's GSA edge currently accepts (the
	/// `macOS;` token has returned HTTP 503 since 2026-11-20 — see
	/// APPLE-AUTH-SIGNIN-503-ASSESSMENT.md). The client-info and User-Agent are
	/// supplied through apple-auth's supported `headers_json` override, applied
	/// consistently to provisioning, anisette and auth; no preset is modified.
	case macLegacy = "mac-legacy"

	/// The OS token the anisette client-info must carry for this platform.
	var clientInfoOS: String {
		switch self {
		case .mac: return "macOS"
		case .macLegacy: return "Mac OS X"
		case .iphone: return "iPhone OS"
		}
	}

	/// Whether this platform runs apple-auth's Mac ADI algorithm (`.mac` and
	/// `.macLegacy` share the identical algorithm and identity derivation).
	var usesMacAlgorithm: Bool { self == .mac || self == .macLegacy }

	/// Allowlisted client-info / User-Agent overrides passed via apple-auth's
	/// `headers_json` (merged last, so they win in every header path). nil keeps
	/// apple-auth's computed defaults. Provenance of the `.macLegacy` values:
	/// the independently-confirmed working configuration from SideStore #1745 /
	/// LiveContainer #1744 (#1752). Difference from our `.mac` preset: the OS
	/// token `macOS;` → `Mac OS X;`, a current-format model/version, and the
	/// legacy akd User-Agent; the ADI algorithm and identity are unchanged.
	var headerOverrides: [String: String]? {
		guard self == .macLegacy else { return nil }
		return ["X-MMe-Client-Info": "<MacBookPro13,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
				"User-Agent": "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"]
	}
}

/// The on-device machine. A single actor serialises access to the underlying
/// apple-auth client, which is created, used and freed within each call.
actor ZagAppleAuthMachine {
	let scope: String
	let platform: ZagAppleAuthPlatform
	private let store: ZagAppleAuthMachineStore
	private let now: @Sendable () -> Date

	/// Sanitized stats from the most recent `anisetteHeaders` call — request
	/// count, whether Apple was reached, and per-request HTTP status codes
	/// (method/host/status only; never content). For the provisioning report.
	private(set) var lastRequestCount = 0
	private(set) var lastReachedApple = false
	private(set) var lastHTTPStatuses: [Int] = []
	/// Per-request sanitized trace (stage, status, allowlisted metadata) from the
	/// last provisioning call.
	private(set) var lastHTTPTrace: [ZagHTTPTraceEntry] = []

	/// Runs `body` with a C string for `s`, or a null pointer when `s` is nil.
	static func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
		if let s { return s.withCString { body($0) } }
		return body(nil)
	}

	/// Parses the transport's sanitized log ("POST host -> 200") into statuses.
	static func httpStatuses(_ log: [String]) -> [Int] {
		log.compactMap { line in
			guard let r = line.range(of: "-> [0-9]{3}$", options: .regularExpression) else { return nil }
			return Int(line[r].dropFirst(3))
		}
	}

	init(scope: String = "device", platform: ZagAppleAuthPlatform = .iphone,
		 store: ZagAppleAuthMachineStore = ZagAppleAuthMachineStore(), now: @escaping @Sendable () -> Date = { Date() }) {
		self.scope = scope
		self.platform = platform
		self.store = store
		self.now = now
	}

	static var isLinked: Bool {
		#if canImport(ZagAppleAuth)
		return true
		#else
		return false
		#endif
	}

	/// The machine for the production native Apple Account path — provisioning,
	/// sign-in and read-only inventory. It uses `.macLegacy`: the `Mac OS X;`
	/// client-info the current Apple GSA edge accepts (SideStore #1745 /
	/// LiveContainer #1744). The `.iphone` default is a hybrid (iPhone client-info
	/// with the Mac ADI algorithm) whose client-info the edge rejects, which is
	/// why a sign-in that reaches Apple came back rejected. The ADI algorithm and
	/// stored identity are identical to `.mac`/`.iphone` (all Mac-derived), so an
	/// existing `device`-scope profile is reused; only the on-the-wire client-info
	/// changes. One factory keeps provisioning, sign-in and inventory on the same
	/// platform and scope, with no cross-phase drift.
	static func nativeAccount() -> ZagAppleAuthMachine {
		ZagAppleAuthMachine(scope: "device", platform: .macLegacy)
	}

	/// Whether a provisioned machine profile is already stored (no network).
	func isProvisioned() -> Bool { (try? store.load(scope: scope)) != nil }

	/// Fresh anisette headers (`X-Apple-*` / `X-Mme-*`) for this machine. With
	/// `allowProvisioning` false, this never contacts Apple: it requires an
	/// already-provisioned profile and derives headers locally. With it true
	/// (an authorised live step only), a missing profile is provisioned once.
	func anisetteHeaders(allowProvisioning: Bool) async throws -> [String: String] {
		#if canImport(ZagAppleAuth)
		let persisted = try store.load(scope: scope)
		if persisted == nil && !allowProvisioning { throw ZagAppleAuthError.notProvisioned }
		let platform = self.platform
		// The apple-auth client calls are synchronous (the transport blocks on
		// the network); run them off the actor's executor. Each attempt gets a
		// fresh transport so its request counts/HTTP trace reflect that attempt.
		func attempt(_ state: Data?) async -> (Result<([String: String], Data), ZagAppleAuthError>, ZagAppleAuthTransport) {
			let transport = ZagAppleAuthTransport(allowNetwork: allowProvisioning)
			let r: Result<([String: String], Data), ZagAppleAuthError> = await withCheckedContinuation { continuation in
				DispatchQueue.global(qos: .userInitiated).async {
					continuation.resume(returning: Self.drive(persisted: state, transport: transport, platform: platform))
				}
			}
			return (r, transport)
		}
		var (result, transport) = await attempt(persisted)
		// ADI lifecycle recovery: a stored profile that Apple no longer accepts —
		// stale, incomplete, or written by an earlier build/platform — makes
		// aauth_client_provision fail. When we hold such a profile and are allowed
		// to provision, discard it and provision once from scratch. A provisioning
		// failure with no stored profile to blame is reported as-is (not retried).
		var recovered = false
		if allowProvisioning, persisted != nil, case .failure(.provisioningFailed) = result {
			try? store.delete(scope: scope)
			(result, transport) = await attempt(nil)
			recovered = true
		}
		lastRequestCount = transport.requestCount
		lastReachedApple = transport.reachedApple
		lastHTTPStatuses = Self.httpStatuses(transport.log)
		lastHTTPTrace = Self.httpTrace(transport.httpTrace, stageFor: Self.provisionStage)
		lastProvisionRecovered = recovered
		let (headers, snapshot) = try result.get()
		try store.save(snapshot, scope: scope)
		return Self.anisetteSubset(headers)
		#else
		throw ZagAppleAuthError.unavailable
		#endif
	}

	/// Whether the most recent `anisetteHeaders` call had to discard a stored ADI
	/// profile and re-provision from scratch (stale/invalid-profile recovery).
	private(set) var lastProvisionRecovered = false

	/// A sanitized provisioning diagnostic for the most recent `anisetteHeaders`
	/// attempt: the failing operation, the native status code, the provisioning
	/// stage (derived from how many requests were accepted) and the last HTTP
	/// status seen. No secrets — only operation, code, stage and status.
	func provisioningDiagnostic(code: Int) -> String {
		var parts = ["op provision", "code \(code)", "stage \(Self.provisionStage(requestCount: lastRequestCount))"]
		if let http = lastHTTPStatuses.last { parts.append("HTTP \(http)") }
		if lastProvisionRecovered { parts.append("after fresh re-provision") }
		return parts.joined(separator: " · ")
	}

	#if canImport(ZagAppleAuth)
	/// Creates an apple-auth client, restoring `persisted` state into RAM, runs
	/// `body` with it, then frees it. The client pointer is valid only inside
	/// `body`. Shared by the anisette and the gated sign-in paths so there is a
	/// single apple-auth client implementation.
	static func withClient<T>(persisted: Data?, transport: ZagAppleAuthTransport, platform: ZagAppleAuthPlatform,
		_ body: (OpaquePointer) -> Result<T, ZagAppleAuthError>) -> Result<T, ZagAppleAuthError> {
		let ctx = Unmanaged.passUnretained(transport).toOpaque()
		var options = aauth_client_options(transport: zagAppleAuthTransportCallback, observer: nil, clock: nil, context: ctx)
		var client: OpaquePointer?
		// Serial absent for every platform (no fabricated hardware identifier).
		// Device fields nil -> apple-auth's default software identity for the
		// platform. `.macLegacy` adds a client-info/User-Agent override through
		// apple-auth's supported headers_json (merged last in every header path);
		// it modifies no preset and shares `.mac`'s algorithm and identity.
		let overridesJSON = platform.headerOverrides.flatMap {
			(try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
		}
		let created: aauth_status = "".withCString { serial in
			var iphone = aauth_iphone_device(model: nil, ios_version: nil, ios_build: nil)
			let devicePlatform = platform.usesMacAlgorithm ? AAUTH_DEVICE_MAC : AAUTH_DEVICE_IPHONE
			return withUnsafePointer(to: &options) { opt in
				withUnsafePointer(to: &iphone) { ip in
					Self.withOptionalCString(overridesJSON) { hj in
						func make(statePtr: UnsafePointer<UInt8>?, stateSize: Int) -> aauth_status {
							var cfg = aauth_client_config(directory: nil, options: opt, platform: devicePlatform,
								mac_device: nil, iphone_device: platform.usesMacAlgorithm ? nil : ip, serial_number: serial,
								headers: nil, headers_json: hj, state: statePtr, state_size: stateSize)
							return aauth_client_create(&cfg, &client)
						}
						if let persisted { return persisted.withUnsafeBytes { make(statePtr: $0.bindMemory(to: UInt8.self).baseAddress, stateSize: persisted.count) } }
						return make(statePtr: nil, stateSize: 0)
					}
				}
			}
		}
		guard created == AAUTH_OK, let client else { return .failure(.provisioningFailed(Int(created.rawValue))) }
		defer { aauth_client_free(client) }
		return body(client)
	}

	/// Provisions if needed and permitted, reads the headers, and returns them
	/// with a fresh state snapshot.
	private static func drive(persisted: Data?, transport: ZagAppleAuthTransport, platform: ZagAppleAuthPlatform) -> Result<([String: String], Data), ZagAppleAuthError> {
		withClient(persisted: persisted, transport: transport, platform: platform) { client in
		let p = aauth_client_provision(client)
		guard p == AAUTH_OK else {
			return .failure(transport.allowNetwork ? .provisioningFailed(Int(p.rawValue)) : .transportBlocked)
		}
		var headerBuf = aauth_client_buffer()
		guard aauth_client_headers(client, &headerBuf) == AAUTH_OK, let hd = headerBuf.data else { return .failure(.malformedHeaders) }
		let headerData = Data(bytes: hd, count: headerBuf.size)
		aauth_client_buffer_free(&headerBuf)
		guard let obj = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { return .failure(.malformedHeaders) }
		var headers: [String: String] = [:]
		for (k, v) in obj { headers[k] = String(describing: v) }

		var stateBuf = aauth_client_buffer()
		guard aauth_client_state(client, &stateBuf) == AAUTH_OK, let sd = stateBuf.data else { return .failure(.malformedHeaders) }
		let snapshot = Data(bytes: sd, count: stateBuf.size)
		aauth_client_buffer_free(&stateBuf)
		return .success((headers, snapshot))
		}
	}
	#endif

	/// Only the anisette-relevant headers, which `ZagAnisetteData` accepts.
	static func anisetteSubset(_ headers: [String: String]) -> [String: String] {
		headers.filter { name, _ in
			let l = name.lowercased()
			return l.hasPrefix("x-apple-") || l.hasPrefix("x-mme-")
		}
	}

	/// Offline consistency check: the anisette `X-MMe-Client-Info` must name the
	/// OS token for `platform` (macOS for a Mac identity, iPhone OS otherwise).
	/// Guards against a client-info / algorithm mismatch — the leading -22410
	/// hypothesis — within a single provisioned identity.
	static func clientInfoConsistent(_ headers: [String: String], platform: ZagAppleAuthPlatform) -> Bool {
		guard let info = headers.first(where: { $0.key.lowercased() == "x-mme-client-info" })?.value else { return false }
		return info.contains(platform.clientInfoOS)
	}

	/// The GrandSlam status code (`ec`) embedded in an apple-auth error message
	/// (e.g. `-80045`). `ec` values are negative, so only a negative integer is
	/// matched — an HTTP status or SRP iteration count is never misread as a
	/// rejection code. The code is a public, non-sensitive constant; the rest of
	/// the message is never surfaced. Returns nil when no `ec` is present.
	static func grandSlamCode(_ text: String) -> Int? {
		guard let r = text.range(of: "-[0-9]{4,6}", options: .regularExpression) else { return nil }
		return Int(text[r])
	}

	/// An Apple edge HTTP failure (e.g. 503 / 429) reported by apple-auth before
	/// any `ec`, distinct from a GrandSlam rejection. Returns the status or nil.
	static func grandSlamHTTPStatus(_ text: String) -> Int? {
		guard let r = text.range(of: "HTTP [0-9]{3}", options: .regularExpression) else { return nil }
		return Int(text[r].dropFirst(5))
	}

	/// The sign-in stage from the request count: 1 lookup, 2 SRP init, 3 SRP
	/// complete. Non-sensitive.
	static func signInStage(requestCount: Int) -> String {
		switch requestCount {
		case ..<1: return "pre-request"
		case 1: return "lookup"
		case 2: return "srp-init"
		default: return "srp-complete"
		}
	}

	/// Classifies a library `AAUTH_NETWORK_ERROR` after a sign-in attempt. It is
	/// `twoFactorRequiredAtCeiling` ONLY when a request was refused at the
	/// ceiling after every accepted request returned HTTP 200 — the library
	/// issues that (post-completion) request only after verifying Apple's M2
	/// proof and an unauthenticated account-state transition, so the SRP proof is
	/// positively established. Otherwise it is a genuine transport failure. Never
	/// derived from HTTP 200 alone.
	static func networkErrorOutcome(hitCeiling: Bool, all200: Bool) -> ZagAppleAuthSignInOutcome {
		(hitCeiling && all200) ? .twoFactorRequiredAtCeiling : .transportFailed
	}

	/// The provisioning stage from the request count: 1 lookup, 2 start, 3
	/// finish. Non-sensitive; parallels `signInStage` for the trace labels.
	static func provisionStage(requestCount: Int) -> String {
		switch requestCount {
		case ..<1: return "pre-request"
		case 1: return "lookup"
		case 2: return "start-provisioning"
		default: return "finish-provisioning"
		}
	}

	/// Builds a sanitized per-request trace from the transport's recorded
	/// (status, allowlisted-metadata) list, labelling each request with its
	/// stage. Carries no header beyond the allowlist and no body.
	static func httpTrace(_ raw: [(status: Int, metadata: [String: String])],
						   stageFor: (Int) -> String) -> [ZagHTTPTraceEntry] {
		raw.enumerated().map { index, entry in
			ZagHTTPTraceEntry(stage: stageFor(index + 1), status: entry.status, metadata: entry.metadata)
		}
	}

	/// Apple's human-readable `em` message, surfaced by the vendored patch as
	/// `em=[…]`. Always sanitized (emails/tokens/identifiers redacted via
	/// `ZagSensitiveRedactor`), control characters stripped and length-bounded.
	/// The raw message is never returned, stored or printed. Returns nil when no
	/// well-formed `em=[…]` is present.
	static func grandSlamMessage(_ text: String, limit: Int = 160) -> String? {
		guard let open = text.range(of: "em=[") else { return nil }
		let rest = text[open.upperBound...]
		guard let close = rest.range(of: "]") else { return nil }   // malformed / unterminated
		let raw = String(rest[..<close.lowerBound])
		if raw.isEmpty { return nil }
		return sanitizeAppleMessage(raw, limit: limit)
	}

	/// Redacts, de-controls and length-bounds an Apple message for diagnostics.
	static func sanitizeAppleMessage(_ raw: String, limit: Int = 160) -> String {
		let redacted = ZagSensitiveRedactor.redact(raw)
		let decontrolled = String(String.UnicodeScalarView(redacted.unicodeScalars.map {
			($0.value < 0x20 || $0.value == 0x7F) ? UnicodeScalar(0x20)! : $0
		}))
		let collapsed = decontrolled.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
		return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
	}

	/// EXPERIMENT-ONLY, gated. Performs at most one GrandSlam SRP sign-in using
	/// this machine's existing provisioned profile (no re-provisioning) and the
	/// on-device anisette it already generates — the same apple-auth client as
	/// the anisette path, never a parallel implementation. Detects a 2FA
	/// challenge and cancels it (never submits a code or triggers an SMS). The
	/// account session is freed immediately and never persisted; the password
	/// is used once and never stored, logged or returned. Returns only a
	/// classification. Requires an authorised live run (`allowNetwork`).
	func signInExperiment(email: String, password: String, allowNetwork: Bool, maxRequests: Int = 6) async throws -> ZagAppleAuthSignInReport {
		#if canImport(ZagAppleAuth)
		guard let persisted = try store.load(scope: scope) else { return ZagAppleAuthSignInReport(outcome: .notProvisioned) }
		// Bounded by `maxRequests`, no retries. The SRP sequence is lookup + SRP
		// init + SRP complete (3); a hard cap of 3 refuses any further request,
		// so no 2FA-delivery/verification request can fire (a 2FA requirement is
		// still detected from the complete response and cancelled, never
		// submitted). With allowNetwork false the transport refuses everything.
		let transport = ZagAppleAuthTransport(allowNetwork: allowNetwork, maxRequests: maxRequests)
		let sentinel = ZagTwoFactorSentinel()
		let platform = self.platform
		return await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: Self.driveSignIn(persisted: persisted, transport: transport,
															   email: email, password: password, sentinel: sentinel, platform: platform))
			}
		}
		#else
		throw ZagAppleAuthError.unavailable
		#endif
	}

	/// The supervised, interactive 2FA sign-in. Completes the GrandSlam exchange
	/// past the 2FA gate using apple-auth's real callbacks, driven by the
	/// `coordinator` (explicit consent before any delivery, phone selection when
	/// offered, a SecureField code on a separate action, cancel throughout).
	/// Bounds: one sequence, no retries, separate per-class ceilings (5 / 2 / 1).
	/// Verification method is AUTOMATIC — it follows the account's actual 2FA
	/// configuration rather than forcing SMS or trusted-device. A session is
	/// retained only when the login positively returns AAUTH_OK with valid
	/// session material. Requires an authorised live run.
	#if canImport(SwiftUI)
	func signInWith2FA(email: String, password: String, coordinator: ZagTwoFactorCoordinator, allowNetwork: Bool = true, includeDeveloperSession: Bool = false) async throws -> ZagAppleAuthSignInReport {
		#if canImport(ZagAppleAuth)
		guard let persisted = try store.load(scope: scope) else { return ZagAppleAuthSignInReport(outcome: .notProvisioned) }
		var policy = ZagTwoFactorPolicy()   // authentication 5, verification-initiation 2, code-submission 1
		// One extra authentication-class request (the apptokens POST GsService2)
		// when the developer session is exchanged from the fresh session.
		if includeDeveloperSession { policy.authenticationCeiling += 1 }
		let overall = policy.authenticationCeiling + policy.verificationInitiationCeiling + policy.codeSubmissionCeiling
		// allowNetwork false = offline preflight: the transport refuses every
		// request, so no Apple contact and no consent/code gate is ever reached.
		let transport = ZagAppleAuthTransport(allowNetwork: allowNetwork, maxRequests: overall,
											  allowedMethods: ["GET", "POST", "PUT"],
											  twoFactorPolicy: policy,
											  consentGate: { coordinator.requestConsent() })
		let platform = self.platform
		let scope = self.scope
		return await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: Self.driveSignInWith2FA(persisted: persisted, transport: transport,
																	   email: email, password: password,
																	   platform: platform, scope: scope, coordinator: coordinator,
																	   includeDeveloperSession: includeDeveloperSession))
			}
		}
		#else
		throw ZagAppleAuthError.unavailable
		#endif
	}
	#endif

	/// Exchanges the stored authenticated session for an Xcode developer-services
	/// token — WITHOUT another GrandSlam login. Reuses the session bytes retained
	/// in this scope's Keychain and this scope's provisioned ADI identity. One
	/// Apple request (`POST GsService2` apptokens), no retries. This does NOT
	/// issue certificates, register devices, create App IDs, request profiles or
	/// sign anything — it only establishes developer-service access. Reports only
	/// sanitized facts: never the token, account id, cookies or session bytes.
	func developerSession(allowNetwork: Bool = true) async throws -> ZagDeveloperSessionReport {
		#if canImport(ZagAppleAuth)
		guard let persisted = try store.load(scope: scope) else { return ZagDeveloperSessionReport(outcome: .notProvisioned) }
		guard let sessionBytes = ZagAppleAuthSessionStore().load(scope: scope) else { return ZagDeveloperSessionReport(outcome: .noSession) }
		let transport = ZagAppleAuthTransport(allowNetwork: allowNetwork, maxRequests: 1)  // one apptokens request, no retry
		let platform = self.platform
		let scope = self.scope
		return await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: Self.driveDeveloperSession(persisted: persisted, sessionBytes: sessionBytes, transport: transport, platform: platform, scope: scope))
			}
		}
		#else
		throw ZagAppleAuthError.unavailable
		#endif
	}

	/// Verified developer-session success is NOT HTTP 200: apple-auth already
	/// requires 200 + the GrandSlam `ec` check + an AES-GCM decrypt of the token
	/// envelope with the session key before returning OK. On top of that this
	/// requires a non-empty token, an unexpired session, and that
	/// `developer_headers` derives an `X-Apple-GS-Token`. Any shortfall is
	/// `failed`/`expired`, never reported as success.
	static func developerSessionOutcome(ok: Bool, tokenPresent: Bool, expiryValid: Bool, headerHasToken: Bool) -> ZagDeveloperSessionOutcome {
		guard ok, tokenPresent else { return .failed }
		guard expiryValid else { return .expired }
		return headerHasToken ? .ok : .failed
	}

	#if canImport(ZagAppleAuth)
	/// Reconstructs the stored account session and exchanges it for a developer
	/// token. The token/account id are used only transiently to derive and verify
	/// the developer headers; neither is logged or returned.
	private static func driveDeveloperSession(persisted: Data, sessionBytes: Data, transport: ZagAppleAuthTransport, platform: ZagAppleAuthPlatform, scope: String) -> ZagDeveloperSessionReport {
		let result: Result<ZagDeveloperSessionReport, ZagAppleAuthError> = withClient(persisted: persisted, transport: transport, platform: platform) { client in
			var account: OpaquePointer?
			let fr = sessionBytes.withUnsafeBytes { raw -> aauth_status in
				aauth_account_session_from_plist(raw.bindMemory(to: UInt8.self).baseAddress, sessionBytes.count, &account)
			}
			guard fr == AAUTH_OK, let account else { return .success(ZagDeveloperSessionReport(outcome: .failed)) }
			defer { aauth_account_session_free(account) }
			return .success(Self.exchangeDeveloper(client: client, account: account, transport: transport, stageFor: { _ in "apptokens" }, persistScope: scope))
		}
		if case .success(let r) = result { return r }
		return ZagDeveloperSessionReport(outcome: .transportFailed, requestCount: transport.requestCount)
	}

	/// Exchanges an authenticated account session (live or reconstructed) for a
	/// developer token on `client`, and verifies the derived headers. Shared by
	/// the stored-session and the fresh-login paths. The token/account id are used
	/// only transiently; never logged or returned.
	static func exchangeDeveloper(client: OpaquePointer, account: OpaquePointer, transport: ZagAppleAuthTransport,
								  stageFor: @escaping (Int) -> String, persistScope: String? = nil) -> ZagDeveloperSessionReport {
		var out = aauth_client_buffer()
		let rc = aauth_client_developer_session(client, account, &out)
		defer { aauth_client_buffer_free(&out) }
		guard rc == AAUTH_OK, let data = out.data, out.size > 0 else {
			let error = String(cString: aauth_client_last_error())
			return ZagDeveloperSessionReport(outcome: transport.reachedApple ? .failed : .transportFailed,
											 requestCount: transport.requestCount, ec: grandSlamCode(error),
											 httpStatus: grandSlamHTTPStatus(error), appleMessage: grandSlamMessage(error),
											 httpTrace: Self.httpTrace(transport.httpTrace, stageFor: stageFor))
		}
		let json = (try? JSONSerialization.jsonObject(with: Data(bytes: data, count: out.size))) as? [String: Any]
		let accountId = json?["account_id"] as? String ?? ""
		let token = json?["token"] as? String ?? ""
		let expiry = (json?["expires_at_ms"] as? NSNumber)?.int64Value ?? 0
		let tokenPresent = !token.isEmpty && !accountId.isEmpty
		let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
		let expiryValid = expiry == 0 || expiry > nowMs
		let expiresInDays = expiry > nowMs ? Int((expiry - nowMs) / 86_400_000) : nil
		// Verify developer_headers derives and carries X-Apple-GS-Token (never its value).
		var headerCount: Int? = nil
		var hasGSToken = false
		if tokenPresent {
			var hdr = aauth_client_buffer()
			let hr = accountId.withCString { a in token.withCString { t in aauth_client_developer_headers(client, a, t, expiry, &hdr) } }
			if hr == AAUTH_OK, let hd = hdr.data, hdr.size > 0,
			   let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: hd, count: hdr.size))) as? [String: Any] {
				headerCount = obj.count
				hasGSToken = obj.keys.contains { $0.lowercased() == "x-apple-gs-token" }
			}
			aauth_client_buffer_free(&hdr)
		}
		// Persist a verified token (opaque, this-device-only) so it can be reused
		// for developer-services requests without another login. Only on a fully
		// verified token (present + GS header); the bytes are never logged.
		if let persistScope, tokenPresent, hasGSToken {
			try? ZagDeveloperTokenStore().save(
				ZagPersistedDeveloperToken(accountID: accountId, token: token, expiresAtMs: expiry), scope: persistScope)
		}
		return ZagDeveloperSessionReport(outcome: Self.developerSessionOutcome(ok: true, tokenPresent: tokenPresent, expiryValid: expiryValid, headerHasToken: hasGSToken),
										 requestCount: transport.requestCount, tokenPresent: tokenPresent,
										 expiresInDays: expiresInDays, headerCount: headerCount, hasGSTokenHeader: hasGSToken,
										 httpTrace: Self.httpTrace(transport.httpTrace, stageFor: stageFor))
	}

	/// Local (no HTTP) developer headers from the PERSISTED developer token and
	/// this scope's ADI, for the native developer-services portal's header
	/// provider. Returns nil when no usable token is persisted or the machine is
	/// not provisioned. Reads only (never writes/alters any ADI profile). The
	/// token and the returned headers are never logged.
	func developerHeaders(now: Date = Date(), expectedAccountID: String? = nil) -> [String: String]? {
		guard let persisted = try? store.load(scope: scope),
			  let token = ZagDeveloperTokenStore().load(scope: scope), token.isUsable(at: now),
			  expectedAccountID == nil || token.accountID == expectedAccountID else { return nil }
		let platform = self.platform
		// A refused transport: developer_headers is local, so no request is made;
		// this guarantees the bridge can never reach the network.
		let transport = ZagAppleAuthTransport(allowNetwork: false, maxRequests: 0)
		let result: Result<[String: String], ZagAppleAuthError> = Self.withClient(persisted: persisted, transport: transport, platform: platform) { client in
			var out = aauth_client_buffer()
			let rc = token.accountID.withCString { a in token.token.withCString { t in
				aauth_client_developer_headers(client, a, t, token.expiresAtMs, &out)
			} }
			defer { aauth_client_buffer_free(&out) }
			guard rc == AAUTH_OK, let d = out.data, out.size > 0,
				  let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: d, count: out.size))) as? [String: String] else {
				return .success([:])
			}
			return .success(obj)
		}
		if case .success(let headers) = result, !headers.isEmpty,
		   headers.keys.contains(where: { $0.lowercased() == "x-apple-gs-token" }) { return headers }
		return nil
	}
	#endif

	#if canImport(ZagAppleAuth)
	private struct RawSignIn { var outcome: ZagAppleAuthSignInOutcome; var ec: Int?; var http: Int?; var message: String?; var sessionStored = false; var dev: ZagDeveloperSessionReport? = nil }

	private static func driveSignIn(persisted: Data, transport: ZagAppleAuthTransport,
									email: String, password: String, sentinel: ZagTwoFactorSentinel,
									platform: ZagAppleAuthPlatform) -> ZagAppleAuthSignInReport {
		let result: Result<RawSignIn, ZagAppleAuthError> = withClient(persisted: persisted, transport: transport, platform: platform) { client in
			// Ensure the profile is loaded (no-op for a provisioned profile; no HTTP).
			let p = aauth_client_provision(client)
			guard p == AAUTH_OK else {
				return .success(RawSignIn(outcome: transport.reachedApple ? .rejected(code: Int(p.rawValue)) : .transportFailed))
			}
			let ctx = Unmanaged.passUnretained(sentinel).toOpaque()
			var verification = aauth_verification_options(
				method: AAUTH_VERIFY_AUTOMATIC, phone_number_id: 0,
				code: zagTwoFactorCancelCallback, select_phone: zagPhoneSelectCancelCallback, context: ctx)
			var session: OpaquePointer?
			let rc: aauth_status = email.withCString { e in password.withCString { pw in
				withUnsafePointer(to: &verification) { v in aauth_client_login(client, e, pw, v, &session) }
			} }
			if let session { aauth_account_session_free(session) }   // never persisted
			if sentinel.requested { return .success(RawSignIn(outcome: .twoFactorRequired)) }
			if rc == AAUTH_OK { return .success(RawSignIn(outcome: .authenticated)) }
			let error = String(cString: aauth_client_last_error())
			let ec = grandSlamCode(error), http = grandSlamHTTPStatus(error), message = grandSlamMessage(error)
			// A library network error that is actually our ceiling refusing a
			// post-completion (2FA-initiation) request is distinguished from a
			// genuine network failure; neither is ever reported as an Apple
			// rejection.
			let isNetworkError = rc.rawValue == AAUTH_NETWORK_ERROR.rawValue
			let all200 = !transport.httpTrace.isEmpty && transport.httpTrace.allSatisfy { $0.status == 200 }
			let outcome: ZagAppleAuthSignInOutcome = ec.map { .rejected(code: $0) }
				?? http.map { .httpError(status: $0) }
				?? (isNetworkError ? Self.networkErrorOutcome(hitCeiling: transport.hitCeiling, all200: all200)
					: (transport.reachedApple ? .rejected(code: Int(rc.rawValue)) : .transportFailed))
			return .success(RawSignIn(outcome: outcome, ec: ec, http: http, message: message))
		}
		let raw: RawSignIn = { if case .success(let r) = result { return r }; return RawSignIn(outcome: .transportFailed) }()
		return ZagAppleAuthSignInReport(outcome: raw.outcome,
										stage: Self.signInStage(requestCount: transport.requestCount),
										requestCount: transport.requestCount,
										ec: raw.ec, httpStatus: raw.http, appleMessage: raw.message,
										httpTrace: Self.httpTrace(transport.httpTrace, stageFor: Self.signInStage))
	}

	#if canImport(SwiftUI)
	/// Drives one interactive 2FA login and securely retains the session on
	/// success. The code and session material never appear in the return value.
	private static func driveSignInWith2FA(persisted: Data, transport: ZagAppleAuthTransport,
										   email: String, password: String, platform: ZagAppleAuthPlatform,
										   scope: String, coordinator: ZagTwoFactorCoordinator,
										   includeDeveloperSession: Bool = false) -> ZagAppleAuthSignInReport {
		coordinator.begin()
		let result: Result<RawSignIn, ZagAppleAuthError> = withClient(persisted: persisted, transport: transport, platform: platform) { client in
			let p = aauth_client_provision(client)
			guard p == AAUTH_OK else {
				return .success(RawSignIn(outcome: transport.reachedApple ? .rejected(code: Int(p.rawValue)) : .transportFailed))
			}
			let ctx = Unmanaged.passUnretained(coordinator).toOpaque()
			// AUTOMATIC: follow the account's real 2FA configuration; do not force a
			// method. phone_number_id 0 discovers the trusted numbers to present.
			var verification = aauth_verification_options(
				method: AAUTH_VERIFY_AUTOMATIC, phone_number_id: 0,
				code: zagTwoFactorCodeCallback, select_phone: zagPhoneSelectCallback, context: ctx)
			var session: OpaquePointer?
			let rc: aauth_status = email.withCString { e in password.withCString { pw in
				withUnsafePointer(to: &verification) { v in aauth_client_login(client, e, pw, v, &session) }
			} }
			var sessionStored = false
			var dev: ZagDeveloperSessionReport? = nil
			// Persist ONLY on a positive AAUTH_OK with valid (non-empty) session
			// material. The bytes are opaque and never logged.
			if rc == AAUTH_OK, let session {
				var buf = aauth_client_buffer()
				if aauth_account_session_plist(session, &buf) == AAUTH_OK, let d = buf.data, buf.size > 0 {
					let bytes = Data(bytes: d, count: buf.size)
					if (try? ZagAppleAuthSessionStore().save(bytes, scope: scope)) != nil { sessionStored = true }
				}
				aauth_client_buffer_free(&buf)
				// Developer-session from the FRESH in-memory session (not the stored,
				// possibly-aged one), immediately after authentication.
				if includeDeveloperSession {
					dev = Self.exchangeDeveloper(client: client, account: session, transport: transport, stageFor: Self.signInStage, persistScope: scope)
				}
			}
			if let session { aauth_account_session_free(session) }
			if rc == AAUTH_OK { return .success(RawSignIn(outcome: .authenticated, sessionStored: sessionStored, dev: dev)) }
			let error = String(cString: aauth_client_last_error())
			let ec = grandSlamCode(error), http = grandSlamHTTPStatus(error), message = grandSlamMessage(error)
			let isNetworkError = rc.rawValue == AAUTH_NETWORK_ERROR.rawValue
			let all200 = !transport.httpTrace.isEmpty && transport.httpTrace.allSatisfy { $0.status == 200 }
			let outcome: ZagAppleAuthSignInOutcome = ec.map { .rejected(code: $0) }
				?? http.map { .httpError(status: $0) }
				?? (isNetworkError ? Self.networkErrorOutcome(hitCeiling: transport.hitCeiling, all200: all200)
					: (transport.reachedApple ? .rejected(code: Int(rc.rawValue)) : .transportFailed))
			return .success(RawSignIn(outcome: outcome, ec: ec, http: http, message: message))
		}
		coordinator.finish()
		let raw: RawSignIn = { if case .success(let r) = result { return r }; return RawSignIn(outcome: .transportFailed) }()
		return ZagAppleAuthSignInReport(outcome: raw.outcome,
										stage: Self.signInStage(requestCount: transport.requestCount),
										requestCount: transport.requestCount,
										ec: raw.ec, httpStatus: raw.http, appleMessage: raw.message,
										httpTrace: Self.httpTrace(transport.httpTrace, stageFor: Self.signInStage),
										twoFactorCompleted: raw.outcome == .authenticated,
										sessionStored: raw.sessionStored,
										acceptedByClass: transport.acceptedByClass,
										refusals: transport.refusalList,
										developerOutcome: raw.dev?.outcome,
										developerTokenPresent: raw.dev?.tokenPresent,
										developerHasGSTokenHeader: raw.dev?.hasGSTokenHeader,
										developerExpiresInDays: raw.dev?.expiresInDays)
	}
	#endif
	#endif
}

/// One request's sanitized HTTP trace: its stage, status, and an allowlisted,
/// sanitized subset of response-header metadata (e.g. `retry-after`). Never a
/// raw header or body.
struct ZagHTTPTraceEntry: Equatable, Sendable {
	let stage: String
	let status: Int
	let metadata: [String: String]
}

/// The classified result of the gated sign-in experiment. Carries no account
/// session, token, credential or anisette value — only what happened.
enum ZagAppleAuthSignInOutcome: Equatable, Sendable {
	case authenticated         // M2 verified, no 2FA requested
	case twoFactorRequired     // Apple asked for a code; the harness did not submit one
	case rejected(code: Int)   // Apple GrandSlam rejection, Status.ec (negative, e.g. -80045)
	case httpError(status: Int)// Apple edge HTTP failure (e.g. 503/429), no ec
	case transportFailed       // no Apple response (offline, blocked, network error)
	case notProvisioned        // no machine profile to sign in with
	/// SRP completed (every accepted request returned 200) and the library then
	/// tried a 2FA-initiation request that our configured ceiling refused. The
	/// library issues that request only after verifying Apple's M2 proof and an
	/// unauthenticated account-state transition, so this positively establishes
	/// that the SRP sign-in succeeded and the account requires 2FA — never
	/// inferred from HTTP 200 alone. No code was requested, sent or submitted.
	case twoFactorRequiredAtCeiling
}

/// The classified result of a developer-session exchange. Carries no token,
/// account id, cookie or session material — only what happened.
enum ZagDeveloperSessionOutcome: Equatable, Sendable {
	case ok              // AAUTH_OK, token present, unexpired, X-Apple-GS-Token derived
	case expired         // token returned but the session is past its expiry
	case failed          // Apple reached but no usable token (ec, bad envelope, etc.)
	case transportFailed // no Apple response (offline, blocked, network error)
	case noSession       // no retained authenticated session in this scope
	case notProvisioned  // no ADI profile in this scope
}

/// A sanitized developer-session report. Never carries the token, account id,
/// cookies or session bytes — only the outcome and non-sensitive counts.
struct ZagDeveloperSessionReport: Equatable, Sendable {
	let outcome: ZagDeveloperSessionOutcome
	var requestCount: Int = 0
	/// Whether a non-empty developer token + account id were returned (never the values).
	var tokenPresent: Bool = false
	/// Coarse days until the session expires (non-sensitive), when known.
	var expiresInDays: Int? = nil
	/// Number of derived developer headers (never their values).
	var headerCount: Int? = nil
	/// Whether the derived headers include `X-Apple-GS-Token` (never its value).
	var hasGSTokenHeader: Bool = false
	var ec: Int? = nil
	var httpStatus: Int? = nil
	/// Apple's `em` message, already sanitized and length-bounded (never raw).
	var appleMessage: String? = nil
	var httpTrace: [ZagHTTPTraceEntry] = []
}

/// A sanitized sign-in report: the outcome plus the stage and request count,
/// which locate a rejection (lookup / SRP init / SRP complete) without exposing
/// any request content, credential, token or anisette value.
struct ZagAppleAuthSignInReport: Equatable, Sendable {
	let outcome: ZagAppleAuthSignInOutcome
	var stage: String? = nil
	var requestCount: Int = 0
	/// Apple's GrandSlam `ec` (negative), when the rejection carried one.
	var ec: Int? = nil
	/// An Apple edge HTTP status (e.g. 503 / 429), when that was the failure.
	var httpStatus: Int? = nil
	/// Apple's `em` message, already sanitized and length-bounded (never raw).
	var appleMessage: String? = nil
	/// Per-request sanitized HTTP trace (stage, status, allowlisted metadata).
	var httpTrace: [ZagHTTPTraceEntry] = []
	/// Whether the 2FA exchange completed and the login returned AAUTH_OK. nil for
	/// the SRP-only experiment that never submits a code.
	var twoFactorCompleted: Bool? = nil
	/// Whether valid session material was securely retained on-device. nil when
	/// retention was not attempted. Never carries the session itself.
	var sessionStored: Bool? = nil
	/// Per-class accepted request counts (authentication / verification-initiation
	/// / code-submission), for bound reporting. No request content.
	var acceptedByClass: [String: Int]? = nil
	/// Why any request was refused (class + reason), locating where a bounded
	/// sequence stopped. No request content.
	var refusals: [[String: String]]? = nil
	/// When a developer-session was exchanged from the fresh in-memory session in
	/// the same run, its sanitized outcome (never the token).
	var developerOutcome: ZagDeveloperSessionOutcome? = nil
	var developerTokenPresent: Bool? = nil
	var developerHasGSTokenHeader: Bool? = nil
	var developerExpiresInDays: Int? = nil
}

#if canImport(ZagAppleAuth)
/// Records that a 2FA challenge occurred, so the experiment can report it
/// without submitting anything.
final class ZagTwoFactorSentinel: @unchecked Sendable {
	private let lock = NSLock()
	private var flag = false
	var requested: Bool { lock.withLock { flag } }
	func mark() { lock.withLock { flag = true } }
}

/// 2FA code callback: mark that a code was requested and cancel. Never writes a
/// verification code.
private let zagTwoFactorCancelCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> Int32 = { ctx, _, _, written in
	if let ctx { Unmanaged<ZagTwoFactorSentinel>.fromOpaque(ctx).takeUnretainedValue().mark() }
	written?.pointee = 0
	return 1   // cancel: do not submit a code
}

/// Phone-selection callback: mark 2FA and cancel, so no SMS is ever triggered.
private let zagPhoneSelectCancelCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int64>?) -> Int32 = { ctx, _, _ in
	if let ctx { Unmanaged<ZagTwoFactorSentinel>.fromOpaque(ctx).takeUnretainedValue().mark() }
	return 1   // cancel: do not select a number / trigger an SMS
}

#if canImport(SwiftUI)
/// Interactive 2FA code callback: blocks for the code the user enters in the
/// SecureField (via the coordinator), writes it into apple-auth's buffer and
/// returns success, or returns cancel. The code is never logged or copied
/// anywhere else; apple-auth wipes its own buffer after use.
private let zagTwoFactorCodeCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> Int32 = { ctx, output, capacity, written in
	guard let ctx, let output else { written?.pointee = 0; return 1 }
	let coordinator = Unmanaged<ZagTwoFactorCoordinator>.fromOpaque(ctx).takeUnretainedValue()
	guard let code = coordinator.provideCode() else { written?.pointee = 0; return 1 }
	let count = code.utf8.count
	guard count > 0, count <= capacity else { written?.pointee = 0; return 1 }
	code.withCString { src in _ = memcpy(output, src, count) }   // digits only, no NUL needed
	written?.pointee = count
	coordinator.markSubmitting()
	return 0
}

/// Interactive phone-selection callback: presents the account's trusted numbers
/// through the coordinator and returns the chosen id, or cancel.
private let zagPhoneSelectCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int64>?) -> Int32 = { ctx, phonesJSON, selected in
	guard let ctx, let phonesJSON, let selected else { return 1 }
	let coordinator = Unmanaged<ZagTwoFactorCoordinator>.fromOpaque(ctx).takeUnretainedValue()
	guard let id = coordinator.selectPhone(String(cString: phonesJSON)) else { return 1 }
	selected.pointee = id
	return 0
}
#endif
#endif
