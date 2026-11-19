#if ZAG_LIVE_EXPERIMENT
#if DEBUG && !ZAG_G5_TESTS
#error("The live experiment is never built with DEBUG (G5 plan §3.3)")
#endif
#if !(ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT)
#error("The live experiment needs ZAG_APPLE_BRIDGE and ZAG_ZSIGN_STRICT")
#endif
import CryptoKit
import Foundation
import Security

// G5: the campaign that bounds the live experiment (plan §5.2, §5.5).
//
// One device-wide Keychain item, the registry, holds every campaign's state.
// It is written by one function only (`commit`), which enforces the state
// machine and reads every write back before trusting it:
//
//   (no record) ─probe→ probing ─E5 proof→ armed ─consume→ spent ─end→ closed
//   any state ─stop rule / inconsistency→ halted   (terminal)
//
// Nothing here talks to the network. `ZAG_G5_TESTS` is set only by
// scripts/test-zag-g5-experiment.sh; the build check refuses it in app builds.

/// The campaign constants as one value, so tests can run other campaigns.
struct ZagCampaignConstants: Equatable, Sendable {
	var campaignID: String
	var campaignNumber: Int
	var notBefore: Date
	var notAfter: Date
	var buildNonce: String
	var anisetteURL: String
	var deviceSerialPolicy: String
	var deviceSerial: String

	static let compiled = ZagCampaignConstants(
		campaignID: ZagLiveExperimentCampaignConstants.campaignID,
		campaignNumber: ZagLiveExperimentCampaignConstants.campaignNumber,
		notBefore: Date(timeIntervalSince1970: ZagLiveExperimentCampaignConstants.notBefore),
		notAfter: Date(timeIntervalSince1970: ZagLiveExperimentCampaignConstants.notAfter),
		buildNonce: ZagLiveExperimentCampaignConstants.buildNonce,
		anisetteURL: ZagLiveExperimentCampaignConstants.anisetteURL,
		deviceSerialPolicy: ZagLiveExperimentCampaignConstants.deviceSerialPolicy,
		deviceSerial: ZagLiveExperimentCampaignConstants.deviceSerial
	)

	/// The longest window the plan allows (§5.5).
	static let maximumWindow: TimeInterval = 7 * 86_400
	/// Apple's time may differ from the device clock by at most this (C5).
	static let maximumSkew: TimeInterval = 600

	/// The G3 provider's host, or nil when none is configured.
	var providerHost: String? {
		guard let url = URL(string: anisetteURL), url.scheme == "https", url.user == nil, url.port == nil,
			  let host = url.host, !host.isEmpty else { return nil }
		return host.lowercased()
	}

	/// Whether these constants could authorise anything at all. The
	/// placeholders in the source cannot.
	var isAuthorisable: Bool {
		campaignID.range(of: #"^G5-C[0-9]{1,3}$"#, options: .regularExpression) != nil
			&& (1...999).contains(campaignNumber)
			&& campaignID == "G5-C\(campaignNumber)"
			&& buildNonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
			&& buildNonce != String(repeating: "0", count: 32)
			&& notAfter > notBefore
			&& notAfter.timeIntervalSince(notBefore) <= Self.maximumWindow
			&& notBefore.timeIntervalSince1970 > 1_700_000_000
			&& providerHost != nil
			&& ["g3Fixed", "g3PerAccount"].contains(deviceSerialPolicy)
	}
}

enum ZagCampaignState: String, Codable, Sendable, CaseIterable {
	case none, probing, armed, spent, closed, halted

	/// How far a campaign has progressed; never decreases except into halted.
	var rank: Int {
		switch self {
		case .none: 0
		case .probing: 1
		case .armed: 2
		case .spent: 3
		case .closed: 4
		case .halted: 5
		}
	}
}

/// The registry item: every campaign this device has seen.
struct ZagCampaignRegistry: Codable, Equatable, Sendable {
	struct Record: Codable, Equatable, Sendable {
		var state: ZagCampaignState
		var buildNonce: String
		/// Certificate requests let through for this campaign: 0 or 1.
		var submissions: Int
		/// The pinned account (`ZagAppleAccountRecord.accountKey`), once pinned.
		var accountKey: String?
		/// E5: launches seen while probing.
		var probeLaunches: Int
		/// The stop rule that halted it, if any.
		var haltRule: String?
	}

