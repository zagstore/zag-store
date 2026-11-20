import Foundation
import Security

// G5 existing-account path (issue #37), offline. Run by
// scripts/test-zag-existing-account.sh, compiled with ZAG_G5_TESTS and
// ZAG_EXISTING_ACCOUNT_EXPERIMENT (never set in an app build).
//
// X1–X15 run the real provisioner, the real bridge portal adapter (its
// campaign gate, `ZagCertificateBudget.consume` and the approval journal
// unchanged) and the real campaign, with the bridge replaced below the
// adapter by the scripted transport (scripts/ZagG5TestHarness.swift) over a
// simulated team seeded as a previously used account. D1–D12 test the
// decision rules directly; K1–K13 the local signing state (Keychain and
// secret-store failures, missing keys, corrupted records). Nothing contacts Apple or an anisette provider.

@main struct Tests {
	nonisolated(unsafe) static var passed = 0
	nonisolated(unsafe) static var failed: [String] = []

	static func check(_ value: Bool, _ label: String) {
		if value {
			passed += 1
			print("PASS: \(label)")
		} else {
			failed.append(label)
			print("FAIL: \(label)")
		}
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		decisionTests()
		keyStateTests()
		await approvalTests()
		await flowTests()
		print("RESULT: \(passed) passed, \(failed.count) failed")
		if !failed.isEmpty {
			for label in failed { print("FAILED: \(label)") }
			exit(1)
		}
		print("SUCCESS: G5 existing-account path (\(passed) checks)")
	}

	// MARK: - Helpers

	static let app = "com.example.notes"
	static let personal = ZagDeveloperTeam(identifier: "ABCDE12345", name: "Personal", kind: .personalFree)
	static let now = Date()

	static func certificate(_ serial: String, days: Double, data: Data? = nil) -> ZagDevelopmentCertificate {
		ZagDevelopmentCertificate(serialNumber: serial, name: "Dev", machineName: "Mac", expiresAt: now.addingTimeInterval(days * 86_400), data: data)
	}

	static func inventory(team: ZagDeveloperTeam = personal, teamCount: Int = 1,
						  certificates: ZagExistingAccountPreflight.Listing<ZagDevelopmentCertificate> = .complete([]),
						  devices: ZagExistingAccountPreflight.Listing<ZagRegisteredDevice> = .complete([]),
						  appIDs: ZagExistingAccountPreflight.Listing<ZagRegisteredAppID> = .complete([])) -> ZagExistingAccountPreflight.Inventory {
		.init(team: team, teamCount: teamCount, certificates: certificates, devices: devices, appIDs: appIDs)
	}

	static func evaluate(_ inventory: ZagExistingAccountPreflight.Inventory, local: ZagExistingAccountPreflight.LocalKeys = .init(),
						 udid: String = deviceUDID) -> ZagExistingAccountPreflight.Assessment {
		ZagExistingAccountPreflight.evaluate(inventory, local: local, bundleIdentifier: "\(personal.identifier).\(app)", deviceUDID: udid, now: now)
	}

	static func mapped(_ rig: Rig) -> String { ZagBundleIdentifierMapping.mapped(app, team: rig.team)! }

	/// A campaign of the existing-account path: armed, with its own approvals
	/// journal (a Keychain-like store that survives relaunches).
	static func armed(_ device: Device, _ number: Int = 1, store: MemoryCampaignRegistry = MemoryCampaignRegistry()) -> (ZagLiveExperimentCampaign, ZagExistingAccountApprovals) {
		let campaign = device.armed(Device.constants(number))
		let approvals = ZagExistingAccountApprovals(campaignID: campaign.constants.campaignID, store: store)
		ZagLiveExperiment.approvals = approvals
		return (campaign, approvals)
	}

	static func preflight(_ rig: Rig, _ campaign: ZagLiveExperimentCampaign, _ approvals: ZagExistingAccountApprovals,
						  udid: String = deviceUDID, secrets: ZagFreeAccountSecretStore? = nil) async -> Result<ZagExistingAccountPreflight.Assessment, Error> {
		let teams = await rig.directory.registry.account(rig.account)!.teams
		do {
			return .success(try await ZagExistingAccountPreflight.run(
				reader: ZagReadOnlyPortal(rig.adapter), team: teams[0], teamCount: teams.count, accountKey: rig.accountKey,
				account: rig.account, secrets: secrets ?? rig.secrets, keys: ZagKeychainSigningKeyFactory(keys: rig.keys),
				bundleIdentifier: mapped(rig), deviceUDID: udid, campaign: campaign, approvals: approvals
			))
		} catch {
			return .failure(error)
		}
	}

	static func approve(_ approvals: ZagExistingAccountApprovals, _ rig: Rig, _ kinds: Set<ZagExistingAccountMutation>) -> Bool {
		kinds.allSatisfy { (try? approvals.approve($0, accountKey: rig.accountKey, team: rig.team)) != nil }
	}

	static let reads: Set<ZagSimulatedDeveloperPortal.Operation> = [.devices, .appIDs, .certificates]

	/// What the simulated portal saw, taken at once (checks are synchronous).
	struct Seen {
		let calls: [ZagSimulatedDeveloperPortal.Operation]
		let mutations: [ZagSimulatedDeveloperPortal.Operation]
		let issued: [ZagDevelopmentCertificate]
		func count(_ operation: ZagSimulatedDeveloperPortal.Operation) -> Int { calls.filter { $0 == operation }.count }
		/// Every call the portal saw is a listing.
		var onlyReads: Bool { calls.allSatisfy(reads.contains) }
	}

