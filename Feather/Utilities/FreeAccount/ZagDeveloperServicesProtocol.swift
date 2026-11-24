import Foundation

// NATIVE free-account developer-services protocol (Phase 3).
//
// apple-auth implements the AUTHENTICATION layer only: `developer_session`
// mints the Xcode developer-services token and `developer_headers` emits the
// signed header bag (X-Apple-GS-Token, X-Apple-I-Identity-Id, X-Apple-App-Info:
// com.apple.gs.xcode.auth, User-Agent: Xcode, X-Xcode-Version + anisette). It
// implements NONE of the developer-account operations. This file is the pure,
// network-free codec for the developer-services ("QH65B2") plist protocol that
// Xcode uses on top of those headers: it builds request bodies and endpoints
// and parses responses. It makes no requests itself and holds no token.
//
// The protocol constants and endpoint paths are reverse-engineered from the
// Xcode / AltStore / SideStore free-account flow and are marked to-confirm
// against the first live experiments; the plist envelope shape is stable.

/// A single developer-services operation: its endpoint action and whether it
/// only reads account state or mutates it. Mutations are gated on explicit
/// consent by the live portal; read-only operations are not.
enum ZagDeveloperServicesAction: String, Sendable, Equatable, CaseIterable {
	// Read-only discovery. Action strings verified against AltSign/SideStore.
	case listTeams           = "listTeams.action"
	case listDevices         = "ios/listDevices.action"
	// NOTE: certificate LISTING and REVOKE now use the /services/v1/ JSON API
	// (POST with X-HTTP-Method-Override: GET/DELETE, application/vnd.api+json,
	// response under "data"), NOT this QH65B2 plist action. Kept here only as a
	// placeholder; the cert phase must switch these two to the v1 transport.
	case listCertificates    = "ios/listAllDevelopmentCerts.action"
	case listAppIDs          = "ios/listAppIds.action"
	case listAppGroups       = "ios/listApplicationGroups.action"
	case listProfiles        = "ios/listProvisioningProfiles.action"
	// Account-state mutations.
	case addDevice           = "ios/addDevice.action"
	case submitCSR           = "ios/submitDevelopmentCSR.action"
	case revokeCertificate   = "ios/revokeDevelopmentCert.action"   // superseded by v1 DELETE
	case addAppID            = "ios/addAppId.action"
	case addAppGroup         = "ios/addApplicationGroup.action"
	case assignAppGroups     = "ios/assignApplicationGroupToAppId.action"
	case downloadProfile     = "ios/downloadTeamProvisioningProfile.action"

	/// `true` when the operation only reads; `false` when it changes the
	/// developer account (creates/registers/revokes). The single source of
	/// truth the live portal consults before gating on consent.
	var isMutating: Bool {
		switch self {
		case .listTeams, .listDevices, .listCertificates, .listAppIDs, .listAppGroups, .listProfiles:
			return false
		case .addDevice, .submitCSR, .revokeCertificate, .addAppID, .addAppGroup, .assignAppGroups, .downloadProfile:
			// downloadTeamProvisioningProfile creates the team profile on demand,
			// so it is treated as a mutation out of caution.
			return true
		}
	}
}

enum ZagNativePortalError: Error, Equatable, Sendable {
	/// A mutating operation was attempted without explicit per-operation consent.
	case consentRequired(ZagDeveloperServicesAction)
	/// The native portal was used without being explicitly enabled.
	case notEnabled
	/// The request ceiling for one provisioning sequence was reached.
	case requestCeilingReached
}

/// Decides, per mutating operation, whether the user has consented. The safe
/// default denies everything, so nothing mutates the account without a real
/// gate supplied at the live step.
protocol ZagAccountMutationConsent: Sendable {
	func mayPerform(_ action: ZagDeveloperServicesAction) -> Bool
}

struct ZagDenyingMutationConsent: ZagAccountMutationConsent {
	func mayPerform(_ action: ZagDeveloperServicesAction) -> Bool { false }
}

/// Pure codec for the developer-services plist protocol. No I/O, no token.
enum ZagDeveloperServicesProtocol {
	static let host = "developerservices2.apple.com"
	/// Xcode's client id and protocol version for the QH65B2 service. To-confirm.
	static let clientID = "XABBG36SBA"
	static let protocolVersion = "QH65B2"
	static let defaultLocale = "en_US"

	static func endpoint(_ action: ZagDeveloperServicesAction) throws -> URL {
		guard let url = URL(string: "https://\(host)/services/\(protocolVersion)/\(action.rawValue)?clientId=\(clientID)") else {
			throw ZagPortalError.malformedResponse
		}
		return url
	}

