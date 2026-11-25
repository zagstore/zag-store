import Foundation

// NATIVE free-account developer portal (Phase 3) — DISABLED BY DEFAULT.
//
// The first live `ZagDeveloperPortalService` for the standalone free-account
// path: it drives the developer-services ("QH65B2") operations over a bounded
// HTTPS transport to developerservices2.apple.com, authenticated purely by
// apple-auth's `developer_headers` (the native on-device token). It reuses the
// existing models, signing-key factory, provisioner, profile parser and Zsign
// raw-signer unchanged — only the live portal was missing.
//
// Safety: constructed only behind an explicit enable (never by default); every
// ACCOUNT-MUTATING operation is refused unless a consent gate returns true for
// that specific operation; read-only discovery is not gated. The transport is
// pinned to one Apple host, no redirects off it, ephemeral, size-capped, with a
// hard request ceiling and no retries. The token is held only in request
// headers and is never logged, persisted here or placed in diagnostics.

/// A developer team as returned by read-only discovery (`viewDeveloper` /
/// listTeams). Not part of `ZagDeveloperPortalService`: discovery precedes it.
struct ZagNativeDeveloperTeam: Codable, Equatable, Sendable {
	let teamID: String
	let name: String
	/// e.g. "active"; Apple also reports membership type for free accounts.
	let status: String
	let type: String?
}

// ZagNativePortalError, ZagAccountMutationConsent and ZagDenyingMutationConsent
// live in ZagDeveloperServicesProtocol.swift (pure), so the consent coordinator
// and host tests compile without the app model graph.

