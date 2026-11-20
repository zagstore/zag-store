#if ZAG_LIVE_EXPERIMENT
import Foundation

// G5: the structured report the owner exports (logging spec §7, §8).
//
// The report is built from the validated events only. Export validates every
// event against the schema again (§7.1), then applies the content rules
// R1–R7 to the only values with free-form characters: hosts logged verbatim
// and every key name (§7.2). Any failure blocks the whole export; the
// offending value is never shown. The Markdown is generated from the JSON by
// one fixed template, regenerated and compared before anything is written.

struct ZagExperimentReport: Equatable, Sendable {
	static let schema = "zag-g5-report/2"

	enum Verdict: String, Sendable { case pass = "PASS", incomplete = "INCOMPLETE", safeStop = "SAFE STOP", unresolvedStop = "UNRESOLVED STOP", safetyFailure = "SAFETY FAILURE" }

	struct Header: Equatable, Sendable {
		var campaignID: String
		var installID8: String
		var branchSHA8: String
		var bridgeLibSHA8: String
		var zsignSHA8: String
		var ipaSHA8: String
		/// Rounded down to the hour.
		var startedAtUTC: Date
		/// major.minor only.
		var iOS: String
		/// A model class, no identifiers.
		var device: String
		var gates: [String: Bool]
		var providerHost: String
		var serialPolicy: String
		var conditions: [String]
	}

	let header: Header
	let events: [ZagLogEvent]
	let privateKeyExportCalls: Int

	// MARK: Verdict (build plan §7.2)

	private func all(_ name: String) -> [ZagLogEvent] {
		let (phase, event) = ZagLogSchema.split(name)
		return events.filter { $0.phase == phase && $0.event == event }
	}

	private func string(_ event: ZagLogEvent?, _ field: String) -> String? {
		if case .string(let value)? = event?.fields?[field] { return value }
		return nil
	}

	private func bool(_ event: ZagLogEvent?, _ field: String) -> Bool? {
		if case .bool(let value)? = event?.fields?[field] { return value }
		return nil
	}

	var certificateRequestsSent: Int { all("cert.budget").filter { string($0, "decision") == "allow" }.count }
	var certificatesIssued: Int { all("cert.submit").filter { string($0, "result") == "issued" }.count }
	var blockedRequests: Int { all("net.request").filter { string($0, "decision") == "blocked" }.count }
	var keyFileWritten: Bool { (all("sign.verify") + all("cert.key")).contains { bool($0, "keyFileWritten") == true } }
	var preflightVerification: String { string(all("readback.preflight").last, "result") ?? "notReached" }
	var installVerification: String { string(all("install.verify").last, "result") ?? "notReached" }
	var launched: Bool { all("install.launch").contains { bool($0, "confirmedByOwner") == true } }
	var stops: [ZagLogEvent] { all("stop.rule") }
	var unresolved: Bool {
		all("cert.journal").contains { string($0, "transition") == "unresolved" } || stops.contains { bool($0, "ambiguityOutstanding") == true }
	}

	var verdict: Verdict {
		if certificateRequestsSent > 1 || certificatesIssued > 1 || privateKeyExportCalls > 0 || keyFileWritten {
			return .safetyFailure
		}
		if !stops.isEmpty { return unresolved ? .unresolvedStop : .safeStop }
		if blockedRequests > 0 { return .safeStop }
		let complete = preflightVerification == "verified" && certificateRequestsSent == 1 && certificatesIssued == 1 && launched
		if complete && installVerification == "verified" { return .pass }
		return .incomplete
	}

	var firstFailure: ZagLogEvent? { events.first { $0.failure != nil } }

	// MARK: Validation (§7)

	enum Validation: Error, Equatable, Sendable {
		case passed
		/// A §7.1 field path and rule, or R1–R7. Never the offending value.
		case blocked(String)
	}

	/// §7.2 content rules for one free-form value (a verbatim host or a key name).
	/// R1–R7 (logging spec §7.2) for a free-form value. `declaredKey` is true
	/// only for a field name the schema declares for that event; such a name
	/// is exempt from R5 alone (camelCase names such as
	/// `extractableAttributeRequested` are long letter runs). Every other
	/// value gets the spec's R5 unchanged: any run of 24 or more base64
	/// characters, letters only included.
	static func contentRule(_ value: String, declaredKey: Bool = false) -> String? {
		let lowered = value.lowercased()
		if value.contains("@") { return "R1" }
		if value.contains("-----BEGIN") { return "R2" }
		if lowered.contains("x-apple-") || lowered.contains("x-mme-") { return "R3" }
		if value.range(of: "^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$", options: .regularExpression) != nil { return "R6" }
		if value.range(of: "[0-9A-Fa-f]{16,}", options: .regularExpression) != nil { return "R4" }
		if !declaredKey, value.range(of: "[A-Za-z0-9+/=]{24,}", options: .regularExpression) != nil { return "R5" }
		let prohibited = ["password", "dsid", "token", "adi", "udid", "serial", "ecid", "imei", "cookie", "authorization", "spim", "cpim", "ptm", "tk", "salt"]
		if prohibited.contains(lowered) || prohibited.contains(where: { lowered == $0 + "s" }) { return "R7" }
		return nil
	}

