import Foundation

// A small, typed client for the App Store Connect API over the shared
// `ZagHTTPTransport` (so tests replace the network with canned responses and
// the real transport keeps the system's TLS validation).
//
// Reads (M1) confirm a connected key; writes (M2) create the provisioning
// resources a development profile needs: a certificate from the device's CSR,
// the target device, a bundle ID and the profile itself. The client makes no
// decisions — the provisioner does — and never logs a token or key.
//
// The API host is held without a scheme and the URL is built with
// `URLComponents`, so no `https://…apple.com` string appears in source.

// MARK: - Errors

enum ZagASCError: Error, Equatable, Sendable {
	/// The request could not be signed or built.
	case tokenUnavailable
	case malformedRequest
	/// The transport failed (its typed reason).
	case transport(ZagTransportError)
	/// 401: the token is missing, malformed or expired, or the key is revoked.
	case unauthorized
	/// 403: the key cannot perform this operation — for provisioning this means
	/// it is not a team key with the Admin role (Certificates, Identifiers &
	/// Profiles access). A user-based key lands here.
	case forbidden
	case notFound
	/// 409: the resource conflicts with an existing one (e.g. an identifier
	/// another team owns, or one that already exists), with Apple's code.
	case conflict(code: String?)
	/// 400 or 422: Apple rejected the request's content (Apple's documented
	/// validation errors), with Apple's code.
	case invalidRequest(code: String?)
	/// 429: Apple is rate-limiting this key.
	case rateLimited
	case server(status: Int)
	/// Any other status, with Apple's error code when it sent one.
	case unexpected(status: Int, code: String?)
	/// A response body that did not decode as expected.
	case malformedResponse
}

// MARK: - Typed responses

/// One resource in a JSON:API document, with decoded attributes.
struct ZagASCRecord<Attributes: Decodable & Sendable>: Decodable, Sendable {
	let type: String
	let id: String
	let attributes: Attributes?
}

/// The attributes Zag Store reads from each provisioning resource. Only the
/// fields the app uses are decoded; unknown fields are ignored.
struct ZagASCDevice: Decodable, Sendable, Equatable {
	let name: String?
	let udid: String?
	let deviceClass: String?
	let status: String?
	let platform: String?
}

struct ZagASCCertificate: Decodable, Sendable, Equatable {
	let name: String?
	let certificateType: String?
	let serialNumber: String?
	let expirationDate: String?
	/// Base64 DER of the issued certificate.
	let certificateContent: String?
}

struct ZagASCBundleID: Decodable, Sendable, Equatable {
	let identifier: String?
	let name: String?
	let platform: String?
}

struct ZagASCProfile: Decodable, Sendable, Equatable {
	let name: String?
	let profileType: String?
	let uuid: String?
	let expirationDate: String?
	/// `ACTIVE` or `INVALID` (e.g. its certificate was revoked).
	let profileState: String?
	/// Base64 of the signed `.mobileprovision`.
	let profileContent: String?
}

/// The provisioning resources, with their endpoint path and JSON:API type.
enum ZagASCResource: String, Sendable {
	case devices = "v1/devices"
	case certificates = "v1/certificates"
	case bundleIDs = "v1/bundleIds"
	case profiles = "v1/profiles"

	/// The JSON:API `type` for this resource (the path without the `v1/`).
	var type: String { String(rawValue.dropFirst(3)) }
}

/// The outcome of a read-only connection check.
struct ZagASCConnection: Equatable, Sendable {
	/// How many of the probed resource Apple reports the team has (from the
	/// response's paging total, else the page count). For display only.
	let sampleTotal: Int
}

// MARK: - Client

struct ZagASCClient: Sendable {
	/// The API host, without a scheme (the URL is built with `https`).
	static let host = "api.appstoreconnect.apple.com"
	/// The largest page Zag Store ever asks for.
	static let maximumLimit = 200

	let transport: ZagHTTPTransport
	let credential: ZagDeveloperAccountCredential
	/// The clock and lifetime used to mint each request's token.
	var now: @Sendable () -> Date = { Date() }
	var tokenLifetime: TimeInterval = 10 * 60
	/// Called after each successful write (POST, PATCH, DELETE). It is how the
	/// developer-account method establishes that the key can really provision
	/// (a read-only check cannot), never with any request data.
	var writeObserver: (@Sendable () -> Void)?

	private struct Collection<Attributes: Decodable & Sendable>: Decodable {
		struct Meta: Decodable { struct Paging: Decodable { let total: Int? }; let paging: Paging? }
		let data: [ZagASCRecord<Attributes>]
		let meta: Meta?
	}

	private struct Single<Attributes: Decodable & Sendable>: Decodable {
		let data: ZagASCRecord<Attributes>
	}

	private struct ErrorEnvelope: Decodable {
		struct Item: Decodable { let status: String?; let code: String? }
		let errors: [Item]
	}

	// MARK: Reads