	static func seen(_ rig: Rig) async -> Seen {
		Seen(calls: await rig.portal.calls, mutations: await rig.portal.mutations, issued: await rig.portal.issuedCertificates)
	}

	/// A previously used account: this iPhone and the test app's App ID
	/// registered, and a certificate from another machine.
	static func seedPopulated(_ rig: Rig, foreignCertificates: Int = 1) async {
		await rig.portal.seedDevice(deviceUDID)
		await rig.portal.seedDevice("00000000-OTHERDEVICE00000")
		await rig.portal.seedAppID(mapped(rig), expiresAt: Date().addingTimeInterval(3 * 86_400))
		await rig.portal.seedAppID("ABCDE12345.com.other.app", expiresAt: Date().addingTimeInterval(5 * 86_400))
		for index in 0..<foreignCertificates {
			await rig.portal.seedCertificate(serial: "FOREIGN0\(index)", expiresAt: Date().addingTimeInterval(200 * 86_400))
		}
	}

	// MARK: - D1–D12: the decision rules

	static func decisionTests() {
		// D1: an empty listing set needs everything; a profile is always needed.
		let empty = evaluate(inventory())
		check(empty.decision == .needsNewAssets([.certificate, .device, .appID, .profile]) && empty.required == [.certificate, .device, .appID, .profile],
			  "D1: an empty account needs a certificate, the device, the App ID and a profile")

		// D2: unknown is never empty.
		for (label, listing) in [("certificates", inventory(certificates: .unknown)), ("devices", inventory(devices: .unknown)), ("App IDs", inventory(appIDs: .unknown))] {
			let assessment = evaluate(listing)
			check(!assessment.decision.allowsProvisioning && assessment.required.isEmpty, "D2: an unknown \(label) listing decides nothing")
		}
		check(evaluate(inventory(certificates: .unknown)).decision == .unknown(.certificates), "D2: reported as an unknown certificate listing")

		// D3: certificates from elsewhere are counted, never reused.
		let foreign = evaluate(inventory(certificates: .complete([certificate("A1", days: 200), certificate("A2", days: 300)])))
		check(foreign.required.contains(.certificate) && foreign.report.foreignValidCertificates == 2 && foreign.report.reusableCertificateDaysLeft == nil,
			  "D3: valid certificates without a key here are not reusable")

		// D4: possession proven and enough time left: reused.
		let registered = ZagRegisteredDevice(udid: deviceUDID.lowercased(), name: "iPhone")
		let appID = ZagRegisteredAppID(identifier: "X", bundleIdentifier: "\(personal.identifier).\(app)", expiresAt: now.addingTimeInterval(86_400))
		let owned = ZagExistingAccountPreflight.LocalKeys(possessedSerial: "MINE", possessedCertificate: Data([1, 2, 3]))
		let reuse = evaluate(inventory(certificates: .complete([certificate("MINE", days: 30, data: Data([1, 2, 3]))]),
									   devices: .complete([registered]), appIDs: .complete([appID])), local: owned)
		check(reuse.decision == .reusePossible && reuse.required == [.profile], "D4: a possessed certificate, the device (case-insensitive UDID) and the App ID are reused; only a profile is needed")

		// D5: expired, or under seven days left: not reused.
		for days in [-1.0, 3.0] {
			let assessment = evaluate(inventory(certificates: .complete([certificate("MINE", days: days)]), devices: .complete([registered]), appIDs: .complete([appID])), local: owned)
			check(assessment.decision == .needsNewAssets([.certificate, .profile]), "D5: a possessed certificate with \(days) days left is not reused")
		}

		// D6: the listing's copy must be the stored certificate.
		let swapped = evaluate(inventory(certificates: .complete([certificate("MINE", days: 30, data: Data([9]))]), devices: .complete([registered]), appIDs: .complete([appID])), local: owned)
		check(swapped.required.contains(.certificate), "D6: the same serial with a different certificate is not possession")

		// D7: no key on this device (missing or unavailable).
		let missing = evaluate(inventory(certificates: .complete([certificate("MINE", days: 30)]), devices: .complete([registered]), appIDs: .complete([appID])))
		check(missing.required.contains(.certificate), "D7: without a proven key the certificate is not reused")

		// D8: the team.
		check(evaluate(inventory(team: ZagDeveloperTeam(identifier: "ABCDE12345", name: "Org", kind: .organization))).decision == .blocked(.notPersonalTeam),
			  "D8: a team other than a Personal Team is blocked")
		check(evaluate(inventory(team: ZagDeveloperTeam(identifier: "ABCDE12345", name: "?", kind: .unknown))).decision == .blocked(.notPersonalTeam),
			  "D8: an unrecognised team type is blocked")
		check(evaluate(inventory(teamCount: 2)).decision == .blocked(.teamCountNotOne), "D8: more than one team is blocked")

		// D9: devices.
		let twice = [ZagRegisteredDevice(udid: deviceUDID, name: "a"), ZagRegisteredDevice(udid: deviceUDID.lowercased(), name: "b")]
		check(evaluate(inventory(devices: .complete(twice))).decision == .blocked(.ambiguousDevice), "D9: the iPhone registered twice is ambiguous and blocked")
		let full = (0..<ZagFreeAccountLimits.devicesPerPlatform).map { ZagRegisteredDevice(udid: "OTHER-\($0)", name: "x") }
		check(evaluate(inventory(devices: .complete(full))).decision == .blocked(.deviceLimit), "D9: a full device list without this iPhone is blocked")
		check(evaluate(inventory(), udid: "").decision == .blocked(.missingIdentity), "D9: no verified device identity is blocked")

		// D10: App IDs.
		do {
			let limit = ZagFreeAccountLimits.appIDsAtOnce
			let others = (0..<limit).map { ZagRegisteredAppID(identifier: "O\($0)", bundleIdentifier: "ABCDE12345.other\($0)", expiresAt: now.addingTimeInterval(86_400)) }
			check(evaluate(inventory(appIDs: .complete(others))).decision == .blocked(.appIDCapacity), "D10: no App ID capacity left is blocked")
			let lapsed = others.map { ZagRegisteredAppID(identifier: $0.identifier, bundleIdentifier: $0.bundleIdentifier, expiresAt: now.addingTimeInterval(-60)) }
			check(evaluate(inventory(appIDs: .complete(lapsed))).required.contains(.appID), "D10: lapsed App IDs do not use capacity")
		}
		check(evaluate(inventory(appIDs: .complete([appID, appID]))).decision == .blocked(.ambiguousAppID), "D10: the test App ID twice is ambiguous and blocked")

		// D11: duplicate serials, and an earlier request whose outcome is unknown.
		check(evaluate(inventory(certificates: .complete([certificate("D", days: 9), certificate("D", days: 9)]))).decision == .blocked(.duplicateCertificate),
			  "D11: a listing with a duplicated serial is blocked")
		check(evaluate(inventory(), local: .init(unresolvedRequest: true)).decision == .blocked(.unresolvedCertificateRequest),
			  "D11: an unresolved earlier certificate request is blocked")

		// D12: the report is redacted.
		let text = foreign.report.lines.joined(separator: "\n") + reuse.report.lines.joined(separator: "\n")
		check(!text.contains(deviceUDID) && !text.lowercased().contains(deviceUDID.lowercased()) && !text.contains("A1") && !text.contains("MINE")
			  && !text.contains(app) && !text.contains("@") && !text.contains(personal.identifier),
			  "D12: the report holds no UDID, serial, bundle identifier, address or team identifier")
	}

