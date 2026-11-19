#if ZAG_LIVE_EXPERIMENT
import CryptoKit
import Foundation
import Security

// G5: the experiment's typed diagnostic record (G5-DIAGNOSTIC-LOGGING-SPEC.md).
//
// Every event is a typed record whose every field has one declared format
// (§7.1). Free text from Apple, the anisette provider, the device or Rust is
// never stored: callers pass enum members, bounded integers, booleans and
// tokens only, and anything that fails the schema is dropped and replaced by
// `logger.rejected`. Nothing here sends anything anywhere: the record stays
// in the app container until the owner exports it.

/// One field's declared format (§7.1).
enum ZagLogFormat: Sendable {
	case oneOf(Set<String>)
	case int(ClosedRange<Int>)
	case bool
	case sha8
	case ref8
	case campaign
	case host
	case template
	case list(Set<String>)
}

enum ZagLogValue: Codable, Equatable, Sendable {
	case string(String)
	case int(Int)
	case bool(Bool)
	case list([String])

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode(Int.self) { self = .int(value) }
		else if let value = try? container.decode(String.self) { self = .string(value) }
		else { self = .list(try container.decode([String].self)) }
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .string(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .bool(let value): try container.encode(value)
		case .list(let value): try container.encode(value)
		}
	}
}

/// One stored event (§2).
struct ZagLogEvent: Codable, Equatable, Sendable {
	var seq: Int
	var t: Int
	var phase: String
	var event: String
	var outcome: String
	var durationMs: Int?
	var failure: String?
	var fields: [String: ZagLogValue]?
	var stopRule: String?
}

/// The schema: envelope enums, field formats and the events of §4.
enum ZagLogSchema {
	static let outcomes: Set<String> = ["started", "ok", "failed", "cancelled", "skipped", "blocked", "stopped"]

	/// The closed `failure` enum (§6).
	static let failures: Set<String> = [
		"network.offline", "network.timeout", "network.tls", "policy.blocked",
		"http.4xx", "http.5xx", "http.429",
		"apple.authFailed", "apple.accountLocked", "apple.twoFactorRejected", "apple.twoFactorLimit", "apple.sessionRejected", "apple.unexpectedResponse",
		"anisette.unavailable", "anisette.provisioningFailed", "anisette.invalidHeaders",
		"portal.rateLimited", "portal.deviceLimit", "portal.appIDCapacity", "portal.identifierUnavailable", "portal.certificateLimit", "portal.unexpectedResponse",
		"cert.unresolved", "cert.possessionMismatch", "cert.budgetSpent", "cert.ledgerWriteFailed",
		"experiment.halted", "experiment.accountMismatch", "experiment.notArmed",
		"profile.invalid", "sign.failed", "sign.verifyFailed",
		"install.refused", "install.unknown", "install.transport",
		"readback.unavailable", "keychain.storage", "cancelled", "deadline", "internal",
	]

	static let stopRules = Set(ZagStopRule.allCases.map(\.rawValue))
	static let states: Set<String> = Set(ZagCampaignState.allCases.map(\.rawValue))
	static let readback: Set<String> = ["verified", "mismatch", "notVerified", "unavailable"]
	static let unavailableReasons: Set<String> = ["pairing", "tunnel", "misagent", "timeout", "other"]
	static let conditions: Set<String> = ["ZAG_APPLE_BRIDGE", "ZAG_ZSIGN_STRICT", "ZAG_LIVE_EXPERIMENT"]
	static let checks: Set<String> = ["C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8"]
	static let windows: Set<String> = ["inside", "before", "after"]
	static let pins: Set<String> = ["pinnedNow", "matches", "mismatch"]
	static let entitlementNames: Set<String> = [
		"application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups",
		"com.apple.security.application-groups", "aps-environment", "unlisted",
	]

	/// Path templates (§4.4). Anything else is `unlisted`.
	static let templates: Set<String> = [
		"/grandslam/GsService2", "/grandslam/GsService2/lookup", "/auth/verify/trusteddevice", "/auth/verify/phone",
		"/auth/verify/phone/securitycode", "/services/QH65B2/{op}.action", "/services/v1/{resource}",
		"/v3/client_info", "/v3/get_headers", "/v3/provisioning_session", "unlisted",
	]
	static let portalOperations: Set<String> = [
		"listTeams", "viewDeveloper", "ios/listDevices", "ios/addDevice", "ios/listAppIds", "ios/addAppId",
		"ios/listApplicationGroups", "ios/addApplicationGroup", "ios/assignApplicationGroupToAppId",
		"ios/listAllDevelopmentCerts", "ios/submitDevelopmentCSR", "ios/downloadTeamProvisioningProfile",
	]
	static let v1Resources: Set<String> = ["certificates", "devices", "bundleIds", "profiles"]

