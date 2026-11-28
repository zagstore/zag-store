import Foundation

enum ZagAppleIDMaintenancePolicy {
	static let automaticKey = "ZagStore.automaticAppleIDRefresh"
	static let notificationsKey = "ZagStore.appleIDExpirationNotifications"
	static let lastSuccessKey = "ZagStore.lastAutomaticAppleIDRefresh"
	static let window: TimeInterval = 48 * 3600

	static func isDue(expiry: Date, now: Date, attempts: Int, retryAt: Date?, lastSuccess: Date? = nil) -> Bool {
		let secondsLeft = expiry.timeIntervalSince(now)
		let cooldown = lastSuccess.map { now.timeIntervalSince($0) < 12 * 3600 } ?? false
		return secondsLeft <= window && (secondsLeft <= 6 * 3600 || !cooldown)
			&& attempts < 3 && (retryAt ?? .distantPast) <= now
	}

	static func retry(at now: Date, afterAttempts attempts: Int, transient: Bool) -> Date {
		guard transient, (1...2).contains(attempts) else { return .distantFuture }
		return now.addingTimeInterval((attempts == 1 ? 1 : 4) * 3600)
	}

	static func allowsFullResign(profileOnly: Bool, target: String, runningApp: String?) -> Bool {
		!profileOnly && target != runningApp
	}

	struct Reminder: Hashable {
		let threshold: Int
		let minute: Int
	}

	static func reminders(expiring dates: [Date], now: Date) -> [Reminder: Date] {
		var reminders: [Reminder: Date] = [:]
		for expiry in dates {
			for threshold in [48, 24, 6, 0] {
				let deadline = expiry.addingTimeInterval(Double(-threshold * 3600))
				guard deadline > now else { continue }
				let key = Reminder(threshold: threshold, minute: Int(deadline.timeIntervalSince1970 / 60))
				reminders[key] = min(reminders[key] ?? deadline, deadline)
			}
		}
		return reminders
	}
}