/// The live native portal. Disabled by default: the designated initializer is
/// internal and the convenience factory returns the disabled stub unless an
/// explicit enable is passed.
// Conforms to ZagReplacementPortal (ZagCertificateReplacementService.swift): it
// already implements all three operations that service needs.
extension ZagNativeDeveloperPortal: ZagReplacementPortal {}

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
	private let budget: ZagRequestBudget

	init(transport: ZagHTTPTransport,
		 headers: @escaping HeadersProvider,
		 consent: ZagAccountMutationConsent = ZagDenyingMutationConsent(),
		 maxRequests: Int = 16,
		 now: @escaping @Sendable () -> Date = { Date() }) {
		self.transport = transport
		self.headers = headers
		self.consent = consent
		self.budget = ZagRequestBudget(limit: maxRequests)
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
					 maxRequests: Int = 16) -> ZagNativeDeveloperPortal {
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
	static func readOnlyInventory(machine: ZagAppleAuthMachine = ZagAppleAuthMachine(),
								  maxRequests: Int = 8) -> ZagNativeDeveloperPortal {
		ZagNativeDeveloperPortal(transport: ZagReadOnlyTransport(base: transport()),
								 headers: { await machine.developerHeaders() ?? [:] },
								 consent: ZagDenyingMutationConsent(), maxRequests: maxRequests)
	}
	#endif

	// MARK: - Core request

	private func send(_ action: ZagDeveloperServicesAction, teamID: String?, parameters: [String: Any] = [:]) async throws -> [String: Any] {
		if action.isMutating && !consent.mayPerform(action) { throw ZagNativePortalError.consentRequired(action) }
		guard budget.take() else { throw ZagNativePortalError.requestCeilingReached }
		var requestHeaders = try await headers()
		guard !requestHeaders.isEmpty, requestHeaders.keys.contains(where: { $0.lowercased() == "x-apple-gs-token" }) else {
			throw ZagPortalError.sessionRejected
		}
		requestHeaders["Content-Type"] = "text/x-xml-plist"
		requestHeaders["Accept"] = "text/x-xml-plist"
		let request = ZagHTTPRequest(
			url: try ZagDeveloperServicesProtocol.endpoint(action),
			method: "POST",
			headers: requestHeaders,
			body: try ZagDeveloperServicesProtocol.requestBody(teamID: teamID, parameters: parameters))
		let response: ZagHTTPResponse
		do {
			response = try await transport.send(request)
		} catch let error as ZagTransportError {
			throw error == .offline || error == .timedOut ? ZagPortalError.network : ZagPortalError.network
		}
		return try ZagDeveloperServicesProtocol.parse(response.body, httpStatus: response.statusCode)
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
				type: (row["type"] as? String) ?? (memberships?["name"] as? String))
		}
	}

	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		let dict = try await send(.listDevices, teamID: team)
		return ((dict["devices"] as? [[String: Any]]) ?? []).compactMap { row in
			guard let udid = (row["deviceNumber"] as? String) ?? (row["udid"] as? String) else { return nil }
			return ZagRegisteredDevice(udid: udid, name: (row["name"] as? String) ?? "device")
		}
	}

	func appIDs(team: String) async throws -> [ZagRegisteredAppID] {
		let dict = try await send(.listAppIDs, teamID: team)
		return ((dict["appIds"] as? [[String: Any]]) ?? []).compactMap { row in
			guard let identifier = (row["appIdId"] as? String) ?? (row["appIdentifierId"] as? String),
				  let bundle = (row["identifier"] as? String) else { return nil }
			return ZagRegisteredAppID(identifier: identifier, bundleIdentifier: bundle,
									  expiresAt: ZagDeveloperServicesProtocol.date(row["expirationDate"]))
		}
	}

	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] {
		let dict = try await send(.listAppGroups, teamID: team)
		return ((dict["applicationGroupList"] as? [[String: Any]]) ?? []).compactMap { row in
			(row["identifier"] as? String).map { ZagRegisteredAppGroup(identifier: $0) }
		}
	}

	/// Development certificates via the `/services/v1/` JSON API (POST +
	/// X-HTTP-Method-Override: GET), not the QH65B2 plist action. Read-only.
	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		let response = try await sendV1(path: "certificates", methodOverride: "GET",
										body: try ZagDeveloperServicesV1.listCertificatesBody(teamID: team))
		let rows = try ZagDeveloperServicesV1.parseList(response.body, httpStatus: response.statusCode)
		return rows.compactMap { ZagDeveloperServicesProtocol.parseCertificate($0).map(Self.certificate) }
	}

	/// Read-only revocation candidates: the same `/services/v1/certificates`
	/// listing as `certificates(team:)`, but preserving the v1 `id` and a DER
	/// SHA-1 so a later revoke can target the EXACT certificate. No new endpoint.
	func revocableCertificates(team: String) async throws -> [ZagRevocableCertificate] {
		let response = try await sendV1(path: "certificates", methodOverride: "GET",
										body: try ZagDeveloperServicesV1.listCertificatesBody(teamID: team))
		let rows = try ZagDeveloperServicesV1.parseList(response.body, httpStatus: response.statusCode)
		return ZagCertificateRevocation.candidates(from: rows)
	}

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		let dict = try await send(.downloadProfile, teamID: team, parameters: ["appIdId": appID.identifier])
		guard let profile = dict["provisioningProfile"] as? [String: Any],
			  let encoded = (profile["encodedProfile"] as? Data) else { throw ZagPortalError.malformedResponse }
		return try ZagIssuedProfile(profileData: encoded)
	}

	// MARK: - Mutations (consent-gated)

	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice {
		let dict = try await send(.addDevice, teamID: team, parameters: ["deviceNumber": udid, "name": name])
		let row = (dict["device"] as? [String: Any]) ?? [:]
		return ZagRegisteredDevice(udid: (row["deviceNumber"] as? String) ?? udid, name: (row["name"] as? String) ?? name)
	}

	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID {
		let dict = try await send(.addAppID, teamID: team, parameters: ["identifier": bundleIdentifier, "name": name])
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
		_ = try await send(.assignAppGroups, teamID: team,
						   parameters: ["appIdId": appID.identifier, "applicationGroups": groups])
	}

	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		// The CSR is PEM; the private key stays in the Keychain (only the public
		// request is sent). No key material is ever in this request.
		let pem = ZagDeveloperServicesProtocol.pem(request.data)
		// submitDevelopmentCSR is a QH65B2 plist action; the DER comes straight
		// back under "certRequest" (verified: AltSign/SideStore do not re-list).
		// machineId is a STABLE per-install identifier (not a fresh value per
		// request): the established protocol labels the request with the machine's
		// identity, and a stable id keeps the account from accruing certificates
		// that look like they came from many machines.
		let dict = try await send(.submitCSR, teamID: team, parameters: ["csrContent": pem, "machineName": "Zag Store", "machineId": ZagMachineIdentifier.current()])
		guard let row = (dict["certRequest"] as? [String: Any]) ?? (dict["certificate"] as? [String: Any]),
			  let parsed = ZagDeveloperServicesProtocol.parseCertificate(row), let der = parsed.der else {
			throw ZagPortalError.malformedResponse
		}
		return ZagIssuedCertificate(certificate: Self.certificate(parsed), data: der)
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
		let response = try await sendV1(path: ZagCertificateRevocation.endpointPath(id: certificate.id),
										methodOverride: ZagCertificateRevocation.methodOverride, body: Data())
		_ = try ZagCertificateRevocation.parse(response.body, httpStatus: response.statusCode)
	}

	// MARK: - Helpers

	/// One request to the `/services/v1/` JSON API over the pinned transport.
	private func sendV1(path: String, methodOverride: String, body: Data) async throws -> ZagHTTPResponse {
		guard budget.take() else { throw ZagNativePortalError.requestCeilingReached }
		var requestHeaders = try await headers()
		guard !requestHeaders.isEmpty, requestHeaders.keys.contains(where: { $0.lowercased() == "x-apple-gs-token" }) else {
			throw ZagPortalError.sessionRejected
		}
		for (k, v) in ZagDeveloperServicesV1.headers(methodOverride: methodOverride) { requestHeaders[k] = v }
		let request = ZagHTTPRequest(url: try ZagDeveloperServicesV1.endpoint(path), method: "POST", headers: requestHeaders, body: body)
		do { return try await transport.send(request) }
		catch is ZagTransportError { throw ZagPortalError.network }
	}

	/// Maps a parsed certificate (transport-independent) to the app model.
	private static func certificate(_ p: ZagParsedCertificate) -> ZagDevelopmentCertificate {
		ZagDevelopmentCertificate(serialNumber: p.serialNumber, name: p.name, machineName: p.machineName,
								  expiresAt: p.expiresAt ?? Date.distantPast, data: p.der)
	}
}