	/// The XML-plist request body. Every request carries the envelope keys
	/// (clientId, protocolVersion, requestId, userLocale) plus the team id (when
	/// known) and the action-specific `parameters`. `requestId` is a fresh
	/// uppercased UUID per request. Never contains the token (that is a header).
	static func requestBody(teamID: String?, parameters: [String: Any] = [:], requestID: String = UUID().uuidString.uppercased()) throws -> Data {
		var plist: [String: Any] = [
			"clientId": clientID,
			"protocolVersion": protocolVersion,
			"requestId": requestID,
			"userLocale": [defaultLocale],
		]
		if let teamID, !teamID.isEmpty { plist["teamId"] = teamID }
		for (key, value) in parameters { plist[key] = value }
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	}

	/// Parsed, validated developer-services response: the top-level plist with
	/// its result code checked. Throws a mapped `ZagPortalError` on any Apple
	/// error code, so callers only ever see a success dictionary.
	static func parse(_ body: Data, httpStatus: Int) throws -> [String: Any] {
		guard (200..<300).contains(httpStatus) else {
			throw httpStatus == 401 || httpStatus == 403 ? ZagPortalError.sessionRejected
				: httpStatus == 429 ? ZagPortalError.rateLimited
				: ZagPortalError.network
		}
		guard let object = try? PropertyListSerialization.propertyList(from: body, format: nil),
			  let dict = object as? [String: Any] else {
			throw ZagPortalError.malformedResponse
		}
		try throwIfError(dict)
		return dict
	}

	/// Maps the developer-services result code / user string to a typed error.
	/// resultCode 0 (or absent with no error string) is success. The specific
	/// codes are the documented Xcode/AltStore ones; unknown non-zero codes map
	/// to `.malformedResponse` so nothing proceeds on an unrecognised state.
	static func throwIfError(_ dict: [String: Any]) throws {
		let code = (dict["resultCode"] as? NSNumber)?.intValue ?? (dict["resultCode"] as? Int) ?? 0
		if code == 0 { return }
		let message = (dict["userString"] as? String) ?? (dict["resultString"] as? String) ?? ""
		switch code {
		case 1100, 1:                 throw ZagPortalError.sessionRejected        // invalid/expired session
		case 7460:                    throw ZagPortalError.existingCertificateOrPendingRequest  // OBSERVED: "You already have a current iOS Development certificate or a pending certificate request." (NOT a throttle)
		case 9120, 9401:              throw ZagPortalError.deviceLimitReached     // device limit
		case 9412, 35:                throw ZagPortalError.appIDLimitReached      // App ID limit (free: per-week)
		case 3540, 7458:              throw ZagPortalError.certificateLimitReached// cert limit
		// 7788 was previously grouped with 7460 as a "throttle"; that grouping was
		// never evidenced and 7460 is now known NOT to be a throttle, so 7788 falls
		// through to the unknown path below rather than asserting a meaning we
		// cannot support. Genuine throttling is HTTP 429 (handled in parse()).
		default:
			// An identifier owned by another team surfaces a distinctive message.
			if message.lowercased().contains("not available") || message.lowercased().contains("already in use") {
				throw ZagPortalError.identifierUnavailable(message)
			}
			throw ZagPortalError.malformedResponse
		}
	}

