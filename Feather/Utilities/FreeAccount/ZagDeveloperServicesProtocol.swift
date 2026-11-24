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
		case 7460, 7788, 4:           throw ZagPortalError.rateLimited            // throttled / too many
		case 9120, 9401:              throw ZagPortalError.deviceLimitReached     // device limit
		case 9412, 35:                throw ZagPortalError.appIDLimitReached      // App ID limit (free: per-week)
		case 3540, 7458:              throw ZagPortalError.certificateLimitReached// cert limit
		case 9401 where message.lowercased().contains("device"):
			throw ZagPortalError.deviceLimitReached
		default:
			// An identifier owned by another team surfaces a distinctive message.
			if message.lowercased().contains("not available") || message.lowercased().contains("already in use") {
				throw ZagPortalError.identifierUnavailable(message)
			}
			throw ZagPortalError.malformedResponse
		}
	}

	/// Wraps DER CSR bytes as a PEM CERTIFICATE REQUEST, as the portal expects.
	/// Pure; the private key is never involved (only the public request).
	static func pem(_ der: Data) -> String {
		let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
		return "-----BEGIN CERTIFICATE REQUEST-----\n\(b64)\n-----END CERTIFICATE REQUEST-----\n"
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