	// MARK: - K1–K13: the local signing state

	/// A secret store whose reads of one kind fail (a Keychain error).
	final class FailingSecrets: ZagFreeAccountSecretStore, @unchecked Sendable {
		let base: ZagFreeAccountSecretStore
		let failing: ZagFreeAccountSecretKind
		init(_ base: ZagFreeAccountSecretStore, failing: ZagFreeAccountSecretKind) {
			self.base = base
			self.failing = failing
		}
		func save(_ secret: Data, kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { try base.save(secret, kind: kind, account: account, team: team) }
		func load(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws -> Data? {
			if kind == failing { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
			return try base.load(kind, account: account, team: team)
		}
		func delete(_ kind: ZagFreeAccountSecretKind, account: UUID, team: String?) throws { try base.delete(kind, account: account, team: team) }
		func deleteAll(account: UUID) throws { try base.deleteAll(account: account) }
		func accountIDs() throws -> Set<UUID> { try base.accountIDs() }
	}

	struct StubLookup: ZagSigningKeyLookup {
		enum Mode { case absent, present, fails }
		let mode: Mode
		func key(account: UUID, team: String, slot: String?) throws -> SecKey? {
			switch mode {
			case .absent: return nil
			case .fails: throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
			case .present:
				return SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)
			}
		}
	}

	struct StubFactory: ZagSigningKeyFactory {
		let result: ZagIssuedCertificateCheck
		func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) { throw CocoaError(.featureUnsupported) }
		func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { result }
	}

