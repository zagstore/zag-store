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
throws_(.existingCertificateOrPendingRequest, { _ = try ZagDeveloperServicesProtocol.parse(plist(["resultCode": 7460]), httpStatus: 200) }, "parse 7460 -> existingCertificateOrPendingRequest")
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

// MARK: Profile-identity audit (reuse decision; sanitized bool/count output only).
let soon = Date().addingTimeInterval(6 * 86_400)     // ~7-day free-account profile
let aud = ZagProfileIdentityAudit.audit(
	profileTeam: "V54K5JYGS4", profileDevices: ["00009999-000ABCDEF1234567"],
	profileCertificateSerials: ["A", "B", "C"], profileBundle: "dev.zagstore.ptteamprobe",
	profileExpiresAt: soon, discoveredTeam: "v54k5jygs4",
	expectedDeviceUDID: "00009999-000abcdef1234567", targetBundle: "dev.zagstore.ptteamprobe")
check(aud.teamMatchesDiscovered, "team matches discovered (case-insensitive)")
check(aud.deviceInProfile, "this device's UDID found in profile (case-insensitive)")
check(aud.bundleMatchesTarget, "profile bundle matches target")
check(aud.certificateCount == 3 && aud.deviceCount == 1, "counts are exposed, not identifiers")
check(!aud.profileExpired && aud.profileExpiresInDays == 6, "profile expiry reported in coarse days")
let miss = ZagProfileIdentityAudit.audit(
	profileTeam: "V54K5JYGS4", profileDevices: ["00009999-000ABCDEF1234567"],
	profileCertificateSerials: [], profileBundle: "dev.zagstore.ptteamprobe",
	profileExpiresAt: Date().addingTimeInterval(-3 * 86_400), discoveredTeam: "OTHERTEAMX",
	expectedDeviceUDID: "DEADBEEF", targetBundle: nil)
check(!miss.teamMatchesDiscovered, "different team -> no match")
check(!miss.deviceInProfile, "absent UDID -> not in profile")
check(miss.bundleMatchesTarget, "nil target bundle -> treated as matching")
check(miss.profileExpired && miss.profileExpiresInDays == -3, "past expiry -> expired, negative days")
let sani = aud.sanitized
check(sani["team_matches_discovered"] as? Bool == true && sani.count == 7, "sanitized dict carries only verdicts/counts")

// MARK: Certificate-cap preflight (inferred, NOT authoritative).
let within = ZagCertificateCapPreflight.evaluate(certificateCount: 1, inferredCap: 2)
check(within == .withinInferredCap(count: 1, inferredCap: 2) && !within.isInferredRisk, "count below inferred cap -> within")
let risk = ZagCertificateCapPreflight.evaluate(certificateCount: 3, inferredCap: 2)
check(risk.isInferredRisk, "count at/over inferred cap -> inferred risk")
check(risk.sanitized["authoritative"] as? Bool == false, "cap preflight is explicitly non-authoritative")

// MARK: Active-certificate guard (protects the Xcode cert; legacy = unknown, not unused).
let guardz = ZagActiveCertificateGuard(activeSHA1: "5657782A6EADFFF608040D39186E6533557349FC", activeSerial: "723BE3EC")
let active = ZagRevocableCertificate(id: "v1-active", serialNumber: "723BE3EC", sha1: "5657782a6eadfff608040d39186e6533557349fc", name: "Apple Development", machineName: nil, expiresAt: nil)
let legacy = ZagRevocableCertificate(id: "v1-legacy", serialNumber: "1950B2FA", sha1: "AAAA", name: "iPhone Developer", machineName: nil, expiresAt: nil)
check(guardz.classify(active) == .activeProtected, "active Xcode cert is classified protected (by SHA-1, case-insensitive)")
check(guardz.classify(legacy) == .unknownUsage, "legacy cert is unknown usage, never assumed unused")
check(!guardz.mayRevoke(active, explicitOverride: false), "active cert refused without explicit override")
check(guardz.mayRevoke(active, explicitOverride: true), "active cert revocable only with explicit override")
check(guardz.mayRevoke(legacy, explicitOverride: false), "non-active cert revocable once consented")

