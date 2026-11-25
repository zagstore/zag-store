import Foundation

extension Tests {
	@MainActor
	static func nativeAppIDsAcrossAccounts() async {
		let clock = TestClock()
		let secrets = MemorySecrets()
		let original = "com.example.integration"
		let accounts = ["111111111", "222222222", "333333333"]
		let teams = ["FREETEAM01", "FREETEAM02", "FREETEAM03"]
		let fixture = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
		let certificate = ZagCertificateInspection(der: fixture)!
		let expiration = clock.now + 7 * 86_400
		let transport = NativeAppIDTransport(teams: Dictionary(uniqueKeysWithValues: zip(accounts, teams)), certDER: fixture,
			certificateSerial: certificate.serialNumber, now: clock.now)
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		do {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let consent = ZagMutationConsentCoordinator()
			consent.authorize([.addDevice, .submitCSR, .addAppID, .downloadProfile])
			let tokens = accounts.map { ZagPersistedDeveloperToken(accountID: $0, token: "mock-token-\($0)", expiresAtMs: 0) }
			let portals = tokens.map { token in
				ZagNativeDeveloperPortal(transport: transport, headers: { try await transport.headers(for: token) }, consent: consent, maxRequests: nil)
			}
			await transport.seed(
				(0..<12).map { .init(identifier: "UNDATED\($0)", bundleIdentifier: "com.other.app\($0)", expiresAt: nil) },
				team: teams[1]
			)
			let existingBundle = ZagBundleIdentifierMapping.mapped(original, team: teams[2])!
			await transport.seed([
				.init(identifier: "EXISTING", bundleIdentifier: existingBundle, expiresAt: expiration),
				.init(identifier: "EXISTING", bundleIdentifier: existingBundle, expiresAt: expiration),
				.init(identifier: "EXPIRED", bundleIdentifier: "com.example.expired", expiresAt: clock.now - 1)
			], team: teams[2])
			var scopes: Set<ZagSigningScope> = []
			for index in accounts.indices {
				await transport.select(accounts[index])
				let discovered = try await portals[index].teams()
				guard let team = ZagNativeDeveloperTeam.personalTeam(in: discovered), team.teamID == teams[index] else {
					return check(false, "select the signed-in account's active Personal Team")
				}
				if index > 0 {
					do {
						_ = try await portals[index - 1].appIDs(team: teams[index - 1])
						check(false, "the previous account's portal should reject calls after switching")
					} catch ZagPortalError.sessionRejected {
						check(true, "switching invalidates the previous account's portal session")
					}
				}
				let authorization = ZagSigningAuthorization.nativeAccount(token: tokens[index], teamID: team.teamID)
				scopes.insert(authorization.scope)
				let provisioner = ZagFreeAccountProvisioner(portal: portals[index], keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
					account: authorization.scope.accountID, now: { clock.now })
				let request = ZagProvisioningRequest(accountID: authorization.scope.accountID, team: team.teamID, deviceUDID: udid,
					deviceName: "Test Device", app: .init(originalBundleIdentifier: original, name: "Integration Test", entitlements: entitlements()),
					extensions: [], installedFreeAccountApps: [])
				let actual = try await ZagNativeSigningPipeline.run(request, authorization: authorization, app: root,
					provisioner: provisioner, secrets: secrets, signer: AppIDTestSigner(), installer: AppIDTestInstaller(),
					verifyTarget: {}, now: { clock.now })
				check(actual == .verified(profileExpiresAt: expiration, certificateExpiresAt: certificate.expiresAt),
					"native account \(index + 1) provisions, signs, installs and verifies the app")
			}
			let registrationCounts = await transport.registrations
			check(scopes.count == 3 && registrationCounts == [teams[0]: 1, teams[1]: 1],
				"fresh and undated inventories allow registration, team scopes stay distinct, and an existing ID is reused")

			await transport.select(accounts[0])
			await transport.rejectRegistration(code: 37)
			let auth = ZagSigningAuthorization.nativeAccount(token: tokens[0], teamID: teams[0])
			let provisioner = ZagFreeAccountProvisioner(portal: portals[0], keys: ZagSimulatedSigningKeyFactory(), secrets: secrets,
				onCertificateReady: { await transport.certificateReady() }, account: auth.scope.accountID, now: { clock.now })
			let request = ZagProvisioningRequest(accountID: auth.scope.accountID, team: teams[0], deviceUDID: udid,
				deviceName: "Test Device", app: .init(originalBundleIdentifier: "com.example.second", name: "Second Test", entitlements: entitlements()),
				extensions: [], installedFreeAccountApps: [])
			let rejected = await provisioner.provision(request, authorization: auth)
			let certificateWasReady = await transport.certificatesReady == 1
			check(certificateWasReady, "certificate-ready notification clears recovery UI even when a later provisioning step fails")
			check(rejected.failure?.kind == .appIDServerLimitReached && rejected.failure?.appleAppIDRejection?.fault.resultCode == 37
				&& rejected.failure?.message.contains("code 37") == true && rejected.failure?.message.contains(accounts[0]) == false,
				"the server's genuine quota rejection retains its sanitized code and remains distinct from local capacity")
		} catch {
			check(false, "native three-account App ID and install integration: \(error)")
		}
	}
}