	static func keyStateTests() {
		let account = UUID(), team = personal.identifier
		let identity = ZagSigningIdentity(serialNumber: "MINE", certificate: Data([1, 2, 3]), privateKey: Data(), expiresAt: now.addingTimeInterval(30 * 86_400), keySlot: "s1")
		let matches = StubFactory(result: .matches(serialNumber: "MINE", expiresAt: identity.expiresAt))
		func store(identity value: Data? = nil, pending: Data? = nil) -> MemorySecrets {
			let secrets = MemorySecrets()
			if let value { try? secrets.save(value, kind: .signingPrivateKey, account: account, team: team) }
			if let pending { try? secrets.save(pending, kind: .pendingSigningKey, account: account, team: team) }
			return secrets
		}
		let stored = try! JSONEncoder().encode(identity)
		func local(_ secrets: ZagFreeAccountSecretStore, _ lookup: StubLookup.Mode, _ factory: ZagSigningKeyFactory = matches) -> ZagExistingAccountPreflight.LocalKeys {
			ZagExistingAccountPreflight.localKeys(secrets: secrets, keys: factory, lookup: StubLookup(mode: lookup), account: account, team: team)
		}
		let registered = ZagRegisteredDevice(udid: deviceUDID, name: "iPhone")
		let appID = ZagRegisteredAppID(identifier: "X", bundleIdentifier: "\(personal.identifier).\(app)", expiresAt: now.addingTimeInterval(86_400))
		let listed = inventory(certificates: .complete([certificate("MINE", days: 30, data: identity.certificate)]), devices: .complete([registered]), appIDs: .complete([appID]))
		func blocked(_ value: ZagExistingAccountPreflight.LocalKeys) -> Bool {
			let assessment = evaluate(listed, local: value)
			return assessment.decision == .blocked(.signingKeysUnreadable) && assessment.required.isEmpty && !assessment.decision.allowsProvisioning
		}

		// Genuinely absent: not possessed, readable, a certificate is needed.
		let nothing = local(store(), .absent)
		check(nothing.unreadable == nil && nothing.possessedSerial == nil && evaluate(listed, local: nothing).decision == .needsNewAssets([.certificate, .profile]),
			  "K1: no stored identity is absent (a new certificate may be approved)")
		let keyGone = local(store(identity: stored), .absent)
		check(keyGone.unreadable == nil && keyGone.possessedSerial == nil && evaluate(listed, local: keyGone).required.contains(.certificate),
			  "K2: a stored identity whose key item is absent is not possessed (a new certificate may be approved)")
		let held = local(store(identity: stored), .present)
		check(held.unreadable == nil && held.possessedSerial == "MINE" && evaluate(listed, local: held).decision == .reusePossible,
			  "K3: a readable identity with its key present and matching is reused")

		// Read failures block; they never become "absent".
		let identityFails = local(FailingSecrets(store(identity: stored), failing: .signingPrivateKey), .present)
		check(identityFails.unreadable == .secretStore && blocked(identityFails), "K4: a Keychain error reading the identity blocks (no certificate requested)")
		let pendingFails = local(FailingSecrets(store(identity: stored), failing: .pendingSigningKey), .present)
		check(pendingFails.unreadable == .secretStore && blocked(pendingFails), "K5: a Keychain error reading the pending request blocks")
		let lookupFails = local(store(identity: stored), .fails)
		check(lookupFails.unreadable == .keyStore && blocked(lookupFails), "K6: a Keychain error looking up the key blocks")
		let emptyAndFailing = local(FailingSecrets(store(), failing: .signingPrivateKey), .absent)
		check(emptyAndFailing.unreadable == .secretStore && evaluate(inventory(), local: emptyAndFailing).decision == .blocked(.signingKeysUnreadable),
			  "K7: a Keychain error on an otherwise empty account blocks rather than asking for a certificate")

		// Corrupted records block.
		let garbage = Data("not json".utf8)
		check(local(store(identity: garbage), .present).unreadable == .corruptedRecord && blocked(local(store(identity: garbage), .present)),
			  "K8: a stored identity that does not decode blocks")
		check(local(store(identity: Data()), .present).unreadable == .corruptedRecord, "K8: an empty stored identity blocks")
		check(local(store(identity: stored, pending: garbage), .present).unreadable == .corruptedRecord && blocked(local(store(identity: stored, pending: garbage), .present)),
			  "K9: a pending request that does not decode blocks")
		let mismatch = local(store(identity: stored), .present, StubFactory(result: .mismatch))
		check(mismatch.unreadable == .identityMismatch && blocked(mismatch), "K10: a present key that does not match its certificate blocks")
		let otherSerial = local(store(identity: stored), .present, StubFactory(result: .matches(serialNumber: "OTHER", expiresAt: identity.expiresAt)))
		check(otherSerial.unreadable == .identityMismatch && blocked(otherSerial), "K11: a certificate whose serial differs from the stored identity blocks")
		let exported = ZagSigningIdentity(serialNumber: "MINE", certificate: identity.certificate, privateKey: Data([7]), expiresAt: identity.expiresAt)
		check(local(store(identity: try! JSONEncoder().encode(exported)), .present).unreadable == .identityMismatch, "K12: an identity with exported key bytes is never reused; it blocks")

		// The report says so, and stays redacted.
		let report = evaluate(listed, local: lookupFails).report.lines.joined(separator: "\n")
		check(report.contains("could not be read (blocked)") && !report.contains("MINE") && !report.contains(deviceUDID), "K13: the report states the keys could not be read, with nothing identifying")
	}

	// MARK: - The approval journal

	static func approvalTests() async {
		let store = MemoryCampaignRegistry()
		let approvals = ZagExistingAccountApprovals(campaignID: "G5-C1", store: store)
		check((try? approvals.approve(.device, accountKey: "K", team: "T")) == nil, "J1: nothing can be approved before a preflight")
		try? approvals.recordPreflight(accountKey: "K", team: "T", required: [.device, .profile])
		check((try? approvals.approve(.certificate, accountKey: "K", team: "T")) == nil, "J2: a mutation the preflight did not require cannot be approved")
		check((try? approvals.approve(.device, accountKey: "OTHER", team: "T")) == nil && (try? approvals.approve(.device, accountKey: "K", team: "T2")) == nil,
			  "J3: another account or team cannot approve")
		check((try? approvals.recordPreflight(accountKey: "OTHER", team: "T", required: [.device])) == nil, "J3: another account's preflight is refused")
		check((try? approvals.consume(.device, accountKey: "K", team: "T")) == nil, "J4: an unapproved mutation cannot be consumed")
		check((try? approvals.approve(.device, accountKey: "K", team: "T")) != nil, "J5: a required mutation is approved")

		// Concurrent consumers: exactly one wins.
		let wins = Box(0)
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<50 {
				group.addTask { if (try? approvals.consume(.device, accountKey: "K", team: "T")) != nil { wins.value += 1 } }
			}
		}
		check(wins.value == 1, "J6: 50 concurrent consumers of one approval: exactly one may send (\(wins.value))")
		approvals.settle(.device, succeeded: false)
		check((try? approvals.consume(.device, accountKey: "K", team: "T")) == nil, "J7: after a failure the mutation is not sent again (no retry)")
		check((try? approvals.approve(.device, accountKey: "K", team: "T")) == nil, "J7: and it cannot be approved again")

