import Foundation

// Host tests for the NATIVE developer-services codec (Phase 3), offline only.
// Compiled with ZagPortalError.swift + ZagDeveloperServicesProtocol.swift.
// Validates request/response structure, action classification, error mapping,
// the request budget and PEM wrapping — no Apple contact, no model graph.

var failures = 0
func check(_ cond: Bool, _ what: String) {
	if cond { print("PASS: \(what)") } else { print("FAIL: \(what)"); failures += 1 }
}
func throws_(_ expected: ZagPortalError, _ body: () throws -> Void, _ what: String) {
	do { try body(); print("FAIL: \(what) (did not throw)"); failures += 1 }
	catch let e as ZagPortalError { check(e == expected, "\(what) -> \(e)") }
	catch { print("FAIL: \(what) (\(error))"); failures += 1 }
}

// MARK: Action classification (read-only vs mutating) — audit item 5.
let readOnly: [ZagDeveloperServicesAction] = [.listTeams, .listDevices, .listCertificates, .listAppIDs, .listAppGroups, .listProfiles]
let mutating: [ZagDeveloperServicesAction] = [.addDevice, .submitCSR, .revokeCertificate, .addAppID, .addAppGroup, .assignAppGroups, .downloadProfile]
check(readOnly.allSatisfy { !$0.isMutating }, "all discovery actions are read-only")
check(mutating.allSatisfy { $0.isMutating }, "all create/register/revoke actions are mutating")
check(Set(readOnly + mutating).count == ZagDeveloperServicesAction.allCases.count, "every action is classified exactly once")

// MARK: Endpoint building.
let ep = try! ZagDeveloperServicesProtocol.endpoint(.listTeams)
check(ep.scheme == "https" && ep.host == "developerservices2.apple.com", "endpoint is https on the pinned host")
check(ep.path == "/services/QH65B2/listTeams.action", "endpoint path includes protocol version + action")
check((ep.query ?? "").contains("clientId=XABBG36SBA"), "endpoint carries the clientId query")
let csrEp = try! ZagDeveloperServicesProtocol.endpoint(.submitCSR)
check(csrEp.path == "/services/QH65B2/ios/submitDevelopmentCSR.action", "ios-scoped action path")

// MARK: Request body envelope.
let body = try! ZagDeveloperServicesProtocol.requestBody(teamID: "ABCDE12345", parameters: ["deviceNumber": "UDID", "name": "iPhone"], requestID: "FIXED-REQUEST-ID")
let decoded = try! PropertyListSerialization.propertyList(from: body, format: nil) as! [String: Any]
check(decoded["clientId"] as? String == "XABBG36SBA", "body carries clientId")
check(decoded["protocolVersion"] as? String == "QH65B2", "body carries protocolVersion")
check(decoded["requestId"] as? String == "FIXED-REQUEST-ID", "body carries requestId")
check((decoded["userLocale"] as? [String]) == ["en_US"], "body carries userLocale array")
check(decoded["teamId"] as? String == "ABCDE12345", "body carries teamId when supplied")
check(decoded["deviceNumber"] as? String == "UDID" && decoded["name"] as? String == "iPhone", "body merges action parameters")
let noTeam = try! PropertyListSerialization.propertyList(from: ZagDeveloperServicesProtocol.requestBody(teamID: nil), format: nil) as! [String: Any]
check(noTeam["teamId"] == nil, "teamId omitted for team discovery (no team yet)")
let auto = try! PropertyListSerialization.propertyList(from: ZagDeveloperServicesProtocol.requestBody(teamID: nil), format: nil) as! [String: Any]
let rid = auto["requestId"] as? String ?? ""
check(rid == rid.uppercased() && rid.count >= 36, "auto requestId is an uppercased UUID")

// MARK: Response parsing + error mapping.
func plist(_ d: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0) }
let ok = try! ZagDeveloperServicesProtocol.parse(plist(["resultCode": 0, "teams": [["teamId": "T1", "name": "Me"]]]), httpStatus: 200)
check((ok["teams"] as? [[String: Any]])?.first?["teamId"] as? String == "T1", "success (resultCode 0) returns payload")
let okNoCode = try! ZagDeveloperServicesProtocol.parse(plist(["teams": []]), httpStatus: 200)
check(okNoCode["teams"] != nil, "absent resultCode treated as success")
throws_(.sessionRejected, { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 1100, "userString": "bad session"]), httpStatus: 200) }, "resultCode 1100 -> sessionRejected")
throws_(.rateLimited,     { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 7460]), httpStatus: 200) }, "resultCode 7460 -> rateLimited")
throws_(.deviceLimitReached, { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 9120]), httpStatus: 200) }, "resultCode 9120 -> deviceLimitReached")
throws_(.appIDLimitReached,  { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 9412]), httpStatus: 200) }, "resultCode 9412 -> appIDLimitReached")
throws_(.certificateLimitReached, { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 3540]), httpStatus: 200) }, "resultCode 3540 -> certificateLimitReached")
throws_(.identifierUnavailable("Identifier is not available"), { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 9999, "userString": "Identifier is not available"]), httpStatus: 200) }, "identifier message -> identifierUnavailable")
throws_(.malformedResponse, { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 55555, "userString": "???"]), httpStatus: 200) }, "unknown non-zero code -> malformedResponse")
throws_(.malformedResponse, { _ = try ZagDeveloperServicesProtocol.parse(Data("not a plist".utf8), httpStatus: 200) }, "non-plist body -> malformedResponse")
throws_(.sessionRejected, { _ = try ZagDeveloperServicesProtocol.parse(Data(), httpStatus: 401) }, "HTTP 401 -> sessionRejected")
throws_(.rateLimited,     { _ = try ZagDeveloperServicesProtocol.parse(Data(), httpStatus: 429) }, "HTTP 429 -> rateLimited")
throws_(.network,         { _ = try ZagDeveloperServicesProtocol.parse(Data(), httpStatus: 500) }, "HTTP 500 -> network")

