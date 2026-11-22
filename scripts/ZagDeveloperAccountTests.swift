import CryptoKit
import Foundation

// Milestone 1 of the App Store Connect developer-account signing method
// (ASC_API_ARCHITECTURE.md): the ES256 token, the typed client, per-account
// Keychain storage, the onboarding model and the feature gate. Everything is
// offline — the client runs against a mock transport and nothing contacts
// Apple. The real Keychain store is exercised on the simulator by
// test-zag-free-account-keychain.sh.

// MARK: - Harness

@main struct Tests {
	static var passed = 0

	static func check(_ value: Bool, _ label: String) {
		guard value else { fatalError("FAIL: \(label)") }
		passed += 1
		print("PASS: \(label)")
	}

	static let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
	static let keyID = "ABCDE12345"
	static let issuerID = "69a6de70-1234-47e3-e053-5b8c7c11a4d1"
	static let teamID = "TEAM012345"

	static func main() async {
		token()
		credential()
		storage()
		await client()
		await onboarding()
		signingMethod()
		await clientWrites()
		await portal()
		await provisioning()
		await coordinator()
		await mockASCProvisioning()
		await mockASCRecovery()
		await mockASCCoordinator()
		realAdapter()
		redaction()
		await mockASCProfiles()
		await serviceWiring()
		await installModel()
		await onboardingRemoval()
		print("SUCCESS: \(passed) developer-account (M1–M3) checks passed")
	}

	// MARK: - Helpers

	/// A fresh P-256 key as an unencrypted PKCS #8 PEM, like Apple's `.p8`.
	static func makeKeyPEM() -> (pem: String, publicKey: P256.Signing.PublicKey) {
		let key = P256.Signing.PrivateKey()
		return (key.pemRepresentation, key.publicKey)
	}

	static func base64URLDecode(_ string: String) -> Data {
		var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while s.count % 4 != 0 { s += "=" }
		return Data(base64Encoded: s) ?? Data()
	}

	static func field(_ json: Data, _ key: String) -> Any? {
		((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?[key]
	}

	static func response(_ status: Int, _ json: String) -> ZagHTTPResponse {
		ZagHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
	}

	// MARK: - Token

	static func token() {
		let (pem, publicKey) = makeKeyPEM()
		let jwt = try! ZagASCToken.mint(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem, issuedAt: fixedNow, lifetime: 600)
		let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
		check(parts.count == 3, "token: three dot-separated segments")

		let header = base64URLDecode(parts[0])
		let payload = base64URLDecode(parts[1])
		check(field(header, "alg") as? String == "ES256", "token: header alg is ES256")
		check(field(header, "kid") as? String == keyID, "token: header kid is the key ID")
		check(field(header, "typ") as? String == "JWT", "token: header typ is JWT")
		check(field(payload, "iss") as? String == issuerID, "token: payload iss is the issuer ID (team key)")
		check(field(payload, "aud") as? String == "appstoreconnect-v1", "token: payload aud is appstoreconnect-v1")
		check(field(payload, "sub") == nil, "token: no sub claim (team key, not a user key)")
		let iat = field(payload, "iat") as? Int ?? -1
		let exp = field(payload, "exp") as? Int ?? -1
		check(iat == Int(fixedNow.timeIntervalSince1970), "token: iat is the issued instant")
		check(exp - iat == 600, "token: exp honours the requested lifetime")

		// The signature verifies against the key's public half.
		let signingInput = Data((parts[0] + "." + parts[1]).utf8)
		let signature = try! P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
		check(publicKey.isValidSignature(signature, for: signingInput), "token: ES256 signature verifies")

		// Apple caps the lifetime at 20 minutes.
		let capped = try! ZagASCToken.mint(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem, issuedAt: fixedNow, lifetime: 3600)
		let cappedPayload = base64URLDecode(capped.split(separator: ".").map(String.init)[1])
		check((field(cappedPayload, "exp") as? Int ?? 0) - (field(cappedPayload, "iat") as? Int ?? 0) == 20 * 60,
			  "token: lifetime is clamped to 20 minutes")

		// Bad inputs are rejected before anything is signed.
		check((try? ZagASCToken.mint(keyID: "nope", issuerID: issuerID, privateKeyPEM: pem)) == nil, "token: rejects a malformed key ID")
		check((try? ZagASCToken.mint(keyID: keyID, issuerID: "nope", privateKeyPEM: pem)) == nil, "token: rejects a malformed issuer ID")
		let notAKey = "-----BEGIN PRIVATE KEY-----\n\(Data("not a key".utf8).base64EncodedString())\n-----END PRIVATE KEY-----"
		check((try? ZagASCToken.mint(keyID: keyID, issuerID: issuerID, privateKeyPEM: notAKey)) == nil, "token: rejects a non-key .p8 body")
	}

	// MARK: - Credential

	static func credential() {
		let (pem, _) = makeKeyPEM()
		let made = try! ZagDeveloperAccountCredential(issuerID: " \(issuerID) ", keyID: " \(keyID) ", teamID: " \(teamID.lowercased()) ", privateKeyPEM: pem)
		check(made.keyID == keyID && made.issuerID == issuerID, "credential: trims key and issuer IDs")
		check(made.teamID == teamID && made.team.kind == .individualPaid, "credential: upper-cases the team ID and is a paid team")

		check(ZagDeveloperAccountCredential.isValidKeyID(keyID), "credential: a ten upper-case key ID is valid")
		check(!ZagDeveloperAccountCredential.isValidKeyID("abcde12345"), "credential: a lower-case key ID is invalid")
		check(!ZagDeveloperAccountCredential.isValidKeyID("ABCDE1234"), "credential: a nine-character key ID is invalid")
		check(ZagDeveloperAccountCredential.isValidIssuerID(issuerID), "credential: a UUID issuer ID is valid")
		check(!ZagDeveloperAccountCredential.isValidIssuerID("not-a-uuid"), "credential: a non-UUID issuer ID is invalid")
		check(ZagDeveloperAccountCredential.looksLikePrivateKeyPEM(pem), "credential: a real .p8 looks like a private key")
		check(!ZagDeveloperAccountCredential.looksLikePrivateKeyPEM("hello"), "credential: arbitrary text is not a .p8")

		func problem(_ issuer: String, _ key: String, _ team: String, _ pem: String) -> ZagDeveloperAccountCredential.Problem? {
			do { _ = try ZagDeveloperAccountCredential(issuerID: issuer, keyID: key, teamID: team, privateKeyPEM: pem); return nil }
			catch let p as ZagDeveloperAccountCredential.Problem { return p } catch { return nil }
		}
		check(problem(issuerID, "bad", teamID, pem) == .invalidKeyID, "credential: reports a bad key ID")
		check(problem("bad", keyID, teamID, pem) == .invalidIssuerID, "credential: reports a bad issuer ID")
		check(problem(issuerID, keyID, "bad", pem) == .invalidTeamID, "credential: reports a bad team ID")
		check(problem(issuerID, keyID, teamID, "garbage") == .invalidPrivateKey, "credential: reports a bad private key")
	}

	// MARK: - Storage

	static func storage() {
		let (pem, _) = makeKeyPEM()
		let secrets = MemorySecrets()
		let store = ZagDeveloperAccountStore(secrets: secrets)
		let account = UUID(), other = UUID()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: pem)

		try! store.save(credential, account: account)
		check((try! store.load(account: account)) == credential, "storage: a saved credential loads back unchanged")
		check(store.isConnected(account: account), "storage: a saved account reads as connected")
		check((try! store.load(account: other)) == nil && !store.isConnected(account: other), "storage: another account has no credential")
		check(secrets.items.keys.allSatisfy { $0.contains("developerAPIKey") }, "storage: the key is kept under the developerAPIKey kind")

		try! store.remove(account: account)
		check((try! store.load(account: account)) == nil && !store.isConnected(account: account), "storage: disconnect removes the credential")

		// Account removal (deleteAll) also clears the key.
		try! store.save(credential, account: account)
		try! secrets.deleteAll(account: account)
		check((try! store.load(account: account)) == nil, "storage: removing the account clears the developer key")
	}

	// MARK: - Client

	static let certificatesPage = """
	{"data":[{"type":"certificates","id":"C1","attributes":{"name":"Zag","certificateType":"IOS_DEVELOPMENT","serialNumber":"AA11","expirationDate":"2027-01-01T00:00:00.000+00:00"}}],"meta":{"paging":{"total":2}}}
	"""
	static let devicesPage = """
	{"data":[{"type":"devices","id":"D1","attributes":{"name":"iPhone","udid":"00008030-ABCDEF","deviceClass":"IPHONE","status":"ENABLED","platform":"IOS"}}],"meta":{"paging":{"total":1}}}
	"""

	static func makeClient(_ transport: ZagHTTPTransport) -> ZagASCClient {
		let (pem, _) = makeKeyPEM()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: pem)
		return ZagASCClient(transport: transport, credential: credential, now: { fixedNow })
	}

	static func client() async {
		let ok = MockTransport(.success(response(200, certificatesPage)))
		let connection = try! await makeClient(ok).connectionCheck()
		check(connection.sampleTotal == 2, "client: connectionCheck reports the paging total")

		// The request is a signed GET to the certificates endpoint over https.
		let request = ok.lastRequest!
		check(request.method == "GET", "client: the probe is a GET")
		check(request.url.scheme == "https" && request.url.host == ZagASCClient.host, "client: https to the ASC host")
		check(request.url.host?.contains("appstoreconnect.apple.com") == true, "client: the ASC host is App Store Connect")
		check(request.url.path == "/v1/certificates", "client: the probe reads certificates")
		check((request.headers["Authorization"] ?? "").hasPrefix("Bearer "), "client: the request carries a bearer token")

		// Typed listing decodes attributes.
		let devices = try! await makeClient(MockTransport(.success(response(200, devicesPage)))).list(.devices, as: ZagASCDevice.self)
		check(devices.total == 1 && devices.records.first?.attributes?.udid == "00008030-ABCDEF", "client: devices decode with typed attributes")

		// Status mapping.
		func error(_ result: Result<ZagHTTPResponse, ZagTransportError>) async -> ZagASCError? {
			do { _ = try await makeClient(MockTransport(result)).connectionCheck(); return nil }
			catch let e as ZagASCError { return e } catch { return nil }
		}
		check(await error(.success(response(401, "{}"))) == .unauthorized, "client: 401 maps to unauthorized")
		check(await error(.success(response(403, "{}"))) == .forbidden, "client: 403 maps to forbidden (key lacks provisioning access)")
		check(await error(.success(response(429, "{}"))) == .rateLimited, "client: 429 maps to rate-limited")
		check(await error(.success(response(503, "{}"))) == .server(status: 503), "client: 5xx maps to server error")
		check(await error(.success(response(200, "{"))) == .malformedResponse, "client: an undecodable 200 is a malformed response")
		check(await error(.failure(.offline)) == .transport(.offline), "client: a transport failure is reported with its reason")
	}