		// Durable: a relaunch reads the same journal.
		let relaunched = ZagExistingAccountApprovals(campaignID: "G5-C1", store: store)
		check(relaunched.journal?.sent[.device] == .failed && (try? relaunched.consume(.device, accountKey: "K", team: "T")) == nil,
			  "J8: after a relaunch the sent mutation stays sent")
		try? relaunched.recordPreflight(accountKey: "K", team: "T", required: [.profile])
		check(relaunched.journal?.approved == [] && relaunched.journal?.sent[.device] == .failed, "J8: a new preflight withdraws other approvals and keeps the record of what was sent")

		// A journal write that cannot be read back refuses.
		let failing = MemoryCampaignRegistry()
		let strict = ZagExistingAccountApprovals(campaignID: "G5-C1", store: failing)
		try? strict.recordPreflight(accountKey: "K", team: "T", required: [.profile])
		try? strict.approve(.profile, accountKey: "K", team: "T")
		failing.failWrites = true
		check((try? strict.consume(.profile, accountKey: "K", team: "T")) == nil, "J9: a journal write failure refuses, so nothing is sent")
		failing.failWrites = false
		check(strict.journal?.sent[.profile] == nil, "J9: and nothing was recorded as sent")

		// Another campaign starts with a new journal.
		check(ZagExistingAccountApprovals(campaignID: "G5-C2", store: store).journal?.accountKey == nil, "J10: another campaign's journal is not this one's")
	}

	// MARK: - X1–X15: the path end to end

	static func flowTests() async {
		// X1: a previously used account, read-only preflight; then provisioning
		// with exactly the approved changes.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			let result = await preflight(rig, campaign, approvals)
			let assessment = try? result.get()
			check(assessment?.decision == .needsNewAssets([.certificate, .profile]), "X1: a used account with this iPhone and the App ID needs only a certificate and a profile")
			var p = await seen(rig)
			check(p.onlyReads && rig.counter.value == 0 && p.mutations.isEmpty, "X1: the preflight made listing calls only")
			check(device.registryValue?.campaigns["G5-C1"]?.accountKey == rig.accountKey, "X1: the accepted preflight pinned the account")
			check(approvals.journal?.required == [.certificate, .profile], "X1: the journal accepts approvals for exactly the required changes")

			let unapproved = await rig.provision()
			p = await seen(rig)
			check((try? unapproved.get()) == nil && rig.counter.value == 0 && p.mutations.isEmpty && p.count(.profile) == 0,
				  "X1: without approval nothing is created")
			check(device.registryValue?.campaigns["G5-C1"]?.state == .armed, "X1: a refused approval leaves the budget unspent")

			check(approve(approvals, rig, [.certificate, .profile]), "X1: the owner approves the certificate and the profile")
			let provisioned = await rig.provision()
			check((try? provisioned.get()) != nil, "X1: provisioning succeeds (\(describe([provisioned], [rig])))")
			p = await seen(rig)
			check(rig.counter.value == 1 && p.mutations == [.submitCertificateRequest] && p.count(.profile) == 1,
				  "X1: exactly one certificate request and one profile; no device or App ID registration")
			check(approvals.journal?.sent == [.certificate: .succeeded, .profile: .succeeded], "X1: the journal records both as sent and succeeded")
			check(p.issued.contains { $0.serialNumber == "FOREIGN00" }, "X1: the existing certificate is untouched (never revoked)")
			rig.cleanUp()
		}

