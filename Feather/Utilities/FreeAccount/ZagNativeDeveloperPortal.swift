import Foundation

// Native developer services uses the persisted Apple session and scoped consent.
/// A developer team as returned by read-only discovery (`viewDeveloper` /
/// listTeams). Not part of `ZagDeveloperPortalService`: discovery precedes it.
struct ZagNativeDeveloperTeam: Codable, Equatable, Sendable {
	let teamID: String
	let name: String
	/// e.g. "active"; Apple also reports membership type for free accounts.
	let status: String
	let type: String?

	var isPersonalTeam: Bool {
		let membership = type?.lowercased()
		return ZagDeveloperTeam.isValidIdentifier(teamID)
			&& status.lowercased() != "inactive"
			&& (membership?.contains("free") == true || membership?.contains("personal") == true
				|| name.lowercased().hasSuffix("(personal team)"))
	}

}

// ZagNativePortalError, ZagAccountMutationConsent and ZagDenyingMutationConsent
// live in ZagDeveloperServicesProtocol.swift (pure), so the consent coordinator
// and host tests compile without the app model graph.

extension ZagNativeDeveloperPortal: ZagReplacementPortal {
	var lastFailureReason: String? { fault.reason }
}

/// A tiny thread-safe box for the last request's sanitized failure reason.
/// Reference type so a `let` on the value-type portal still records across a
/// non-mutating `send`. Holds ONLY a short, secret-free string (an HTTP status
/// or a transport-refusal reason) — never a token, header value or body.
final class ZagPortalFaultBox: @unchecked Sendable {
	private let lock = NSLock()
	private var value: String?
	func set(_ s: String?) { lock.lock(); value = s; lock.unlock() }
	var reason: String? { lock.lock(); defer { lock.unlock() }; return value }
}

struct ZagNativeDeveloperPortal: ZagDeveloperPortalService {
	/// Supplies the current developer headers (token bag). Async so it can be
	/// backed by the Keychain-held session; it performs NO network itself
	/// (developer_headers is local in apple-auth). Returns an empty map when no
	/// developer session is available, which surfaces as `.sessionRejected`.
	typealias HeadersProvider = @Sendable () async throws -> [String: String]

	private let transport: ZagHTTPTransport
	private let headers: HeadersProvider
	private let consent: ZagAccountMutationConsent
	private let now: @Sendable () -> Date
	/// Shared across one provisioning sequence; counts every request, mutating
	/// or not, and refuses past the ceiling. No retries anywhere.
	private let budget: ZagRequestBudget?
	/// The last request's sanitized failure reason (see `ZagPortalFaultBox`).
	private let fault = ZagPortalFaultBox()

	init(transport: ZagHTTPTransport,
		 headers: @escaping HeadersProvider,
		 consent: ZagAccountMutationConsent = ZagDenyingMutationConsent(),
		 maxRequests: Int? = 16,
		 now: @escaping @Sendable () -> Date = { Date() }) {
		self.transport = transport
		self.headers = headers
		self.consent = consent
		self.budget = maxRequests.map { ZagRequestBudget(limit: $0) }
		self.now = now
	}

	/// The transport pinned to the developer-services host only.
	static func transport() -> ZagURLSessionTransport {
		ZagURLSessionTransport(policy: ZagTransportPolicy(allowedHosts: [ZagDeveloperServicesProtocol.host]))
	}

	#if canImport(ZagAppleAuth)
	/// Production construction: headers come from the machine's LOCAL
	/// `developer_headers` bridge (persisted token + this scope's ADI, no
	/// network), over the pinned transport. Mutations stay default-denied unless
	/// a real consent gate is supplied at the live step.
	static func live(machine: ZagAppleAuthMachine,
					 consent: ZagAccountMutationConsent = ZagDenyingMutationConsent(),
					 maxRequests: Int? = 16) -> ZagNativeDeveloperPortal {
		ZagNativeDeveloperPortal(transport: transport(),
								 headers: { await machine.developerHeaders() ?? [:] },
								 consent: consent, maxRequests: maxRequests)
	}