	// MARK: - Onboarding

	@MainActor static func onboarding() async {
		let (pem, _) = makeKeyPEM()

		// Gate closed: nothing is read, requested or stored.
		let closedTransport = MockTransport(.success(response(200, certificatesPage)))
		let closedSecrets = MemorySecrets()
		let closed = model(secrets: closedSecrets, gate: .production, transport: closedTransport)
		closed.keyID = keyID; closed.issuerID = issuerID; closed.teamID = teamID
		closed.importKey(contents: pem, fileName: "AuthKey.p8")
		await closed.connect()
		if case .failed(let message) = closed.phase { check(message.contains("not available"), "onboarding: a closed gate reports unavailable") }
		else { check(false, "onboarding: a closed gate must fail") }
		check(closedTransport.count == 0, "onboarding: a closed gate makes no request")
		check(closedSecrets.items.isEmpty, "onboarding: a closed gate stores nothing")

		// Gate open and the key works: validated (not "connected": a read
		// proves nothing about provisioning), stored, key cleared.
		let openSecrets = MemorySecrets()
		let m = model(secrets: openSecrets, gate: .testingOpen, transport: MockTransport(.success(response(200, certificatesPage))))
		m.keyID = keyID; m.issuerID = issuerID; m.teamID = teamID
		m.importKey(contents: pem, fileName: "AuthKey.p8")
		check(m.canConnect, "onboarding: valid input can connect")
		await m.connect()
		if case .credentialsValidated(let k, let total) = m.phase { check(k == keyID && total == 2, "onboarding: a working key is validated") }
		else { check(false, "onboarding: a working key must be validated") }
		check(m.methodStatus == .credentialsValidated(keyID: keyID), "onboarding: a read-only check never claims provisioning")
		check(ZagDeveloperAccountStore(secrets: openSecrets).isConnected(account: m.account), "onboarding: the credential is stored")
		check(!m.hasImportedKey, "onboarding: the private key is cleared once stored")

		// Gate open, key lacks provisioning access (403): guidance, not stored.
		let forbiddenSecrets = MemorySecrets()
		let f = model(secrets: forbiddenSecrets, gate: .testingOpen, transport: MockTransport(.success(response(403, "{}"))))
		f.keyID = keyID; f.issuerID = issuerID; f.teamID = teamID
		f.importKey(contents: pem, fileName: "AuthKey.p8")
		await f.connect()
		if case .needsAttention(let message) = f.phase { check(message.contains("Admin"), "onboarding: a 403 explains the key needs Admin access") }
		else { check(false, "onboarding: a 403 needs attention") }
		check(forbiddenSecrets.items.isEmpty, "onboarding: an unusable key is not stored")

		// Invalid input never reaches the network.
		let badTransport = MockTransport(.success(response(200, certificatesPage)))
		let bad = model(secrets: MemorySecrets(), gate: .testingOpen, transport: badTransport)
		bad.keyID = "bad"; bad.issuerID = issuerID
		bad.importKey(contents: pem, fileName: "AuthKey.p8")
		check(!bad.canConnect, "onboarding: a bad key ID cannot connect")
		await bad.connect()
		if case .failed = bad.phase {} else { check(false, "onboarding: a bad key ID fails") }
		check(badTransport.count == 0, "onboarding: invalid input makes no request")

		// A bad file is rejected on import.
		let importBad = model(secrets: MemorySecrets(), gate: .testingOpen, transport: MockTransport(.success(response(200, certificatesPage))))
		importBad.importKey(contents: "nonsense", fileName: "x.p8")
		check(!importBad.hasImportedKey, "onboarding: a non-.p8 file is rejected")

		// Disconnect clears everything.
		m.disconnect()
		check(!ZagDeveloperAccountStore(secrets: openSecrets).isConnected(account: m.account), "onboarding: disconnect removes the stored key")
		if case .idle = m.phase { check(m.keyID.isEmpty && m.issuerID.isEmpty, "onboarding: disconnect clears the fields") }
		else { check(false, "onboarding: disconnect returns to idle") }
	}

	@MainActor static func model(secrets: MemorySecrets, gate: ZagDeveloperAccountGate, transport: MockTransport) -> ZagDeveloperAccountOnboardingModel {
		ZagDeveloperAccountOnboardingModel(
			account: UUID(),
			store: ZagDeveloperAccountStore(secrets: secrets),
			gate: gate,
			makeClient: { credential in ZagASCClient(transport: transport, credential: credential, now: { fixedNow }) }
		)
	}

	// MARK: - Signing method

	static func signingMethod() {
		check(!ZagSigningMethodAvailability.developerAccountEnabled, "method: the developer-account gate is closed by default")
		check(!ZagDeveloperAccountGate.production.isOpen, "method: the production gate is closed")
		check(ZagSigningMethodAvailability.listedMethods() == [.importedCertificate, .byoc],
			  "method: the default list is unchanged (no developer account, no free account)")
		check(ZagSigningMethodAvailability.listedMethods(developerAccountEnabled: true) == [.importedCertificate, .byoc, .developerAccount],
			  "method: enabling it lists the developer account last")
		check(ZagSigningMethodAvailability.listedMethods(freeAccountEnabled: true, developerAccountEnabled: true) == [.freeAppleAccount, .importedCertificate, .byoc, .developerAccount],
			  "method: both gates open lists all four in order")
		check(ZagSigningMethod.developerAccount.signsOnDevice, "method: developer-account signing is on-device")
		check(!ZagSigningMethod.developerAccount.title.isEmpty && !ZagSigningMethod.developerAccount.summary.isEmpty, "method: has a title and summary")

		let none = ZagSigningMethodAvailability.ImportedCertificates(total: 0, usable: 0, nearestExpiry: nil)
		func status(_ dev: ZagDeveloperAccountStatus) -> ZagSigningMethodStatus {
			ZagSigningMethodAvailability.status(of: .developerAccount, imported: none, freeAccount: .signedOut, developerAccount: dev)
		}
		check(status(.notConnected) == .actionRequired("Add your App Store Connect API key"), "method: not connected asks for a key")
		check(status(.connecting) == .actionRequired("Connecting…"), "method: connecting is shown")
		check(status(.credentialsValidated(keyID: keyID)) == .ready(detail: "Credentials validated — provisioning unverified"),
			  "method: a validated key says provisioning is unverified")
		check(status(.provisioningVerified(keyID: keyID)) == .ready(detail: "Key \(keyID) · Provisioning verified"),
			  "method: provisioning is verified only after a write")
		check(status(.needsAttention("fix me")) == .actionRequired("fix me"), "method: needs-attention surfaces the message")
		// The existing imported-certificate status is unaffected by the new parameter.
		check(ZagSigningMethodAvailability.status(of: .byoc, imported: none, freeAccount: .signedOut) == .external("Signed on zagstore.app"),
			  "method: existing status calls still work")
	}

	// MARK: - M2: client write operations