	static let count = ZagLogFormat.int(0...500)
	static let ms = ZagLogFormat.int(0...600_000)

	/// Every event and its fields (§4). An event not listed is rejected.
	static let events: [String: [String: ZagLogFormat]] = [
		"build.identity": [
			"campaignID": .campaign, "branchSHA8": .sha8, "bridgeLibSHA8": .sha8, "zsignSHA8": .sha8, "installID8": .sha8,
			"conditions": .list(conditions), "debugCompiled": .oneOf(["false"]),
		],
		"build.configureLive": ["providerHost": .host, "serialPolicy": .oneOf(["g3Fixed", "g3PerAccount"])],
		"campaign.durability": [
			"registryProbe": .oneOf(["present", "absent"]), "containerMarker": .oneOf(["present", "absent"]),
			"result": .oneOf(["probeWritten", "stillProbing", "armed"]),
		],
		"campaign.state": ["from": .oneOf(states), "to": .oneOf(states), "reason": .oneOf(stopRules.union(["consume", "end", "e5Proof", "probe"]))],
		"campaign.check": ["check": .oneOf(checks), "result": .oneOf(["pass", "refuse"])],
		"campaign.window": [
			"deviceClock": .oneOf(windows), "authenticated": .oneOf(windows.union(["notYetChecked"])), "skewWithinTenMinutes": .bool,
		],
		"campaign.registryWrite": ["readBackMatches": .bool],
		"campaign.accountPin": ["result": .oneOf(pins)],
		"transport.preflight.tunnel": ["vpnInterfacePresent": .bool, "endpointAccepted": .bool, "latencyMs": ms],
		"transport.preflight.pairing": ["pairingPresent": .bool, "pairVerify": .oneOf(["ok", "failed", "notRun"])],
		"transport.preflight.developerMode": ["confirmedByOwner": .bool],
		"readback.preflight": [
			"result": .oneOf(readback), "unavailableReason": .oneOf(unavailableReasons), "installedProfileCount": count, "ownProfileFound": .bool,
		],
		"anisette.clientInfo": ["httpStatus": .int(100...599)],
		"anisette.provisioning.start": ["adiStatePresent": .bool],
		"anisette.provisioning.step": [
			"step": .oneOf(["lookup", "wsConnect", "giveIdentifier", "startMachineProvisioning", "giveStartData", "finishMachineProvisioning", "giveEndData", "success"]),
			"httpStatus": .int(100...599),
		],
		"anisette.provisioning.end": ["adiStateStored": .bool],
		"anisette.headers": ["headerSetValid": .bool, "headerCount": count, "fresh": .bool],
		"net.request": [
			"client": .oneOf(["apple", "anisette"]), "host": .host, "pathTemplate": .template, "method": .oneOf(["GET", "POST", "PUT", "DELETE"]),
			"scheme": .oneOf(["https", "wss"]), "decision": .oneOf(["allowed", "blocked"]),
			"blockReason": .oneOf(["hostNotAllowed", "notSecure", "credentialsInURL", "portInURL", "redirect", "disabled", "invalidURL"]),
		],
		"net.response": ["status": .int(100...599), "sizeBucket": .oneOf(sizeBuckets), "contentKind": .oneOf(["plist", "json", "other"])],
		"net.tls": ["tlsFailure": .oneOf(["untrusted", "expired", "hostname", "other"])],
		"net.lookup": ["key": .oneOf(["unlisted"]), "decision": .oneOf(["allowed", "blocked"]), "host": .host],
		"auth.signin.start": [:],
		"auth.srp": ["step": .oneOf(["init", "complete"])],
		"auth.state": [
			"from": .oneOf(authStates), "to": .oneOf(authStates),
		],
		"auth.twoFactor.challenge": ["kind": .oneOf(["trustedDevice", "sms", "unknown"]), "smsNumberCount": .int(0...10)],
		"auth.twoFactor.request": ["kind": .oneOf(["trustedDevice", "sms", "unknown"])],
		"auth.twoFactor.submit": ["result": .oneOf(["accepted", "rejected"]), "attemptsRemaining": .int(0...3)],
		"auth.twoFactor.limit": ["reason": .oneOf(["tooManyCodes", "locked", "rateLimited"])],
		"auth.session.validate": ["expiryUnit": .oneOf(["seconds", "milliseconds", "invalid"]), "expiresInHours": .int(0...8_760)],
		"auth.session.store": ["keychainAccessible": .oneOf(["afterFirstUnlockThisDeviceOnly", "other"])],
		"auth.signout": ["itemsRemoved": count],
		"portal.teams": ["teamCount": count, "teamKind": .oneOf(["personal", "paid", "unknown"]), "teamRef": .ref8],
		"portal.device": ["step": .oneOf(["list", "register"]), "registeredDeviceCount": count, "deviceRef": .ref8, "deviceMatchesPairing": .bool],
		"portal.appid": ["step": .oneOf(["list", "register"]), "appIDCount": count, "appIDRef": .ref8, "capacityRemaining": count],
		"portal.rateLimit": ["operation": .oneOf(["teams", "device", "appid", "certificate", "profile", "group"]), "retryAfterSeconds": .int(0...86_400)],
		"cert.preflight": ["certificateCount": count, "zagAppIDCount": count, "registeredDeviceCount": count, "hasDERContent": .bool],
		"cert.budget": [
			"submissionsBefore": .int(0...1), "ledgerState": .oneOf(states), "accountPin": .oneOf(pins),
			"decision": .oneOf(["allow", "budgetSpent", "accountMismatch", "halted", "ledgerWriteFailed"]),
		],
		"cert.key": [
			"keyClass": .oneOf(["softwareRSA2048"]), "permanent": .bool, "synchronizable": .bool,
			"accessibility": .oneOf(["afterFirstUnlockThisDeviceOnly"]), "extractableAttributeRequested": .bool,
			"privateKeyExportCalls": .int(0...100), "keyFileWritten": .bool,
		],
		"cert.journal": [
			"transition": .oneOf(["pendingCreated", "submissionUnconfirmedSet", "submissionUnconfirmedCleared", "issuedRecorded", "unresolved", "pendingDiscarded"]),
			"attempts": .int(0...10),
		],
		"cert.submit": ["result": .oneOf(["issued", "refused", "unknown"])],
		"cert.verify": ["possessionMatch": .bool, "certRef": .ref8, "expiresInDays": .int(0...400)],
		"cert.recovery": [
			"action": .oneOf(["checkAgain"]), "result": .oneOf(["recovered", "notIssued", "unresolved", "checkFailed"]), "listingCount": count,
		],
		"cert.limit": ["reason": .oneOf(["certificateMustBeRevoked"]), "candidateCount": count],
		"cert.swap": [:],
		"profile.fetch": ["profileRef": .ref8, "sizeBucket": .oneOf(sizeBuckets)],
		"profile.check": [
			"result": .oneOf(["ok", "problem"]), "teamMatches": .bool, "bundleMatches": .bool, "certMatches": .bool, "deviceIncluded": .bool,
			"expiresInHours": .int(0...10_000), "entitlementNames": .list(entitlementNames),
		],
		"sign.start": ["componentCount": .int(0...64), "path": .oneOf(["strictKeychain"])],
		"sign.component": ["index": .int(0...64), "kind": .oneOf(["app", "framework", "extension"])],
		"sign.verify": ["zsignVerify": .oneOf(["ok", "failed"]), "keyFileWritten": .bool],
		"sign.package": ["sizeBucket": .oneOf(sizeBuckets)],
		"install.start": ["transport": .oneOf(["rppairing"]), "network": .oneOf(["wifi", "cellularWithShortcut", "other"])],
		"install.step": ["step": .oneOf(["pairVerify", "tunnel", "rsd", "afcUpload", "installProxy"])],
		"install.result": [
			"result": .oneOf(["installed", "refused", "unknown"]),
			"deviceErrorClass": .oneOf(["signatureInvalid", "profileMissing", "profileExpired", "deviceNotProvisioned", "entitlementMismatch", "other"]),
		],
		"install.launch": ["confirmedByOwner": .bool],
		"install.verify": [
			"result": .oneOf(readback), "unavailableReason": .oneOf(unavailableReasons), "attempt": .int(1...2), "installedProfileCount": count,
		],
		"preflight.account": ["a1": .bool, "a2": .bool, "a3": .bool, "a4": .bool, "a5": .bool, "a6": .bool],
		"inventory.counts": [
			"sessionItems": count, "identityItems": count, "pendingItems": count, "anisetteItems": count, "orphanItems": count, "ledgerRecordsPreserved": .bool,
		],
		"stop.rule": ["haltSet": .bool, "ambiguityOutstanding": .bool],
		"report.export": ["validation": .oneOf(["passed", "blocked"]), "blockedRule": .oneOf(blockedRules), "eventCount": .int(0...2_000)],
		"logger.rejected": ["droppedPhase": .oneOf(phases.union(["unknown"])), "droppedEvent": .oneOf(eventNames.union(["unknown"]))],
	]