	/// First-live-session construction: the pinned transport is wrapped in the
	/// read-only boundary, so ONLY read-only endpoints (certificate inventory,
	/// team/device discovery) can ever leave the device — a revoke or a CSR is
	/// refused before transmission, independent of consent. Mutations are ALSO
	/// denied at the consent layer (defence in depth), but the transport is the
	/// hard boundary. A smaller request ceiling bounds the session.
	static func readOnlyInventory(machine: ZagAppleAuthMachine = ZagAppleAuthMachine.nativeAccount(),
								  maxRequests: Int? = nil) -> ZagNativeDeveloperPortal {
		ZagNativeDeveloperPortal(transport: ZagReadOnlyTransport(base: transport()),
								 headers: { await machine.developerHeaders() ?? [:] },
								 consent: ZagDenyingMutationConsent(), maxRequests: maxRequests)
	}
	#endif

	// MARK: - Core request

	private func send(_ action: ZagDeveloperServicesAction, teamID: String?, parameters: [String: Any] = [:]) async throws -> [String: Any] {
		if action.isMutating && !consent.mayPerform(action) { throw ZagNativePortalError.consentRequired(action) }
		guard budget?.take() != false else { throw ZagNativePortalError.requestCeilingReached }
		var requestHeaders = try await headers()
		guard !requestHeaders.isEmpty, requestHeaders.keys.contains(where: { $0.lowercased() == "x-apple-gs-token" }) else {
			throw ZagPortalError.sessionRejected
		}
		requestHeaders["Content-Type"] = "text/x-xml-plist"
		requestHeaders["Accept"] = "text/x-xml-plist"
		requestHeaders["Accept-Language"] = "en-us"
		let request = ZagHTTPRequest(
			url: try ZagDeveloperServicesProtocol.endpoint(action),
			method: "POST",
			headers: requestHeaders,
			body: try ZagDeveloperServicesProtocol.requestBody(teamID: teamID, parameters: parameters))
		fault.set(nil)
		let response: ZagHTTPResponse
		do {
			response = try await transport.send(request)
		} catch let error as ZagTransportError {
			fault.set(Self.transportReason(error))
			throw ZagPortalError.network
		}
		// A non-2xx that parse collapses to `.network` (not 401/403/429) keeps its
		// status, so the banner shows e.g. "HTTP 404" instead of a bare "network".
		if !(200..<300).contains(response.statusCode),
		   ![401, 403, 429].contains(response.statusCode) {
			fault.set("HTTP \(response.statusCode)")
		}
		return try ZagDeveloperServicesProtocol.parse(response.body, httpStatus: response.statusCode, action: action)
	}

	/// A short, secret-free reason for a transport refusal.
	private static func transportReason(_ error: ZagTransportError) -> String {
		switch error {
		case .offline:                 return "offline"
		case .timedOut:                return "timed out"
		case .readOnlyBlocked(let w):  return "read-only blocked: \(w)"
		default:                       return "transport refused"
		}
	}

	// MARK: - Read-only discovery