	/// Captures a developer-services error WITHOUT throwing, so the raw Apple
	/// resultCode, HTTP status and a safely-redacted, bounded message can be
	/// recorded. Returns nil on success (HTTP 2xx + resultCode 0). The raw
	/// resultCode is a small integer (not sensitive); the message is redacted.
	/// Classification is CONSERVATIVE: only HTTP 429 and the verified throttle
	/// codes are a confirmed rate-limit — every other unknown non-zero code is
	/// `ambiguousRejection`, never silently called a throttle.
	static func fault(body: Data, httpStatus: Int) -> ZagDeveloperServicesFault? {
		guard (200..<300).contains(httpStatus) else {
			let classification: ZagDeveloperServicesFault.Classification =
				httpStatus == 401 || httpStatus == 403 ? .sessionRejected
				: httpStatus == 429 ? .confirmedRateLimit : .network
			return ZagDeveloperServicesFault(classification: classification, resultCode: nil, httpStatus: httpStatus, message: "")
		}
		guard let dict = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any] else {
			return ZagDeveloperServicesFault(classification: .malformed, resultCode: nil, httpStatus: httpStatus, message: "")
		}
		let code = (dict["resultCode"] as? NSNumber)?.intValue ?? (dict["resultCode"] as? Int) ?? 0
		if code == 0 { return nil }
		let raw = (dict["userString"] as? String) ?? (dict["resultString"] as? String) ?? ""
		let message = sanitizeMessage(raw)
		let classification: ZagDeveloperServicesFault.Classification
		switch code {
		case 1100, 1:     classification = .sessionRejected
		case 7460:        classification = .existingCertificateOrPendingRequest   // OBSERVED (HTTP 200 + 7460): existing cert / pending request, NOT a throttle
		case 9120, 9401:  classification = .deviceLimitReached
		case 9412, 35:    classification = .appIDLimitReached
		case 3540, 7458:  classification = .certificateLimitReached
		// 7788 is intentionally NOT mapped here: its old "confirmedRateLimit" label
		// was inherited without evidence, and the only code grouped with it (7460)
		// proved to be a certificate conflict. It now falls to ambiguousRejection
		// (the explicit "unknown" bucket). Genuine throttling is HTTP 429 above.
		default:
			classification = (raw.lowercased().contains("not available") || raw.lowercased().contains("already in use"))
				? .identifierUnavailable : .ambiguousRejection
		}
		return ZagDeveloperServicesFault(classification: classification, resultCode: code, httpStatus: httpStatus, message: message)
	}

	/// Redacts and bounds an Apple error string for diagnostics: removes anything
	/// email/token-like, strips control characters, collapses whitespace and caps
	/// the length. Never returns credentials, identifiers or long opaque tokens.
	static func sanitizeMessage(_ text: String, limit: Int = 160) -> String {
		var s = text
		for pattern in ["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[A-Za-z0-9+/_-]{24,}={0,2}"] {
			s = s.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
		}
		s = String(s.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 32) })
		s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
		return s.count > limit ? String(s.prefix(limit)) + "…" : s
	}

	/// Wraps DER CSR bytes as a PEM CERTIFICATE REQUEST, as the portal expects.
	/// Pure; the private key is never involved (only the public request).
	static func pem(_ der: Data) -> String {
		let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
		return "-----BEGIN CERTIFICATE REQUEST-----\n\(b64)\n-----END CERTIFICATE REQUEST-----\n"
	}

	/// Parses a certificate row from either the QH65B2 `certRequest` dict or a
	/// `/services/v1/certificates` `data[]` item. Field names verified against
	/// AltSign/SideStore: DER bytes come from `certContent` (raw) or
	/// `certificateContent` (base64 string); serial from `serialNumber`/`serialNum`;
	/// an `attributes` sub-dict is used when present (v1 JSON). Pure.
	static func parseCertificate(_ row: [String: Any]) -> ZagParsedCertificate? {
		let attrs = (row["attributes"] as? [String: Any]) ?? row
		var der: Data? = attrs["certContent"] as? Data
		if der == nil, let b64 = attrs["certificateContent"] as? String { der = Data(base64Encoded: b64) }
		let serial = (attrs["serialNumber"] as? String) ?? (attrs["serialNum"] as? String)
		guard serial != nil || der != nil else { return nil }
		return ZagParsedCertificate(
			serialNumber: (serial ?? "").drop(while: { $0 == "0" }).isEmpty && !(serial ?? "").isEmpty ? (serial ?? "") : String((serial ?? "").drop(while: { $0 == "0" })),
			name: (attrs["name"] as? String) ?? "iOS Development",
			machineName: attrs["machineName"] as? String,
			expiresAt: date(attrs["expirationDate"]),
			der: der)
	}

	/// ISO8601 (with or without fractional seconds) or a native Date.
	static func date(_ value: Any?) -> Date? {
		if let date = value as? Date { return date }
		guard let string = value as? String else { return nil }
		return iso8601.date(from: string) ?? iso8601NoFraction.date(from: string)
	}
	static let iso8601: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
	}()
	static let iso8601NoFraction = ISO8601DateFormatter()
}

