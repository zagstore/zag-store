import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class ZagAppleIDExpirationNotifications: NSObject, UNUserNotificationCenterDelegate {
	static let shared = ZagAppleIDExpirationNotifications()
	private let center = UNUserNotificationCenter.current()
	private let prefix = "zag-apple-id-expiry."
	private let categoryID = "zag-apple-id-expiry"
	private let refreshAction = "zag-apple-id-refresh"
	private var reconciliation: Task<Void, Never>?
	private var inventoryChanges: AnyCancellable?
	private var categoryUpdate: Task<Void, Never>?

	func register() {
		center.delegate = self
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		inventoryChanges = ZagNativeAppInventory.changes.sink { [weak self] _ in self?.reconcile() }
		#endif
	}

	func enable() async -> Bool {
		let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
		if allowed { registerCategory() }
		return allowed
	}

	func reconcile() {
		reconciliation?.cancel()
		reconciliation = Task {
			let pending = await center.pendingNotificationRequests()
			let delivered = await center.deliveredNotifications()
			guard !Task.isCancelled else { return }
			let enabled = UserDefaults.standard.bool(forKey: ZagAppleIDMaintenancePolicy.notificationsKey)
			let settings = await center.notificationSettings()
			guard !Task.isCancelled else { return }
			var desired: [String: (ZagAppleIDMaintenancePolicy.Reminder, Date)] = [:]
			var currentWarnings: Set<String> = []
			#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
			if enabled, [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
				await ZagRunningInstallation.shared.inspect()
				guard !Task.isCancelled else { return }
				let dates = ZagNativeAppInventory.verifiedInstalledEntries().compactMap { entry -> Date? in
					let record = entry.installation.record
					return record.owner?.teamKind == .personalFree ? record.expiresAt : nil
				}
				let now = Date()
				let reminders = ZagAppleIDMaintenancePolicy.reminders(expiring: dates, now: .distantPast)
				currentWarnings = Set(reminders.keys.map { "\(prefix)\($0.threshold).\($0.minute)" })
				for (key, date) in reminders.filter({ $0.value > now }).sorted(by: { $0.value < $1.value }).prefix(40) {
					desired["\(prefix)\(key.threshold).\(key.minute)"] = (key, date)
				}
				registerCategory()
			}
			#endif
			let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
			let stale = existing.subtracting(desired.keys)
			center.removePendingNotificationRequests(withIdentifiers: Array(stale))
			let obsoleteDelivered = delivered.map(\.request.identifier).filter {
				$0.hasPrefix(prefix) && !currentWarnings.contains($0)
			}
			center.removeDeliveredNotifications(withIdentifiers: obsoleteDelivered)
			for (id, (key, date)) in desired where !existing.contains(id) {
				guard !Task.isCancelled else { return }
				let content = UNMutableNotificationContent()
				content.title = "Apple ID App Expiration"
				content.body = key.threshold == 0 ? "A signed app may have expired."
					: "One or more signed apps expire within \(key.threshold) hours."
				content.categoryIdentifier = categoryID
				content.sound = .default
				let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
				try? await center.add(.init(identifier: id, content: content, trigger: trigger))
			}
		}
	}

	private func registerCategory() {
		let category = UNNotificationCategory(identifier: categoryID, actions: [
			UNNotificationAction(identifier: refreshAction, title: "Refresh All", options: [.foreground]),
			UNNotificationAction(identifier: "zag-apple-id-open", title: "Open Zag Store", options: [.foreground])
		], intentIdentifiers: [], options: [])
		registerCategory(category)
	}

	func registerCategory(_ category: UNNotificationCategory) {
		let previous = categoryUpdate
		categoryUpdate = Task {
			await previous?.value
			let categories = await center.notificationCategories()
			var merged = categories.filter { $0.identifier != category.identifier }
			merged.insert(category)
			center.setNotificationCategories(merged)
		}
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		guard response.notification.request.content.categoryIdentifier == "zag-apple-id-expiry",
			  response.actionIdentifier == "zag-apple-id-refresh" else { return }
		await MainActor.run { ZagBatchQuickActions.shared.enqueue(.refresh) }
	}
}