	static let sizeBuckets: Set<String> = ["<1 KB", "1–10 KB", "10–100 KB", "100 KB–1 MB", ">1 MB"]
	static let authStates: Set<String> = ["signedOut", "signingIn", "awaitingTwoFactor", "signedIn", "failed"]
	static let blockedRules: Set<String> = ["schema", "R1", "R2", "R3", "R4", "R5", "R6", "R7", "markdown"]

	/// "phase.event" split as stored: the phase is everything before the last dot.
	static func split(_ name: String) -> (phase: String, event: String) {
		let dot = name.lastIndex(of: ".")!
		return (String(name[..<dot]), String(name[name.index(after: dot)...]))
	}

	static let phases: Set<String> = Set(eventNamesList.map { split($0).phase })
	static let eventNames: Set<String> = Set(eventNamesList.map { split($0).event })
	private static let eventNamesList = [
		"build.identity", "build.configureLive", "campaign.durability", "campaign.state", "campaign.check", "campaign.window",
		"campaign.registryWrite", "campaign.accountPin", "transport.preflight.tunnel", "transport.preflight.pairing",
		"transport.preflight.developerMode", "readback.preflight", "anisette.clientInfo", "anisette.provisioning.start",
		"anisette.provisioning.step", "anisette.provisioning.end", "anisette.headers", "net.request", "net.response", "net.tls",
		"net.lookup", "auth.signin.start", "auth.srp", "auth.state", "auth.twoFactor.challenge", "auth.twoFactor.request",
		"auth.twoFactor.submit", "auth.twoFactor.limit", "auth.session.validate", "auth.session.store", "auth.signout",
		"portal.teams", "portal.device", "portal.appid", "portal.rateLimit", "cert.preflight", "cert.budget", "cert.key",
		"cert.journal", "cert.submit", "cert.verify", "cert.recovery", "cert.limit", "cert.swap", "profile.fetch",
		"profile.check", "sign.start", "sign.component", "sign.verify", "sign.package", "install.start", "install.step",
		"install.result", "install.launch", "install.verify", "preflight.account", "inventory.counts", "stop.rule",
		"report.export", "logger.rejected",
	]