	var highestCampaignNumber = 0
	var campaigns: [String: Record] = [:]

	/// The stored form: compared byte for byte after every write.
	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(self)
	}
}

/// The container marker: a file deleting the app removes (E5, C7).
struct ZagCampaignMarker: Codable, Equatable, Sendable {
	let campaignID: String
	let buildNonce: String
	let state: ZagCampaignState
}

/// Where the registry lives. `write` replaces the whole item in one call.
protocol ZagCampaignRegistryStore: AnyObject, Sendable {
	/// Nil when the item does not exist. Throws when it cannot be read.
	func read() throws -> Data?
	func write(_ data: Data) throws
}

/// Where the container marker lives.
protocol ZagCampaignMarkerStore: AnyObject, Sendable {
	func read() -> Data?
	func write(_ data: Data) throws
}

enum ZagCampaignStoreError: Error { case keychain(OSStatus), file }

/// The registry in the Keychain: this device only, not synchronised, and
/// outside every service the account directory lists or removes.
final class ZagKeychainCampaignRegistryStore: ZagCampaignRegistryStore, @unchecked Sendable {
	static let service = "ZagStore.live-test.registry"
	let service: String
	private let account = "registry"

	init(service: String = ZagKeychainCampaignRegistryStore.service) { self.service = service }

	private var query: [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: false,
		]
	}

	func read() throws -> Data? {
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query.merging([
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]) { $1 } as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw ZagCampaignStoreError.keychain(status) }
		return data
	}

	func write(_ data: Data) throws {
		let updated = SecItemUpdate(query as CFDictionary, [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		] as CFDictionary)
		if updated == errSecSuccess { return }
		guard updated == errSecItemNotFound else { throw ZagCampaignStoreError.keychain(updated) }
		let added = SecItemAdd(query.merging([
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]) { $1 } as CFDictionary, nil)
		guard added == errSecSuccess else { throw ZagCampaignStoreError.keychain(added) }
	}
}

/// The marker in the app's own container (Application Support), excluded
/// from backups so that a restore cannot bring it back.
final class ZagFileCampaignMarkerStore: ZagCampaignMarkerStore, @unchecked Sendable {
	let url: URL

	init(directory: URL = ZagLiveExperiment.containerDirectory) {
		url = directory.appendingPathComponent("campaign-marker.json")
	}

	func read() -> Data? { try? Data(contentsOf: url) }

	func write(_ data: Data) throws {
		do {
			var directory = url.deletingLastPathComponent()
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			try? directory.setResourceValues(values)
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			throw ZagCampaignStoreError.file
		}
	}
}

/// Why the experiment refused an operation. Each refusal is shown as a stop.
enum ZagLiveExperimentRefusal: Error, Equatable, Sendable {
	/// The campaign is not armed (E5 not proven, or unconfigured constants).
	case notArmed
	case halted
	case certificateBudgetSpent
	case accountMismatch
	case ledgerWriteFailed
	/// One of the local checks C1–C8 refused.
	case check(String)
	/// Abandoning a certificate request is refused during a campaign (E3).
	case abandonRefused
}

/// The stop rules of plan §7.3. Each one halts the campaign.
enum ZagStopRule: String, CaseIterable, Codable, Sendable {
	case e5NotArmed, campaignCheck, healthCheck, readbackPreflight, notArmed
	case authTwoFailures, authLimit, authUnexpectedPrompt, authUnknownTwoFactor, accountMismatch
	case policyBlocked, tlsFailure
	case anisetteProvisioning, anisetteHeaders
	case teamCount
	case accountNotEmpty, certificateMustBeRevoked, certificateUnresolved, possessionMismatch
	case budgetSpent, ledgerWriteFailed, interruptedAfterConsume
	case deviceLimit, differentDevice
	case profileProblem, identifierUnavailable, appIDCapacity
	case signingFailed, keyFileWritten
	case installRefused, installUnknown, launchFailed, readbackMismatch, readbackNotVerified
	case ownerUnrecognised
}