// MARK: Request budget (hard ceiling, no retries).
let budget = ZagRequestBudget(limit: 2)
check(budget.take() && budget.take(), "budget admits up to its limit")
check(!budget.take(), "budget refuses past its limit")
check(budget.used == 2, "budget counts used requests")
check(!ZagRequestBudget(limit: 0).take(), "a zero budget admits nothing")

// MARK: Team-discovery gate cannot reach a mutation (audit item 9).
// The team-discovery path uses only listTeams; assert it is read-only, and that
// every mutating action is distinct from it, so the gate cannot touch one.
check(ZagDeveloperServicesAction.listTeams.isMutating == false, "team discovery (listTeams) is read-only")
check(ZagDeveloperServicesAction.allCases.filter { $0.isMutating }.allSatisfy { $0 != .listTeams }, "no mutating action equals listTeams")
check(ZagPersistedDeveloperToken(accountID: "a", token: "t", expiresAtMs: 0).isUsable(at: Date()), "token with no expiry is usable")
check(!ZagPersistedDeveloperToken(accountID: "a", token: "t", expiresAtMs: 1).isUsable(at: Date()), "expired token is not usable")
check(!ZagPersistedDeveloperToken(accountID: "", token: "", expiresAtMs: 0).isUsable(at: Date()), "empty token is not usable")

// MARK: PEM wrapping of the CSR (public request only).
let pem = ZagDeveloperServicesProtocol.pem(Data([0x30, 0x82, 0x01, 0x02]))
check(pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n") && pem.hasSuffix("-----END CERTIFICATE REQUEST-----\n"), "PEM wraps DER with request armor")
check(pem.contains("MIIBAg"), "PEM carries base64 of the DER")

// MARK: Certificate parser (certContent raw, certificateContent base64, attributes nesting).
let derBytes = Data([0x30, 0x82, 0x02, 0x01])
let certRaw = ZagDeveloperServicesProtocol.parseCertificate(["certContent": derBytes, "serialNumber": "0A1B", "name": "iOS Dev", "machineName": "Zag"])
check(certRaw?.der == derBytes && certRaw?.serialNumber == "A1B" && certRaw?.machineName == "Zag", "cert from certContent (raw DER), serial leading-zero stripped")
let certB64 = ZagDeveloperServicesProtocol.parseCertificate(["attributes": ["certificateContent": derBytes.base64EncodedString(), "serialNum": "00FF"]])
check(certB64?.der == derBytes && certB64?.serialNumber == "FF", "cert from attributes.certificateContent (base64) + serialNum fallback")
check(ZagDeveloperServicesProtocol.parseCertificate(["name": "x"]) == nil, "cert row with no content and no serial -> nil")

// MARK: /services/v1/ JSON codec.
let v1ep = try! ZagDeveloperServicesV1.endpoint("certificates")
check(v1ep.absoluteString == "https://developerservices2.apple.com/services/v1/certificates", "v1 endpoint path")
let v1body = try! ZagDeveloperServicesV1.listCertificatesBody(teamID: "ABCDE12345")
let v1json = try! JSONSerialization.jsonObject(with: v1body) as! [String: Any]
check((v1json["urlEncodedQueryParams"] as? String)?.contains("teamId=ABCDE12345") == true, "v1 cert body carries url-encoded teamId")
check((v1json["urlEncodedQueryParams"] as? String)?.contains("certificateType") == true, "v1 cert body carries certificateType filter")
let v1hdrs = ZagDeveloperServicesV1.headers(methodOverride: "GET")
check(v1hdrs["X-HTTP-Method-Override"] == "GET" && v1hdrs["Content-Type"] == "application/vnd.api+json", "v1 headers set method override + json:api content type")
func v1(_ d: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: d) }
let v1ok = try! ZagDeveloperServicesV1.parseList(v1(["data": [["id": "C1", "attributes": ["serialNumber": "AB"]]]]), httpStatus: 200)
check(v1ok.count == 1 && (v1ok.first?["id"] as? String) == "C1", "v1 parseList returns the data array")
throws_(.sessionRejected, { _ = try ZagDeveloperServicesV1.parseList(Data(), httpStatus: 401) }, "v1 HTTP 401 -> sessionRejected")
throws_(.certificateLimitReached, { _ = try ZagDeveloperServicesV1.parseList(v1(["errors": [["detail": "Maximum number of certificates reached"]]]), httpStatus: 200) }, "v1 errors 'limit' -> certificateLimitReached")

// MARK: Account-mutation consent coordinator (default-deny, up-front authorize, cancel).
let consent = ZagMutationConsentCoordinator()
check(consent.mayPerform(.addDevice) == false, "consent default-deny before authorization")
consent.authorize([.addDevice, .listTeams])
check(consent.mayPerform(.addDevice) == true, "authorized mutation is permitted")
check(consent.mayPerform(.listTeams) == false, "read-only action is never stored as a mutation consent")
check(consent.mayPerform(.submitCSR) == false, "unauthorized mutation stays denied")
consent.cancel()
check(consent.mayPerform(.addDevice) == false, "cancel revokes all consent")
check(ZagDenyingMutationConsent().mayPerform(.addDevice) == false, "denying consent denies everything")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