	/// The hosts logged verbatim when allowed.
	static func allowedHosts(provider: String?) -> Set<String> {
		Set(["gsa.apple.com", "developerservices2.apple.com"] + (provider.map { [$0] } ?? []))
	}

	/// §4.4: how a host is recorded. Allowed hosts verbatim; a blocked host
	/// verbatim only if it is an ordinary `.apple.com` name; otherwise a class.
	static func recordedHost(_ host: String, provider: String?) -> String {
		let host = host.lowercased()
		if allowedHosts(provider: provider).contains(host) { return host }
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)
		let ordinary = host.count <= 64 && host.hasSuffix(".apple.com")
			&& labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
			&& !labels.contains { $0.count >= 16 && $0.allSatisfy(\.isHexDigit) }
		if ordinary { return host }
		return host.hasSuffix("apple.com") ? "appleUnusual" : "nonApple"
	}

	/// §4.4: the path template; never the path itself.
	static func template(_ path: String) -> String {
		if templates.contains(path) && path != "unlisted" && !path.contains("{") { return path }
		if path.hasPrefix("/services/QH65B2/"), path.hasSuffix(".action") {
			let op = String(path.dropFirst("/services/QH65B2/".count).dropLast(".action".count))
			return portalOperations.contains(op) ? "/services/QH65B2/{op}.action" : "unlisted"
		}
		if path.hasPrefix("/services/v1/") {
			let resource = String(path.dropFirst("/services/v1/".count))
			return v1Resources.contains(resource) ? "/services/v1/{resource}" : "unlisted"
		}
		return "unlisted"
	}

	/// §7.1: whether one value matches its declared format.
	static func accepts(_ value: ZagLogValue, as format: ZagLogFormat, provider: String?) -> Bool {
		switch (format, value) {
		case (.oneOf(let members), .string(let string)): return members.contains(string)
		case (.oneOf(let members), .bool(let bool)): return members.contains(String(bool))
		case (.int(let range), .int(let int)): return range.contains(int)
		case (.bool, .bool): return true
		case (.sha8, .string(let string)), (.ref8, .string(let string)):
			return string.count == 8 && string.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
		case (.campaign, .string(let string)): return string.range(of: #"^G5-C[0-9]{1,3}$"#, options: .regularExpression) != nil
		case (.host, .string(let string)):
			return string == "nonApple" || string == "appleUnusual" || recordedHost(string, provider: provider) == string
		case (.template, .string(let string)): return templates.contains(string)
		case (.list(let members), .list(let list)):
			return list.count <= 64 && list == list.sorted() && Set(list).count == list.count && list.allSatisfy(members.contains)
		default: return false
		}
	}

	/// §7.1 for one whole event. Returns the failing field path, or nil.
	static func violation(_ event: ZagLogEvent, provider: String?) -> String? {
		guard let fields = events["\(event.phase).\(event.event)"] else { return "event" }
		guard (1...2_000).contains(event.seq) else { return "seq" }
		guard (0...86_400_000).contains(event.t) else { return "t" }
		guard outcomes.contains(event.outcome) else { return "outcome" }
		if let duration = event.durationMs, !(0...600_000).contains(duration) || duration % 10 != 0 { return "durationMs" }
		if let failure = event.failure, !failures.contains(failure) { return "failure" }
		if let rule = event.stopRule, !stopRules.contains(rule) { return "stopRule" }
		for (name, value) in event.fields ?? [:] {
			// An undeclared key is reported without its name (it may carry data).
			guard let format = fields[name] else { return "fields.undeclared" }
			guard accepts(value, as: format, provider: provider) else { return "fields.\(name)" }
		}
		return nil
	}
}