/// What a live operation is, for the campaign's checks.
enum ZagLiveOperation: String, Sendable {
	case signIn, portalRead, portalMutate, submitCertificate, sign, install
	/// Allowed even when halted (plan §5.2, E2).
	case certificateList, signOut, inventory
}

/// The campaign of this build: its checks, its one-use budget and its halt.
final class ZagLiveExperimentCampaign: @unchecked Sendable {
	let constants: ZagCampaignConstants
	private let registry: ZagCampaignRegistryStore
	private let marker: ZagCampaignMarkerStore
	private let logger: ZagExperimentLogger?
	private let now: @Sendable () -> Date
	/// Seconds since 1970 of the latest TLS-verified Apple `Date` header, or
	/// nil (from the bridge in the app; scripted in tests).
	private let authenticatedTime: @Sendable () -> Date?
	private let lock = NSLock()
	/// This process consumed the budget: the run may finish its later steps.
	/// A later launch that finds the record spent refuses (C2).
	private var consumedInThisProcess = false
	/// The E4 account-state check passed in this process (C8).
	/// C8 / E4: the accounts and teams found empty in this process, each
	/// `accountKey + "\n" + team`. Only the pinned account can be in it.
	private var verifiedAccounts = Set<String>()
	/// A halt was attempted in this process: even if it could not be
	/// stored, nothing more runs here.
	private var haltedInProcess = false

	init(
		constants: ZagCampaignConstants = .compiled,
		registry: ZagCampaignRegistryStore = ZagKeychainCampaignRegistryStore(),
		marker: ZagCampaignMarkerStore = ZagFileCampaignMarkerStore(),
		logger: ZagExperimentLogger? = nil,
		now: @escaping @Sendable () -> Date = { Date() },
		authenticatedTime: @escaping @Sendable () -> Date? = { nil }
	) {
		self.constants = constants
		self.registry = registry
		self.marker = marker
		self.logger = logger
		self.now = now
		self.authenticatedTime = authenticatedTime
	}

	// MARK: Reading

	/// The registry as stored. Unreadable or undecodable: nil (fail closed).
	private func load() -> ZagCampaignRegistry?? {
		do {
			guard let data = try registry.read() else { return .some(nil) }
			guard let decoded = try? JSONDecoder().decode(ZagCampaignRegistry.self, from: data) else { return nil }
			return .some(decoded)
		} catch {
			return nil
		}
	}

	private func loadMarker() -> ZagCampaignMarker? {
		marker.read().flatMap { try? JSONDecoder().decode(ZagCampaignMarker.self, from: $0) }
	}

	/// This campaign's state as stored; `.none` without a record, `.halted`
	/// when the registry cannot be read.
	var state: ZagCampaignState {
		lock.withLock {
			guard case .some(let stored) = load() else { return .halted }
			return stored?.campaigns[constants.campaignID]?.state ?? .none
		}
	}

	var record: ZagCampaignRegistry.Record? {
		lock.withLock {
			guard case .some(let stored) = load() else { return nil }
			return stored?.campaigns[constants.campaignID]
		}
	}

	// MARK: The one writer

	/// Whether `old → new` is allowed for one campaign record.
	static func allowed(_ old: ZagCampaignRegistry.Record?, _ new: ZagCampaignRegistry.Record?) -> Bool {
		guard let new else { return old == nil }
		guard let old else { return new.state == .probing || new.state == .halted }
		if old.state == .halted { return old == new }
		guard new.buildNonce == old.buildNonce,
			  new.submissions >= old.submissions, new.submissions <= 1,
			  old.accountKey == nil || new.accountKey == old.accountKey else { return false }
		if new.submissions != old.submissions && !(old.state == .armed && new.state == .spent) { return false }
		switch (old.state, new.state) {
		case (_, .halted): return true
		case (.probing, .probing), (.probing, .armed), (.armed, .armed), (.armed, .spent), (.spent, .closed), (.spent, .spent), (.closed, .closed):
			return new.state != .spent || new.submissions == 1
		default:
			return false
		}
	}