// MARK: Revocation codec (unambiguous id; synthetic responses only).
let revRows: [[String: Any]] = [["id": "CERTID1", "attributes": ["serialNumber": "AB", "certificateContent": Data([1,2,3]).base64EncodedString(), "name": "Apple Development"]]]
let cands = ZagCertificateRevocation.candidates(from: revRows)
check(cands.count == 1 && cands.first?.id == "CERTID1" && cands.first?.sha1 != nil, "revoke candidate carries v1 id + DER sha1")
check(ZagCertificateRevocation.endpointPath(id: "CERTID1") == "certificates/CERTID1" && ZagCertificateRevocation.methodOverride == "DELETE", "revoke uses v1 DELETE on the id")
check((try? ZagCertificateRevocation.parse(Data(), httpStatus: 200)) == true, "empty 2xx -> revoked")
check((try? ZagCertificateRevocation.parse(Data("{\"data\":null}".utf8), httpStatus: 200)) == true, "2xx json without errors -> revoked")
throws_(.sessionRejected, { _ = try ZagCertificateRevocation.parse(Data(), httpStatus: 403) }, "revoke HTTP 403 -> sessionRejected")
throws_(.malformedResponse, { _ = try ZagCertificateRevocation.parse(Data("{\"errors\":[{\"detail\":\"no\"}]}".utf8), httpStatus: 200) }, "revoke errors -> malformedResponse")

// MARK: Pending-CSR journal (idempotency: no duplicate request, no orphaned key).
let now = Date()
let fresh = ZagPendingCSRState(keySlot: "slot1", request: Data([9]), startedAt: now, attempts: 1, submissionUnconfirmed: false, issuedSerial: nil)
check(fresh.nextStep(at: now) == .submit, "fresh pending with attempts left -> submit (reuses stored request/key)")
var unconfirmed = fresh; unconfirmed.submissionUnconfirmed = true
check(unconfirmed.nextStep(at: now) == .resolveUnconfirmed, "unconfirmed submission -> resolve via listing, never resubmit")
var issued = fresh; issued.issuedSerial = "SER123"
check(issued.nextStep(at: now) == .reuseIssued(serial: "SER123"), "already issued -> reuse, no new request")
let spent = ZagPendingCSRState(keySlot: "slot1", request: Data([9]), startedAt: now.addingTimeInterval(-90_000), attempts: 3, submissionUnconfirmed: false, issuedSerial: nil)
check(spent.nextStep(at: now) == .exhausted, "retry budget/lifetime exhausted -> stop, keep key for review")

// MARK: Fault capture + conservative classifier (item 1/2).
func faultPlist(_ code: Int, _ msg: String = "") -> Data {
	var d: [String: Any] = ["resultCode": code]; if !msg.isEmpty { d["userString"] = msg }
	return try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
}
check(ZagDeveloperServicesProtocol.fault(body: faultPlist(0), httpStatus: 200) == nil, "resultCode 0 -> no fault (success)")
check(ZagDeveloperServicesProtocol.fault(body: faultPlist(7460), httpStatus: 200)?.classification == .existingCertificateOrPendingRequest, "7460 -> existingCertificateOrPendingRequest (corrected)")
check(ZagDeveloperServicesProtocol.fault(body: Data(), httpStatus: 429)?.classification == .confirmedRateLimit, "HTTP 429 -> confirmed rate-limit")
let amb = ZagDeveloperServicesProtocol.fault(body: faultPlist(4, "user@example.com please retry"), httpStatus: 200)
check(amb?.classification == .ambiguousRejection, "resultCode 4 is AMBIGUOUS, not a confirmed throttle")
check(amb?.resultCode == 4 && amb?.httpStatus == 200, "fault preserves the raw resultCode + http status")
check(amb?.message.contains("@example.com") == false && amb?.message.contains("[redacted]") == true, "fault message is redacted (no email)")
check(ZagDeveloperServicesProtocol.fault(body: faultPlist(3540), httpStatus: 200)?.classification == .certificateLimitReached, "3540 -> certificate limit")
check(ZagDeveloperServicesProtocol.fault(body: faultPlist(9999, "Identifier is not available"), httpStatus: 200)?.classification == .identifierUnavailable, "identifier message -> identifierUnavailable")
check(ZagDeveloperServicesProtocol.fault(body: Data("x".utf8), httpStatus: 200)?.classification == .malformed, "non-plist 2xx -> malformed")
check(ZagDeveloperServicesProtocol.fault(body: Data(), httpStatus: 500)?.classification == .network, "HTTP 500 -> network")
check(ZagDeveloperServicesProtocol.sanitizeMessage(String(repeating: "a", count: 300)).count <= 161, "message is length-bounded")
// Classifier audit: resultCode 4 must no longer throw rateLimited.
throws_(.malformedResponse, { try ZagDeveloperServicesProtocol.throwIfError(["resultCode": 4]) }, "throwIfError no longer maps 4 -> rateLimited")