/// Where the log lives: JSON Lines in the container, or memory in tests.
protocol ZagExperimentLogStore: AnyObject, Sendable {
	func load() -> [Data]
	func append(_ line: Data)
	func clear()
}

final class ZagFileExperimentLogStore: ZagExperimentLogStore, @unchecked Sendable {
	let url: URL
	init(directory: URL = ZagLiveExperiment.containerDirectory) { url = directory.appendingPathComponent("experiment-log.jsonl") }

	func load() -> [Data] {
		guard let data = try? Data(contentsOf: url) else { return [] }
		return data.split(separator: 0x0A).map { Data($0) }
	}

	func append(_ line: Data) {
		var directory = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? directory.setResourceValues(values)
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: line + Data([0x0A]))
		} else {
			try? (line + Data([0x0A])).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
	}

	func clear() { try? FileManager.default.removeItem(at: url) }
}

final class ZagMemoryExperimentLogStore: ZagExperimentLogStore, @unchecked Sendable {
	private let lock = NSLock()
	private var lines: [Data] = []
	func load() -> [Data] { lock.withLock { lines } }
	func append(_ line: Data) { lock.withLock { lines.append(line) } }
	func clear() { lock.withLock { lines = [] } }
}

/// The per-installation secret for ref tokens (§1.5): 32 random bytes in the
/// live-test Keychain namespace, never exported.
enum ZagExperimentRunKey {
	static let service = "ZagStore.accounts.live-test.runkey"

	static func loadOrCreate(service: String = service) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: "runKey",
			kSecAttrSynchronizable as String: false,
		]
		var result: CFTypeRef?
		if SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result) == errSecSuccess,
		   let data = result as? Data, data.count == 32 {
			return data
		}
		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
		let data = Data(bytes)
		SecItemDelete(query as CFDictionary)
		guard SecItemAdd(query.merging([
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]) { $1 } as CFDictionary, nil) == errSecSuccess else { return nil }
		return data
	}
}

/// The typed recorder. Every method takes typed values only.
final class ZagExperimentLogger: @unchecked Sendable {
	static let maximumEvents = 2_000

	private let lock = NSLock()
	private let store: ZagExperimentLogStore
	private let runKey: SymmetricKey
	private let provider: String?
	private let clock: @Sendable () -> Date
	private var started: Date?
	private var stored: [ZagLogEvent]
	/// Calls to Zag Store's private-key export wrapper (§4.7); expected 0.
	private(set) var privateKeyExportCalls = 0
	let installID8: String

	init(store: ZagExperimentLogStore, runKey: Data, provider: String?, clock: @escaping @Sendable () -> Date = { Date() }) {
		self.store = store
		self.runKey = SymmetricKey(data: runKey)
		self.provider = provider
		self.clock = clock
		installID8 = Self.hex8(HMAC<SHA256>.authenticationCode(for: Data("installID".utf8), using: SymmetricKey(data: runKey)))
		stored = store.load().compactMap { try? JSONDecoder().decode(ZagLogEvent.self, from: $0) }
	}

