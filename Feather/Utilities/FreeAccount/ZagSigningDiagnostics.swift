import Foundation

/// One bounded, local report for the latest native signing attempt.
final class ZagSigningDiagnostics: @unchecked Sendable {
	static let current = TaskLocal<ZagSigningDiagnostics?>(wrappedValue: nil)
	private let lock = NSLock()
	private var lines: [String] = []
	private let defaults: UserDefaults
	private static let key = "ZagNativeSigningDiagnostics"

	init(defaults: UserDefaults = .standard) { self.defaults = defaults }

	static var latest: String { UserDefaults.standard.string(forKey: key) ?? "" }

	func record(_ event: String) {
		lock.lock()
		defer { lock.unlock() }
		lines.append(event)
		if lines.count > 100 { lines.removeFirst() }
		defaults.set(lines.joined(separator: "\n"), forKey: Self.key)
	}

	static func record(_ event: String) { current.get()?.record(event) }
}

/// Carries a safe description through discovery, provisioning and the UI.
struct ZagPortalOperationFailure: LocalizedError, Equatable, Sendable {
	let operation: String
	let reason: String
	let underlying: ZagPortalError
	var resultCode: Int? = nil

	var errorDescription: String? { "\(operation) — \(reason)" }
}

enum ZagSigningFailurePhase: String {
	case authentication = "Authentication"
	case provisioning = "Provisioning"
	case signing = "Signing"
	case verification = "Verification"
	case installation = "Installation"
	case refresh = "Refresh"

	var title: String { rawValue + " Failed" }

	var message: String {
		switch self {
		case .authentication: "Sign in to the required Apple ID and try again."
		case .provisioning: "Apple could not prepare this app for signing. Check the account and try again."
		case .signing: "The app could not be signed. Check its signing options and try again."
		case .verification: "Zag Store could not verify this app. The saved expiration has not changed."
		case .installation: "The app could not be installed. Check the device connection and try Install again."
		case .refresh: "The app’s validity could not be extended. Try refreshing it again later."
		}
	}
}

struct ZagStagedSigningFailure: LocalizedError {
	let phase: ZagSigningFailurePhase
	let underlying: Error
	var errorDescription: String? { underlying.localizedDescription }
}

struct ZagFreeAppLimitReached: LocalizedError {
	let bundleIDs: [String]
	var reportedIdentifiers: [String] = []
	var errorDescription: String? { Self.message }
	static let title = "Free App Limit Reached"
	static let message = "This iPhone already has the maximum number of installed apps signed with free developer profiles, even across different Apple IDs. Remove one of those apps before trying Install again."

	static func classify(_ error: Error) -> Self? {
		if let limit = error as? Self { return limit }
		if let staged = error as? ZagStagedSigningFailure { return classify(staged.underlying) }
		if let provisioning = error as? ZagProvisioningFailure,
		   case .installSlotsFull(let installed) = provisioning.kind { return .init(bundleIDs: installed) }
		let ns = error as NSError
		let message = ns.localizedDescription
		let folded = message.lowercased()
		let structured = (ns.userInfo["FunctionName"] as? String)?.contains("MIFreeProfileValidatedAppTracker") == true
		let specific = folded.contains("maximum number")
			&& (folded.contains("free developer profile") || folded.contains("free development profile"))
		if structured || specific {
			let regex = try? NSRegularExpression(pattern: #"\b[A-Z0-9]{10}\.([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\b"#)
			let matches = regex?.matches(in: message, range: NSRange(message.startIndex..., in: message)) ?? []
			func identifiers(at index: Int) -> [String] {
				Array(Set(matches.compactMap { Range($0.range(at: index), in: message).map { String(message[$0]) } })).sorted()
			}
			return .init(bundleIDs: identifiers(at: 1), reportedIdentifiers: identifiers(at: 0))
		}
		if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== ns { return classify(underlying) }
		return nil
	}
}

extension ZagSigningDiagnostics {
	static func failureDetails(_ phase: ZagSigningFailurePhase, _ failure: Error) -> String {
		let error = (failure as? ZagStagedSigningFailure)?.underlying ?? failure
		let info = error as NSError
		let transport = info.localizedDescription.replacingOccurrences(
			of: #"(?i)\b(?:Authorization|Set-Cookie|Cookie)\s*[:=][^\r\n]+"#,
			with: "[redacted]", options: .regularExpression)
		let message = ZagDeveloperServicesProtocol.sanitizeMessage(transport, limit: 600)
		// Error domains come from NSError, not arbitrary response payload fields.
		let domain = info.domain.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
		var details = "\(phase.rawValue) failed [\(domain.prefix(120)) \(info.code)]: \(message)"
		if let limit = ZagFreeAppLimitReached.classify(error), !limit.bundleIDs.isEmpty {
			let identifiers = limit.reportedIdentifiers.isEmpty ? limit.bundleIDs : limit.reportedIdentifiers
			details += "\nReported installed app identifiers: " + identifiers.joined(separator: ", ")
		}
		return details
	}

	static func recordFailure(_ phase: ZagSigningFailurePhase, _ error: Error) {
		record(failureDetails(phase, error))
	}
}