	/// Applies `change` to the registry: refuses any transition the state
	/// machine does not allow, writes the whole item at once, and reads it
	/// back. Any failure throws `ledgerWriteFailed`; the caller halts.
	private func commit(_ change: (inout ZagCampaignRegistry) throws -> Void) throws {
		guard case .some(let stored) = load() else { throw ZagLiveExperimentRefusal.ledgerWriteFailed }
		let before = stored ?? ZagCampaignRegistry()
		var after = before
		try change(&after)
		guard after.highestCampaignNumber >= before.highestCampaignNumber else { throw ZagLiveExperimentRefusal.ledgerWriteFailed }
		for id in Set(before.campaigns.keys).union(after.campaigns.keys) where !Self.allowed(before.campaigns[id], after.campaigns[id]) {
			throw ZagLiveExperimentRefusal.ledgerWriteFailed
		}
		guard after != before else { return }
		let data: Data
		do {
			data = try after.encoded()
			try registry.write(data)
		} catch {
			logger?.campaignRegistryWrite(ok: false, readBackMatches: false)
			throw ZagLiveExperimentRefusal.ledgerWriteFailed
		}
		let readBack = try? registry.read()
		guard readBack == data else {
			logger?.campaignRegistryWrite(ok: true, readBackMatches: false)
			throw ZagLiveExperimentRefusal.ledgerWriteFailed
		}
		logger?.campaignRegistryWrite(ok: true, readBackMatches: true)
		let id = constants.campaignID, from = before.campaigns[id]?.state ?? .none
		if let to = after.campaigns[id]?.state, to != from {
			logger?.campaignState(from: from, to: to, reason: after.campaigns[id]?.haltRule ?? Self.reason(to))
		}
	}

	private static func reason(_ state: ZagCampaignState) -> String {
		switch state {
		case .spent: "consume"
		case .closed: "end"
		case .armed: "e5Proof"
		case .probing: "probe"
		case .none, .halted: "end"
		}
	}

	private func writeMarker(_ state: ZagCampaignState) {
		guard let data = try? JSONEncoder().encode(ZagCampaignMarker(campaignID: constants.campaignID, buildNonce: constants.buildNonce, state: state)) else { return }
		try? marker.write(data)
	}

	// MARK: Halt (E2)

	/// Sets this campaign halted, before the stop is shown. Without a record
	/// (nothing was ever armed) a halted record is created, so the campaign
	/// can never arm later. Returns whether the halt is stored.
	@discardableResult
	func halt(_ rule: ZagStopRule) -> Bool {
		lock.withLock { haltLocked(rule) }
	}

	private func haltLocked(_ rule: ZagStopRule) -> Bool {
		haltedInProcess = true
		let id = constants.campaignID, nonce = constants.buildNonce
		do {
			try commit { registry in
				guard var record = registry.campaigns[id] else {
					registry.campaigns[id] = .init(state: .halted, buildNonce: nonce, submissions: 0, accountKey: nil, probeLaunches: 0, haltRule: rule.rawValue)
					return
				}
				guard record.state != .halted else { return }
				record.state = .halted
				record.haltRule = rule.rawValue
				registry.campaigns[id] = record
			}
		} catch {
			// The registry cannot be written: every check reads it and refuses
			// (an unreadable or non-armed registry never arms or consumes).
			logger?.stop(rule, haltSet: false)
			return false
		}
		writeMarker(.halted)
		logger?.stop(rule, haltSet: true)
		return true
	}

	/// Ends a campaign whose certificate was spent (`spent → closed`).
	func close() throws {
		try lock.withLock {
			let id = constants.campaignID
			try commit { registry in
				guard var record = registry.campaigns[id], record.state == .spent else { return }
				record.state = .closed
				registry.campaigns[id] = record
			}
			writeMarker(.closed)
		}
	}

	// MARK: Launch: E5 and the launch checks

	enum Durability: String, Sendable { case unconfigured, probeWritten, stillProbing, armed, refused }

	/// Runs at every launch, without network: C1–C4 and C7, then E5. Returns
	/// what happened; only `armed` lets live operations run.
	@discardableResult
	func launch() -> Durability {
		lock.withLock { launchLocked() }
	}

	private func refuseLocked(_ check: String, halting: Bool) -> Durability {
		logger?.campaignCheck(check, pass: false)
		if halting { _ = haltLocked(.campaignCheck) }
		return .refused
	}

