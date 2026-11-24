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
	private let maxRequests: Int

	init(allowNetwork: Bool, maxRequests: Int = 3) {
		self.allowNetwork = allowNetwork
		self.maxRequests = maxRequests
	}

	/// Whether any request actually went to Apple (distinguishes a transport
	/// failure from a server rejection).
	var reachedApple: Bool { lock.withLock { count > 0 } }

	/// How many requests actually went to Apple. For the sign-in sequence this
	/// identifies the stage a rejection occurred at (1 = lookup, 2 = SRP init,
	/// 3 = SRP complete) without exposing any request content.
	var requestCount: Int { lock.withLock { count } }

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
		guard allowNetwork else { lock.lock(); log.append("BLOCKED (offline)"); lock.unlock(); return nil }
		guard let u = URL(string: url), u.scheme == "https", let host = u.host, host.hasSuffix(".apple.com") else { return nil }
		guard method == "GET" || method == "POST" else { return nil }
		lock.lock()
		guard count < maxRequests else { lock.unlock(); return nil }
		count += 1
		lock.unlock()
		var req = URLRequest(url: u)
		req.httpMethod = method
		for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
		if method == "POST" { req.httpBody = body }
		let sem = DispatchSemaphore(value: 0)
		var out: (Int, Data, [[String]])?
		session.dataTask(with: req) { data, resp, _ in
			defer { sem.signal() }
			guard let http = resp as? HTTPURLResponse else { return }
			var pairs: [[String]] = []
			for (k, v) in http.allHeaderFields { pairs.append([String(describing: k), String(describing: v)]) }
			out = (http.statusCode, data ?? Data(), pairs)
		}.resume()
		sem.wait()
		lock.lock()
		log.append("\(method) \(host) -> \(out.map { String($0.0) } ?? "err")")
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

	/// The OS token the anisette client-info must carry for this platform.
	var clientInfoOS: String { self == .mac ? "macOS" : "iPhone OS" }
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
		let transport = ZagAppleAuthTransport(allowNetwork: allowProvisioning)
		let platform = self.platform
		// The apple-auth client calls are synchronous (the transport blocks on
		// the network); run them off the actor's executor.
		let result: Result<([String: String], Data), ZagAppleAuthError> = await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: Self.drive(persisted: persisted, transport: transport, platform: platform))
			}
		}
		lastRequestCount = transport.requestCount
		lastReachedApple = transport.reachedApple
		lastHTTPStatuses = Self.httpStatuses(transport.log)
		let (headers, snapshot) = try result.get()
		try store.save(snapshot, scope: scope)
		return Self.anisetteSubset(headers)
		#else
		throw ZagAppleAuthError.unavailable
		#endif
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
		// Serial absent for both platforms (no fabricated hardware identifier).
		// Device fields nil -> apple-auth's default software identity for the
		// platform (iPhone preset, or Mac preset for the consistent Mac pairing).
		let created: aauth_status = "".withCString { serial in
			var iphone = aauth_iphone_device(model: nil, ios_version: nil, ios_build: nil)
			let devicePlatform = platform == .mac ? AAUTH_DEVICE_MAC : AAUTH_DEVICE_IPHONE
			return withUnsafePointer(to: &options) { opt in
				withUnsafePointer(to: &iphone) { ip in
					func make(statePtr: UnsafePointer<UInt8>?, stateSize: Int) -> aauth_status {
						var cfg = aauth_client_config(directory: nil, options: opt, platform: devicePlatform,
							mac_device: nil, iphone_device: platform == .mac ? nil : ip, serial_number: serial,
							headers: nil, headers_json: nil, state: statePtr, state_size: stateSize)
						return aauth_client_create(&cfg, &client)
					}
					if let persisted { return persisted.withUnsafeBytes { make(statePtr: $0.bindMemory(to: UInt8.self).baseAddress, stateSize: persisted.count) } }
					return make(statePtr: nil, stateSize: 0)
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
	func signInExperiment(email: String, password: String, allowNetwork: Bool) async throws -> ZagAppleAuthSignInReport {
		#if canImport(ZagAppleAuth)
		guard let persisted = try store.load(scope: scope) else { return ZagAppleAuthSignInReport(outcome: .notProvisioned) }
		// Bounded: lookup + SRP init + SRP complete (+ a possible 2FA bootstrap),
		// no retries. With allowNetwork false the transport refuses everything.
		let transport = ZagAppleAuthTransport(allowNetwork: allowNetwork, maxRequests: 6)
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

	#if canImport(ZagAppleAuth)
	private struct RawSignIn { var outcome: ZagAppleAuthSignInOutcome; var ec: Int?; var http: Int?; var message: String? }

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
			let outcome: ZagAppleAuthSignInOutcome = ec.map { .rejected(code: $0) }
				?? http.map { .httpError(status: $0) }
				?? (transport.reachedApple ? .rejected(code: Int(rc.rawValue)) : .transportFailed)
			return .success(RawSignIn(outcome: outcome, ec: ec, http: http, message: message))
		}
		let raw: RawSignIn = { if case .success(let r) = result { return r }; return RawSignIn(outcome: .transportFailed) }()
		return ZagAppleAuthSignInReport(outcome: raw.outcome,
										stage: Self.signInStage(requestCount: transport.requestCount),
										requestCount: transport.requestCount,
										ec: raw.ec, httpStatus: raw.http, appleMessage: raw.message)
	}
	#endif
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
#endif