	/// Validates every event (§7.1), then the content rules (§7.2) unless
	/// `contentRules` is false (L2 proves §7.1 alone suffices).
	static func validate(_ events: [ZagLogEvent], provider: String?, contentRules: Bool = true) -> Validation {
		for (index, event) in events.enumerated() {
			if let field = ZagLogSchema.violation(event, provider: provider) { return .blocked("schema:\(index).\(field)") }
			guard contentRules else { continue }
			let declared = ZagLogSchema.events["\(event.phase).\(event.event)"] ?? [:]
			for (key, value) in event.fields ?? [:] {
				if let rule = contentRule(key, declaredKey: declared[key] != nil) { return .blocked(rule) }
				if key == "host" || key == "providerHost", case .string(let host) = value, !ZagLogSchema.allowedHosts(provider: provider).contains(host),
				   host != "nonApple", host != "appleUnusual", let rule = contentRule(host) {
					return .blocked(rule)
				}
			}
		}
		return .passed
	}

	// MARK: Rendering

	/// The JSON report (§8). Keys sorted; the events exactly as stored.
	func json() throws -> Data {
		struct Body: Encodable {
			let schema: String
			let header: [String: ZagLogValue]
			let gates: [String: Bool]
			let campaign: [String: ZagLogValue]
			let verdict: [String: ZagLogValue]
			let summary: [String: [String: Int]]
			let events: [ZagLogEvent]
		}
		let formatter = ISO8601DateFormatter()
		formatter.timeZone = TimeZone(identifier: "UTC")
		let hour = Date(timeIntervalSince1970: (header.startedAtUTC.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
		var verdictFields: [String: ZagLogValue] = [
			"class": .string(verdict.rawValue),
			"certificateRequestsSent": .int(certificateRequestsSent), "certificatesIssued": .int(certificatesIssued),
			"certificatesRevoked": .int(0), "blockedRequests": .int(blockedRequests),
			"privateKeyExportCalls": .int(privateKeyExportCalls), "keyFileWritten": .bool(keyFileWritten),
			"preflightVerification": .string(preflightVerification), "installVerification": .string(installVerification),
		]
		if let rule = stops.first?.stopRule { verdictFields["stopRule"] = .string(rule) }
		if let first = firstFailure {
			verdictFields["firstFailure"] = .string("\(first.seq) \(first.phase).\(first.event) \(first.failure ?? "")")
		}
		var summary: [String: [String: Int]] = [:]
		for event in events {
			summary[event.phase, default: [:]][event.outcome, default: 0] += 1
		}
		let states = all("campaign.state")
		let body = Body(
			schema: Self.schema,
			header: [
				"campaignID": .string(header.campaignID), "installID8": .string(header.installID8),
				"branchSHA8": .string(header.branchSHA8), "bridgeLibSHA8": .string(header.bridgeLibSHA8),
				"zsignSHA8": .string(header.zsignSHA8), "ipaSHA8": .string(header.ipaSHA8),
				"startedAtUTC": .string(formatter.string(from: hour)), "iOS": .string(header.iOS), "device": .string(header.device),
				"providerHost": .string(header.providerHost), "serialPolicy": .string(header.serialPolicy),
				"conditions": .list(header.conditions.sorted()), "debugCompiled": .bool(false),
			],
			gates: header.gates,
			campaign: [
				"durability": .string(string(all("campaign.durability").last, "result") ?? "notRecorded"),
				"ledgerStateAtEnd": .string(string(states.last, "to") ?? "unchanged"),
				"accountPin": .string(string(all("campaign.accountPin").last, "result") ?? "notPinned"),
			],
			verdict: verdictFields,
			summary: summary,
			events: events
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		return try encoder.encode(body)
	}

	/// The Markdown report, generated only from the JSON by a fixed template.
	static func markdown(fromJSON data: Data) -> String? {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  object["schema"] as? String == schema,
			  let header = object["header"] as? [String: Any], let gates = object["gates"] as? [String: Bool],
			  let campaign = object["campaign"] as? [String: Any], let verdict = object["verdict"] as? [String: Any],
			  let events = object["events"] as? [[String: Any]] else { return nil }
		func value(_ any: Any?) -> String {
			switch any {
			case let string as String: return string
			case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
			case let list as [String]: return list.joined(separator: ", ")
			default: return "—"
			}
		}
		func table(_ dictionary: [String: Any]) -> String {
			dictionary.keys.sorted().map { "| \($0) | \(value(dictionary[$0])) |" }.joined(separator: "\n")
		}
		var lines = [
			"# G5 report \(value(header["campaignID"])) / \(value(header["installID8"]))", "",
			"Schema `\(schema)`. Generated from the validated JSON; nothing else enters it.", "",
			"## Verdict", "", "| Field | Value |", "|---|---|", table(verdict), "",
			"## Header", "", "| Field | Value |", "|---|---|", table(header), "",
			"## Gates", "", "| Gate | Recorded |", "|---|---|", gates.keys.sorted().map { "| \($0) | \(gates[$0]! ? "yes" : "no") |" }.joined(separator: "\n"), "",
			"## Campaign", "", "| Field | Value |", "|---|---|", table(campaign), "",
			"## Events", "", "| seq | t (ms) | phase.event | outcome | failure | stop rule | fields |", "|---|---|---|---|---|---|---|",
		]
		for event in events {
			let fields = (event["fields"] as? [String: Any]).map { f in f.keys.sorted().map { "\($0)=\(value(f[$0]))" }.joined(separator: "; ") } ?? ""
			lines.append("| \(value(event["seq"])) | \(value(event["t"])) | \(value(event["phase"])).\(value(event["event"])) | \(value(event["outcome"])) | \(value(event["failure"])) | \(value(event["stopRule"])) | \(fields) |")
		}
		return lines.joined(separator: "\n") + "\n"
	}

	/// Validates, renders both files, and checks the Markdown regenerates
	/// byte for byte from the JSON. Returns the two files, or the rule that
	/// blocked the export.
	func export(provider: String?, contentRules: Bool = true) -> Result<(json: Data, markdown: String), Validation> {
		if case .blocked(let rule) = Self.validate(events, provider: provider, contentRules: contentRules) { return .failure(.blocked(rule)) }
		let headerValues = [header.campaignID, header.installID8, header.branchSHA8, header.bridgeLibSHA8, header.zsignSHA8, header.ipaSHA8]
		guard header.campaignID.range(of: #"^G5-C[0-9]{1,3}$"#, options: .regularExpression) != nil,
			  headerValues.dropFirst().allSatisfy({ ZagLogSchema.accepts(.string($0), as: .sha8, provider: provider) }),
			  header.iOS.range(of: #"^[0-9]{1,2}\.[0-9]{1,2}$"#, options: .regularExpression) != nil,
			  ZagLogSchema.accepts(.string(header.providerHost), as: .host, provider: provider),
			  ZagLogSchema.accepts(.list(header.conditions.sorted()), as: .list(ZagLogSchema.conditions), provider: provider),
			  header.device.range(of: #"^[A-Za-z0-9 ]{1,40}$"#, options: .regularExpression) != nil,
			  Set(header.gates.keys).isSubset(of: ["G1", "G2", "G3", "G4", "G5", "G6"]) else {
			return .failure(.blocked("schema:header"))
		}
		guard let json = try? json(), let markdown = Self.markdown(fromJSON: json), Self.markdown(fromJSON: json) == markdown else {
			return .failure(.blocked("markdown"))
		}
		return .success((json, markdown))
	}

	/// File names (§8).
	var fileStem: String { "g5-report-\(header.campaignID)-\(header.installID8)" }
}

/// Build plan §6, finding 6: the four read-back results, kept distinct.
/// Only `verified` is a success; `unavailable` means the profiles could not be
/// read at all and is never reported as success.
enum ZagExperimentReadback: String, Sendable {
	case verified, mismatch, notVerified, unavailable

	/// From a read of the device's installed profiles and the expectation.
	static func classify(read: Result<[Data], Error>, expectation: ZagInstallExpectation) -> ZagExperimentReadback {
		switch read {
		case .failure: return .unavailable
		case .success(let profiles): return classify(ZagInstalledProfileCheck.verify(expectation, installedProfiles: profiles), readSucceeded: true)
		}
	}

	/// From a verification result. When the device's profiles were read,
	/// "not among them" is `notVerified`; otherwise nothing was read.
	static func classify(_ verification: ZagInstallVerification, readSucceeded: Bool) -> ZagExperimentReadback {
		switch verification {
		case .verified: return readSucceeded ? .verified : .unavailable
		case .mismatch: return .mismatch
		case .notInstalled: return .notVerified
		case .unverifiable: return readSucceeded ? .notVerified : .unavailable
		}
	}
}
#endif