	private func launchLocked() -> Durability {
		guard constants.isAuthorisable else {
			logger?.campaignCheck("C1", pass: false)
			return .unconfigured
		}
		guard case .some(let stored) = load() else {
			// Unreadable registry: nothing can be decided; never arm.
			return refuseLocked("C7", halting: false)
		}
		let registry = stored ?? ZagCampaignRegistry()
		let id = constants.campaignID
		let record = registry.campaigns[id]
		let container = loadMarker().flatMap { $0.campaignID == id ? $0 : nil }

		// C1: the record belongs to this build.
		if let record, record.buildNonce != constants.buildNonce { return refuseLocked("C1", halting: true) }
		logger?.campaignCheck("C1", pass: true)
		// C2: single use.
		if let record, [.spent, .closed, .halted].contains(record.state) {
			return refuseLocked("C2", halting: record.state == .spent)
		}
		logger?.campaignCheck("C2", pass: true)
		// C3: an older campaign never runs after a newer one.
		if constants.campaignNumber < registry.highestCampaignNumber { return refuseLocked("C3", halting: record != nil) }
		if record?.state != .armed, constants.campaignNumber <= registry.highestCampaignNumber, registry.highestCampaignNumber > 0 {
			return refuseLocked("C3", halting: record != nil)
		}
		logger?.campaignCheck("C3", pass: true)
		// C4: the device clock is inside the window.
		let clock = now()
		logger?.campaignWindow(device: window(clock), authenticated: nil, skewOK: nil)
		guard window(clock) == "inside" else { return refuseLocked("C4", halting: record != nil) }
		logger?.campaignCheck("C4", pass: true)
		// C7: the container and the registry agree. A marker that is armed or
		// later with the registry missing or behind means the Keychain was
		// lost without deleting the app; a probing marker without a registry
		// record is the same loss before arming.
		if let container {
			let behind = record == nil || (record!.state.rank < container.state.rank) || container.buildNonce != constants.buildNonce
			if behind { return refuseLocked("C7", halting: true) }
		}
		logger?.campaignCheck("C7", pass: true)

		// E5 (plan §5.2): arm only on positive proof that the Keychain survived
		// deleting the app and the container did not.
		let result: Durability
		do {
			switch (record?.state, container) {
			case (nil, nil):
				try commit { registry in
					registry.campaigns[id] = .init(state: .probing, buildNonce: constants.buildNonce, submissions: 0, accountKey: nil, probeLaunches: 1, haltRule: nil)
				}
				writeMarker(.probing)
				result = .probeWritten
			case (.probing?, _?):
				try commit { registry in registry.campaigns[id]?.probeLaunches += 1 }
				result = .stillProbing
			case (.probing?, nil):
				try commit { registry in
					registry.campaigns[id]?.state = .armed
					registry.highestCampaignNumber = max(registry.highestCampaignNumber, constants.campaignNumber)
				}
				writeMarker(.armed)
				result = .armed
			case (.armed?, _):
				writeMarker(.armed)
				result = .armed
			default:
				return refuseLocked("C7", halting: true)
			}
		} catch {
			_ = haltLocked(.ledgerWriteFailed)
			return .refused
		}
		logger?.campaignDurability(registryProbe: record != nil, containerMarker: container != nil, result: result)
		return result
	}

	// MARK: Checks before every live operation

	private func window(_ date: Date) -> String {
		date < constants.notBefore ? "before" : date > constants.notAfter ? "after" : "inside"
	}

	/// C5: the latest authenticated Apple time is inside the window and within
	/// ten minutes of the device clock. Nil when no Apple response has been
	/// seen yet (only sign-in may run then).
	private func authenticatedWindowLocked(required: Bool) throws {
		guard let apple = authenticatedTime() else {
			if required {
				logger?.campaignWindow(device: window(now()), authenticated: "notYetChecked", skewOK: false)
				logger?.campaignCheck("C5", pass: false)
				_ = haltLocked(.campaignCheck)
				throw ZagLiveExperimentRefusal.check("C5")
			}
			return
		}
		let skewOK = abs(apple.timeIntervalSince(now())) <= ZagCampaignConstants.maximumSkew
		logger?.campaignWindow(device: window(now()), authenticated: window(apple), skewOK: skewOK)
		guard window(apple) == "inside", skewOK else {
			logger?.campaignCheck("C5", pass: false)
			_ = haltLocked(.campaignCheck)
			throw ZagLiveExperimentRefusal.check("C5")
		}
		logger?.campaignCheck("C5", pass: true)
	}