	static func clientWrites() async {
		let created = response(201, #"{"data":{"type":"devices","id":"D9","attributes":{"name":"iPhone","udid":"UDID-1","platform":"IOS","status":"ENABLED","deviceClass":"IPHONE"}}}"#)
		let transport = MockTransport(.success(created))
		let record = try! await makeClient(transport).create(.devices, attributes: ["name": "iPhone", "platform": "IOS", "udid": "UDID-1"], as: ZagASCDevice.self)
		check(record.id == "D9" && record.attributes?.udid == "UDID-1", "client: create decodes the new record")

		let request = transport.lastRequest!
		check(request.method == "POST" && request.url.path == "/v1/devices", "client: create is a POST to the resource")
		check(request.headers["Content-Type"] == "application/json" && (request.headers["Authorization"] ?? "").hasPrefix("Bearer "), "client: create is JSON and signed")
		let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
		check((body?["data"] as? [String: Any])?["type"] as? String == "devices", "client: the create body is a JSON:API document")

		let pem = ZagASCClient.pemCSR(Data([0x30, 0x01, 0x02]))
		check(pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----") && pem.contains("-----END CERTIFICATE REQUEST-----"), "client: a DER CSR is wrapped as PEM")

		func conflict(_ r: ZagHTTPResponse) async -> ZagASCError? {
			do { _ = try await makeClient(MockTransport(.success(r))).create(.bundleIDs, attributes: ["identifier": "x"], as: ZagASCBundleID.self); return nil }
			catch let e as ZagASCError { return e } catch { return nil }
		}
		check(await conflict(response(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR"}]}"#)) == .conflict(code: "ENTITY_ERROR"), "client: 409 maps to conflict with Apple's code")
	}

	// MARK: - M2: the ASC developer portal

	static func portal() async {
		let (pem, _) = makeKeyPEM()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: pem)
		let certContent = Data("DER-AA11".utf8).base64EncodedString()
		let profileJSON = #"{"uuid":"U1","bundle":"com.example.app"}"#
		let profileContent = Data(profileJSON.utf8).base64EncodedString()
		let bundleIDsPage = #"{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.example.app","name":"App","platform":"IOS"}}],"meta":{"paging":{"total":1}}}"#
		let certCreated = #"{"data":{"type":"certificates","id":"C1","attributes":{"name":"Dev","certificateType":"IOS_DEVELOPMENT","serialNumber":"AA11","expirationDate":"2027-01-01T00:00:00.000+00:00","certificateContent":"\#(certContent)"}}}"#
		let profileCreated = #"{"data":{"type":"profiles","id":"P1","attributes":{"name":"n","profileType":"IOS_APP_DEVELOPMENT","uuid":"U1","expirationDate":"2027-01-01T00:00:00.000+00:00","profileContent":"\#(profileContent)"}}}"#

		func portal(_ handler: @escaping @Sendable (ZagHTTPRequest) -> Result<ZagHTTPResponse, ZagTransportError>) -> ZagASCDeveloperPortal {
			var p = ZagASCDeveloperPortal(client: ZagASCClient(transport: RoutingTransport(handler), credential: credential, now: { fixedNow }))
			p.decodeProfile = { data in
				let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
				return ZagIssuedProfile(uuid: obj["uuid"] as? String ?? "?", teamIdentifier: teamID,
										bundleIdentifier: obj["bundle"] as? String ?? "?", certificateSerials: ["AA11"],
										deviceUDIDs: ["00008030-ABCDEF"], entitlements: try! ZagEntitlementSet([:]),
										createdAt: fixedNow, expiresAt: fixedNow + 365 * 86_400, data: data)
			}
			return p
		}

		let full = portal { request in
			switch (request.method, request.url.path) {
			case ("GET", "/v1/devices"): return .success(response(200, devicesPage))
			case ("GET", "/v1/bundleIds"): return .success(response(200, bundleIDsPage))
			case ("GET", "/v1/certificates"): return .success(response(200, certificatesPage))
			case ("POST", "/v1/certificates"): return .success(response(201, certCreated))
			case ("POST", "/v1/profiles"): return .success(response(201, profileCreated))
			default: return .success(response(404, "{}"))
			}
		}
		check(try! await full.devices(team: teamID).first?.udid == "00008030-ABCDEF", "portal: devices map from ASC JSON")
		check(try! await full.appIDs(team: teamID).first?.bundleIdentifier == "com.example.app", "portal: bundle IDs map to App IDs")
		let issued = try! await full.submitCertificateRequest(ZagCertificateRequest(data: Data([0x30, 0x00])), team: teamID)
		check(!issued.data.isEmpty && issued.certificate.serialNumber == "AA11", "portal: a CSR yields an issued certificate")
		let appID = ZagRegisteredAppID(identifier: "com.example.app", bundleIdentifier: "com.example.app", expiresAt: nil)
		let profile = try! await full.profile(for: appID, team: teamID)
		check(profile.teamIdentifier == teamID && profile.certificateSerials.contains("AA11") && !profile.data.isEmpty, "portal: a profile is created and decoded")

		// A conflict on a bundle ID this team already owns reuses it.
		let reuse = portal { request in
			switch (request.method, request.url.path) {
			case ("POST", "/v1/bundleIds"): return .success(response(409, #"{"errors":[{"code":"ENTITY_ERROR"}]}"#))
			case ("GET", "/v1/bundleIds"): return .success(response(200, bundleIDsPage))
			default: return .success(response(404, "{}"))
			}
		}
		check(try! await reuse.registerAppID(bundleIdentifier: "com.example.app", name: "App", team: teamID).bundleIdentifier == "com.example.app",
			  "portal: a conflict on this team's own bundle ID reuses it")

		// A conflict on an identifier this team does not own is unavailable.
		let taken = portal { request in
			switch (request.method, request.url.path) {
			case ("POST", "/v1/bundleIds"): return .success(response(409, #"{"errors":[{"code":"ENTITY_ERROR"}]}"#))
			case ("GET", "/v1/bundleIds"): return .success(response(200, #"{"data":[],"meta":{"paging":{"total":0}}}"#))
			default: return .success(response(404, "{}"))
			}
		}
		check(await portalError({ _ = try await taken.registerAppID(bundleIdentifier: "com.taken", name: "x", team: teamID) }) == .identifierUnavailable("com.taken"),
			  "portal: a bundle ID another team owns is identifierUnavailable")

		// Transport and auth failures map to portal errors.
		let offline = portal { _ in .failure(.offline) }
		check(await portalError({ _ = try await offline.devices(team: teamID) }) == .network, "portal: a transport failure is a network error")
		let unauthorized = portal { _ in .success(response(401, "{}")) }
		check(await portalError({ _ = try await unauthorized.devices(team: teamID) }) == .sessionRejected, "portal: 401 is a rejected session")
	}

	static func portalError(_ body: @escaping () async throws -> Void) async -> ZagPortalError? {
		do { try await body(); return nil } catch let e as ZagPortalError { return e } catch { return nil }
	}

	// MARK: - M2: the provisioner end to end (simulated portal)

	static func provisioning() async {
		let portal = ZagSimulatedDeveloperPortal(team: "SIMTEAM001", clock: { fixedNow })
		let secrets = MemorySecrets()
		let provisioner = ZagASCProvisioner(portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets, now: { fixedNow })
		let account = UUID()
		let request = ZagProvisioningRequest(
			accountID: account, team: "SIMTEAM001", deviceUDID: "00000000-DEVICE", deviceName: "iPhone",
			app: .init(originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: try! ZagEntitlementSet([:])),
			extensions: [], installedFreeAccountApps: []
		)
		guard case .success(let result) = await provisioner.provision(request) else { return check(false, "provisioner: first provision succeeds") }
		check(result.team == "SIMTEAM001", "provisioner: the result carries the team")
		check(result.app.bundleIdentifier == "com.example.notes.SIMTEAM001", "provisioner: the bundle ID is mapped for the team")
		check(result.changes.createdCertificate && result.changes.registeredDevice, "provisioner: it created a certificate and registered the device")
		check(!result.certificateSerial.isEmpty && result.app.profile.certificateSerials.contains(result.certificateSerial), "provisioner: the profile names the signing certificate")
		check(((try? secrets.load(.signingPrivateKey, account: account, team: "SIMTEAM001")) ?? nil) != nil, "provisioner: the signing identity is stored")

		guard case .success(let again) = await provisioner.provision(request) else { return check(false, "provisioner: second provision succeeds") }
		check(!again.changes.createdCertificate, "provisioner: a second run reuses the stored certificate")
	}

	// MARK: - M3: the signing + install coordinator

	static func coordinator() async {
		func run(gate: ZagDeveloperAccountGate, signerFails: Bool = false, verification: ZagInstallVerification = .verified(profileExpiresAt: fixedNow + 100, certificateExpiresAt: fixedNow + 200), failDevices: Bool = false) async -> ZagASCSigningCoordinator.Outcome {
			let portal = ZagSimulatedDeveloperPortal(team: "SIMTEAM001", clock: { fixedNow })
			if failDevices { await portal.fail(.devices, with: .network) }
			let secrets = MemorySecrets()
			let provisioner = ZagASCProvisioner(portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets, now: { fixedNow })
			let coordinator = ZagASCSigningCoordinator(
				provisioner: provisioner, secrets: secrets,
				signer: StubSigner(fails: signerFails, now: fixedNow),
				installer: StubInstaller(verification: verification), gate: gate, now: { fixedNow }
			)
			let team = ZagDeveloperTeam(identifier: "SIMTEAM001", name: "Team", kind: .individualPaid)
			let component = ZagProvisioningRequest.Component(originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: try! ZagEntitlementSet([:]))
			return await coordinator.install(app: component, account: UUID(), team: team, device: ZagTargetDevice(udid: "00000000-DEVICE", name: "iPhone"), appAt: URL(fileURLWithPath: "/tmp/x.app"))
		}

		check(await run(gate: .production) == .failed(.disabled), "coordinator: a closed gate signs nothing")

		switch await run(gate: .testingOpen) {
		case .installed(let record):
			check(record.expiryVerified == true && record.profileExpiresAt == fixedNow + 100, "coordinator: a verified install records the device's expiry")
		default:
			check(false, "coordinator: the happy path installs and verifies")
		}

		if case .installedUnverified = await run(gate: .testingOpen, verification: .unverifiable("no readback")) {} else { check(false, "coordinator: an unverifiable install is recorded unverified") }
		if case .failed(.signing) = await run(gate: .testingOpen, signerFails: true) {} else { check(false, "coordinator: a signer failure is reported") }
		if case .failed(.provisioning) = await run(gate: .testingOpen, failDevices: true) {} else { check(false, "coordinator: a provisioning failure is reported") }
	}

	// MARK: - End to end against a stateful mock of the ASC API

	struct World {
		let asc: MockASC
		let secrets: MemorySecrets
		let provisioner: ZagASCProvisioner
		let account = UUID()

		func request(_ original: String = "com.example.notes", udid: String = "00008110-000A1B2C3D4E5F60") -> ZagProvisioningRequest {
			ZagProvisioningRequest(
				accountID: account, team: Tests.teamID, deviceUDID: udid, deviceName: "Test iPhone",
				app: .init(originalBundleIdentifier: original, name: "Notes", entitlements: try! ZagEntitlementSet([:])),
				extensions: [], installedFreeAccountApps: []
			)
		}

		func identityStored() -> Bool {
			((try? secrets.load(.signingPrivateKey, account: account, team: Tests.teamID)) ?? nil) != nil
		}
	}

	static func world() -> World {
		let key = P256.Signing.PrivateKey()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: key.pemRepresentation)
		let asc = MockASC(teamID: teamID, keyID: keyID, issuerID: issuerID, publicKey: key.publicKey, now: fixedNow)
		var portal = ZagASCDeveloperPortal(client: ZagASCClient(transport: asc, credential: credential, now: { fixedNow }))
		portal.decodeProfile = MockASC.decodeProfile
		let secrets = MemorySecrets()
		return World(asc: asc, secrets: secrets, provisioner: ZagASCProvisioner(portal: portal, keys: ZagSimulatedSigningKeyFactory(), secrets: secrets, now: { fixedNow }))
	}

	static func mockASCProvisioning() async {
		let w = world()
		let mapped = "com.example.notes.\(teamID)"
		guard case .success(let first) = await w.provisioner.provision(w.request()) else { return check(false, "mock ASC: a fresh team provisions") }
		check(first.app.bundleIdentifier == mapped && first.team == teamID, "mock ASC: a fresh team provisions the team-mapped bundle ID")
		check(w.asc.count("POST /v1/devices") == 1 && w.asc.count("POST /v1/certificates") == 1
			  && w.asc.count("POST /v1/bundleIds") == 1 && w.asc.count("POST /v1/profiles") == 1,
			  "mock ASC: one device, one certificate, one bundle ID and one profile are created")
		let profile = w.asc.profiles[0]
		check(profile.bundleID == w.asc.bundleIDs.first { $0.identifier == mapped }?.id, "mock ASC: the profile's bundleId relationship is the app's bundle ID")
		check(profile.certificateIDs.contains(w.asc.certificates[0].id) && first.certificateSerial == w.asc.certificates[0].serial,
			  "mock ASC: the profile names the issued certificate, and it is the signing certificate")
		check(profile.deviceIDs == [w.asc.devices[0].id], "mock ASC: the profile names the registered device")
		check(w.identityStored(), "mock ASC: the signing identity is stored only after the certificate is issued")
		check(w.asc.tokenProblems.isEmpty && w.asc.requestCount > 0, "mock ASC: every request carries a valid ES256 team-key JWT (\(w.asc.requestCount) verified)")
		check(w.asc.schemaProblems.isEmpty, "mock ASC: every request body matches the ASC JSON:API schema")

		let before = w.asc.requestLog.count
		guard case .success(let second) = await w.provisioner.provision(w.request()) else { return check(false, "mock ASC: a second run succeeds") }
		let writes = w.asc.requestLog.dropFirst(before).filter { !$0.hasPrefix("GET") }
		check(writes.isEmpty, "mock ASC: a second run reuses device, certificate, bundle ID and profile: no writes at all")
		check(!second.changes.createdCertificate && !second.changes.registeredDevice && second.changes.registeredAppIDs.isEmpty,
			  "mock ASC: a second run reports no new resources")

		// A team with more bundle IDs than one page still finds its own.
		let busy = world()
		busy.asc.seedBundleIDs((0..<250).map { "com.other.app\($0)" } + [mapped])
		guard case .success = await busy.provisioner.provision(busy.request()) else { return check(false, "mock ASC: a team with 251 bundle IDs reuses its own") }
		check(busy.asc.bundleIDs.count == 251, "mock ASC: a bundle ID beyond the first page is reused, not reported as another team's")

		// A disabled device is re-enabled; other disabled devices stay out of the profile.
		let disabled = world()
		disabled.asc.seedDevice(udid: "00008110-000A1B2C3D4E5F60", status: "DISABLED")
		disabled.asc.seedDevice(udid: "00008020-OTHERDEVICE00000", status: "DISABLED")
		guard case .success = await disabled.provisioner.provision(disabled.request()) else { return check(false, "mock ASC: a disabled device is re-enabled") }
		check(disabled.asc.count("PATCH /v1/devices/") == 1 && disabled.asc.devices[0].status == "ENABLED" && disabled.asc.devices[1].status == "DISABLED",
			  "mock ASC: the target device is re-enabled, and only it")
		check(disabled.asc.profiles.last?.deviceIDs == [disabled.asc.devices[0].id], "mock ASC: a profile never includes a disabled device")
		check(disabled.asc.schemaProblems.isEmpty, "mock ASC: the PATCH body matches the ASC schema")
	}

	static func mockASCRecovery() async {
		func kind(_ w: World, _ original: String = "com.example.notes") async -> ZagProvisioningFailure.Kind? {
			if case .failure(let failure) = await w.provisioner.provision(w.request(original)) { return failure.kind }
			return nil
		}

		// Cancelled after the certificate was issued: the next run reuses it.
		let cancelled = world()
		cancelled.asc.failNext("POST /v1/bundleIds") { throw ZagTransportError.cancelled }
		check(await kind(cancelled) == .cancelled, "recovery: a cancelled request fails as cancelled")
		check(cancelled.asc.certificates.count == 1 && cancelled.identityStored(), "recovery: the certificate issued before the cancel is kept with its key")
		guard case .success(let resumed) = await cancelled.provisioner.provision(cancelled.request()) else { return check(false, "recovery: the next run succeeds") }
		check(!resumed.changes.createdCertificate && cancelled.asc.certificates.count == 1, "recovery: the next run reuses that certificate instead of creating another")

		let swiftCancel = world()
		swiftCancel.asc.failNext("GET /v1/devices") { throw CancellationError() }
		check(await kind(swiftCancel) == .cancelled, "recovery: Swift task cancellation maps to cancelled")

		// A transient failure while cutting the profile.
		let flaky = world()
		flaky.asc.failNext("POST /v1/profiles") { MockASC.reply(500, ["errors": [["status": "500"]]]) }
		check(await kind(flaky) == .unexpectedResponse, "recovery: a server error while cutting the profile fails cleanly")
		guard case .success = await flaky.provisioner.provision(flaky.request()) else { return check(false, "recovery: the retry succeeds") }
		check(flaky.asc.certificates.count == 1 && flaky.asc.devices.count == 1 && flaky.asc.bundleIDs.count == 1, "recovery: the retry creates nothing twice")

		// Errors the user acts on.
		let limit = world()
		limit.asc.certificateLimit = 0
		if case .certificateMustBeRevoked = await kind(limit) {} else { check(false, "recovery: the certificate limit asks the user to revoke") }
		check(!limit.identityStored(), "recovery: the certificate limit asks the user to revoke, and stores no identity")

		let taken = world()
		check(await kind(taken, "taken.app") == .identifierUnavailable("taken.app.\(teamID)"), "recovery: a bundle ID another team owns is reported as unavailable")

		let revoked = world()
		revoked.asc.revoked = true
		check(await kind(revoked) == .sessionRejected, "recovery: a revoked key is a rejected session")
		check(revoked.asc.requestLog.filter { !$0.hasPrefix("GET") }.isEmpty, "recovery: a revoked key creates nothing")

		let limited = world()
		limited.asc.failNext("GET /v1/devices") { MockASC.reply(429, ["errors": [["status": "429"]]]) }
		check(await kind(limited) == .rateLimited, "recovery: rate limiting is reported as such")

		let developerRole = world()
		developerRole.asc.failNext("POST /v1/certificates") { MockASC.reply(403, ["errors": [["status": "403", "code": "FORBIDDEN_ERROR"]]]) }
		check(await kind(developerRole) == .sessionRejected && !developerRole.identityStored(), "recovery: a key without provisioning rights fails before storing anything")
	}

	static func mockASCCoordinator() async {
		func coordinator(_ w: World, signer: ZagAppSigning = StubSigner(fails: false, now: fixedNow), installer: CountingInstaller = CountingInstaller()) -> ZagASCSigningCoordinator {
			ZagASCSigningCoordinator(provisioner: w.provisioner, secrets: w.secrets, signer: signer, installer: installer, gate: .testingOpen, now: { fixedNow })
		}
		let team = ZagDeveloperTeam(identifier: teamID, name: "Team", kind: .individualPaid)
		let component = ZagProvisioningRequest.Component(originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: try! ZagEntitlementSet([:]))
		let device = ZagTargetDevice(udid: "00008110-000A1B2C3D4E5F60", name: "Test iPhone")
		let app = URL(fileURLWithPath: "/tmp/Notes.app")

		let happy = world()
		let installer = CountingInstaller()
		if case .installed(let record) = await coordinator(happy, installer: installer).install(app: component, account: happy.account, team: team, device: device, appAt: app) {
			check(record.bundleIdentifier == "com.example.notes.\(teamID)" && record.owner?.teamKind == .individualPaid && record.expiryVerified == true,
				  "coordinator + mock ASC: provisions, signs, installs and verifies one app")
			check(installer.installs == 1 && installer.lastExpectation?.teamIdentifier == teamID
				  && installer.lastExpectation?.profileUUID == happy.asc.profiles.last?.id,
				  "coordinator + mock ASC: the device is checked for the profile ASC issued")
		} else { check(false, "coordinator + mock ASC: the happy path installs") }

		// Cancelled while ASC is cutting the profile, then resumed.
		let interrupted = world()
		interrupted.asc.failNext("POST /v1/profiles") { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
		let resumeInstaller = CountingInstaller()
		let first = await Task { await coordinator(interrupted, installer: resumeInstaller).install(app: component, account: interrupted.account, team: team, device: device, appAt: app) }.value
		check(first == .failed(.cancelled) && resumeInstaller.installs == 0, "coordinator + mock ASC: a cancel during provisioning stops before signing or installing")
		let second = await Task { await coordinator(interrupted, installer: resumeInstaller).install(app: component, account: interrupted.account, team: team, device: device, appAt: app) }.value
		if case .installed = second {} else { check(false, "coordinator + mock ASC: the next run installs") }
		check(interrupted.asc.certificates.count == 1 && resumeInstaller.installs == 1, "coordinator + mock ASC: the resumed run reuses the certificate and installs once")

		// Cancelled after signing: nothing is installed.
		let late = world()
		let lateInstaller = CountingInstaller()
		let lateOutcome = await Task {
			await coordinator(late, signer: CancellingSigner(), installer: lateInstaller).install(app: component, account: late.account, team: team, device: device, appAt: app)
		}.value
		check(lateOutcome == .failed(.cancelled) && lateInstaller.installs == 0, "coordinator + mock ASC: a cancel after signing installs nothing")

		// The device reports a different profile.
		let mismatch = world()
		let wrong = CountingInstaller(verification: .mismatch("another profile"))
		let outcome = await coordinator(mismatch, installer: wrong).install(app: component, account: mismatch.account, team: team, device: device, appAt: app)
		check(outcome == .failed(.notVerified), "coordinator + mock ASC: a profile mismatch on the device is never success")
	}

	// MARK: - Idempotent profile management

	static func mockASCProfiles() async {
		@discardableResult func run(_ w: World, _ original: String = "com.example.notes", udid: String = "00008110-000A1B2C3D4E5F60") async -> ZagProvisioningResult? {
			if case .success(let result) = await w.provisioner.provision(w.request(original, udid: udid)) { return result }
			return nil
		}
		let mapped = "com.example.notes.\(teamID)"

		let steady = world()
		await run(steady)
		check(steady.asc.profiles.count == 1 && steady.asc.profiles[0].name == "Zag Store \(mapped)", "profiles: one Zag Store profile per App ID, under a fixed name")
		for _ in 0..<3 { await run(steady) }
		check(steady.asc.count("POST /v1/profiles") == 1 && steady.asc.count("DELETE") == 0 && steady.asc.profiles.count == 1,
			  "profiles: three refreshes reuse the profile instead of creating one each time")

		let expiring = world()
		expiring.asc.profileLifetime = 10 * 86_400
		await run(expiring)
		expiring.asc.profileLifetime = 365 * 86_400
		let renewed = await run(expiring)
		check(expiring.asc.profiles.count == 1 && expiring.asc.count("DELETE /v1/profiles/") == 1 && renewed?.app.profile.expiresAt == fixedNow + 365 * 86_400,
			  "profiles: a profile within 30 days of expiry is replaced, not duplicated")

		let grown = world()
		await run(grown)
		await run(grown, udid: "00008030-SECONDDEVICE0000")
		check(grown.asc.profiles.count == 1 && grown.asc.profiles[0].deviceIDs.count == 2, "profiles: a new device replaces the profile with one naming both devices")

		let invalid = world()
		await run(invalid)
		invalid.asc.invalidateProfiles()
		await run(invalid)
		check(invalid.asc.profiles.count == 1 && invalid.asc.activeProfiles.count == 1, "profiles: an INVALID profile (e.g. revoked certificate) is replaced")

		let two = world()
		await run(two)
		await run(two, "com.example.other")
		let other = two.asc.profiles.first { $0.name.hasSuffix("com.example.other.\(teamID)") }?.id
		await run(two, udid: "00008030-SECONDDEVICE0000")
		check(two.asc.profiles.count == 2 && two.asc.profiles.contains { $0.id == other }, "profiles: replacing one App ID's profile never touches another's")

		// Interrupted between removing the stale profile and creating its replacement.
		let interrupted = world()
		interrupted.asc.profileLifetime = 10 * 86_400
		await run(interrupted)
		interrupted.asc.profileLifetime = 365 * 86_400
		interrupted.asc.failNext("POST /v1/profiles") { MockASC.reply(500, ["errors": [["status": "500"]]]) }
		check(await run(interrupted) == nil && interrupted.asc.profiles.isEmpty, "profiles: a failure after removing the stale profile leaves none")
		check(await run(interrupted) != nil && interrupted.asc.profiles.count == 1, "profiles: the next run creates exactly one")
		check(interrupted.asc.schemaProblems.isEmpty && interrupted.asc.tokenProblems.isEmpty, "profiles: list and delete requests match the schema and are signed")
	}

	// MARK: - The app wiring: service, models, removal

	struct ServiceWorld {
		let asc: MockASC
		let secrets: MemorySecrets
		let keys: RecordingKeyFactory
		let account = UUID()
		let credential: ZagDeveloperAccountCredential

		func service(signer: ZagAppSigning = StubSigner(fails: false, now: Tests.fixedNow), installer: ZagFreeAccountInstaller = CountingInstaller(),
					 gate: ZagDeveloperAccountGate = .testingOpen) -> ZagDeveloperAccountService {
			ZagDeveloperAccountService(account: account, dependencies: .init(
				transport: asc, secrets: secrets, keys: keys, signer: signer, installer: installer,
				gate: gate, now: { Tests.fixedNow }, decodeProfile: MockASC.decodeProfile
			))
		}
		var store: ZagDeveloperAccountStore { ZagDeveloperAccountStore(secrets: secrets) }
		var stored: ZagDeveloperAccountCredential? { (try? store.load(account: account)) ?? nil }
	}

	static func serviceWorld(connected: Bool = true) -> ServiceWorld {
		let key = P256.Signing.PrivateKey()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: key.pemRepresentation, addedAt: fixedNow)
		let w = ServiceWorld(asc: MockASC(teamID: teamID, keyID: keyID, issuerID: issuerID, publicKey: key.publicKey, now: fixedNow),
							 secrets: MemorySecrets(), keys: RecordingKeyFactory(), credential: credential)
		if connected { try! w.store.save(credential, account: w.account) }
		return w
	}

	static func libraryApp(extensions: Bool = false, entitlements: [String: Any] = [:]) -> ZagDeveloperAccountApp {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("zag-asc-app-\(UUID().uuidString)/Notes.app")
		try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		if extensions { try! FileManager.default.createDirectory(at: url.appendingPathComponent("PlugIns/Widget.appex"), withIntermediateDirectories: true) }
		return ZagDeveloperAccountApp(url: url, originalBundleIdentifier: "com.example.notes", name: "Notes", entitlements: try! ZagEntitlementSet(entitlements))
	}

	static let iPhone = ZagTargetDevice(udid: "00008110-000A1B2C3D4E5F60", name: "Test iPhone")

	static func serviceWiring() async {
		let app = libraryApp()

		let closed = serviceWorld()
		check(await closed.service(gate: .production).install(app, on: iPhone) == .failed(.disabled) && closed.asc.requestCount == 0,
			  "wiring: with the gate closed nothing is requested, signed or installed")

		let disconnected = serviceWorld(connected: false)
		check(await disconnected.service().install(app, on: iPhone) == .notConnected && disconnected.asc.requestCount == 0,
			  "wiring: with no stored key it asks to connect and sends nothing")

		let happy = serviceWorld()
		let installer = CountingInstaller()
		if case .installed(let record) = await happy.service(installer: installer).install(app, on: iPhone) {
			check(record.bundleIdentifier == "com.example.notes.\(teamID)" && installer.installs == 1, "wiring: stored key → ASC → provisioner → signer → installer installs and verifies")
		} else { check(false, "wiring: the happy path installs") }
		check(happy.stored?.provisioningVerifiedAt == fixedNow, "wiring: the first successful write marks provisioning verified")
		check(happy.asc.tokenProblems.isEmpty && happy.asc.schemaProblems.isEmpty, "wiring: every request is signed with the stored key and well-formed")
		let writes = happy.asc.requestLog.filter { !$0.hasPrefix("GET") }.count
		if case .installed = await happy.service(installer: installer).install(app, on: iPhone) {} else { check(false, "wiring: a refresh installs") }
		check(happy.asc.requestLog.filter { !$0.hasPrefix("GET") }.count == writes && installer.installs == 2, "wiring: a refresh writes nothing to Apple")

		// Verification needs a write; a run that only reuses resources proves nothing new.
		let reused = serviceWorld()
		_ = await reused.service().install(app, on: iPhone)
		var unverified = reused.credential
		unverified.provisioningVerifiedAt = nil
		try! reused.store.save(unverified, account: reused.account)
		_ = await reused.service().install(app, on: iPhone)
		check(reused.stored?.provisioningVerifiedAt == nil, "wiring: a run with no writes never claims provisioning is verified")

		let readOnly = serviceWorld()
		readOnly.asc.readOnlyKey = true
		check(await readOnly.service().install(app, on: iPhone) == .failed(.provisioning(.sessionRejected)) && readOnly.stored?.provisioningVerifiedAt == nil,
			  "wiring: a key that may read but not write fails, and stays unverified")

		let unsigned = serviceWorld()
		let noInstall = CountingInstaller()
		check(await unsigned.service(signer: StubSigner(fails: true, now: fixedNow), installer: noInstall).install(app, on: iPhone) == .failed(.signing)
			  && noInstall.installs == 0, "wiring: a signing failure installs nothing")
		check(unsigned.stored?.provisioningVerifiedAt != nil, "wiring: provisioning that succeeded before the signing failure still counts")

		let refused = serviceWorld()
		check(await refused.service(installer: FailingInstaller()).install(app, on: iPhone) == .failed(.install), "wiring: an installation failure is reported")

		let blind = serviceWorld()
		if case .installedUnverified = await blind.service(installer: CountingInstaller(verification: .unverifiable("no readback"))).install(app, on: iPhone) {} else {
			check(false, "wiring: an install the device cannot confirm is never reported as verified")
		}

		let revoked = serviceWorld()
		revoked.asc.revoked = true
		let revokedOutcome = await revoked.service().install(app, on: iPhone)
		check(revokedOutcome == .failed(.provisioning(.sessionRejected)) && ZagDeveloperAccountInstallModel.message(for: revokedOutcome).contains("revoked"),
			  "wiring: a revoked key is reported as possibly revoked")

		let interrupted = serviceWorld()
		interrupted.asc.failNext("POST /v1/profiles") { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
		let cancelInstaller = CountingInstaller()
		let cancelled = await Task { await interrupted.service(installer: cancelInstaller).install(app, on: iPhone) }.value
		check(cancelled == .failed(.cancelled) && cancelInstaller.installs == 0, "wiring: cancelling stops before signing and installs nothing")
		if case .installed = await interrupted.service(installer: cancelInstaller).install(app, on: iPhone) {} else { check(false, "wiring: the next attempt installs") }
		check(interrupted.asc.certificates.count == 1, "wiring: the resumed attempt reuses what the cancelled one created")

		let plugins = serviceWorld()
		check(await plugins.service().install(libraryApp(extensions: true), on: iPhone) == .unsupportedApp && plugins.asc.requestCount == 0,
			  "wiring: an app with extensions is refused before anything is created")
		check(await plugins.service().install(libraryApp(entitlements: ["com.apple.security.application-groups": ["group.x"]]), on: iPhone) == .unsupportedApp,
			  "wiring: an app with app groups is refused")

		// Account removal: key, signing identity and Keychain keys; another account untouched.
		let removal = serviceWorld()
		_ = await removal.service().install(app, on: iPhone)
		let bystander = UUID()
		try! removal.secrets.save(Data("other".utf8), kind: .developerAPIKey, account: bystander)
		check(((try? removal.secrets.load(.signingPrivateKey, account: removal.account, team: teamID)) ?? nil) != nil, "removal: an identity exists before removal")
		try! removal.service().removeAccount()
		check(removal.stored == nil && ((try? removal.secrets.load(.signingPrivateKey, account: removal.account, team: teamID)) ?? nil) == nil,
			  "removal: the API key and the signing identity are deleted")
		check(removal.keys.discarded == [teamID], "removal: the team's Keychain signing keys are deleted")
		check(((try? removal.secrets.load(.developerAPIKey, account: bystander)) ?? nil) != nil, "removal: another account's data is untouched")
		let before = removal.asc.requestCount
		check(await removal.service().install(app, on: iPhone) == .notConnected && removal.asc.requestCount == before,
			  "removal: after removal nothing can be provisioned")
		check(removal.asc.certificates.count == 1 && removal.asc.devices.count == 1, "removal: nothing is changed at Apple")

		// The live transport reaches App Store Connect only.
		let live = ZagURLSessionTransport.appStoreConnect()
		check(live.policy.allowedHosts == [ZagASCClient.host], "wiring: the live transport allows only the App Store Connect host")
		let elsewhere = ZagHTTPRequest(url: URL(string: "https://example.com/v1/devices")!)
		check((try? live.policy.validate(elsewhere)) == nil, "wiring: the live transport refuses any other host")
	}

	@MainActor
	static func installModel() async {
		let w = serviceWorld()
		let model = ZagDeveloperAccountInstallModel(service: w.service())
		model.start(libraryApp(), on: nil)
		check(model.phase == .finished("Pair this iPhone first (Settings › Pairing).", succeeded: false), "install model: an unpaired iPhone is asked to pair")

		model.start(libraryApp(), on: iPhone)
		check(model.isRunning, "install model: an install runs")
		await model.wait()
		if case .finished(let message, true) = model.phase { check(message.hasPrefix("Installed and verified"), "install model: success is reported") }
		else { check(false, "install model: success is reported") }

		let cancelInstaller = CountingInstaller()
		let cancelling = ZagDeveloperAccountInstallModel(service: serviceWorld().service(installer: cancelInstaller))
		cancelling.start(libraryApp(), on: iPhone)
		cancelling.cancel()
		await cancelling.wait()
		if case .finished(let message, false) = cancelling.phase {
			check(message.hasPrefix("Cancelled") && cancelInstaller.installs == 0, "install model: Cancel stops the install and nothing is installed")
		} else { check(false, "install model: Cancel is reported") }
	}

	@MainActor
	static func onboardingRemoval() async {
		let w = serviceWorld()
		_ = await w.service().install(libraryApp(), on: iPhone)
		let model = ZagDeveloperAccountOnboardingModel(account: w.account, store: w.store, gate: .testingOpen,
													   makeClient: { w.service().client(for: $0) }, removeAll: { try w.service().removeAccount() })
		model.restore()
		check(model.phase == .provisioningVerified(keyID: keyID) && model.methodStatus == .provisioningVerified(keyID: keyID),
			  "onboarding: after a successful write the screen shows provisioning verified")
		model.removeAccount()
		check(model.phase == .idle && w.stored == nil && w.keys.discarded == [teamID], "onboarding: Remove Developer Account clears the key, identity and keys")

		let failing = ZagDeveloperAccountOnboardingModel(account: w.account, store: w.store, gate: .testingOpen,
														 makeClient: { w.service().client(for: $0) }, removeAll: { throw TestFailure() })
		failing.removeAccount()
		check({ if case .failed = failing.phase { return true }; return false }(), "onboarding: a failed removal is reported, not hidden")
	}

	// MARK: - The real signing adapter accepts the developer-account authorisation

	static func realAdapter() {
		check(!ZagFreeAccountSigningGate.developerAccount.isOpen, "adapter: the developer-account signing gate is closed")

		let work = FileManager.default.temporaryDirectory.appendingPathComponent("zag-asc-adapter-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: work) }
		let app = work.appendingPathComponent("Notes.app")
		try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let info: [String: Any] = ["CFBundleIdentifier": "com.example.notes", "CFBundleExecutable": "Notes", "CFBundleName": "Notes",
								   "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
		try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
		try! Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: app.appendingPathComponent("Notes"))

		let account = UUID()
		let profileData = try! JSONSerialization.data(withJSONObject: ["uuid": "P-1", "team": teamID, "bundle": "com.example.notes.\(teamID)", "serials": ["SER1"], "udids": ["00008110-000A1B2C3D4E5F60"]])
		let profile = try! MockASC.decodeProfile(profileData)
		let result = ZagProvisioningResult(
			team: teamID, certificateSerial: "SER1",
			app: .init(originalBundleIdentifier: "com.example.notes", bundleIdentifier: "com.example.notes.\(teamID)", profile: profile, entitlements: try! ZagEntitlementSet([:]), rejected: []),
			extensions: [], changes: .init()
		)
		let made = try! ZagSimulatedSigningKeyFactory().makeKey(commonName: "Zag Store")
		let identity = ZagSigningIdentity(serialNumber: "SER1", certificate: Data("CERT-SER1".utf8), privateKey: made.privateKey, expiresAt: fixedNow + 365 * 86_400, keySlot: nil)
		let authorization = ZagSigningAuthorization.developerAccount(scope: ZagSigningScope(accountID: account, teamID: teamID), teamKind: .individualPaid, validUntil: fixedNow + 600)

		// The fake signer changes nothing, so the adapter must get past its gate,
		// authorisation and identity checks, call the signer, and then refuse
		// the unsigned result. (Real Zsign signing of a CMS profile is covered
		// by test-zag-free-account-signing.sh; Apple-issued artifacts only live.)
		let signer = NoopCodeSigner()
		let open = ZagFreeAccountSigningAdapter(signer: signer, workRoot: work, gate: .simulationOnly, allowsKeyFiles: true)
		do {
			_ = try open.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: fixedNow)
			check(false, "adapter: unsigned output is never success")
		} catch ZagFreeAccountSigningError.verification {
			check(signer.calls == 1, "adapter: the developer-account authorisation reaches the signer, and unsigned output is refused")
		} catch {
			check(false, "adapter: the developer-account authorisation is accepted (\(error))")
		}
		let closed = ZagFreeAccountSigningAdapter(signer: signer, workRoot: work, gate: .developerAccount, allowsKeyFiles: true)
		check((try? closed.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: fixedNow)) == nil && signer.calls == 1,
			  "adapter: with the developer-account gate closed nothing is signed")
		check((try? open.sign(appAt: app, with: result, identity: identity, authorization: authorization, now: fixedNow + 601)) == nil,
			  "adapter: an expired developer-account authorisation is refused")
		let otherTeam = ZagSigningAuthorization.developerAccount(scope: ZagSigningScope(accountID: account, teamID: "OTHER12345"), teamKind: .individualPaid, validUntil: fixedNow + 600)
		check((try? open.sign(appAt: app, with: result, identity: identity, authorization: otherTeam, now: fixedNow)) == nil,
			  "adapter: an authorisation for another team is refused")
	}

	// MARK: - Sensitive data never appears in text forms

	static func redaction() {
		let (pem, _) = makeKeyPEM()
		let credential = try! ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: pem)
		let client = ZagASCClient(transport: MockTransport(.success(response(200, "{}"))), credential: credential)
		var dumped = ""
		dump(credential, to: &dumped)
		dump(client, to: &dumped)
		let forms = [String(describing: credential), String(reflecting: credential), "\(credential)", dumped,
					 String(describing: client), String(reflecting: client)]
		let body = pem.components(separatedBy: "\n").dropFirst().first ?? "missing"
		check(forms.allSatisfy { !$0.contains("PRIVATE KEY") && !$0.contains(body) }, "redaction: no text form of the credential or client contains the .p8")
		check(forms.allSatisfy { $0.contains(keyID) }, "redaction: the key ID is still shown, for support")

		let errors: [ZagASCError] = [.unauthorized, .forbidden, .conflict(code: "ENTITY_ERROR"), .transport(.offline), .unexpected(status: 418, code: nil)]
		check(errors.allSatisfy { !String(describing: $0).contains("Bearer") && !String(describing: $0).contains("eyJ") }, "redaction: errors carry no token")
		check(ZagSensitiveRedactor.redact("Authorization: Bearer eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.c2ln") == "Authorization: [redacted]"
			  && !ZagSensitiveRedactor.redact(pem).contains(body), "redaction: the shared redactor removes ASC tokens and .p8 keys")
	}
}

// MARK: - Test doubles

final class MemorySecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	var items: [String: Data] = [:]
	func accountIDs() throws -> Set<UUID> { lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.prefix(36))) }) } }
	func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = secret }
	}
	func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? {
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] }
	}
	func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws {
		lock.withLock { items["\(account).\(kind)" + (team.map { ".\($0)" } ?? "")] = nil }
	}
	func deleteAll(account: UUID) throws { lock.withLock { items = items.filter { !$0.key.hasPrefix("\(account).") } } }
}