	#if !ZAG_G5_TESTS
	/// The app's logger: the container file and the Keychain run key. Without
	/// a run key, tokens use a fresh random key (never stored, never linkable).
	static func live() -> ZagExperimentLogger {
		let key = ZagExperimentRunKey.loadOrCreate() ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
		return ZagExperimentLogger(store: ZagFileExperimentLogStore(), runKey: key, provider: ZagCampaignConstants.compiled.providerHost)
	}
	#endif

	private static func hex8<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
		bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
	}

	/// §1.5: HMAC-SHA256(runKey, kind ‖ value), 8 lowercase hex characters.
	func ref(_ kind: String, _ value: String) -> String {
		Self.hex8(HMAC<SHA256>.authenticationCode(for: Data((kind + "\u{0}" + value).utf8), using: runKey))
	}

	var events: [ZagLogEvent] { lock.withLock { stored } }

	/// Records one event, or `logger.rejected` if it fails the schema.
	func record(_ name: String, outcome: String = "ok", durationMs: Int? = nil, failure: String? = nil,
				fields: [String: ZagLogValue] = [:], stopRule: ZagStopRule? = nil) {
		lock.withLock {
			guard stored.count < Self.maximumEvents else { return }
			let now = clock()
			if started == nil { started = now }
			let (phase, event) = ZagLogSchema.events[name] == nil ? ("unknown", "unknown") : ZagLogSchema.split(name)
			var entry = ZagLogEvent(
				seq: stored.count + 1, t: max(0, min(86_400_000, Int(now.timeIntervalSince(started!) * 1_000))),
				phase: phase, event: event, outcome: outcome,
				durationMs: durationMs.map { min(600_000, max(0, ($0 / 10) * 10)) }, failure: failure,
				fields: fields.isEmpty ? nil : fields, stopRule: stopRule?.rawValue
			)
			if ZagLogSchema.violation(entry, provider: provider) != nil {
				let droppedPhase = ZagLogSchema.phases.contains(phase) ? phase : "unknown"
				let droppedEvent = ZagLogSchema.eventNames.contains(event) ? event : "unknown"
				entry = ZagLogEvent(seq: entry.seq, t: entry.t, phase: "logger", event: "rejected", outcome: "skipped",
									fields: ["droppedPhase": .string(droppedPhase), "droppedEvent": .string(droppedEvent)])
			}
			stored.append(entry)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			if let line = try? encoder.encode(entry) { store.append(line) }
		}
	}

	func clear() {
		lock.withLock {
			stored = []
			started = nil
			store.clear()
		}
	}

	/// Counts a call to the private-key export wrapper (none exists in the
	/// experiment build; the L9 mutant calls this).
	func notePrivateKeyExport() { lock.withLock { privateKeyExportCalls += 1 } }

	// MARK: Campaign events (§4.1)

	func campaignCheck(_ check: String, pass: Bool) {
		record("campaign.check", outcome: pass ? "ok" : "blocked", fields: ["check": .string(check), "result": .string(pass ? "pass" : "refuse")])
	}

	func campaignState(from: ZagCampaignState, to: ZagCampaignState, reason: String) {
		record("campaign.state", fields: ["from": .string(from.rawValue), "to": .string(to.rawValue), "reason": .string(reason)])
	}

	func campaignWindow(device: String, authenticated: String?, skewOK: Bool?) {
		var fields: [String: ZagLogValue] = ["deviceClock": .string(device), "authenticated": .string(authenticated ?? "notYetChecked")]
		if let skewOK { fields["skewWithinTenMinutes"] = .bool(skewOK) }
		record("campaign.window", fields: fields)
	}

	func campaignRegistryWrite(ok: Bool, readBackMatches: Bool) {
		record("campaign.registryWrite", outcome: ok ? "ok" : "failed", failure: ok && readBackMatches ? nil : "cert.ledgerWriteFailed",
			   fields: ["readBackMatches": .bool(readBackMatches)])
	}

	func campaignAccountPin(_ result: String) {
		record("campaign.accountPin", fields: ["result": .string(result)])
	}

	func campaignDurability(registryProbe: Bool, containerMarker: Bool, result: ZagLiveExperimentCampaign.Durability) {
		record("campaign.durability", fields: [
			"registryProbe": .string(registryProbe ? "present" : "absent"),
			"containerMarker": .string(containerMarker ? "present" : "absent"),
			"result": .string(result.rawValue),
		])
	}

	func certPreflight(certificates: Int, appIDs: Int, devices: Int, ok: Bool) {
		record("cert.preflight", outcome: ok ? "ok" : "blocked", fields: [
			"certificateCount": .int(min(500, certificates)), "zagAppIDCount": .int(min(500, appIDs)), "registeredDeviceCount": .int(min(500, devices)),
		])
	}

	func certBudget(before: Int, state: ZagCampaignState, pin: String?, decision: String) {
		var fields: [String: ZagLogValue] = ["submissionsBefore": .int(before), "ledgerState": .string(state.rawValue), "decision": .string(decision)]
		if let pin { fields["accountPin"] = .string(pin) }
		let failure: String? = switch decision {
		case "allow": nil
		case "budgetSpent": "cert.budgetSpent"
		case "accountMismatch": "experiment.accountMismatch"
		case "ledgerWriteFailed": "cert.ledgerWriteFailed"
		default: "experiment.halted"
		}
		record("cert.budget", outcome: decision == "allow" ? "ok" : "blocked", failure: failure, fields: fields)
	}

	func stop(_ rule: ZagStopRule, haltSet: Bool, ambiguityOutstanding: Bool = false) {
		record("stop.rule", outcome: "stopped", fields: ["haltSet": .bool(haltSet), "ambiguityOutstanding": .bool(ambiguityOutstanding)], stopRule: rule)
	}

	// MARK: Network (§4.4), from the bridge's policy observer

	/// Records the bridge's policy decisions (`zag_bridge_take_policy_decisions`).
	/// Returns whether any was blocked (a stop rule).
	@discardableResult
	func recordPolicyDecisions(_ json: Data) -> Bool {
		struct Decision: Decodable { let host: String; let path: String; let method: String; let scheme: String; let allowed: Bool; let reason: String? }
		guard let decisions = try? JSONDecoder().decode([Decision].self, from: json) else { return false }
		var blocked = false
		for decision in decisions {
			var fields: [String: ZagLogValue] = [
				"client": .string(decision.scheme == "wss" || decision.host == provider ? "anisette" : "apple"),
				"host": .string(ZagLogSchema.recordedHost(decision.host, provider: provider)),
				"pathTemplate": .string(ZagLogSchema.template(decision.path)),
				"method": .string(decision.method), "scheme": .string(decision.scheme),
				"decision": .string(decision.allowed ? "allowed" : "blocked"),
			]
			if let reason = decision.reason { fields["blockReason"] = .string(reason) }
			record("net.request", outcome: decision.allowed ? "ok" : "blocked", failure: decision.allowed ? nil : "policy.blocked", fields: fields)
			blocked = blocked || !decision.allowed
		}
		return blocked
	}
}