	/// Refuses `operation` unless this campaign may run it now. Refusals that
	/// come from a check halt the campaign (E2).
	/// Every operation except a portal mutation, which needs its account and
	/// team (`authorizeMutation`).
	func authorize(_ operation: ZagLiveOperation) throws {
		try lock.withLock { try authorizeLocked(operation, account: nil) }
	}

	/// A mutating portal call (device, App ID, group, profile): the campaign
	/// checks, then C6 (the pinned account, set when E4 found it empty) and
	/// C8 (E4 ran for this account and team in this process).
	func authorizeMutation(accountKey: String, team: String) throws {
		try lock.withLock { try authorizeLocked(.portalMutate, account: (accountKey, team)) }
	}

	private func authorizeLocked(_ operation: ZagLiveOperation, account: (key: String, team: String)?) throws {
		if [.certificateList, .signOut, .inventory].contains(operation) { return }
		if haltedInProcess { throw ZagLiveExperimentRefusal.halted }
		guard constants.isAuthorisable else { throw ZagLiveExperimentRefusal.notArmed }
		guard case .some(let stored) = load(), let record = stored?.campaigns[constants.campaignID] else {
			throw ZagLiveExperimentRefusal.notArmed
		}
		guard record.buildNonce == constants.buildNonce else {
			logger?.campaignCheck("C1", pass: false)
			_ = haltLocked(.campaignCheck)
			throw ZagLiveExperimentRefusal.check("C1")
		}
		if record.state == .halted { throw ZagLiveExperimentRefusal.halted }
		if constants.campaignNumber < (stored?.highestCampaignNumber ?? 0) {
			logger?.campaignCheck("C3", pass: false)
			_ = haltLocked(.campaignCheck)
			throw ZagLiveExperimentRefusal.check("C3")
		}
		switch record.state {
		case .armed:
			break
		case .spent where consumedInThisProcess && operation != .submitCertificate:
			break
		case .spent, .closed:
			if operation == .submitCertificate {
				logger?.certBudget(before: record.submissions, state: record.state, pin: nil, decision: "budgetSpent")
				_ = haltLocked(.budgetSpent)
				throw ZagLiveExperimentRefusal.certificateBudgetSpent
			}
			throw ZagLiveExperimentRefusal.check("C2")
		case .none, .probing, .halted:
			throw ZagLiveExperimentRefusal.notArmed
		}
		guard window(now()) == "inside" else {
			logger?.campaignCheck("C4", pass: false)
			_ = haltLocked(.campaignCheck)
			throw ZagLiveExperimentRefusal.check("C4")
		}
		try authenticatedWindowLocked(required: operation != .signIn)
		if operation == .portalMutate {
			guard let account else {
				logger?.campaignCheck("C8", pass: false)
				_ = haltLocked(.accountNotEmpty)
				throw ZagLiveExperimentRefusal.check("C8")
			}
			try checkPinLocked(account.key)
			guard verifiedAccounts.contains(Self.verificationKey(account.key, account.team)) else {
				logger?.campaignCheck("C8", pass: false)
				_ = haltLocked(.accountNotEmpty)
				throw ZagLiveExperimentRefusal.check("C8")
			}
		}
	}

	// MARK: C6 and C8

	/// C5 as the bridge enforced it (`zag_bridge_time_gate_status`): 3–8
	/// mean a response's Date was missing, malformed, outside the window or
	/// too far from the device clock, and nothing after it reached Apple.
	/// That is recorded as C5 refused, and halts.
	/// When signed in, the gate must also have verified a Date (status 1):
	/// unconfigured or still pending means the window was never enforced.
	func checkTimeGate(_ status: Int32, signedIn: Bool = false) throws {
		guard (3...8).contains(status) || (signedIn && status != 1) else { return }
		lock.withLock {
			let authenticated = status == 5 ? "before" : status == 6 ? "after" : nil
			logger?.campaignWindow(device: window(now()), authenticated: authenticated, skewOK: status == 7 ? false : nil)
			logger?.campaignCheck("C5", pass: false)
			_ = haltLocked(.campaignCheck)
		}
		throw ZagLiveExperimentRefusal.check("C5")
	}

