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