	/// Team discovery — the smallest safe first live experiment. Read-only.
	func teams() async throws -> [ZagNativeDeveloperTeam] {
		let dict = try await send(.listTeams, teamID: nil)
		let rows = (dict["teams"] as? [[String: Any]]) ?? []
		return rows.compactMap { row in
			guard let id = row["teamId"] as? String else { return nil }
			let memberships = (row["memberships"] as? [[String: Any]])?.first
			return ZagNativeDeveloperTeam(
				teamID: id,
				name: (row["name"] as? String) ?? id,
				status: (row["status"] as? String) ?? "unknown",
				type: (memberships?["name"] as? String) ?? (row["type"] as? String))
		}
	}

	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		let dict = try await send(.listDevices, teamID: team)
		guard let rows = dict["devices"] as? [[String: Any]] else { throw ZagPortalError.malformedResponse }
		return rows.compactMap { row in
			guard let udid = (row["deviceNumber"] as? String) ?? (row["udid"] as? String) else { return nil }
			return ZagRegisteredDevice(udid: udid, name: (row["name"] as? String) ?? "device")
		}
	}

	func appIDs(team: String) async throws -> [ZagRegisteredAppID] {
		let dict = try await send(.listAppIDs, teamID: team)
		guard let rows = dict["appIds"] as? [[String: Any]] else { throw ZagPortalError.malformedResponse }
		return rows.compactMap { row in
			guard let identifier = (row["appIdId"] as? String) ?? (row["appIdentifierId"] as? String),
				  let bundle = (row["identifier"] as? String) else { return nil }
			return ZagRegisteredAppID(identifier: identifier, bundleIdentifier: bundle,
									  expiresAt: ZagDeveloperServicesProtocol.date(row["expirationDate"]))
		}
	}

	private func appGroupRows(team: String) async throws -> [[String: Any]] {
		let dict = try await send(.listAppGroups, teamID: team)
		guard let rows = dict["applicationGroupList"] as? [[String: Any]] else { throw ZagPortalError.malformedResponse }
		return rows
	}

	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] {
		try await appGroupRows(team: team).compactMap { row in
			(row["identifier"] as? String).map { ZagRegisteredAppGroup(identifier: $0) }
		}
	}

	/// Development certificates via the `/services/v1/` JSON API (POST +
	/// X-HTTP-Method-Override: GET), not the QH65B2 plist action. Read-only.
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		let rows = try await listCertificateRows(team: team)
		var certificates: [ZagDevelopmentCertificate] = []
		for row in rows {
			guard let parsed = ZagDeveloperServicesProtocol.parseCertificate(row) else { throw ZagPortalError.malformedResponse }
			let complete = await certificateDetail(for: row, parsed: parsed, team: team)
			certificates.append(Self.certificate(complete))
		}
		return certificates
	}

	/// Read-only revocation candidates: the same listing as `certificates(team:)`,
	/// preserving the certificate id and a DER SHA-1 so a later (consent-gated,
	/// here blocked) revoke could target the EXACT certificate.
	func revocableCertificates(team: String) async throws -> [ZagRevocableCertificate] {
		let rows = try await listCertificateRows(team: team)
		return ZagCertificateRevocation.candidates(from: rows).map { candidate in
			let parsed = rows.first { $0["id"] as? String == candidate.id }.flatMap(ZagDeveloperServicesProtocol.parseCertificate)
			guard let der = parsed?.der, ZagCertificateInspection(der: der) != nil else {
				return ZagRevocableCertificate(id: candidate.id, serialNumber: candidate.serialNumber, sha1: nil,
											   name: candidate.name, machineName: candidate.machineName, expiresAt: candidate.expiresAt)
			}
			return candidate
		}
	}

	private func listCertificateRows(team: String) async throws -> [[String: Any]] {
		let response = try await sendV1(path: "certificates", methodOverride: "GET",
									   body: ZagDeveloperServicesV1.listCertificatesBody(teamID: team))
		if !(200..<300).contains(response.statusCode) { fault.set("HTTP \(response.statusCode)") }
		let rows = try ZagDeveloperServicesV1.parseList(response.body, httpStatus: response.statusCode)
		guard rows.allSatisfy({ ZagDeveloperServicesProtocol.parseCertificate($0) != nil }) else {
			throw ZagPortalError.malformedResponse
		}
		return rows
	}

	/// The collection may contain only serial and display metadata. Try the
	/// individual resource and accept its DER only for the exact listed ID and serial.
	private func certificateDetail(for row: [String: Any], parsed: ZagParsedCertificate, team: String) async -> ZagParsedCertificate {
		if let der = parsed.der, ZagCertificateInspection(der: der) != nil { return parsed }
		guard let id = row["id"] as? String, Self.isCertificateID(id),
			  let body = try? ZagDeveloperServicesV1.listCertificatesBody(teamID: team),
			  let response = try? await sendV1(path: "certificates/\(id)", methodOverride: "GET", body: body),
			  (200..<300).contains(response.statusCode),
			  let document = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
			  let resource = document["data"] as? [String: Any], resource["id"] as? String == id,
			  let detail = ZagDeveloperServicesProtocol.parseCertificate(resource), let der = detail.der,
			  let inspected = ZagCertificateInspection(der: der),
			  parsed.serialNumber.isEmpty || Self.normalizedSerial(inspected.serialNumber) == Self.normalizedSerial(parsed.serialNumber) else {
			return parsed
		}
		return detail
	}

	private static func isCertificateID(_ id: String) -> Bool {
		!id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
	}

	private static func normalizedSerial(_ serial: String) -> String {
		String(serial.uppercased().drop(while: { $0 == "0" }))
	}

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		let dict = try await send(.downloadProfile, teamID: team, parameters: ["appIdId": appID.identifier])
		guard let profile = dict["provisioningProfile"] as? [String: Any],
			  let encoded = (profile["encodedProfile"] as? Data) ?? (profile["encodedProfile"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw ZagPortalError.malformedResponse }
		return try ZagIssuedProfile(profileData: encoded)
	}

	// MARK: - Mutations (consent-gated)

	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice {
		let dict = try await send(.addDevice, teamID: team, parameters: ["deviceNumber": udid, "name": name])
		let row = (dict["device"] as? [String: Any]) ?? [:]
		return ZagRegisteredDevice(udid: (row["deviceNumber"] as? String) ?? udid, name: (row["name"] as? String) ?? name)
	}

	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID {
		let allowed = CharacterSet.alphanumerics.union(.whitespaces)
		let cleanName = name.folding(options: .diacriticInsensitive, locale: nil)
			.components(separatedBy: allowed.inverted).joined().trimmingCharacters(in: .whitespaces)
		let dict = try await send(.addAppID, teamID: team, parameters: ["identifier": bundleIdentifier, "name": cleanName.isEmpty ? "Zag Store App" : cleanName])
		let row = (dict["appId"] as? [String: Any]) ?? [:]
		guard let identifier = row["appIdId"] as? String else { throw ZagPortalError.malformedResponse }
		return ZagRegisteredAppID(identifier: identifier,
								  bundleIdentifier: (row["identifier"] as? String) ?? bundleIdentifier,
								  expiresAt: ZagDeveloperServicesProtocol.date(row["expirationDate"]))
	}

	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup {
		let dict = try await send(.addAppGroup, teamID: team, parameters: ["identifier": identifier, "name": identifier])
		let row = (dict["applicationGroup"] as? [String: Any]) ?? [:]
		return ZagRegisteredAppGroup(identifier: (row["identifier"] as? String) ?? identifier)
	}

	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws {
		let rows = try await appGroupRows(team: team)
		let groupIDs = try groups.map { group in
			guard let row = rows.first(where: { $0["identifier"] as? String == group }),
				  let id = row["applicationGroup"] as? String else { throw ZagPortalError.malformedResponse }
			return id
		}
		_ = try await send(.assignAppGroups, teamID: team,
						   parameters: ["appIdId": appID.identifier, "applicationGroups": groupIDs])
	}

	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		// The CSR is PEM; the private key stays in the Keychain (only the public
		// request is sent). No key material is ever in this request.
		let pem = ZagDeveloperServicesProtocol.pem(request.data)

		// machineId is a STABLE per-install identifier (not a fresh value per
		// request): the established protocol labels the request with the machine's
		// identity, and a stable id keeps the account from accruing certificates
		// that look like they came from many machines.
		let dict = try await send(.submitCSR, teamID: team, parameters: ["csrContent": pem, "machineName": "Zag Store", "machineId": ZagMachineIdentifier.current()])
		guard let row = (dict["certRequest"] as? [String: Any]) ?? (dict["certificate"] as? [String: Any]) else {
			throw ZagPortalError.malformedResponse
		}
		if let parsed = ZagDeveloperServicesProtocol.parseCertificate(row), let der = parsed.der, !der.isEmpty {
			return ZagIssuedCertificate(certificate: Self.certificate(parsed), data: der)
		}
		let id = (row["certificateId"] ?? row["certRequestId"]) as? String
		let serial = ZagDeveloperServicesProtocol.parseCertificate(row)?.serialNumber
		// Apple accepted the CSR response. A later inventory error cannot prove
		// that the CSR was refused, even if that read returns 401 or 429.
		guard id != nil || serial?.isEmpty == false,
			  let listed = try? await listCertificateRows(team: team) else { throw ZagPortalError.malformedResponse }
		guard let match = listed.first(where: { candidate in
			if let id, candidate["id"] as? String == id { return true }
			guard let serial, !serial.isEmpty else { return false }
			guard let candidateSerial = ZagDeveloperServicesProtocol.parseCertificate(candidate)?.serialNumber else { return false }
			return Self.normalizedSerial(candidateSerial) == Self.normalizedSerial(serial)
		}), let parsed = ZagDeveloperServicesProtocol.parseCertificate(match) else { throw ZagPortalError.malformedResponse }
		let complete = await certificateDetail(for: match, parsed: parsed, team: team)
		guard let der = complete.der, !der.isEmpty else { throw ZagPortalError.malformedResponse }
		return ZagIssuedCertificate(certificate: Self.certificate(complete), data: der)
	}

	/// Revokes ONE certificate via `/services/v1/` DELETE. Consent-gated on
	/// `.revokeCertificate` and guarded by `ZagActiveCertificateGuard`: the active
	/// Xcode certificate is refused unless `override` is explicitly set. This is
	/// never reachable from a capacity error — it requires an explicit `id`.
	func revokeCertificate(_ certificate: ZagRevocableCertificate, guard activeGuard: ZagActiveCertificateGuard,
						   override: Bool, team: String) async throws {
		guard consent.mayPerform(.revokeCertificate) else { throw ZagNativePortalError.consentRequired(.revokeCertificate) }
		guard activeGuard.mayRevoke(certificate, explicitOverride: override) else {
			throw ZagNativePortalError.consentRequired(.revokeCertificate)   // active cert without override
		}
		guard Self.isCertificateID(certificate.id) else { throw ZagPortalError.malformedResponse }
		let response = try await sendV1(path: ZagCertificateRevocation.endpointPath(id: certificate.id),
										methodOverride: ZagCertificateRevocation.methodOverride,
									body: ZagDeveloperServicesV1.listCertificatesBody(teamID: team))
		_ = try ZagCertificateRevocation.parse(response.body, httpStatus: response.statusCode)
	}

	// MARK: - Helpers

	/// One request to the `/services/v1/` JSON API over the pinned transport.
	private func sendV1(path: String, methodOverride: String, body: Data) async throws -> ZagHTTPResponse {
		guard budget?.take() != false else { throw ZagNativePortalError.requestCeilingReached }
		var requestHeaders = try await headers()
		guard !requestHeaders.isEmpty, requestHeaders.keys.contains(where: { $0.lowercased() == "x-apple-gs-token" }) else {
			throw ZagPortalError.sessionRejected
		}
		requestHeaders["Accept-Language"] = "en-us"
		for (k, v) in ZagDeveloperServicesV1.headers(methodOverride: methodOverride) { requestHeaders[k] = v }
		let request = ZagHTTPRequest(url: try ZagDeveloperServicesV1.endpoint(path), method: "POST", headers: requestHeaders, body: body)
		fault.set(nil)
		do { return try await transport.send(request) }
		catch let error as ZagTransportError { fault.set(Self.transportReason(error)); throw ZagPortalError.network }
	}

	/// Maps a parsed certificate (transport-independent) to the app model.
	private static func certificate(_ p: ZagParsedCertificate) -> ZagDevelopmentCertificate {
		let inspected = p.der.flatMap(ZagCertificateInspection.init(der:))
		return ZagDevelopmentCertificate(serialNumber: inspected?.serialNumber ?? p.serialNumber.uppercased(),
										 name: p.name, machineName: p.machineName,
										 expiresAt: inspected?.expiresAt ?? p.expiresAt ?? Date.distantPast,
										 data: inspected == nil ? nil : p.der)
	}
}