final class MockTransport: ZagHTTPTransport, @unchecked Sendable {
	private let lock = NSLock()
	private let result: Result<ZagHTTPResponse, ZagTransportError>
	private(set) var lastRequest: ZagHTTPRequest?
	private var requestCount = 0
	var count: Int { lock.withLock { requestCount } }

	init(_ result: Result<ZagHTTPResponse, ZagTransportError>) { self.result = result }

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		lock.withLock { lastRequest = request; requestCount += 1 }
		switch result {
		case .success(let response): return response
		case .failure(let error): throw error
		}
	}
}

/// Tests only: the simulated portal stands in for ASC in the provisioner tests.
extension ZagSimulatedDeveloperPortal: ZagASCProvisioningPortal {}

final class RoutingTransport: ZagHTTPTransport, @unchecked Sendable {
	private let handler: @Sendable (ZagHTTPRequest) -> Result<ZagHTTPResponse, ZagTransportError>
	init(_ handler: @escaping @Sendable (ZagHTTPRequest) -> Result<ZagHTTPResponse, ZagTransportError>) { self.handler = handler }
	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		switch handler(request) {
		case .success(let response): return response
		case .failure(let error): throw error
		}
	}
}

struct StubSigner: ZagAppSigning {
	let fails: Bool
	let now: Date
	func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity, authorization: ZagSigningAuthorization, now: Date) throws -> ZagSignedAppRecord {
		if fails { throw ZagSignerFailure(message: "stub signer") }
		return ZagSignedAppRecord(
			bundleIdentifier: result.app.bundleIdentifier,
			originalBundleIdentifier: result.app.originalBundleIdentifier,
			signedAt: now,
			profileExpiresAt: result.app.profile.expiresAt,
			certificateExpiresAt: identity.expiresAt,
			owner: ZagAppOwnership(
				scope: authorization.scope,
				teamKind: authorization.teamKind,
				certificateSerial: identity.serialNumber,
				profileUUID: result.app.profile.uuid
			)
		)
	}
}