/// A certificate parsed from a developer-services response, independent of the
/// app model graph (so the parser is host-testable). Serial has leading zeros
/// stripped, as AltSign does, for serial-based matching.
/// A developer-services error captured without throwing, so the raw resultCode,
/// HTTP status and a redacted message can be recorded and reconciled later.
struct ZagDeveloperServicesFault: Equatable, Sendable {
	/// Conservative classification: a confirmed server rate-limit is distinguished
	/// from an unknown/ambiguous rejection, which is never silently called a throttle.
	enum Classification: String, Equatable, Sendable {
		case sessionRejected
		case confirmedRateLimit
		case deviceLimitReached
		case appIDLimitReached
		case certificateLimitReached
		/// resultCode 7460: the account already has a current development certificate
		/// or an outstanding pending certificate request. A definite application-level
		/// refusal (nothing was created), kept DISTINCT from a numeric certificate cap
		/// and from HTTP throttling.
		case existingCertificateOrPendingRequest
		case identifierUnavailable
		/// A non-zero resultCode we do not map with confidence — outcome unknown.
		case ambiguousRejection
		/// The body was not a usable plist.
		case malformed
		/// A non-2xx, non-auth, non-throttle HTTP status (transport/service level).
		case network
	}
	let classification: Classification
	/// The raw Apple resultCode (a small integer; not sensitive). Nil for HTTP-level faults.
	let resultCode: Int?
	let httpStatus: Int
	/// A redacted, length-bounded message. Never a credential/identifier/token.
	let message: String

	var sanitized: [String: Any] {
		var out: [String: Any] = ["classification": classification.rawValue, "http_status": httpStatus]
		if let resultCode { out["result_code"] = resultCode }
		if !message.isEmpty { out["apple_message"] = message }
		return out
	}
}

struct ZagParsedCertificate: Equatable, Sendable {
	let serialNumber: String
	let name: String
	let machineName: String?
	let expiresAt: Date?
	let der: Data?
}

/// The newer `/services/v1/` JSON API, used (per AltSign/SideStore) for
/// certificate LISTING and REVOKE. Pure codec: no I/O, no token. The logical
/// GET/DELETE is sent as POST with `X-HTTP-Method-Override`, bodies and
/// responses are JSON:API (`application/vnd.api+json`), results under `data`.
enum ZagDeveloperServicesV1 {
	static let host = ZagDeveloperServicesProtocol.host  // developerservices2.apple.com
	static let base = "https://developerservices2.apple.com/services/v1/"
	static let contentType = "application/vnd.api+json"

	static func endpoint(_ path: String) throws -> URL {
		guard let url = URL(string: base + path) else { throw ZagPortalError.malformedResponse }
		return url
	}

	/// Body for listing development certificates: a JSON object carrying the
	/// url-encoded query (teamId + certificate-type filter), as AltSign sends it.
	static func listCertificatesBody(teamID: String, certificateTypes: String = "IOS_DEVELOPMENT,DEVELOPMENT") throws -> Data {
		let raw = "teamId=\(teamID)&filter[certificateType]=\(certificateTypes)"
		let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "=&-_"))) ?? raw
		return try JSONSerialization.data(withJSONObject: ["urlEncodedQueryParams": encoded], options: [])
	}

	/// Parses a JSON:API response and returns the `data` array, mapping any
	/// `errors` / HTTP status to a typed `ZagPortalError`. Pure.
	static func parseList(_ body: Data, httpStatus: Int) throws -> [[String: Any]] {
		guard (200..<300).contains(httpStatus) else {
			throw httpStatus == 401 || httpStatus == 403 ? ZagPortalError.sessionRejected
				: httpStatus == 429 ? ZagPortalError.rateLimited : ZagPortalError.network
		}
		guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw ZagPortalError.malformedResponse }
		if let errors = obj["errors"] as? [[String: Any]], let first = errors.first {
			let detail = ((first["detail"] as? String) ?? (first["title"] as? String) ?? "").lowercased()
			if detail.contains("limit") || detail.contains("maximum") { throw ZagPortalError.certificateLimitReached }
			throw ZagPortalError.malformedResponse
		}
		return (obj["data"] as? [[String: Any]]) ?? []
	}

	/// The headers the v1 API needs beyond the developer-headers bag:
	/// the method override and the JSON:API content types.
	static func headers(methodOverride: String) -> [String: String] {
		["X-HTTP-Method-Override": methodOverride, "Content-Type": contentType, "Accept": contentType]
	}
}

/// A tiny thread-safe counter: a hard ceiling on requests for one provisioning
/// sequence, with no retries. Shared by every operation of one portal instance.
final class ZagRequestBudget: @unchecked Sendable {
	private let lock = NSLock()
	private var remaining: Int
	let limit: Int
	init(limit: Int) { self.limit = max(0, limit); self.remaining = max(0, limit) }
	func take() -> Bool { lock.withLock { guard remaining > 0 else { return false }; remaining -= 1; return true } }
	var used: Int { lock.withLock { limit - remaining } }
}