	/// Reads a page of a resource with decoded attributes. `filters` become
	/// `filter[key]=value` query items.
	func list<Attributes: Decodable & Sendable>(
		_ resource: ZagASCResource,
		as _: Attributes.Type,
		filters: [String: String] = [:],
		limit: Int = 200
	) async throws -> (records: [ZagASCRecord<Attributes>], total: Int?) {
		var query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, Self.maximumLimit))))]
		for (key, value) in filters.sorted(by: { $0.key < $1.key }) {
			query.append(URLQueryItem(name: "filter[\(key)]", value: value))
		}
		let response = try await perform(method: "GET", path: resource.rawValue, query: query)
		guard let collection = try? JSONDecoder().decode(Collection<Attributes>.self, from: response.body) else {
			throw ZagASCError.malformedResponse
		}
		return (collection.data, collection.meta?.paging?.total)
	}

	/// A read-only probe: lists one certificate. 2xx means the key is valid and
	/// can reach the Provisioning endpoints; 403 means it cannot (not a team
	/// key with Admin access). Creates and changes nothing.
	func connectionCheck() async throws -> ZagASCConnection {
		let (records, total) = try await list(.certificates, as: ZagASCCertificate.self, limit: 1)
		return ZagASCConnection(sampleTotal: total ?? records.count)
	}

	// MARK: Writes

	/// Creates a resource from its attributes and relationships, returning the
	/// one decoded record Apple replies with.
	func create<Attributes: Decodable & Sendable>(
		_ resource: ZagASCResource,
		attributes: [String: Any],
		relationships: [String: Any] = [:],
		as _: Attributes.Type
	) async throws -> ZagASCRecord<Attributes> {
		var data: [String: Any] = ["type": resource.type, "attributes": attributes]
		if !relationships.isEmpty { data["relationships"] = relationships }
		guard let body = try? JSONSerialization.data(withJSONObject: ["data": data]) else {
			throw ZagASCError.malformedRequest
		}
		let response = try await perform(method: "POST", path: resource.rawValue, body: body)
		guard let single = try? JSONDecoder().decode(Single<Attributes>.self, from: response.body) else {
			throw ZagASCError.malformedResponse
		}
		return single.data
	}

	/// Changes attributes of an existing resource (`PATCH`), returning the
	/// updated record. Used to re-enable a disabled device.
	func update<Attributes: Decodable & Sendable>(
		_ resource: ZagASCResource,
		id: String,
		attributes: [String: Any],
		as _: Attributes.Type
	) async throws -> ZagASCRecord<Attributes> {
		guard Self.isValidID(id),
			  let body = try? JSONSerialization.data(withJSONObject: ["data": ["type": resource.type, "id": id, "attributes": attributes]]) else {
			throw ZagASCError.malformedRequest
		}
		let response = try await perform(method: "PATCH", path: resource.rawValue + "/" + id, body: body)
		guard let single = try? JSONDecoder().decode(Single<Attributes>.self, from: response.body) else {
			throw ZagASCError.malformedResponse
		}
		return single.data
	}

	/// Deletes a resource (`DELETE`, 204). A resource that is already gone is
	/// not an error.
	func delete(_ resource: ZagASCResource, id: String) async throws {
		guard Self.isValidID(id) else { throw ZagASCError.malformedRequest }
		do {
			_ = try await perform(method: "DELETE", path: resource.rawValue + "/" + id)
		} catch ZagASCError.notFound {
			return
		}
	}

	/// Wraps a DER certificate signing request as the PEM text ASC expects for
	/// `csrContent`.
	static func pemCSR(_ der: Data) -> String {
		let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
		return "-----BEGIN CERTIFICATE REQUEST-----\n\(base64)\n-----END CERTIFICATE REQUEST-----"
	}

	// MARK: Internals

	/// ASC resource IDs are opaque but path-safe: letters, digits and dashes.
	static func isValidID(_ id: String) -> Bool {
		!id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
	}

	private func perform(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> ZagHTTPResponse {
		let token: String
		do {
			token = try ZagASCToken.mint(
				keyID: credential.keyID,
				issuerID: credential.issuerID,
				privateKeyPEM: credential.privateKeyPEM,
				issuedAt: now(),
				lifetime: tokenLifetime
			)
		} catch {
			throw ZagASCError.tokenUnavailable
		}

		var components = URLComponents()
		components.scheme = "https"
		components.host = Self.host
		components.path = "/" + path
		if !query.isEmpty { components.queryItems = query }
		guard let url = components.url else { throw ZagASCError.malformedRequest }

		var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
		if body != nil { headers["Content-Type"] = "application/json" }
		let request = ZagHTTPRequest(url: url, method: method, headers: headers, body: body)

		let response: ZagHTTPResponse
		do {
			response = try await transport.send(request)
		} catch let error as ZagTransportError {
			throw ZagASCError.transport(error)
		} catch is CancellationError {
			throw ZagASCError.transport(.cancelled)
		} catch {
			throw ZagASCError.transport(.failed(code: 0))
		}
		switch response.statusCode {
		case 200..<300:
			if method != "GET" { writeObserver?() }
			return response
		case 400, 422:
			throw ZagASCError.invalidRequest(code: Self.code(response.body))
		case 401:
			throw ZagASCError.unauthorized
		case 403:
			throw ZagASCError.forbidden
		case 404:
			throw ZagASCError.notFound
		case 409:
			throw ZagASCError.conflict(code: Self.code(response.body))
		case 429:
			throw ZagASCError.rateLimited
		case 500...599:
			throw ZagASCError.server(status: response.statusCode)
		default:
			throw ZagASCError.unexpected(status: response.statusCode, code: Self.code(response.body))
		}
	}

	private static func code(_ body: Data) -> String? {
		(try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.errors.first?.code
	}
}

/// `dump`, `print` and the debugger show the key ID only, never the `.p8`.
extension ZagASCClient: CustomReflectable {
	var customMirror: Mirror { Mirror(self, children: ["keyID": credential.keyID], displayStyle: .struct) }
}