/// §4.7 `keyFileWritten`: files under the temporary and caches directories
/// holding a private key (PEM headers, or PKCS #1 / PKCS #8 DER). Compared
/// before and after signing; a new one is a safety failure.
enum ZagExperimentKeyFileScan {
	static func keyFiles(in roots: [URL] = [FileManager.default.temporaryDirectory]
		+ FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)) -> Set<String> {
		var found: Set<String> = []
		for root in roots {
			guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
			for case let url as URL in walker {
				guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
					  let size = values.fileSize, size > 0, size < 64 * 1024,
					  let handle = try? FileHandle(forReadingFrom: url) else { continue }
				let head = (try? handle.read(upToCount: 4_096)) ?? Data()
				try? handle.close()
				if isKey(head) { found.insert(url.path) }
			}
		}
		return found
	}

	static func isKey(_ head: Data) -> Bool {
		if let text = String(data: head.prefix(64), encoding: .ascii),
		   text.contains("PRIVATE KEY-----") || text.contains("BEGIN RSA PRIVATE") || text.contains("BEGIN EC PRIVATE") {
			return true
		}
		let bytes = [UInt8](head.prefix(32))
		guard bytes.count >= 12, bytes[0] == 0x30, bytes[1] == 0x82 else { return false }
		// PKCS #1 RSAPrivateKey: SEQUENCE { INTEGER 0, INTEGER (modulus) ... }
		if bytes[4] == 0x02, bytes[5] == 0x01, bytes[6] == 0x00, bytes[7] == 0x02 { return true }
		// PKCS #8 PrivateKeyInfo: SEQUENCE { INTEGER 0, SEQUENCE { OID ... } }
		if bytes[4] == 0x02, bytes[5] == 0x01, bytes[6] == 0x00, bytes[7] == 0x30 { return true }
		return false
	}
}