	/// C6 at sign-in: a pinned campaign accepts only its own account.
	func checkAccount(_ accountKey: String) throws {
		try lock.withLock { try checkPinLocked(accountKey) }
	}

	/// C6: once an account is pinned, only that account may act.
	private func checkPinLocked(_ accountKey: String) throws {
		guard case .some(let stored) = load(), let record = stored?.campaigns[constants.campaignID] else { return }
		guard let pinned = record.accountKey else { return }
		if pinned == accountKey {
			logger?.campaignAccountPin("matches")
			logger?.campaignCheck("C6", pass: true)
			return
		}
		logger?.campaignAccountPin("mismatch")
		logger?.campaignCheck("C6", pass: false)
		_ = haltLocked(.accountMismatch)
		throw ZagLiveExperimentRefusal.accountMismatch
	}


	/// C8 / E4 before an account's first mutating portal call: the account
	/// is the pinned one (C6), or becomes it (the pin is written and read
	/// back here, before any mutation), and its team has no certificate, no
	/// App ID and no device. A relaunch checks again (and then finds this
	/// run's own device: a stop).
	func verifyAccountState(accountKey: String, team: String, certificates: Int, appIDs: Int, devices: Int) throws {
		try lock.withLock {
			try checkPinLocked(accountKey)
			let empty = certificates == 0 && appIDs == 0 && devices == 0
			logger?.certPreflight(certificates: certificates, appIDs: appIDs, devices: devices, ok: empty)
			guard empty else {
				logger?.campaignCheck("C8", pass: false)
				_ = haltLocked(.accountNotEmpty)
				throw ZagLiveExperimentRefusal.check("C8")
			}
			let id = constants.campaignID
			guard case .some(let stored) = load(), let record = stored?.campaigns[id], record.state == .armed || record.accountKey == accountKey else {
				logger?.campaignCheck("C8", pass: false)
				_ = haltLocked(.accountNotEmpty)
				throw ZagLiveExperimentRefusal.check("C8")
			}
			if record.accountKey == nil {
				do {
					try commit { registry in registry.campaigns[id]?.accountKey = accountKey }
				} catch {
					_ = haltLocked(.ledgerWriteFailed)
					throw ZagLiveExperimentRefusal.ledgerWriteFailed
				}
				logger?.campaignAccountPin("pinnedNow")
			}
			logger?.campaignCheck("C8", pass: true)
			verifiedAccounts.insert(Self.verificationKey(accountKey, team))
		}
	}

	func needsAccountStateCheck(accountKey: String, team: String) -> Bool {
		lock.withLock { !verifiedAccounts.contains(Self.verificationKey(accountKey, team)) }
	}

	private static func verificationKey(_ accountKey: String, _ team: String) -> String { accountKey + "\n" + team }

	// MARK: The budget (E1), through ZagCertificateBudget only

