// Supervised one-shot machine-provisioning experiment for the apple-auth
// Mac-algorithm ADI, running entirely on the iPhone. It drives apple-auth's own
// `aauth_client_provision` (lookup -> midStartProvisioning -> midFinishProvisioning)
// over a URLSession transport that is pinned to Apple provisioning endpoints,
// capped at three requests, with no redirects, no retries and no background work.
//
// It runs ONLY when launched with the environment variable ZAG_RUN_PROVISION=1.
// A normal launch does the offline self-test and never contacts Apple.
//
// No Apple Account authentication, 2FA, developer-portal, certificate or device
// registration is possible from here: only aauth_client_provision is called.
// Diagnostics are sanitized: method, host, HTTP status, byte counts and stage
// only — never headers, bodies, identifiers, keys or provisioning payloads.
import Foundation
import os

final class ProvisioningTransport: NSObject, URLSessionTaskDelegate {
    private(set) var requestCount = 0
    private(set) var log: [String] = []
    private let maxRequests = 3
    private let allowedHostSuffix = ".apple.com"
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // Block all redirects: provisioning must not be redirected elsewhere.
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Synchronous fetch with the experiment's guard rails. Returns (status, body, headerPairs)
    /// or nil to abort the transaction (a guard-rail violation or transport error).
    func perform(url: String, method: String, headers: [String: String], body: Data) -> (Int, Data, [[String]])? {
        guard let u = URL(string: url), (u.scheme ?? "") == "https",
              let host = u.host, host.hasSuffix(allowedHostSuffix) else {
            log.append("DENY non-apple-or-insecure url"); return nil
        }
        guard method == "GET" || method == "POST" else { log.append("DENY method \(method)"); return nil }
        guard requestCount < maxRequests else { log.append("DENY request cap reached"); return nil }
        requestCount += 1
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if method == "POST" { req.httpBody = body }
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, Data, [[String]])?
        let task = session.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse else { return }
            var pairs: [[String]] = []
            for (k, v) in http.allHeaderFields { pairs.append([String(describing: k), String(describing: v)]) }
            out = (http.statusCode, data ?? Data(), pairs)
        }
        task.resume()
        sem.wait()
        if let o = out {
            log.append("\(method) \(host) -> \(o.0) (\(o.1.count)B)")
        } else {
            log.append("\(method) \(host) -> transport error")
        }
        return out
    }
}

// C transport callback. `context` is an unretained ProvisioningTransport.
private let transportCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<aauth_http_request>?, UnsafeMutablePointer<aauth_http_response>?) -> Int32 = { context, request, response in
    guard let context, let request, let response else { return 1 }
    let t = Unmanaged<ProvisioningTransport>.fromOpaque(context).takeUnretainedValue()
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
    guard let (status, respBody, pairs) = t.perform(url: url, method: method, headers: headers, body: body) else {
        return 1
    }
    // Fill response; library takes ownership of buffers allocated via aauth_client_buffer_alloc.
    response.pointee.status = status
    var bodyBuf = aauth_client_buffer(); if aauth_client_buffer_alloc(respBody.count, &bodyBuf) == AAUTH_OK, let dst = bodyBuf.data {
        respBody.copyBytes(to: dst, count: respBody.count)
    }
    response.pointee.body = bodyBuf
    let hdrJSON = (try? JSONSerialization.data(withJSONObject: pairs)) ?? Data("[]".utf8)
    var hdrBuf = aauth_client_buffer(); if aauth_client_buffer_alloc(hdrJSON.count, &hdrBuf) == AAUTH_OK, let dst = hdrBuf.data {
        hdrJSON.copyBytes(to: dst, count: hdrJSON.count)
    }
    response.pointee.headers_json = hdrBuf
    return 0
}

enum ProvisioningExperiment {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["ZAG_RUN_PROVISION"] == "1" }

    /// One supervised attempt. Returns a sanitized JSON report.
    static func run() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("zag-adi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let transport = ProvisioningTransport()
        let ctx = Unmanaged.passUnretained(transport).toOpaque()
        var options = aauth_client_options(transport: transportCallback, observer: nil, clock: nil, context: ctx)

        var report: [String: Any] = ["library": String(cString: aauth_client_version()),
                                     "platform": "iphone", "serial": "absent"]
        var client: OpaquePointer?
        let rc: aauth_status = dir.path.withCString { dirPtr in
            "".withCString { serialPtr in
                var iphone = aauth_iphone_device(model: nil, ios_version: nil, ios_build: nil)
                return withUnsafePointer(to: &options) { opt in
                    withUnsafePointer(to: &iphone) { ip in
                        var cfg = aauth_client_config(directory: dirPtr, options: opt,
                            platform: AAUTH_DEVICE_IPHONE, mac_device: nil, iphone_device: ip,
                            serial_number: serialPtr, headers: nil, headers_json: nil,
                            state: nil, state_size: 0)
                        return aauth_client_create(&cfg, &client)
                    }
                }
            }
        }
        guard rc == AAUTH_OK, let client else {
            report["stage"] = "create"; report["status"] = Int(rc.rawValue)
            report["error"] = sanitize(String(cString: aauth_client_last_error()))
            return json(report)
        }
        defer { aauth_client_free(client) }

        let provisionRC = aauth_client_provision(client)
        report["requests"] = transport.requestCount
        report["request_log"] = transport.log
        if provisionRC == AAUTH_OK {
            report["stage"] = "finish-provisioning"
            report["status"] = 0
            report["provisioned"] = true
            // Local only (no HTTP): confirm anisette headers are now derivable.
            var hb = aauth_client_buffer()
            report["anisette_headers_available"] = (aauth_client_headers(client, &hb) == AAUTH_OK)
            aauth_client_buffer_free(&hb)
        } else {
            report["stage"] = transport.requestCount >= 3 ? "finish-provisioning" :
                              (transport.requestCount == 2 ? "start-provisioning" : "lookup")
            report["status"] = Int(provisionRC.rawValue)
            report["provisioned"] = false
            report["error"] = sanitize(String(cString: aauth_client_last_error()))
        }
        let out = docs.appendingPathComponent("zag_provision_result.json")
        try? (json(report) + "\n").data(using: .utf8)?.write(to: out)
        os_log("ZAGPROVISION %{public}@", json(report))
        return json(report)
    }

    // Keep only recognised, non-identifying text (status codes, stage words, result codes).
    private static func sanitize(_ s: String) -> String {
        let allowed = "Provisioning rejected / HTTP status only; identifiers withheld"
        if s.lowercased().contains("http") || s.lowercased().contains("provision") || s.lowercased().contains("rejected") {
            // numeric codes are safe to keep
            let codes = s.split(whereSeparator: { !$0.isNumber }).filter { !$0.isEmpty }.prefix(2).joined(separator: " ")
            return "\(allowed); codes: \(codes)"
        }
        return allowed
    }
    private static func json(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
