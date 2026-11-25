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

// --- Native 7460 conflict resolution (distinguishing the two arms + safe replace) ---
typealias CR = ZagCertificateConflictResolution
let crSoon = Date().addingTimeInterval(300 * 86_400)
let crPast = Date().addingTimeInterval(-86_400)
func crCert(_ id: String, _ serial: String, sha1: String? = nil, expires: Date? = crSoon) -> ZagRevocableCertificate {
	ZagRevocableCertificate(id: id, serialNumber: serial, sha1: sha1, name: "Development", machineName: nil, expiresAt: expires)
}
// Listing unavailable -> decides nothing.
check(CR.resolve(certificates: nil, locallyHeldSerials: [], activeGuard: guardz, now: Date()) == .listingUnavailable,
	  "conflict: nil listing -> listingUnavailable (never empty)")
// No existing valid dev cert -> the pending-request arm (Check Again / Abandon).
check(CR.resolve(certificates: [], locallyHeldSerials: [], activeGuard: guardz, now: Date()) == .resolvePendingRequest,
	  "conflict: empty listing -> resolvePendingRequest")
check(CR.resolve(certificates: [crCert("v1-x", "EXPIRED", expires: crPast)], locallyHeldSerials: [], activeGuard: guardz, now: Date()) == .resolvePendingRequest,
	  "conflict: only expired certs -> resolvePendingRequest")
// A listed valid cert we hold the key for -> reuse, no request/revoke.
check(CR.resolve(certificates: [crCert("v1-a", "HELD")], locallyHeldSerials: ["HELD"], activeGuard: guardz, now: Date()) == .recoverExisting(serial: "HELD"),
	  "conflict: locally-held valid cert -> recoverExisting")
// Existing valid foreign certs, none held -> replacement candidates (soonest first).
let foreignA = crCert("v1-a", "FA", expires: Date().addingTimeInterval(100 * 86_400))
let foreignB = crCert("v1-b", "FB", expires: Date().addingTimeInterval(50 * 86_400))
if case .replacementRequired(let cands) = CR.resolve(certificates: [foreignA, foreignB], locallyHeldSerials: [], activeGuard: guardz, now: Date()) {
	check(cands.map(\.serialNumber) == ["FB", "FA"], "conflict: replacement candidates sorted soonest-expiring first")
} else { check(false, "conflict: foreign valid certs -> replacementRequired") }
// The active Xcode cert is NEVER a replacement candidate.
let activeValid = ZagRevocableCertificate(id: "v1-active", serialNumber: "723BE3EC", sha1: "5657782a6eadfff608040d39186e6533557349fc", name: "Apple Development", machineName: nil, expiresAt: crSoon)
check(CR.resolve(certificates: [activeValid], locallyHeldSerials: [], activeGuard: guardz, now: Date()) == .onlyActiveCertificatePresent,
	  "conflict: only the active Xcode cert -> onlyActiveCertificatePresent (protected)")
if case .replacementRequired(let cands) = CR.resolve(certificates: [activeValid, foreignA], locallyHeldSerials: [], activeGuard: guardz, now: Date()) {
	check(cands.map(\.serialNumber) == ["FA"], "conflict: active cert excluded, foreign offered")
} else { check(false, "conflict: active + foreign -> replacementRequired without the active one") }
// Reuse takes priority even when foreign certs are present.
check(CR.resolve(certificates: [foreignA, crCert("v1-h", "HELD")], locallyHeldSerials: ["HELD"], activeGuard: guardz, now: Date()) == .recoverExisting(serial: "HELD"),
	  "conflict: reuse wins over replacement when a held cert is valid")
// Only reuse / pending are autonomously recoverable.
check(CR.isAutonomouslyRecoverable(.recoverExisting(serial: "X")) && CR.isAutonomouslyRecoverable(.resolvePendingRequest), "conflict: reuse+pending are autonomous")
check(!CR.isAutonomouslyRecoverable(.replacementRequired(candidates: [])) && !CR.isAutonomouslyRecoverable(.onlyActiveCertificatePresent), "conflict: replacement needs explicit consent")