// MARK: Reconciliation state machine (item 3/4) — not-found alone never clears.
typealias Rec = ZagCSRReconciliation
check(Rec.decide(match: .found(serial: "S1"), submit: .ambiguous) == .recover(serial: "S1"), "matching cert -> recover (verify+recover)")
check(Rec.decide(match: .notFound, submit: .authoritativeRejection) == .retryable, "no match + authoritative rejection -> retryable")
check(Rec.decide(match: .notFound, submit: .ambiguous) == .preserveForReview, "no match + ambiguous -> preserve for review (NOT cleared)")
check(Rec.decide(match: .notFound, submit: .none) == .preserveForReview, "no match + no recorded verdict -> preserve for review")
check(Rec.decide(match: .notFound, submit: .transportIncomplete) == .preserveUnconfirmed, "no match + transport incomplete -> preserve")
check(Rec.decide(match: .listingUnavailable, submit: .authoritativeRejection) == .preserveUnconfirmed, "listing unavailable -> preserve, even with authoritative verdict")
check(Rec.verdict(for: .certificateLimitReached) == .authoritativeRejection, "cap -> authoritative rejection")
check(Rec.verdict(for: .confirmedRateLimit) == .authoritativeRejection, "confirmed rate-limit -> authoritative (not processed)")
check(Rec.verdict(for: .ambiguousRejection) == .ambiguous, "ambiguous code -> ambiguous verdict")
check(Rec.verdict(for: .network) == .transportIncomplete, "network fault -> transport incomplete")
check(Rec.verdict(for: nil) == .none, "no recorded classification -> none")
// Delayed-visibility + crash recovery: an attempt-1 journal (ambiguous, unconfirmed) is preserved, not resubmitted.
let attempt1 = ZagPendingCSRState(keySlot: "slot1", request: Data([9]), startedAt: Date(), attempts: 1, submissionUnconfirmed: true, issuedSerial: nil, lastResultCode: 4, lastHTTPStatus: 200, lastMessage: "could not be completed", lastClassification: "ambiguousRejection")
check(attempt1.nextStep(at: Date()) == .resolveUnconfirmed, "attempt-1 (unconfirmed) -> resolve, never auto-submit")
check(Rec.decide(match: .notFound, submit: Rec.verdict(for: .ambiguousRejection)) == .preserveForReview, "attempt-1 not-found stays for review (no silent clear)")
// Delayed visibility: the same key's cert appears in a later listing -> recover.
check(Rec.decide(match: .found(serial: "LATE"), submit: Rec.verdict(for: .ambiguousRejection)) == .recover(serial: "LATE"), "delayed cert visibility -> recover on later listing")