struct StubInstaller: ZagFreeAccountInstaller {
	let verification: ZagInstallVerification
	func install(signedApp: URL, bundleIdentifier: String) async throws {}
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification { verification }
}

/// A deterministic, stateful stand-in for the App Store Connect provisioning
/// API: devices, bundle IDs, certificates and profiles live in memory, every
/// request's JWT is verified against the key's public half, and every write
/// body is checked against the JSON:API shapes Apple documents. Profiles are
/// JSON (decoded by `decodeProfile`) rather than signed CMS, so the provisioner
/// runs unchanged with no certificate authority.
final class MockASC: ZagHTTPTransport, @unchecked Sendable {
	struct Device { let id: String; let udid: String; let name: String; var status: String }
	struct Certificate { let id: String; let serial: String }
	struct Profile { let id: String; let name: String; let bundleID: String; let certificateIDs: [String]; let deviceIDs: [String]; let expires: Date; var state: String }

	private let lock = NSLock()
	let teamID: String, keyID: String, issuerID: String
	let publicKey: P256.Signing.PublicKey
	let now: Date
	var certificateLimit = 2
	var revoked = false
	/// A key that may read but not write (e.g. a Developer-role key): every
	/// write is 403.
	var readOnlyKey = false
	/// How long new profiles last (development profiles: a year).
	var profileLifetime: TimeInterval = 365 * 86_400
	private(set) var devices: [Device] = []
	private(set) var bundleIDs: [(id: String, identifier: String)] = []
	private(set) var certificates: [Certificate] = []
	private(set) var profiles: [Profile] = []
	private(set) var requestLog: [String] = []
	private(set) var schemaProblems: [String] = []
	private(set) var tokenProblems: [String] = []
	private(set) var requestCount = 0
	private var failures: [(prefix: String, action: @Sendable () throws -> ZagHTTPResponse)] = []
	private var serial = 0