// --- Stable machineId (replaces the random-per-call value) ---
final class MemMachineStore: ZagMachineIdentifierStore, @unchecked Sendable {
	var value: String?
	func load() -> String? { value }
	func save(_ v: String) -> Bool { value = v; return true }
}
let mstore = MemMachineStore()
let m1 = ZagMachineIdentifier.current(store: mstore)
let m2 = ZagMachineIdentifier.current(store: mstore)
check(ZagMachineIdentifier.isValid(m1), "machineId: a valid UUID is produced")
check(m1 == m2, "machineId: stable across calls (not random-per-request)")
check(mstore.value == m1, "machineId: persisted once in the backing store")
let preseeded = MemMachineStore(); preseeded.value = "FEEDFACE-0000-4000-8000-000000000001"
check(ZagMachineIdentifier.current(store: preseeded) == "FEEDFACE-0000-4000-8000-000000000001", "machineId: reuses an existing persisted value")
let corrupt = MemMachineStore(); corrupt.value = "not-a-uuid"
check(ZagMachineIdentifier.isValid(ZagMachineIdentifier.current(store: corrupt)), "machineId: replaces a corrupt stored value with a valid one")

// --- Certificate-replacement coordinator (gated two-mutation state machine) ---
typealias RC2 = ZagCertificateReplacementCoordinator
let foreign = ZagRevocableCertificate(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB", name: "iPhone Developer", machineName: nil, expiresAt: crSoon)
let activeCert2 = ZagRevocableCertificate(id: "v1-active", serialNumber: "723BE3EC", sha1: "5657782a6eadfff608040d39186e6533557349fc", name: "Apple Development", machineName: nil, expiresAt: crSoon)
func step(_ s: ZagCertificateReplacementState, _ e: ZagCertificateReplacementEvent) -> ZagCertificateReplacementState { RC2.reduce(s, e, guard: guardz) }

// The protected active certificate is rejected at selection.
check(step(.idle, .select(activeCert2)) == .abandoned(reason: .protectedActiveCertificate), "replace: active Xcode cert rejected at selection")
// Happy path requires a confirmation AND a separate authorization.
let sel = step(.idle, .select(foreign))
check(sel == .selected(target: ZagReplacementTarget(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB")), "replace: exact certificate captured at selection")
check(!RC2.mayRevoke(sel), "replace: cannot revoke straight after selection")
let confirmed = step(sel, .confirmRevoke)
check(RC2.mayRevoke(confirmed), "replace: revoke allowed only after separate confirmation")
let revoking = step(confirmed, .revokeStarted)
let revoked = step(revoking, .revokeSucceeded)
check(!RC2.maySubmitCSR(revoked), "replace: revoke success alone does NOT authorize the CSR")
let csrAuth = step(revoked, .authorizeCSR)
check(RC2.maySubmitCSR(csrAuth), "replace: CSR allowed only after a SECOND separate authorization")
check(step(step(csrAuth, .csrStarted), .csrSucceeded) == .completed(serial: "FOR123"), "replace: full gated path completes")

// A failed OR ambiguous revoke is terminal and cannot advance to the CSR.
let failed = step(revoking, .revokeFailed)
check(failed == .revokeHalted(target: ZagReplacementTarget(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB"), reason: .revokeFailed), "replace: revoke failure halts")
check(step(failed, .authorizeCSR) == failed && !RC2.maySubmitCSR(step(failed, .authorizeCSR)), "replace: a failed revoke cannot advance to CSR")
let ambiguous = step(revoking, .revokeAmbiguous)
check(ambiguous == .revokeHalted(target: ZagReplacementTarget(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB"), reason: .revokeAmbiguous), "replace: ambiguous revoke halts")
check(!RC2.maySubmitCSR(step(ambiguous, .authorizeCSR)), "replace: an ambiguous revoke cannot advance to CSR")

// No chained mutations: you cannot jump selection straight to authorizeCSR.
check(step(sel, .authorizeCSR) == .abandoned(reason: .illegalTransition), "replace: cannot skip revoke to authorize CSR")
check(step(revoked, .csrStarted) == .abandoned(reason: .illegalTransition), "replace: cannot start CSR without its authorization")
// Duplicate operations: a terminal state ignores further events.
check(step(.completed(serial: "FOR123"), .csrStarted) == .completed(serial: "FOR123"), "replace: completed ignores duplicate events")
check(step(failed, .revokeStarted) == failed, "replace: halted ignores duplicate revoke")

// Interruption recovery: in-flight mutations resolve to NON-advancing states.
check(RC2.recoverAfterInterruption(revoking) == .revokeHalted(target: ZagReplacementTarget(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB"), reason: .interruptedDuringRevoke), "replace: interrupted revoke -> halt (needs re-check)")
check(RC2.recoverAfterInterruption(step(csrAuth, .csrStarted)) == .submissionUnconfirmed(serial: "FOR123"), "replace: interrupted CSR -> submissionUnconfirmed (reconcile, never completed)")
check(RC2.recoverAfterInterruption(revoked) == revoked, "replace: a settled state recovers unchanged")
// The journal round-trips through Codable (survives termination).
let enc = try! JSONEncoder().encode(csrAuth)
check((try? JSONDecoder().decode(ZagCertificateReplacementState.self, from: enc)) == csrAuth, "replace: journal state survives Codable round-trip")

// --- Replacement helpers: pre-revoke verification + failure classification ---
let selTarget = ZagReplacementTarget(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB")
let freshMatch = ZagRevocableCertificate(id: "v1-foreign", serialNumber: "FOR123", sha1: "BBBB", name: "iPhone Developer", machineName: nil, expiresAt: crSoon)
typealias RS = ZagCertificateReplacementService
// Happy verification.
if case .success(let c) = RS.verifyTargetForRevoke(selected: selTarget, freshListing: [freshMatch], activeGuard: guardz) {
	check(c.id == "v1-foreign", "verify: fresh listing match returns the exact candidate")
} else { check(false, "verify: expected success for a matching candidate") }
// Stale inventory — target gone.
check(RS.verifyTargetForRevoke(selected: selTarget, freshListing: [], activeGuard: guardz) == .failure(.targetNoLongerPresent), "verify: stale inventory -> targetNoLongerPresent")
// Fingerprint mismatch (same id, different sha1).
let changed = ZagRevocableCertificate(id: "v1-foreign", serialNumber: "FOR123", sha1: "CCCC", name: "x", machineName: nil, expiresAt: crSoon)
check(RS.verifyTargetForRevoke(selected: selTarget, freshListing: [changed], activeGuard: guardz) == .failure(.fingerprintMismatch), "verify: fingerprint mismatch -> refused")
// The id now resolves to the protected active cert.
let nowActive = ZagRevocableCertificate(id: "v1-foreign", serialNumber: "723BE3EC", sha1: "5657782a6eadfff608040d39186e6533557349fc", name: "Apple Development", machineName: nil, expiresAt: crSoon)
let selActiveId = ZagReplacementTarget(id: "v1-foreign", serialNumber: "723BE3EC", sha1: "5657782a6eadfff608040d39186e6533557349fc")
check(RS.verifyTargetForRevoke(selected: selActiveId, freshListing: [nowActive], activeGuard: guardz) == .failure(.targetNowActive), "verify: target now the active cert -> refused")
// Listing unavailable decides nothing.
check(RS.verifyTargetForRevoke(selected: selTarget, freshListing: nil, activeGuard: guardz) == .failure(.listingUnavailable), "verify: nil listing -> listingUnavailable")

// Failure classification: repeated 7460 and limits are authoritative; the rest ambiguous.
check(RS.classifySubmitFailure(ZagPortalError.existingCertificateOrPendingRequest) == .repeatedConflict, "classify: repeated 7460 -> repeatedConflict (not success)")
check(RS.classifySubmitFailure(ZagPortalError.certificateLimitReached) == .certificateLimitReached, "classify: cert limit -> certificateLimitReached")
check(RS.classifySubmitFailure(ZagPortalError.network) == .ambiguousSubmission, "classify: network CSR error -> ambiguousSubmission")
check(RS.classifyRevokeFailure(ZagPortalError.network) == .ambiguousRevoke, "classify: network revoke error -> ambiguousRevoke")
check(RS.classifyRevokeFailure(ZagPortalError.sessionRejected) == .sessionRejected, "classify: revoke session rejection surfaced")

// Reconcile verdict from a fresh listing.
check(RS.reconcileVerdict(target: selTarget, freshListing: []) == .targetGone, "reconcile: target absent -> targetGone")
check(RS.reconcileVerdict(target: selTarget, freshListing: [freshMatch]) == .targetStillPresent, "reconcile: target present -> targetStillPresent")
check(RS.reconcileVerdict(target: selTarget, freshListing: nil) == .listingUnavailable, "reconcile: nil listing -> listingUnavailable")

// --- End-to-end driver workflow against a scripted mock portal ---
final class MockPortal: ZagReplacementPortal, @unchecked Sendable {
	var listings: [[ZagRevocableCertificate]]   // consumed FIFO per inventory call
	var revokeError: Error?
	var revokeCalls = 0
	var submitError: Error?
	var submitCalls = 0
	let issued: ZagIssuedCertificate
	init(listings: [[ZagRevocableCertificate]], issued: ZagIssuedCertificate) { self.listings = listings; self.issued = issued }
	func revocableCertificates(team: String) async throws -> [ZagRevocableCertificate] {
		listings.isEmpty ? [] : listings.removeFirst()
	}
	func revokeCertificate(_ c: ZagRevocableCertificate, guard g: ZagActiveCertificateGuard, override: Bool, team: String) async throws {
		revokeCalls += 1; if let e = revokeError { throw e }
	}
	func submitCertificateRequest(_ r: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		submitCalls += 1; if let e = submitError { throw e }; return issued
	}
}
final class MemJournal: ZagReplacementJournalStore, @unchecked Sendable {
	var s: ZagCertificateReplacementState?
	func loadReplacementState() -> ZagCertificateReplacementState? { s }
	func saveReplacementState(_ v: ZagCertificateReplacementState) { s = v }
}
let issuedCert = ZagIssuedCertificate(certificate: ZagDevelopmentCertificate(serialNumber: "NEW9", name: "Apple Development", machineName: "Zag Store", expiresAt: crSoon, data: Data([1,2,3])), data: Data([1,2,3]))
func makeDriver(_ portal: MockPortal, _ journal: MemJournal) -> ZagCertificateReplacementDriver {
	ZagCertificateReplacementDriver(portal: portal, consent: ZagMutationConsentCoordinator(), activeGuard: guardz, journal: journal, team: "V54K5JYGS4")
}
func run(_ body: @escaping () async -> Void) { let g = DispatchGroup(); g.enter(); Task { await body(); g.leave() }; g.wait() }

// 1. Full successful replacement: select -> revoke (stops) -> separately submit -> completed.
run {
	let portal = MockPortal(listings: [[freshMatch], [freshMatch]], issued: issuedCert)
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch)
	try? await d.confirmAndRevoke()
	check(await d.currentState() == .revoked(target: selTarget), "e2e: a successful revoke STOPS at revoked (no auto CSR)")
	check(portal.submitCalls == 0, "e2e: the CSR was NOT auto-submitted after revoke")
	_ = try? await d.authorizeAndSubmitCSR(ZagCertificateRequest(data: Data([9])))
	check(await d.currentState() == .completed(serial: "FOR123"), "e2e: a separate CSR authorization completes the flow")
	check(portal.revokeCalls == 1 && portal.submitCalls == 1, "e2e: exactly one revoke and one submission")
}
// 2. Repeated 7460 after a successful revoke: not treated as success; flow abandons honestly.
run {
	let portal = MockPortal(listings: [[freshMatch], [freshMatch]], issued: issuedCert)
	portal.submitError = ZagPortalError.existingCertificateOrPendingRequest
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch); try? await d.confirmAndRevoke()
	do { _ = try await d.authorizeAndSubmitCSR(ZagCertificateRequest(data: Data([9]))); check(false, "e2e: repeated 7460 should throw") }
	catch { check((error as? ZagReplacementError) == .repeatedConflict, "e2e: repeated 7460 -> repeatedConflict") }
	check(await d.currentState() == .abandoned(reason: .csrRejected), "e2e: repeated 7460 abandons, never completed")
}
// 3. Ambiguous revoke (network): halts, requires read-only reconcile; reconcile proves gone -> revoked.
run {
	let portal = MockPortal(listings: [[freshMatch], []], issued: issuedCert)  // 2nd listing (reconcile) shows it gone
	portal.revokeError = ZagPortalError.network
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch)
	do { try await d.confirmAndRevoke(); check(false, "e2e: ambiguous revoke should throw") }
	catch { check((error as? ZagReplacementError) == .ambiguousRevoke, "e2e: network revoke -> ambiguousRevoke") }
	check(await d.currentState() == .revokeHalted(target: selTarget, reason: .revokeAmbiguous), "e2e: ambiguous revoke halts")
	try? await d.reconcileAfterAmbiguousRevoke()
	check(await d.currentState() == .revoked(target: selTarget), "e2e: reconcile proving the cert gone -> revoked")
}
// 4. Ambiguous revoke; reconcile shows it STILL present -> back to selected (not advanced).
run {
	let portal = MockPortal(listings: [[freshMatch], [freshMatch]], issued: issuedCert)
	portal.revokeError = ZagPortalError.network
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch); _ = try? await d.confirmAndRevoke()
	try? await d.reconcileAfterAmbiguousRevoke()
	check(await d.currentState() == .selected(target: selTarget), "e2e: reconcile showing the cert present -> selected (cannot reach CSR)")
	check(!ZagCertificateReplacementCoordinator.maySubmitCSR(await d.currentState()), "e2e: still cannot submit the CSR")
}
// 5. App termination during revocation: journal left `revoking`; launch recovery -> halt (needs re-check).
run {
	let j = MemJournal(); j.saveReplacementState(.revoking(target: selTarget))
	let portal = MockPortal(listings: [[freshMatch]], issued: issuedCert)
	let d = makeDriver(portal, j)
	await d.recoverOnLaunch()
	check(await d.currentState() == .revokeHalted(target: selTarget, reason: .interruptedDuringRevoke), "e2e: interrupted revoke recovers to a halt")
}
// 6. Ambiguous CSR submission: journal left `submitting`; recovery -> submissionUnconfirmed.
run {
	let portal = MockPortal(listings: [[freshMatch], [freshMatch]], issued: issuedCert)
	portal.submitError = ZagPortalError.network
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch); try? await d.confirmAndRevoke()
	do { _ = try await d.authorizeAndSubmitCSR(ZagCertificateRequest(data: Data([9]))); check(false, "e2e: ambiguous CSR should throw") }
	catch { check((error as? ZagReplacementError) == .ambiguousSubmission, "e2e: network CSR -> ambiguousSubmission") }
	check(await d.currentState() == .submissionUnconfirmed(serial: "FOR123"), "e2e: ambiguous CSR -> submissionUnconfirmed (reconcile)")
}
// 7. Protected active cert cannot be selected through the driver.
run {
	let portal = MockPortal(listings: [[nowActive]], issued: issuedCert)
	let j = MemJournal(); let d = makeDriver(portal, j)
	do { try await d.select(nowActive); check(false, "e2e: selecting the active cert should throw") }
	catch { check((error as? ZagReplacementError) == .targetNowActive, "e2e: driver rejects selecting the protected active cert") }
}
// 8. Stale inventory at revoke time: the chosen cert vanished between select and revoke.
run {
	let portal = MockPortal(listings: [[]], issued: issuedCert)  // gone by the revoke-time refresh
	let j = MemJournal(); let d = makeDriver(portal, j)
	try? await d.select(freshMatch)
	do { try await d.confirmAndRevoke(); check(false, "e2e: stale target should throw") }
	catch { check((error as? ZagReplacementError) == .targetNoLongerPresent, "e2e: stale inventory refuses the revoke") }
	check(portal.revokeCalls == 0, "e2e: no revoke call was made for a stale target")
}

// --- Read-only transport boundary: mutations cannot reach the network ---
func req(_ url: String, override: String? = nil) -> ZagHTTPRequest {
	var h: [String: String] = [:]; if let override { h["X-HTTP-Method-Override"] = override }
	return ZagHTTPRequest(url: URL(string: url)!, method: "POST", headers: h, body: Data())
}
let H = "https://developerservices2.apple.com/services"
// Read-only endpoints pass.
check(ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/listAllDevelopmentCerts.action?clientId=X")), "readonly: QH65B2 cert listing allowed")
check(ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/listTeams.action?clientId=X")), "readonly: QH65B2 listTeams allowed")
check(ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/v1/certificates", override: "GET")), "readonly: v1 GET override (inventory) allowed")
check(ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/v1/certificates", override: "get")), "readonly: v1 override case-insensitive")
// Mutating endpoints are blocked.
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/submitDevelopmentCSR.action?clientId=X")), "readonly: QH65B2 submitCSR blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/revokeDevelopmentCert.action?clientId=X")), "readonly: QH65B2 revoke action blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/addDevice.action?clientId=X")), "readonly: QH65B2 addDevice blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/downloadTeamProvisioningProfile.action?clientId=X")), "readonly: QH65B2 downloadProfile (mutating) blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/v1/certificates/ID123", override: "DELETE")), "readonly: v1 DELETE revoke blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/v1/certificates", override: "POST")), "readonly: v1 POST override blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/v1/certificates")), "readonly: v1 with no override blocked (fail closed)")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("\(H)/QH65B2/ios/unknownFuture.action?clientId=X")), "readonly: unknown QH65B2 action blocked (fail closed)")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(req("https://developerservices2.apple.com/other/thing")), "readonly: unrecognised path blocked (fail closed)")
// Build the real URLs through the production builders and confirm classification.
check(ZagReadOnlyEndpointPolicy.isReadOnly(ZagHTTPRequest(url: try! ZagDeveloperServicesV1.endpoint("certificates"), method: "POST", headers: ZagDeveloperServicesV1.headers(methodOverride: "GET"), body: Data())), "readonly: real v1 GET inventory request allowed")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(ZagHTTPRequest(url: try! ZagDeveloperServicesV1.endpoint("certificates/ID"), method: "POST", headers: ZagDeveloperServicesV1.headers(methodOverride: "DELETE"), body: Data())), "readonly: real v1 DELETE revoke request blocked")
check(!ZagReadOnlyEndpointPolicy.isReadOnly(ZagHTTPRequest(url: try! ZagDeveloperServicesProtocol.endpoint(.submitCSR), method: "POST", headers: [:], body: Data())), "readonly: real submitCSR endpoint blocked")

// The wrapper never forwards a blocked request to the base transport.
final class RecordingTransport: ZagHTTPTransport, @unchecked Sendable {
	var sentPaths: [String] = []
	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		sentPaths.append(request.url.path)
		return ZagHTTPResponse(statusCode: 200, headers: [:], body: Data("{\"data\":[]}".utf8))
	}
}
run {
	let base = RecordingTransport(); let t = ZagReadOnlyTransport(base: base)
	_ = try? await t.send(req("\(H)/v1/certificates", override: "GET"))                 // allowed
	check(base.sentPaths.count == 1, "readonly transport: inventory reached the base")
	do { _ = try await t.send(req("\(H)/v1/certificates/ID", override: "DELETE")); check(false, "readonly transport: revoke should throw") }
	catch { check((error as? ZagTransportError).map { if case .readOnlyBlocked = $0 { return true } else { return false } } ?? false, "readonly transport: revoke throws readOnlyBlocked") }
	do { _ = try await t.send(req("\(H)/QH65B2/ios/submitDevelopmentCSR.action?clientId=X")); check(false, "readonly transport: submitCSR should throw") }
	catch { _ = error }
	check(base.sentPaths.count == 1, "readonly transport: NO mutating request reached the base (still 1)")
}
// The read-only experiment default mode is disabled (flag off in this build).
check(ZagCertReplacementExperiment.mode == .disabled || ZagCertReplacementExperiment.mode == .readOnlyInventory, "experiment: mode is a defined value")

// --- Full read-only inventory decode path: mock developer token + recording transport ---
// Exercises the exact bytes a live read-only inventory would: a v1 GET request
// carrying a (mock) developer token through ZagReadOnlyTransport over a recording
// base that returns a scripted certificate listing, decoded by the real parser.
run {
	final class InventoryBase: ZagHTTPTransport, @unchecked Sendable {
		var sawToken = false; var sawPath = ""; var method = ""
		func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
			sawToken = request.headers.contains { $0.key.lowercased() == "x-apple-gs-token" && !$0.value.isEmpty }
			sawPath = request.url.path
			method = request.headers.first(where: { $0.key.caseInsensitiveCompare("X-HTTP-Method-Override") == .orderedSame })?.value ?? request.method
			let body = """
			{"data":[{"id":"v1-RO-1","attributes":{"serialNumber":"FOR123","name":"iPhone Developer","expirationDate":"2027-09-06T17:51:01Z"}},
			         {"id":"v1-RO-2","attributes":{"serialNumber":"723BE3EC","name":"Apple Development","expirationDate":"2027-09-27T01:37:10Z"}}]}
			"""
			return ZagHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
		}
	}
	let base = InventoryBase()
	let ro = ZagReadOnlyTransport(base: base)
	var headers = ZagDeveloperServicesV1.headers(methodOverride: "GET")
	headers["X-Apple-GS-Token"] = "MOCK.DEVELOPER.TOKEN"   // mocked native developer token
	let request = ZagHTTPRequest(url: try! ZagDeveloperServicesV1.endpoint("certificates"), method: "POST", headers: headers,
								 body: try! ZagDeveloperServicesV1.listCertificatesBody(teamID: "V54K5JYGS4"))
	let response = try! await ro.send(request)
	let rows = try! ZagDeveloperServicesV1.parseList(response.body, httpStatus: response.statusCode)
	let candidates = ZagCertificateRevocation.candidates(from: rows)
	check(base.sawToken, "inventory: the request carried the (mock) developer token")
	check(base.method.caseInsensitiveCompare("GET") == .orderedSame, "inventory: sent as a GET (read-only)")
	check(candidates.count == 2 && candidates.contains { $0.serialNumber == "FOR123" }, "inventory: scripted certificate listing decoded to candidates")
	// A mutating call with the same token is still refused before the base sees it.
	let before = base.sawPath
	do { _ = try await ro.send(ZagHTTPRequest(url: try! ZagDeveloperServicesV1.endpoint("certificates/v1-RO-1"), method: "POST", headers: { var h = ZagDeveloperServicesV1.headers(methodOverride: "DELETE"); h["X-Apple-GS-Token"] = "MOCK.DEVELOPER.TOKEN"; return h }(), body: Data())); check(false, "inventory: revoke should be blocked") }
	catch { _ = error }
	check(base.sawPath == before, "inventory: the revoke never reached the base even with a valid token")
}

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