private actor NativeAppIDTransport: ZagHTTPTransport {
	let teams: [String: String]
	let certDER: Data
	let certificateSerial: String
	let now: Date
	var selected: String?
	var rows: [String: [ZagRegisteredAppID]] = [:]
	var registeredDevices = Set<String>()
	var issued = Set<String>()
	var registrations: [String: Int] = [:]
	var registrationRejection: Int?
	var certificatesReady = 0

	init(teams: [String: String], certDER: Data, certificateSerial: String, now: Date) {
		self.teams = teams
		self.certDER = certDER
		self.certificateSerial = certificateSerial
		self.now = now
	}

	func select(_ account: String) { selected = account }
	func seed(_ ids: [ZagRegisteredAppID], team: String) { rows[team] = ids }
	func rejectRegistration(code: Int) { registrationRejection = code }
	func certificateReady() { certificatesReady += 1 }

	func headers(for token: ZagPersistedDeveloperToken) throws -> [String: String] {
		guard selected == token.accountID else { throw ZagPortalError.sessionRejected }
		return ["X-Apple-I-Identity-Id": token.accountID, "X-Apple-GS-Token": token.token]
	}

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		guard let selected, let team = teams[selected], request.method == "POST",
			  request.headers["X-Apple-I-Identity-Id"] == selected,
			  request.headers["X-Apple-GS-Token"] == "mock-token-\(selected)", let body = request.body else {
			throw ZagPortalError.sessionRejected
		}

		if request.url.path == "/services/v1/certificates" {
			let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
			guard json?["urlEncodedQueryParams"] == "teamId=\(team)",
				  request.headers["X-HTTP-Method-Override"] == "GET" else { throw ZagPortalError.malformedResponse }
			let rows: [[String: Any]] = issued.contains(team) ? [["id": "CERT", "attributes": [
				"serialNumber": certificateSerial, "certificateContent": certDER.base64EncodedString()
			]]] : []
			return .init(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: ["data": rows]))
		}

		let params = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
		guard params?["clientId"] as? String == "XABBG36SBA", params?["protocolVersion"] as? String == "QH65B2",
			  request.url.query == "clientId=XABBG36SBA", request.headers["Content-Type"] == "text/x-xml-plist" else {
			throw ZagPortalError.malformedResponse
		}
		let action = request.url.lastPathComponent
		if action != "listTeams.action", params?["teamId"] as? String != team { throw ZagPortalError.sessionRejected }
		var reply: [String: Any] = ["resultCode": 0]
		switch action {
		case "listTeams.action":
			reply["teams"] = [
				["teamId": "PAIDTEAM01", "name": "Organization", "status": "active", "type": "Company"],
				["teamId": "OLDTEAM001", "name": "Expired (Personal Team)", "status": "expired"],
				["teamId": team, "name": "Test Personal Team", "status": "active", "memberships": [["name": "Free Provisioning"]]]
			]
		case "listDevices.action":
			reply["devices"] = registeredDevices.contains(team) ? [["deviceNumber": udid, "name": "Test Device"]] : []
		case "addDevice.action":
			guard params?["deviceNumber"] as? String == udid else { throw ZagPortalError.malformedResponse }
			registeredDevices.insert(team)
			reply["device"] = ["deviceNumber": udid, "name": "Test Device"]
		case "listAppIds.action":
			// Apple can omit the optional array on an explicitly successful empty reply.
			if let ids = rows[team] {
				reply["appIds"] = ids.map { row in
					var encoded: [String: Any] = ["appIdId": row.identifier, "identifier": row.bundleIdentifier]
					if let expiry = row.expiresAt { encoded["expirationDate"] = expiry }
					return encoded
				}
			}
		case "submitDevelopmentCSR.action":
			issued.insert(team)
			reply["certRequest"] = ["certContent": certDER, "serialNumber": certificateSerial]
		case "addAppId.action":
			guard let bundle = params?["identifier"] as? String, bundle.hasSuffix(".\(team)"),
				  let name = params?["name"] as? String, !name.isEmpty else { throw ZagPortalError.malformedResponse }
			if let code = registrationRejection {
				reply = ["resultCode": code, "userString": "App ID limit reached for \(selected) on \(team)."]
			} else {
				let id = "NEW\(registrations[team, default: 0])"
				let expiry = now + 7 * 86_400
				registrations[team, default: 0] += 1
				rows[team, default: []].append(.init(identifier: id, bundleIdentifier: bundle, expiresAt: expiry))
				reply["appId"] = ["appIdId": id, "identifier": bundle, "expirationDate": expiry]
			}
		case "downloadTeamProvisioningProfile.action":
			guard let id = params?["appIdId"] as? String, let app = rows[team]?.first(where: { $0.identifier == id }) else {
				throw ZagPortalError.malformedResponse
			}
			let profile = try PropertyListSerialization.data(fromPropertyList: [
				"AppIDName": "Test", "CreationDate": now, "ExpirationDate": now + 7 * 86_400,
				"Platform": ["iOS"], "DeveloperCertificates": [certDER], "DER-Encoded-Profile": Data([1]),
				"Entitlements": ["application-identifier": "\(team).\(app.bundleIdentifier)"], "Name": "Test",
				"ProvisionedDevices": [udid], "TeamIdentifier": [team], "TeamName": "Test", "TimeToLive": 7, "UUID": "TESTPROFILE", "Version": 1
			], format: .xml, options: 0)
			reply["provisioningProfile"] = ["encodedProfile": profile]
		default: throw ZagPortalError.malformedResponse
		}
		return .init(statusCode: 200, headers: [:], body: try PropertyListSerialization.data(fromPropertyList: reply, format: .xml, options: 0))
	}
}