/// §6: the closed failure enum, mapped by total switches (no `default`), so
/// a new error case cannot compile without a mapping (L5).
enum ZagExperimentFailureMap {
	static func failure(_ kind: ZagProvisioningFailure.Kind) -> String {
		switch kind {
		case .invalidRequest: "internal"
		case .notAuthorized: "experiment.notArmed"
		case .installSlotsFull: "portal.appIDCapacity"
		case .deviceLimitReached: "portal.deviceLimit"
		case .appIDCapacityExhausted: "portal.appIDCapacity"
		case .identifierUnavailable: "portal.identifierUnavailable"
		case .certificateMustBeRevoked: "portal.certificateLimit"
		case .certificateRequestUnresolved: "cert.unresolved"
		case .invalidProfile: "profile.invalid"
		case .keyStorage: "keychain.storage"
		case .sessionRejected: "apple.sessionRejected"
		case .network: "network.offline"
		case .rateLimited: "portal.rateLimited"
		case .unexpectedResponse: "portal.unexpectedResponse"
		case .timedOut: "deadline"
		case .cancelled: "cancelled"
		case .unavailable: "experiment.notArmed"
		}
	}

	static func failure(_ kind: ZagFreeAccountFailure.Kind) -> String {
		switch kind {
		case .invalidCredentials: "apple.authFailed"
		case .twoFactorRejected: "apple.twoFactorRejected"
		case .accountLocked: "apple.accountLocked"
		case .rateLimited: "apple.twoFactorLimit"
		case .network: "network.offline"
		case .anisetteUnavailable: "anisette.unavailable"
		case .unexpectedResponse: "apple.unexpectedResponse"
		case .cancelled: "cancelled"
		case .differentAccount: "experiment.accountMismatch"
		case .unavailable: "experiment.notArmed"
		case .addressNotRecognised: "experiment.accountMismatch"
		}
	}

	static func failure(_ error: ZagPortalError) -> String {
		switch error {
		case .sessionRejected: "apple.sessionRejected"
		case .network: "network.offline"
		case .rateLimited: "portal.rateLimited"
		case .malformedResponse: "portal.unexpectedResponse"
		case .identifierUnavailable: "portal.identifierUnavailable"
		case .deviceLimitReached: "portal.deviceLimit"
		case .appIDLimitReached: "portal.appIDCapacity"
		case .certificateLimitReached: "portal.certificateLimit"
		case .livePortalDisabled: "experiment.notArmed"
		}
	}

	static func failure(_ refusal: ZagLiveExperimentRefusal) -> String {
		switch refusal {
		case .notArmed: "experiment.notArmed"
		case .halted: "experiment.halted"
		case .certificateBudgetSpent: "cert.budgetSpent"
		case .accountMismatch: "experiment.accountMismatch"
		case .ledgerWriteFailed: "cert.ledgerWriteFailed"
		case .check: "experiment.halted"
		case .abandonRefused: "experiment.halted"
		}
	}

	static func failure(_ failure: ZagBridgeFailure) -> String {
		switch failure {
		case .disabled, .notConfigured, .unsupported: "experiment.notArmed"
		case .network: "network.offline"
		case .rejected: "apple.authFailed"
		case .twoFactorRejected: "apple.twoFactorRejected"
		case .rateLimited: "portal.rateLimited"
		case .cancelled: "cancelled"
		case .sessionExpired, .notSignedIn: "apple.sessionRejected"
		case .refused, .malformed, .busy, .invalidInput: "apple.unexpectedResponse"
		}
	}

	static func failure(_ error: ZagAuthenticationServiceError) -> String {
		switch error {
		case .invalidCredentials: "apple.authFailed"
		case .twoFactorRejected: "apple.twoFactorRejected"
		case .accountLocked: "apple.accountLocked"
		case .rateLimited: "apple.twoFactorLimit"
		case .network: "network.offline"
		case .malformedResponse: "apple.unexpectedResponse"
		case .liveAuthenticationDisabled: "experiment.notArmed"
		}
	}

	static func failure(_ error: ZagAnisetteError) -> String {
		switch error {
		case .providerUnavailable: "anisette.unavailable"
		case .invalidResponse: "anisette.invalidHeaders"
		case .timedOut: "network.timeout"
		case .cancelled: "cancelled"
		case .liveProvidersDisabled: "anisette.unavailable"
		}
	}
}
#endif
