import Foundation
import ZagAppleAuth

// Keep the identity consistent with ZagAppleAuthPlatform.macLegacy.
let identity = [
    "X-MMe-Client-Info": "<MacBookPro13,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
    "User-Agent": "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0",
]

final class ProvisioningTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowed: Bool
    private(set) var count = 0
    private(set) var networkHint: String?
    init(allowed: Bool) { self.allowed = allowed }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func request(_ url: URL, method: String, headers: [String: String], body: Data?) -> (Int, Data, [[String]])? {
        guard allowed, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "gsa.apple.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let sequence = [
            ("GET", ["/grandslam/GsService2/lookup"]),
            ("POST", ["/grandslam/MidService/startProvisioning", "/grandslam/MidService/startMachineProvisioning"]),
            ("POST", ["/grandslam/MidService/finishProvisioning", "/grandslam/MidService/finishMachineProvisioning"]),
        ]
        guard count < sequence.count, sequence[count].0 == method,
              sequence[count].1.contains(parts.percentEncodedPath) else { return nil }
        count += 1
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.httpBody = method == "GET" ? nil : body
        let pending = Response()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { pending.failure = DesktopNetworkError.transportMessage(error); return }
            guard let response = response as? HTTPURLResponse, let data,
                  data.count <= 1024 * 1024 else { return }
            if response.statusCode != 200 { pending.failure = DesktopNetworkError.httpMessage(response.statusCode, release: false) }
            let headers = response.allHeaderFields.map { [String(describing: $0.key), String(describing: $0.value)] }
            pending.value = (response.statusCode, data, headers)
        }.resume()
        semaphore.wait()
        networkHint = pending.failure
        return pending.value
    }
}

private final class Response: @unchecked Sendable {
    // Written by the completion handler and read only after the semaphore is signaled.
    var value: (Int, Data, [[String]])?
    var failure: String?
}

func copy(_ data: Data, into buffer: inout aauth_client_buffer) -> Bool {
    guard aauth_client_buffer_alloc(data.count, &buffer) == AAUTH_OK else { return false }
    if let target = buffer.data { data.copyBytes(to: target, count: data.count) }
    return true
}

let transportCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<aauth_http_request>?, UnsafeMutablePointer<aauth_http_response>?
) -> Int32 = { context, request, response in
    guard let context, let request, let response, let rawURL = request.pointee.url,
          let url = URL(string: String(cString: rawURL)), let method = request.pointee.method else { return 1 }
    let raw = request.pointee
    let transport = Unmanaged<ProvisioningTransport>.fromOpaque(context).takeUnretainedValue()
    let headers = raw.headers_json.flatMap {
        (try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8))) as? [String: String]
    } ?? [:]
    let body = raw.body.map { Data(bytes: $0, count: raw.body_size) }
    guard let (status, bytes, responseHeaders) = transport.request(url, method: String(cString: method), headers: headers, body: body),
          let encoded = try? JSONSerialization.data(withJSONObject: responseHeaders) else { return 1 }
    response.pointee.status = status
    guard copy(bytes, into: &response.pointee.body),
          copy(encoded, into: &response.pointee.headers_json) else { return 1 }
    return 0
}

func output(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    FileHandle.standardOutput.write(data)
}

func run() throws -> Bool {
    guard CommandLine.arguments.count == 2,
          ["identity", "headers", "provision"].contains(CommandLine.arguments[1]) else { return false }
    let mode = CommandLine.arguments[1]
    let transport = ProvisioningTransport(allowed: mode == "provision")
    let state = FileHandle.standardInput.readDataToEndOfFile()
    guard state.count <= 1024 * 1024 else { return false }
    let overrides = String(decoding: try JSONSerialization.data(withJSONObject: identity), as: UTF8.self)
    var options = aauth_client_options(transport: transportCallback, observer: nil, clock: nil,
                                       context: Unmanaged.passUnretained(transport).toOpaque())
    var client: OpaquePointer?
    let result = withUnsafePointer(to: &options) { options in
        overrides.withCString { overrides in
            "".withCString { serial in
                state.withUnsafeBytes { state in
                    var config = aauth_client_config(directory: nil, options: options, platform: AAUTH_DEVICE_MAC,
                        mac_device: nil, iphone_device: nil, serial_number: serial, headers: nil, headers_json: overrides,
                        state: state.isEmpty ? nil : state.bindMemory(to: UInt8.self).baseAddress, state_size: state.count)
                    return aauth_client_create(&config, &client)
                }
            }
        }
    }
    guard result == AAUTH_OK, let client else { return false }
    defer { aauth_client_free(client) }
    if mode == "identity" {
        try output(["identity": identity])
        return true
    }
    let status = aauth_client_provision(client)
    guard status == AAUTH_OK else {
        var failure: [String: Any] = ["status": status.rawValue, "requests": transport.count]
        if let hint = transport.networkHint { failure["network_hint"] = hint }
        try output(failure)
        return true
    }
    var headers = aauth_client_buffer()
    var snapshot = aauth_client_buffer()
    defer {
        aauth_client_buffer_free(&headers)
        aauth_client_buffer_free(&snapshot)
    }
    guard aauth_client_headers(client, &headers) == AAUTH_OK, let headerBytes = headers.data,
          aauth_client_state(client, &snapshot) == AAUTH_OK, let stateBytes = snapshot.data,
          let values = try JSONSerialization.jsonObject(with: Data(bytes: headerBytes, count: headers.size)) as? [String: String]
    else { return false }
    try output(["headers": values, "state": Data(bytes: stateBytes, count: snapshot.size).base64EncodedString()])
    return true
}

do {
    if try !run() { exit(1) }
} catch {
    exit(1)
}