	init(teamID: String, keyID: String, issuerID: String, publicKey: P256.Signing.PublicKey, now: Date) {
		self.teamID = teamID; self.keyID = keyID; self.issuerID = issuerID; self.publicKey = publicKey; self.now = now
	}

	func count(_ prefix: String) -> Int { requestLog.filter { $0.hasPrefix(prefix) }.count }
	func failNext(_ prefix: String, _ action: @escaping @Sendable () throws -> ZagHTTPResponse) { failures.append((prefix, action)) }
	func seedBundleIDs(_ identifiers: [String]) { for id in identifiers { bundleIDs.append((next("BID"), id)) } }
	func seedDevice(udid: String, status: String) { devices.append(Device(id: next("DEV"), udid: udid, name: "Old", status: status)) }
	func invalidateProfiles() { for index in profiles.indices { profiles[index].state = "INVALID" } }
	var activeProfiles: [Profile] { profiles.filter { $0.state == "ACTIVE" } }

	private func next(_ prefix: String) -> String { serial += 1; return "\(prefix)\(serial)" }

	static func reply(_ status: Int, _ object: [String: Any]) -> ZagHTTPResponse {
		ZagHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: object))
	}

	/// The profile content this mock issues, decoded the way the real parser
	/// would present a signed development profile.
	static let decodeProfile: @Sendable (Data) throws -> ZagIssuedProfile = { data in
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let uuid = object["uuid"] as? String, let team = object["team"] as? String, let bundle = object["bundle"] as? String,
			  let serials = object["serials"] as? [String], let udids = object["udids"] as? [String] else { throw ZagPortalError.malformedResponse }
		let expires = (object["expires"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Tests.fixedNow + 365 * 86_400
		let entitlements: [String: Any] = [
			ZagFreeAccountEntitlements.applicationIdentifierKey: "\(team).\(bundle)",
			"com.apple.developer.team-identifier": team,
			"get-task-allow": true
		]
		return ZagIssuedProfile(uuid: uuid, teamIdentifier: team, bundleIdentifier: bundle, certificateSerials: serials, deviceUDIDs: udids,
								entitlements: try ZagEntitlementSet(entitlements), createdAt: Tests.fixedNow,
								expiresAt: expires, data: data)
	}

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		try lock.withLock {
			let response = Self.withLinks(try handle(request), path: request.url.path)
			Self.dump(request, response)
			return response
		}
	}

	/// Adds the `links` members Apple's documents mark as required (the
	/// client ignores them), so mock responses keep Apple's documented shape.
	private static func withLinks(_ response: ZagHTTPResponse, path: String) -> ZagHTTPResponse {
		guard (200..<300).contains(response.statusCode),
			  var object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any], let data = object["data"] else { return response }
		let base = "https://" + ZagASCClient.host
		func linked(_ resource: Any) -> Any {
			guard var resource = resource as? [String: Any], let type = resource["type"] as? String, let id = resource["id"] as? String else { return resource }
			resource["links"] = ["self": "\(base)/v1/\(type)/\(id)"]
			return resource
		}
		object["data"] = (data as? [Any]).map { $0.map(linked) } ?? linked(data)
		object["links"] = ["self": base + path]
		return ZagHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: try! JSONSerialization.data(withJSONObject: object))
	}

	/// With ZAG_ASC_REQUEST_DUMP set, each exchange is appended as a JSON line
	/// for validation against Apple's published OpenAPI document (the runner's
	/// optional step). The token is never written.
	private static func dump(_ request: ZagHTTPRequest, _ response: ZagHTTPResponse) {
		guard let path = ProcessInfo.processInfo.environment["ZAG_ASC_REQUEST_DUMP"] else { return }
		let query = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { [$0.name, $0.value ?? ""] }
		let line: [String: Any] = [
			"method": request.method, "path": request.url.path, "query": query,
			"body": request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
			"status": response.statusCode,
			"response": (try? JSONSerialization.jsonObject(with: response.body)) ?? NSNull()
		]
		guard var data = try? JSONSerialization.data(withJSONObject: line) else { return }
		data.append(0x0A)
		if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
		else { FileManager.default.createFile(atPath: path, contents: data) }
	}

	private func handle(_ request: ZagHTTPRequest) throws -> ZagHTTPResponse {
		let path = request.url.path
		let key = "\(request.method) \(path)"
		requestLog.append(key)
		requestCount += 1
		verifyToken(request.headers["Authorization"], key)
		if request.url.host != ZagASCClient.host || request.url.scheme != "https" { schemaProblems.append("\(key): wrong origin") }
		if let index = failures.firstIndex(where: { key.hasPrefix($0.prefix) }) {
			return try failures.remove(at: index).action()
		}
		if revoked { return Self.reply(401, ["errors": [["status": "401", "code": "NOT_AUTHORIZED"]]]) }
		if readOnlyKey, request.method != "GET" { return Self.reply(403, ["errors": [["status": "403", "code": "FORBIDDEN_ERROR"]]]) }

		let query = Dictionary((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
		let data = (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["data"] as? [String: Any]
		let attributes = data?["attributes"] as? [String: Any] ?? [:]
		func bad(_ why: String) -> ZagHTTPResponse { schemaProblems.append("\(key): \(why)"); return Self.reply(422, ["errors": [["status": "422", "code": "PARAMETER_ERROR.INVALID"]]]) }
		func expect(_ type: String) -> Bool {
			request.headers["Content-Type"] == "application/json" && data?["type"] as? String == type
		}
		let conflict = Self.reply(409, ["errors": [["status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID"]]])
		func page(_ rows: [[String: Any]]) -> ZagHTTPResponse {
			let limit = Int(query["limit"] ?? "") ?? 20
			if limit < 1 || limit > 200 { schemaProblems.append("\(key): limit \(limit)") }
			return Self.reply(200, ["data": Array(rows.prefix(limit)), "meta": ["paging": ["total": rows.count, "limit": limit]]])
		}
		func json(_ d: Device) -> [String: Any] {
			["type": "devices", "id": d.id, "attributes": ["udid": d.udid, "name": d.name, "status": d.status, "platform": "IOS", "deviceClass": "IPHONE"]]
		}
		func profileJSON(_ p: Profile) -> [String: Any] {
			let bundle = bundleIDs.first { $0.id == p.bundleID }?.identifier ?? ""
			let content = try! JSONSerialization.data(withJSONObject: [
				"uuid": p.id, "team": teamID, "bundle": bundle, "expires": p.expires.timeIntervalSince1970,
				"serials": certificates.filter { p.certificateIDs.contains($0.id) }.map(\.serial),
				"udids": devices.filter { p.deviceIDs.contains($0.id) }.map(\.udid)
			])
			return ["type": "profiles", "id": p.id, "attributes": [
				"name": p.name, "platform": "IOS", "profileType": "IOS_APP_DEVELOPMENT", "profileState": p.state, "uuid": p.id,
				"expirationDate": ISO8601DateFormatter().string(from: p.expires), "profileContent": content.base64EncodedString()
			]]
		}
		func json(_ c: Certificate) -> [String: Any] {
			["type": "certificates", "id": c.id, "attributes": ["name": "iOS Development", "certificateType": "IOS_DEVELOPMENT", "serialNumber": c.serial,
				"expirationDate": "2027-11-18T09:00:00.000+0000", "certificateContent": Data("CERT-\(c.serial)".utf8).base64EncodedString()]]
		}

		switch (request.method, path) {
		case ("GET", "/v1/devices"):
			return page(devices.filter { d in
				(query["filter[udid]"].map { $0 == d.udid } ?? true) && (query["filter[status]"].map { $0 == d.status } ?? true)
					&& (query["filter[platform]"].map { $0 == "IOS" } ?? true)
			}.map(json))
		case ("POST", "/v1/devices"):
			guard expect("devices"), let udid = attributes["udid"] as? String, let name = attributes["name"] as? String,
				  attributes["platform"] as? String == "IOS", attributes.count == 3 else { return bad("device create body") }
			if devices.contains(where: { $0.udid == udid }) { return conflict }
			let device = Device(id: next("DEV"), udid: udid, name: name, status: "ENABLED")
			devices.append(device)
			return Self.reply(201, ["data": json(device)])
		case ("PATCH", _) where path.hasPrefix("/v1/devices/"):
			let id = String(path.dropFirst("/v1/devices/".count))
			guard expect("devices"), data?["id"] as? String == id, let status = attributes["status"] as? String, ["ENABLED", "DISABLED"].contains(status) else {
				return bad("device update body")
			}
			guard let index = devices.firstIndex(where: { $0.id == id }) else { return Self.reply(404, ["errors": [["status": "404"]]]) }
			devices[index].status = status
			return Self.reply(200, ["data": json(devices[index])])
		case ("GET", "/v1/bundleIds"):
			// Apple's identifier filter matches identifiers containing the text.
			return page(bundleIDs.filter { b in query["filter[identifier]"].map { b.identifier.contains($0) } ?? true }
				.map { ["type": "bundleIds", "id": $0.id, "attributes": ["identifier": $0.identifier, "name": "App", "platform": "IOS"]] })
		case ("POST", "/v1/bundleIds"):
			guard expect("bundleIds"), let identifier = attributes["identifier"] as? String, attributes["name"] is String,
				  attributes["platform"] as? String == "IOS" else { return bad("bundle ID create body") }
			if identifier.hasPrefix("taken.") || bundleIDs.contains(where: { $0.identifier == identifier }) { return conflict }
			let id = next("BID")
			bundleIDs.append((id, identifier))
			return Self.reply(201, ["data": ["type": "bundleIds", "id": id, "attributes": ["identifier": identifier, "name": "App", "platform": "IOS"]]])
		case ("GET", "/v1/certificates"):
			if let type = query["filter[certificateType]"], type != "IOS_DEVELOPMENT" { return page([]) }
			return page(certificates.map(json))
		case ("POST", "/v1/certificates"):
			guard expect("certificates"), attributes["certificateType"] as? String == "IOS_DEVELOPMENT",
				  let pem = attributes["csrContent"] as? String,
				  pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n"), pem.hasSuffix("\n-----END CERTIFICATE REQUEST-----"),
				  let der = Data(base64Encoded: pem.components(separatedBy: "\n").dropFirst().dropLast().joined()), !der.isEmpty else {
				return bad("certificate create body")
			}
			if certificates.count >= certificateLimit { return conflict }
			let certificate = Certificate(id: next("CER"), serial: "SER\(certificates.count + 1)")
			certificates.append(certificate)
			return Self.reply(201, ["data": json(certificate)])
		case ("GET", "/v1/profiles"):
			if let type = query["filter[profileType]"], type != "IOS_APP_DEVELOPMENT" { return page([]) }
			return page(profiles.filter { p in query["filter[name]"].map { $0 == p.name } ?? true }.map(profileJSON))
		case ("DELETE", _) where path.hasPrefix("/v1/profiles/"):
			let id = String(path.dropFirst("/v1/profiles/".count))
			guard let index = profiles.firstIndex(where: { $0.id == id }) else { return Self.reply(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]]) }
			profiles.remove(at: index)
			return ZagHTTPResponse(statusCode: 204, headers: [:], body: Data())
		case ("POST", "/v1/profiles"):
			guard expect("profiles"), attributes["profileType"] as? String == "IOS_APP_DEVELOPMENT", (attributes["name"] as? String)?.isEmpty == false,
				  let relationships = data?["relationships"] as? [String: Any] else { return bad("profile create body") }
			func ids(_ name: String, _ type: String, many: Bool) -> [String]? {
				let value = (relationships[name] as? [String: Any])?["data"]
				let items = many ? value as? [[String: Any]] : (value as? [String: Any]).map { [$0] }
				guard let items, !items.isEmpty, items.allSatisfy({ $0["type"] as? String == type && $0["id"] is String }) else { return nil }
				return items.compactMap { $0["id"] as? String }
			}
			guard let bundle = ids("bundleId", "bundleIds", many: false), let bundleRow = bundleIDs.first(where: { $0.id == bundle[0] }) else {
				return bad("profile bundleId relationship")
			}
			guard let certificateIDs = ids("certificates", "certificates", many: true),
				  certificateIDs.allSatisfy({ id in certificates.contains { $0.id == id } }) else { return bad("profile certificates relationship") }
			guard let deviceIDs = ids("devices", "devices", many: true),
				  deviceIDs.allSatisfy({ id in devices.contains { $0.id == id && $0.status == "ENABLED" } }) else { return bad("profile devices relationship") }
			let name = attributes["name"] as! String
			if profiles.contains(where: { $0.name == name }) { return conflict }   // assume names are unique per team (strictest case)
			let profile = Profile(id: next("PRO"), name: name, bundleID: bundleRow.id, certificateIDs: certificateIDs, deviceIDs: deviceIDs,
								  expires: now + profileLifetime, state: "ACTIVE")
			profiles.append(profile)
			return Self.reply(201, ["data": profileJSON(profile)])
		default:
			return Self.reply(404, ["errors": [["status": "404"]]])
		}
	}

	private func verifyToken(_ authorization: String?, _ key: String) {
		func problem(_ why: String) { tokenProblems.append("\(key): \(why)") }
		guard let authorization, authorization.hasPrefix("Bearer ") else { return problem("no bearer token") }
		let parts = authorization.dropFirst(7).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
		guard parts.count == 3 else { return problem("not a compact JWS") }
		let header = (try? JSONSerialization.jsonObject(with: Tests.base64URLDecode(parts[0]))) as? [String: Any] ?? [:]
		let claims = (try? JSONSerialization.jsonObject(with: Tests.base64URLDecode(parts[1]))) as? [String: Any] ?? [:]
		if header["alg"] as? String != "ES256" || header["kid"] as? String != keyID || header["typ"] as? String != "JWT" { problem("header") }
		if claims["iss"] as? String != issuerID || claims["aud"] as? String != "appstoreconnect-v1" || claims["sub"] != nil { problem("claims") }
		guard let iat = claims["iat"] as? Int, let exp = claims["exp"] as? Int, exp > iat, exp - iat <= 1_200,
			  Double(iat) <= now.timeIntervalSince1970 + 60, Double(exp) > now.timeIntervalSince1970 else { return problem("lifetime") }
		guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: Tests.base64URLDecode(parts[2])),
			  publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else { return problem("signature") }
	}
}