	/// Lets exactly one certificate request through for this campaign, and
	/// records it (and the account pin) before returning. Called only by
	/// `ZagCertificateBudget.consume` (a static test checks this).
	func recordSubmission(accountKey: String, team: String, certificatesNow: Int) throws {
		try lock.withLock {
			let id = constants.campaignID
			guard case .some(let stored) = load(), let record = stored?.campaigns[id] else {
				logger?.certBudget(before: 0, state: .none, pin: nil, decision: "halted")
				throw ZagLiveExperimentRefusal.notArmed
			}
			let pin = record.accountKey == nil ? "pinnedNow" : record.accountKey == accountKey ? "matches" : "mismatch"
			if record.state == .halted || haltedInProcess {
				logger?.certBudget(before: record.submissions, state: record.state, pin: pin, decision: "halted")
				throw ZagLiveExperimentRefusal.halted
			}
			guard record.submissions == 0, record.state == .armed else {
				logger?.certBudget(before: record.submissions, state: record.state, pin: pin, decision: "budgetSpent")
				_ = haltLocked(.budgetSpent)
				throw ZagLiveExperimentRefusal.certificateBudgetSpent
			}
			if pin == "mismatch" {
				logger?.certBudget(before: record.submissions, state: record.state, pin: pin, decision: "accountMismatch")
				logger?.campaignAccountPin("mismatch")
				_ = haltLocked(.accountMismatch)
				throw ZagLiveExperimentRefusal.accountMismatch
			}
			guard verifiedAccounts.contains(Self.verificationKey(accountKey, team)), certificatesNow == 0 else {
				logger?.campaignCheck("C8", pass: false)
				logger?.certBudget(before: record.submissions, state: record.state, pin: pin, decision: "halted")
				_ = haltLocked(.accountNotEmpty)
				throw ZagLiveExperimentRefusal.check("C8")
			}
			do {
				try commit { registry in
					registry.campaigns[id]?.submissions = 1
					registry.campaigns[id]?.state = .spent
					registry.campaigns[id]?.accountKey = accountKey
				}
			} catch {
				logger?.certBudget(before: record.submissions, state: record.state, pin: pin, decision: "ledgerWriteFailed")
				_ = haltLocked(.ledgerWriteFailed)
				throw ZagLiveExperimentRefusal.ledgerWriteFailed
			}
			writeMarker(.spent)
			consumedInThisProcess = true
			logger?.campaignAccountPin(pin)
			logger?.certBudget(before: 0, state: .armed, pin: pin, decision: "allow")
		}
	}

	/// C1–C5 and C8 again immediately before consuming (plan §5.5). Called
	/// only by `ZagCertificateBudget.consume`.
	func authorizeSubmission() throws {
		try lock.withLock { try authorizeLocked(.submitCertificate, account: nil) }
	}

	// MARK: E3

	/// Abandoning an unresolved certificate request is refused for the whole
	/// campaign (E3). Tests may open it to prove E1 still refuses (T7).
	var refusesAbandon: Bool {
		#if ZAG_G5_TESTS
		return !ZagLiveExperiment.testAllowsAbandon
		#else
		return true
		#endif
	}
}

/// The process-wide experiment objects of the app build.
enum ZagLiveExperiment {
	/// Everything the experiment keeps in the container (the marker, the log).
	static var containerDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return base.appendingPathComponent("ZagStore.accounts.live-test", isDirectory: true)
	}

	static let accountNamespace = "ZagStore.accounts.live-test"
	static let testBundleIdentifier = "com.zagstore.livetest.hello"

	#if ZAG_G5_TESTS
	nonisolated(unsafe) static var logger: ZagExperimentLogger? = nil
	nonisolated(unsafe) static var campaign = ZagLiveExperimentCampaign(registry: MemoryCampaignRegistry(), marker: MemoryCampaignMarker())
	nonisolated(unsafe) static var testAllowsAbandon = false
	#else
	static let logger: ZagExperimentLogger? = ZagExperimentLogger.live()
	static let campaign = ZagLiveExperimentCampaign(logger: logger, authenticatedTime: {
		let seconds = zag_bridge_last_apple_date()
		return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
	})
	#endif
}

#if ZAG_G5_TESTS
/// Tests only: the registry in memory, surviving "reinstalls" like the
/// Keychain, with failures on demand.
final class MemoryCampaignRegistry: ZagCampaignRegistryStore, @unchecked Sendable {
	private let lock = NSLock()
	private var data: Data?
	var failWrites = false
	var corruptReadBack = false
	var failReads = false
	var writes = 0
	func read() throws -> Data? {
		try lock.withLock {
			if failReads { throw ZagCampaignStoreError.file }
			if corruptReadBack, let data { return data + Data([0x20]) }
			return data
		}
	}
	func write(_ data: Data) throws {
		try lock.withLock {
			if failWrites { throw ZagCampaignStoreError.file }
			self.data = data
			writes += 1
		}
	}
	func wipe() { lock.withLock { data = nil } }
	var stored: Data? { lock.withLock { data } }
}

/// Tests only: the container marker; `wipe` is deleting the app.
final class MemoryCampaignMarker: ZagCampaignMarkerStore, @unchecked Sendable {
	private let lock = NSLock()
	private var data: Data?
	func read() -> Data? { lock.withLock { data } }
	func write(_ data: Data) throws { lock.withLock { self.data = data } }
	func wipe() { lock.withLock { data = nil } }
}
#endif
#endif