// MARK: Single-use, evidence-bound operator override (item 11).
let csrFP = ZagReconciliationEvidence.fingerprint(Data([9]))
func ev(keySlot: String? = "slot1", csr: String? = nil, team: String = "T1", account: String = "ACC",
		complete: Bool = true, http: Int = 200, matchFound: Bool = false, verdictUnknown: Bool = true,
		age: TimeInterval = 10) -> ZagReconciliationEvidence {
	ZagReconciliationEvidence(teamID: team, keySlot: keySlot, csrSHA256: csr ?? csrFP, account: account,
							  listingComplete: complete, httpStatus: http, certificateCountObserved: 3,
							  matchingPublicKeyFound: matchFound, originalVerdictUnknown: verdictUnknown,
							  observedAt: now.addingTimeInterval(-age))
}
func journal(team: String? = "T1", unconfirmed: Bool = true, retryable: Bool? = nil, issued: String? = nil,
			 evidence: ZagReconciliationEvidence?) -> ZagPendingCSRState {
	var s = ZagPendingCSRState(keySlot: "slot1", request: Data([9]), startedAt: now, attempts: 1,
							   submissionUnconfirmed: unconfirmed, issuedSerial: issued)
	s.team = team; s.reviewEvidence = evidence; s.retryableAfterReview = retryable
	return s
}
func ovr(_ s: ZagPendingCSRState, account: String = "ACC") -> String {
	switch ZagReconciliationOverride.apply(to: s, account: account, now: now) {
	case .success: return "ok"; case .failure(let r): return r.rawValue
	}
}
// Successful issuance path: valid bound evidence -> retryableAfterReview, CSR+key preserved.
if case .success(let u) = ZagReconciliationOverride.apply(to: journal(evidence: ev()), account: "ACC", now: now) {
	check(u.submissionUnconfirmed == false && u.retryableAfterReview == true, "override: clears unconfirmed, sets retryableAfterReview")
	check(u.nextStep(at: now) == .submitAfterReview, "overridden journal -> submitAfterReview (one submission)")
	check(u.request == Data([9]) && u.keySlot == "slot1", "override preserves original CSR + key")
} else { check(false, "override should succeed on valid bound evidence") }
// Replayed authorization / duplicate prevention: can't override an already-overridden or issued journal.
check(ovr(journal(retryable: true, evidence: ev())) == "journalNotUnconfirmed", "replay guard: already retryableAfterReview -> rejected")
check(ovr(journal(unconfirmed: false, issued: "S1", evidence: ev())) == "journalNotUnconfirmed", "already issued -> rejected")
check(ovr(journal(unconfirmed: false, evidence: ev())) == "journalNotUnconfirmed", "not unconfirmed -> rejected")
// Stale reconciliation evidence.
check(ovr(journal(evidence: ev(age: 7200))) == "evidenceStale", "stale evidence (2h) -> rejected")
check(ovr(journal(evidence: ev(age: -5))) == "evidenceStale", "future-dated evidence -> rejected")
// Wrong-key / wrong-team / wrong-account / wrong-CSR overrides.
check(ovr(journal(evidence: ev(keySlot: "other"))) == "keyBindingMismatch", "wrong key binding -> rejected")
check(ovr(journal(team: "T1", evidence: ev(team: "T2"))) == "teamMismatch", "wrong team -> rejected")
check(ovr(journal(evidence: ev()), account: "OTHER") == "accountMismatch", "wrong account -> rejected")
check(ovr(journal(evidence: ev(csr: "deadbeef"))) == "csrMismatch", "wrong CSR fingerprint -> rejected")
// Incomplete / ambiguous / match-found evidence must not authorize a retry.
check(ovr(journal(evidence: nil)) == "noEvidence", "no evidence -> rejected")
check(ovr(journal(evidence: ev(http: 500))) == "evidenceIncomplete", "incomplete listing (HTTP 500) -> rejected")
check(ovr(journal(evidence: ev(complete: false))) == "evidenceIncomplete", "incomplete listing flag -> rejected")
check(ovr(journal(evidence: ev(matchFound: true))) == "matchFound", "cert WAS found -> recover, not override")
check(ovr(journal(evidence: ev(verdictUnknown: false))) == "verdictNotUnknown", "verdict known -> normal path, not override")
// Ambiguous outcome after a consumed override: flag cleared + evidence gone -> must reconcile again.
var consumed = journal(evidence: nil); consumed.retryableAfterReview = false; consumed.submissionUnconfirmed = true
check(consumed.nextStep(at: now) == .resolveUnconfirmed, "post-consume ambiguous -> resolveUnconfirmed (reconcile again)")
check(ovr(consumed) == "noEvidence", "re-override after ambiguous needs FRESH evidence (no silent replay)")
// The real attempt-1 journal shape (team known, evidence to be gathered) still needs evidence first.
check(ovr(journal(evidence: nil)) == "noEvidence", "attempt-1-shaped journal: override blocked until reconcile records evidence")

