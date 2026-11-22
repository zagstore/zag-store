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

		// Gate open and the key works: connected and stored, key cleared.
		let openSecrets = MemorySecrets()
		let m = model(secrets: openSecrets, gate: .testingOpen, transport: MockTransport(.success(response(200, certificatesPage))))
		m.keyID = keyID; m.issuerID = issuerID; m.teamID = teamID
		m.importKey(contents: pem, fileName: "AuthKey.p8")
		check(m.canConnect, "onboarding: valid input can connect")
		await m.connect()
		if case .connected(let k, let total) = m.phase { check(k == keyID && total == 2, "onboarding: a working key connects") }
		else { check(false, "onboarding: a working key must connect") }
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
		check(status(.connected(keyID: keyID)) == .ready(detail: "Key \(keyID)"), "method: connected shows the key ID")
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

		if case .failed(.disabled) = await run(gate: .production) {} else { check(false, "coordinator: a closed gate is disabled") }
		check(true, "coordinator: a closed gate signs nothing")

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