private struct AppIDTestSigner: ZagAppSigning {
	func sign(appAt app: URL, with result: ZagProvisioningResult, identity: ZagSigningIdentity,
			  authorization: ZagSigningAuthorization, now: Date) throws -> ZagSignedAppRecord {
		guard identity.serialNumber == result.certificateSerial, result.team == authorization.scope.teamID,
			  result.app.entitlements.dictionary["application-identifier"] as? String == "\(result.team).\(result.app.bundleIdentifier)" else {
			throw ZagFreeAccountSigningError.identityMismatch
		}
		try Data(result.app.bundleIdentifier.utf8).write(to: app.appendingPathComponent("signature"))
		return .init(bundleIdentifier: result.app.bundleIdentifier, originalBundleIdentifier: result.app.originalBundleIdentifier,
			signedAt: now, profileExpiresAt: result.expiresAt, certificateExpiresAt: identity.expiresAt)
	}
}

private actor AppIDTestInstaller: ZagFreeAccountInstaller {
	var installed: String?
	func install(signedApp: URL, bundleIdentifier: String) async throws {
		guard try String(contentsOf: signedApp.appendingPathComponent("signature"), encoding: .utf8) == bundleIdentifier else {
			throw ZagFreeAccountSigningError.verification("test signature")
		}
		installed = bundleIdentifier
	}
	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		guard installed == expectation.bundleIdentifier, expectation.profileUUID == "TESTPROFILE" else { return .notInstalled }
		return .verified(profileExpiresAt: expectation.profileExpiresAt, certificateExpiresAt: expectation.certificateExpiresAt)
	}
}