final class CountingInstaller: ZagFreeAccountInstaller, @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	private var expectation: ZagInstallExpectation?
	let verification: ZagInstallVerification?
	init(verification: ZagInstallVerification? = nil) { self.verification = verification }
	var installs: Int { lock.withLock { count } }
	var lastExpectation: ZagInstallExpectation? { lock.withLock { expectation } }
	func install(signedApp: URL, bundleIdentifier: String) async throws { lock.withLock { count += 1 } }
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		lock.withLock { self.expectation = expectation }
		return verification ?? .verified(profileExpiresAt: expectation.profileExpiresAt, certificateExpiresAt: expectation.certificateExpiresAt)
	}
}

/// Signs, then cancels the task it runs in (a user tapping Cancel right after
/// signing finished).
struct CancellingSigner: ZagAppSigning {
	func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity, authorization: ZagSigningAuthorization, now: Date) throws -> ZagSignedAppRecord {
		let record = try StubSigner(fails: false, now: now).sign(appAt: app, with: result, identity: identity, authorization: authorization, now: now)
		withUnsafeCurrentTask { $0?.cancel() }
		return record
	}
}

/// A code signer that records the call and changes nothing.
final class NoopCodeSigner: ZagCodeSigner, @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	var calls: Int { lock.withLock { count } }
	func sign(app: URL, profile: URL, privateKey: URL, entitlements: URL, bundleIdentifier: String) throws { lock.withLock { count += 1 } }
}

struct TestFailure: Error {}

/// The simulated key factory, recording which teams' keys were discarded.
final class RecordingKeyFactory: ZagSigningKeyFactory, @unchecked Sendable {
	private let lock = NSLock()
	private var teams: [String] = []
	private let base = ZagSimulatedSigningKeyFactory()
	var discarded: [String] { lock.withLock { teams } }
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) { try base.makeKey(commonName: commonName) }
	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { base.check(certificate: certificate, privateKey: privateKey) }
	func discardKeys(account: UUID, team: String, except keeping: Set<String?>) throws { lock.withLock { teams.append(team) } }
}

struct FailingInstaller: ZagFreeAccountInstaller {
	func install(signedApp: URL, bundleIdentifier: String) async throws { throw TestFailure() }
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification { .notInstalled }
}