		// X2: at the certificate limit: one request, refused by Apple, a stop;
		// nothing revoked and nothing sent again.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig, foreignCertificates: 2)
			_ = await preflight(rig, campaign, approvals)
			_ = approve(approvals, rig, [.certificate, .profile])
			let first = await rig.provision()
			// The scripted bridge reports Apple's refusal as an unrecognised
			// response (as in G5; the live classification is an experiment
			// point): either way it is a stop at the certificate step.
			if case .failure(let failure) = first, failure.step == .certificate {
				check(true, "X2: at the limit the request is refused, a stop at the certificate step")
			} else {
				check(false, "X2: at the limit the request is refused (\(describe([first], [rig])))")
			}
			check(device.registryValue?.campaigns["G5-C1"]?.state == .halted, "X2: the campaign is halted")
			_ = await rig.provision()
			let p = await seen(rig)
			check(rig.counter.value == 1 && p.issued.count == 2, "X2: one request in all; both existing certificates remain")
			check(approvals.journal?.sent[.certificate] == .failed, "X2: the certificate approval is spent")
			rig.cleanUp()
		}

		// X3: reuse. Campaign 1 provisions; campaign 2 finds the possessed
		// certificate, the device and the App ID, and needs only a profile.
		do {
			let device = Device()
			let (first, approvals1) = armed(device)
			let rig = await Rig.make(first)
			guard case .success(let a1) = await preflight(rig, first, approvals1) else { check(false, "X3: the first preflight is accepted"); return }
			_ = approve(approvals1, rig, a1.required)
			let firstRun = await rig.provision()
			check((try? firstRun.get()) != nil, "X3: campaign 1 provisions an empty team with four approvals")
			let (second, approvals2) = armed(device, 2)
			let again = rig.relaunched(second)
			let before = await again.portal.calls.count
			let result = await preflight(again, second, approvals2)
			check((try? result.get())?.decision == .reusePossible, "X3: campaign 2 reuses the certificate, the device and the App ID")
			check((try? result.get())?.report.reusableCertificateDaysLeft != nil, "X3: the report shows a reusable certificate")
			let later = await again.portal.calls
			check(later.dropFirst(before).allSatisfy(reads.contains), "X3: the second preflight made listing calls only")
			_ = approve(approvals2, again, [.profile])
			let reused = await again.provision()
			check((try? reused.get()) != nil, "X3: campaign 2 provisions (\(describe([reused], [again])))")
			let q = await seen(again)
			check(again.counter.value == 1 && q.count(.registerDevice) == 1 && q.count(.registerAppID) == 1,
				  "X3: no certificate request, device or App ID registration in campaign 2")
			check(device.registryValue?.campaigns["G5-C2"]?.submissions == 0, "X3: campaign 2's certificate budget is untouched")

			// X4: the key becomes unavailable: the certificate is no longer reusable.
			let (third, approvals3) = armed(device, 3)
			let keyless = rig.relaunched(third)
			try? keyless.keys.deleteAll(account: keyless.account)
			let assessment = try? (await preflight(keyless, third, approvals3)).get()
			check(assessment?.required.contains(.certificate) == true && assessment?.report.foreignValidCertificates == 1,
				  "X4: with the private key gone the certificate counts as foreign and a new one is needed")

			// X5: a key of another team is not this team's.
			let local = ZagExistingAccountPreflight.localKeys(secrets: rig.secrets, keys: ZagKeychainSigningKeyFactory(keys: rig.keys), lookup: rig.keys,
															  account: rig.account, team: "ZZZZZ99999")
			check(local.possessedSerial == nil, "X5: another team's identity is not possession for this team")
			rig.cleanUp()
		}

		// X6: partial or failed listings: unknown, refused, nothing sent, not halted.
		for (operation, failure) in [(ZagSimulatedDeveloperPortal.Operation.certificates, ZagSimulatedDeveloperPortal.Failure.network),
									 (.devices, .malformed), (.appIDs, .sessionRejected)] {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			await rig.portal.fail(operation, with: failure)
			let result = await preflight(rig, campaign, approvals)
			check((try? result.get()) == nil && approvals.journal?.accountKey == nil, "X6: a failed \(operation) listing is unknown and the preflight is refused")
			let p = await seen(rig)
			check(p.onlyReads && device.registryValue?.campaigns["G5-C1"]?.state == .armed && device.registryValue?.campaigns["G5-C1"]?.accountKey == nil,
				  "X6: nothing sent, the campaign not halted and no account pinned")
			let provisioned = await rig.provision()
			let after = await seen(rig)
			check((try? provisioned.get()) == nil && after.mutations.isEmpty, "X6: without an accepted preflight provisioning changes nothing (C8)")
			rig.cleanUp()
		}

		// X7: a cancelled preflight reads nothing and decides nothing.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			let task = Task { () -> Result<ZagExistingAccountPreflight.Assessment, Error> in
				withUnsafeCurrentTask { $0?.cancel() }
				return await preflight(rig, campaign, approvals)
			}
			let result = await task.value
			let p = await seen(rig)
			check((try? result.get()) == nil && p.calls.isEmpty && approvals.journal?.accountKey == nil,
				  "X7: a cancelled preflight sends nothing and is not accepted")
			rig.cleanUp()
		}

		// X8: a mismatched profile is rejected; the profile is not requested again.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			await rig.portal.tamperProfiles(.missingDevice)
			_ = await preflight(rig, campaign, approvals)
			_ = approve(approvals, rig, [.certificate, .profile])
			let result = await rig.provision()
			if case .failure(let failure) = result, case .invalidProfile(.deviceMissing) = failure.kind {
				check(true, "X8: a profile without this iPhone is rejected before signing")
			} else {
				check(false, "X8: a profile without this iPhone is rejected (\(describe([result], [rig])))")
			}
			_ = await rig.provision()
			let p = await seen(rig)
			check(p.count(.profile) == 1 && approvals.journal?.sent[.profile] != nil, "X8: one profile request; the approval is spent (no retry)")
			rig.cleanUp()
		}

		// X9: cancellation while a change is out: recorded as sent, never resent.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await rig.portal.seedAppID("placeholder.unused", expiresAt: Date().addingTimeInterval(-60))
			await rig.portal.fail(.registerDevice, with: .noResponse)
			guard case .success(let a) = await preflight(rig, campaign, approvals) else { check(false, "X9: preflight accepted"); return }
			_ = approve(approvals, rig, a.required)
			let task = Task { await rig.provision() }
			let started = await wait(10) { await seen(rig).count(.registerDevice) == 1 }
			task.cancel()
			let result = await task.value
			check(started && (try? result.get()) == nil, "X9: the cancelled provisioning fails")
			await rig.portal.fail(.registerDevice, with: nil)
			_ = await rig.provision()
			let p = await seen(rig)
			check(p.count(.registerDevice) == 1 && approvals.journal?.sent[.device] != nil && approvals.journal?.sent[.device] != .succeeded,
				  "X9: the device registration was journalled before sending and is not sent again")
			rig.cleanUp()
		}

		// X10: concurrent provisioning: each approved change reaches the portal once.
		for round in 1...5 {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			guard case .success(let a) = await preflight(rig, campaign, approvals) else { check(false, "X10: preflight accepted"); continue }
			_ = approve(approvals, rig, a.required)
			async let first = rig.provision()
			async let second = rig.provision()
			let results = await [first, second]
			let succeeded = results.filter { (try? $0.get()) != nil }.count
			let p = await seen(rig)
			check(succeeded == 1 && rig.counter.value == 1 && p.count(.registerDevice) == 1 && p.count(.registerAppID) == 1 && p.count(.profile) == 1,
				  "X10 round \(round): two concurrent provisionings: one succeeds, and one certificate, device, App ID and profile request in all")
			rig.cleanUp()
		}

		// X11: app groups are never approved, so never registered.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			guard case .success(let a) = await preflight(rig, campaign, approvals) else { check(false, "X11: preflight accepted"); return }
			_ = approve(approvals, rig, a.required)
			let registered = try? await rig.adapter.registerAppGroup("group.\(rig.team).x", team: rig.team)
			let p = await seen(rig)
			check(registered == nil && p.count(.registerAppGroup) == 0, "X11: an app group registration is refused before sending")
			rig.cleanUp()
		}

		// X12: the certificate count changed after the preflight: refused at the
		// budget (C8), nothing sent.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			_ = await preflight(rig, campaign, approvals)
			_ = approve(approvals, rig, [.certificate, .profile])
			await rig.portal.seedCertificate(serial: "LATECOMER", expiresAt: Date().addingTimeInterval(300 * 86_400))
			let result = await rig.provision()
			check((try? result.get()) == nil && rig.counter.value == 0, "X12: a certificate listing changed since the preflight stops the request (nothing sent)")
			rig.cleanUp()
		}

		// X13: another account cannot use the pinned campaign.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			_ = await preflight(rig, campaign, approvals)
			let other = await Rig.make(campaign, appleID: SimulatedAccounts.second, secrets: rig.secrets, directory: rig.directory, keys: rig.keys)
			let result = await preflight(other, campaign, approvals)
			let p = await seen(other)
			check((try? result.get()) == nil && p.calls.isEmpty, "X13: a second account's preflight is refused before any listing (C6)")
			rig.cleanUp()
		}

		// X14: a blocked inventory is refused: a full device list.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			for index in 0..<ZagFreeAccountLimits.devicesPerPlatform { await rig.portal.seedDevice("00000000-FULL\(index)") }
			let result = await preflight(rig, campaign, approvals)
			let p = await seen(rig)
			check((try? result.get()) == nil && p.mutations.isEmpty && approvals.journal?.accountKey == nil,
				  "X14: a blocked inventory (device limit) is refused with nothing sent")
			rig.cleanUp()
		}

		// X15: the redacted report of a populated account.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			let lines = (try? (await preflight(rig, campaign, approvals)).get())?.report.lines ?? []
			let text = lines.joined(separator: "\n")
			check(!lines.isEmpty && !text.contains("FOREIGN") && !text.lowercased().contains(deviceUDID.lowercased()) && !text.contains(rig.team) && !text.contains("@"),
				  "X15: the report shows counts only")
			print(lines.map { "  | \($0)" }.joined(separator: "\n"))
			rig.cleanUp()
		}

		// X16: a Keychain read failure, end to end: the inventory is refused,
		// nothing is created (no certificate request), the campaign not halted.
		do {
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			let result = await preflight(rig, campaign, approvals, secrets: FailingSecrets(rig.secrets, failing: .signingPrivateKey))
			check((try? result.get()) == nil && approvals.journal?.accountKey == nil && !approve(approvals, rig, [.certificate]),
				  "X16: a Keychain error refuses the inventory; no certificate can be approved")
			let provisioned = await rig.provision()
			let p = await seen(rig)
			check((try? provisioned.get()) == nil && rig.counter.value == 0 && p.mutations.isEmpty && p.count(.profile) == 0,
				  "X16: and provisioning creates nothing")
			check(device.registryValue?.campaigns["G5-C1"]?.state == .armed, "X16: the campaign stays armed (a refusal, not a stop)")
			rig.cleanUp()
		}

		// X17 (G4 follow-up 1): the journal write fails after the certificate
		// budget is spent. Nothing is sent, the campaign halts, and neither a
		// retry, a relaunch nor a working journal can send it afterwards.
		do {
			let device = Device()
			let store = MemoryCampaignRegistry()
			let (campaign, approvals) = armed(device, store: store)
			let rig = await Rig.make(campaign)
			await seedPopulated(rig)
			_ = await preflight(rig, campaign, approvals)
			_ = approve(approvals, rig, [.certificate, .profile])
			store.failWrites = true
			let first = await rig.provision()
			let record = device.registryValue?.campaigns["G5-C1"]
			check((try? first.get()) == nil && rig.counter.value == 0, "X17: a journal write failure after the budget is spent sends no certificate request")
			check(record?.submissions == 1 && record?.state == .halted, "X17: the budget stays spent and the campaign halts (a stop)")
			check(approvals.journal?.sent[.certificate] == nil, "X17: the journal does not record a send that did not happen")
			store.failWrites = false
			_ = await rig.provision()
			let (again, _) = device.launch(Device.constants(1))
			let relaunched = rig.relaunched(again)
			let after = await relaunched.provision()
			let p = await seen(rig)
			check((try? after.get()) == nil && rig.counter.value == 0 && relaunched.counter.value == 0 && !p.mutations.contains(.submitCertificateRequest),
				  "X17: no retry: neither a second attempt nor a relaunch with a working journal sends a certificate request")
			rig.cleanUp()
		}

		// X18 (G4 follow-up 2): a new campaign ID never inherits or revives
		// approvals; each change needs the new campaign's own preflight and
		// approval, and the old campaign can never send again.
		do {
			let device = Device()
			let store = MemoryCampaignRegistry()
			let (first, approvals1) = armed(device, store: store)
			let rig = await Rig.make(first)
			guard case .success(let a1) = await preflight(rig, first, approvals1) else { check(false, "X18: campaign 1 preflight accepted"); return }
			_ = approve(approvals1, rig, a1.required)
			check((try? (await rig.provision()).get()) != nil && approvals1.journal?.sent[.device] == .succeeded, "X18: campaign 1 sends its approved changes")
			let base = await seen(rig)

			let (second, approvals2) = armed(device, 2, store: store)
			check(approvals2.journal?.approved == [] && approvals2.journal?.sent == [:] && approvals2.journal?.accountKey == nil,
				  "X18: campaign 2's journal starts empty: nothing approved carries over")
			let unprepared = await rig.relaunched(second).provision()
			var now = await seen(rig)
			check((try? unprepared.get()) == nil && now.mutations.count == base.mutations.count && now.count(.profile) == base.count(.profile),
				  "X18: campaign 2 without its own preflight changes nothing (C8)")
			let again = rig.relaunched(second)
			_ = await preflight(again, second, approvals2)
			let unapproved = await again.provision()
			now = await seen(rig)
			check((try? unapproved.get()) == nil && now.count(.profile) == base.count(.profile), "X18: campaign 2's preflight alone approves nothing; the profile is not requested")

			// Campaign 1's journal with campaign 2's campaign: refused before sending.
			let crossed = ZagIsideloadDeveloperPortal(account: rig.account, secrets: rig.secrets, campaign: second, approvals: approvals1,
														transport: scriptedTransport(rig.portal, counter: rig.counter))
			_ = try? await crossed.registerDevice(udid: "00000000-CROSSED000000000", name: "x", team: rig.team)
			let crossedPreflight = try? await ZagExistingAccountPreflight.run(
				reader: ZagReadOnlyPortal(crossed), team: ZagDeveloperTeam(identifier: rig.team, name: "Personal", kind: .personalFree), teamCount: 1,
				accountKey: rig.accountKey, account: rig.account, secrets: rig.secrets, keys: ZagKeychainSigningKeyFactory(keys: rig.keys),
				bundleIdentifier: mapped(rig), deviceUDID: deviceUDID, campaign: second, approvals: approvals1)
			now = await seen(rig)
			check(now.count(.registerDevice) == base.count(.registerDevice) && crossedPreflight == nil, "X18: another campaign's journal is refused (no send, no preflight)")

			// Campaign 1 relaunched after campaign 2 is armed: C3 refuses everything.
			let (old, _) = device.launch(Device.constants(1))
			let oldRig = rig.relaunched(old)
			let revived = await oldRig.provision()
			let oldPreflight = await preflight(oldRig, old, ZagExistingAccountApprovals(campaignID: "G5-C1", store: store))
			now = await seen(rig)
			check((try? revived.get()) == nil && (try? oldPreflight.get()) == nil && now.mutations.count == base.mutations.count,
				  "X18: the older campaign never sends again once a newer one is armed (C3)")
			rig.cleanUp()
		}

		// X19 (G4 follow-up 3): listings that are malformed or incomplete at
		// the bridge's JSON boundary are unknown, never an empty account; only
		// a well-formed empty array is empty.
		do {
			let cases: [(String, String, String)] = [
				("devices", "null", "null"), ("devices", "{}", "an object"), ("devices", "{\"devices\":[]}", "a wrapped list"),
				("devices", "[{\"name\":\"x\"}]", "an entry without a UDID"), ("devices", "\"[]\"", "a string"),
				("certificates", "[{\"name\":\"x\",\"expiresAt\":1}]", "a certificate without a serial"),
				("certificates", "[{\"serialNumber\":\"A\",\"name\":\"x\"}]", "a certificate without an expiry"),
				("appIds", "[{\"identifier\":\"X\"}]", "an App ID without a bundle identifier"), ("appIds", "", "an empty body"),
			]
			for (op, body, label) in cases {
				let device = Device()
				let (campaign, approvals) = armed(device)
				let rig = await Rig.make(campaign)
				let base = scriptedTransport(rig.portal, counter: rig.counter)
				let transport: ZagIsideloadDeveloperPortal.Transport = { credential, json in
					if let request = try? JSONSerialization.jsonObject(with: json) as? [String: Any], request["op"] as? String == op { return .result(Data(body.utf8)) }
					return await base(credential, json)
				}
				let adapter = ZagIsideloadDeveloperPortal(account: rig.account, secrets: rig.secrets, campaign: campaign, approvals: approvals, transport: transport)
				let result = try? await ZagExistingAccountPreflight.run(
					reader: ZagReadOnlyPortal(adapter), team: ZagDeveloperTeam(identifier: rig.team, name: "Personal", kind: .personalFree), teamCount: 1,
					accountKey: rig.accountKey, account: rig.account, secrets: rig.secrets, keys: ZagKeychainSigningKeyFactory(keys: rig.keys),
					bundleIdentifier: mapped(rig), deviceUDID: deviceUDID, campaign: campaign, approvals: approvals)
				let read = await ZagExistingAccountPreflight.read(ZagReadOnlyPortal(adapter), team: ZagDeveloperTeam(identifier: rig.team, name: "Personal", kind: .personalFree), teamCount: 1)
				let unknown: Bool = switch op {
				case "devices": read.devices.items == nil
				case "certificates": read.certificates.items == nil
				default: read.appIDs.items == nil
				}
				check(result == nil && unknown && approvals.journal?.accountKey == nil, "X19: \(op) as \(label) is unknown, not empty; the inventory is refused")
				rig.cleanUp()
			}
			// The control: a well-formed empty listing is a genuinely empty one.
			let device = Device()
			let (campaign, approvals) = armed(device)
			let rig = await Rig.make(campaign)
			let assessment = try? (await preflight(rig, campaign, approvals)).get()
			check(assessment?.report.certificates == 0 && assessment?.report.devices == 0 && assessment?.decision == .needsNewAssets([.certificate, .device, .appID, .profile]),
				  "X19: a well-formed empty listing is empty (control)")
			rig.cleanUp()
		}
	}
}
