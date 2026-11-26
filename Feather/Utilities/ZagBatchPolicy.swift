import Foundation

enum ZagBatchOperation: String {
	case refresh
	case update

	var title: String {
		switch self {
		case .refresh: return "Refresh All"
		case .update: return "Update All"
		}
	}

	var icon: String {
		switch self {
		case .refresh: return "arrow.clockwise"
		case .update: return "arrow.down.circle"
		}
	}

	var shortcutType: String { "zagstore.batch.\(rawValue)" }

	init?(shortcutType: String) {
		switch shortcutType {
		case Self.refresh.shortcutType: self = .refresh
		case Self.update.shortcutType: self = .update
		default: return nil
		}
	}
}

enum ZagBatchOrigin {
	case inApp, quickAction, shortcut, automatic

	enum Presentation { case none, attention, details }

	func presentation(unlocked: Bool, needsAttention: Bool) -> Presentation {
		switch self {
		case .shortcut, .automatic: return .none
		case .inApp, .quickAction:
			if unlocked { return .details }
			return needsAttention ? .attention : .none
		}
	}
}

struct ZagBatchReservation {
	private(set) var operation: ZagBatchOperation?
	private(set) var cancelled = false

	mutating func begin(_ operation: ZagBatchOperation) -> Bool {
		guard self.operation == nil else { return false }
		self.operation = operation
		cancelled = false
		return true
	}

	mutating func cancel() {
		if operation != nil { cancelled = true }
	}

	mutating func finish() {
		operation = nil
		cancelled = false
	}
}

struct ZagBatchLaunchRequest {
	private var pending: ZagBatchOperation?

	mutating func enqueue(_ operation: ZagBatchOperation) {
		pending = operation
	}

	mutating func takeIfReady(_ ready: Bool) -> ZagBatchOperation? {
		guard ready else { return nil }
		defer { pending = nil }
		return pending
	}
}