// MARK: resultCode 7460 classifier correction (the exact observed response).
let msg7460 = "You already have a current iOS Development certificate or a pending certificate request."
func plist7460(_ code: Int, _ m: String) -> Data {
	try! PropertyListSerialization.data(fromPropertyList: ["resultCode": code, "userString": m], format: .xml, options: 0)
}
let f7460 = ZagDeveloperServicesProtocol.fault(body: plist7460(7460, msg7460), httpStatus: 200)
check(f7460?.classification == .existingCertificateOrPendingRequest, "7460 -> existingCertificateOrPendingRequest (NOT throttle)")
check(f7460?.classification != .confirmedRateLimit, "7460 is NOT confirmedRateLimit")
check(f7460?.classification != .certificateLimitReached, "7460 is NOT collapsed into certificate-cap")
check(f7460?.resultCode == 7460 && f7460?.httpStatus == 200, "7460 fault preserves raw code + status")
check(f7460?.message == msg7460, "7460 fault preserves the exact Apple message (no email/token to redact)")
check(f7460?.sanitized["apple_message"] as? String == msg7460, "sanitized dict carries the real message")
// HTTP 200 + app-level error remains an error.
check(ZagDeveloperServicesProtocol.fault(body: plist7460(7460, msg7460), httpStatus: 200) != nil, "HTTP 200 + 7460 is still a fault (not success)")
// 7788 is no longer asserted to be a throttle (conservative: unknown).
check(ZagDeveloperServicesProtocol.fault(body: plist7460(7788, "x"), httpStatus: 200)?.classification == .ambiguousRejection, "7788 -> ambiguousRejection (no evidence it is a throttle)")
// Genuine throttle and cert-cap stay distinct from 7460.
check(ZagDeveloperServicesProtocol.fault(body: Data(), httpStatus: 429)?.classification == .confirmedRateLimit, "HTTP 429 -> confirmedRateLimit (genuine throttle, distinct)")
check(ZagDeveloperServicesProtocol.fault(body: plist7460(3540, "limit"), httpStatus: 200)?.classification == .certificateLimitReached, "3540 -> certificateLimitReached (distinct cap)")
check(ZagDeveloperServicesProtocol.fault(body: plist7460(1100, "session"), httpStatus: 200)?.classification == .sessionRejected, "1100 -> sessionRejected (distinct auth)")
// throwIfError path: 7460 -> dedicated typed error, not rateLimited.
throws_(.existingCertificateOrPendingRequest, { try ZagDeveloperServicesProtocol.throwIfError(["resultCode": 7460, "userString": msg7460]) }, "throwIfError 7460 -> existingCertificateOrPendingRequest")
throws_(.malformedResponse, { try ZagDeveloperServicesProtocol.throwIfError(["resultCode": 7788]) }, "throwIfError 7788 -> unknown (malformedResponse), not rateLimited")
throws_(.certificateLimitReached, { try ZagDeveloperServicesProtocol.throwIfError(["resultCode": 3540]) }, "throwIfError 3540 -> certificateLimitReached (unchanged)")
// Reconciliation: a confirmed conflict is preserved for review, never auto-retried.
check(Rec.verdict(for: .existingCertificateOrPendingRequest) == .confirmedConflict, "7460 classification -> confirmedConflict verdict")
check(Rec.decide(match: .notFound, submit: .confirmedConflict) == .preserveForReview, "conflict + not-found -> preserveForReview (NOT retryable)")
check(Rec.decide(match: .found(serial: "S9"), submit: .confirmedConflict) == .recover(serial: "S9"), "conflict but cert found -> recover")
// The four outcomes are distinct verdicts: conflict / cap / throttle / unknown.
check(Rec.verdict(for: .existingCertificateOrPendingRequest) != Rec.verdict(for: .ambiguousRejection), "conflict distinct from unknown")
check(Rec.verdict(for: .certificateLimitReached) == .authoritativeRejection && Rec.verdict(for: .existingCertificateOrPendingRequest) == .confirmedConflict, "cap vs conflict are different verdicts")
check(Rec.decide(match: .notFound, submit: .confirmedConflict) != Rec.decide(match: .notFound, submit: .authoritativeRejection), "conflict (preserve) differs from authoritative cap (retryable)")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
