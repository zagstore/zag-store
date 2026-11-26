import Foundation

@main
struct ZagBatchPolicyTests {
	static func main() {
		var reservation = ZagBatchReservation()
		precondition(reservation.begin(.refresh))
		precondition(!reservation.begin(.refresh))
		precondition(!reservation.begin(.update))
		reservation.cancel()
		precondition(reservation.cancelled && reservation.operation == .refresh)
		reservation.finish()
		precondition(reservation.begin(.update) && !reservation.cancelled)
		reservation.finish()
		reservation.cancel()
		precondition(reservation.operation == nil && !reservation.cancelled)

		var request = ZagBatchLaunchRequest()
		let operation = ZagBatchOperation(shortcutType: "zagstore.batch.refresh")
		precondition(operation == .refresh)
		precondition(ZagBatchOperation(shortcutType: "unrelated") == nil)
		request.enqueue(.refresh)
		precondition(request.takeIfReady(false) == nil)
		request.enqueue(.refresh)
		precondition(request.takeIfReady(false) == nil)
		precondition(request.takeIfReady(true) == .refresh)
		precondition(request.takeIfReady(true) == nil)
		request.enqueue(.update)
		precondition(request.takeIfReady(true) == .update)

		for unlocked in [false, true] {
			for needsAttention in [false, true] {
				precondition(ZagBatchOrigin.shortcut.presentation(unlocked: unlocked, needsAttention: needsAttention) == .none)
			}
		}
		for origin in [ZagBatchOrigin.inApp, .quickAction] {
			precondition(origin.presentation(unlocked: false, needsAttention: false) == .none)
			precondition(origin.presentation(unlocked: false, needsAttention: true) == .attention)
			precondition(origin.presentation(unlocked: true, needsAttention: false) == .details)
			precondition(origin.presentation(unlocked: true, needsAttention: true) == .details)
		}
		precondition(ZagBatchOrigin.automatic.presentation(unlocked: true, needsAttention: true) == .none)
		precondition(!ZagAppleIDMaintenancePolicy.allowsFullResign(profileOnly: true, target: "signed-app", runningApp: "store"))
		precondition(!ZagAppleIDMaintenancePolicy.allowsFullResign(profileOnly: false, target: "store", runningApp: "store"))
		precondition(ZagAppleIDMaintenancePolicy.allowsFullResign(profileOnly: false, target: "signed-app", runningApp: "store"))
		let now = Date(timeIntervalSince1970: 2_000_000_040)
		let window = ZagAppleIDMaintenancePolicy.window
		precondition(!ZagAppleIDMaintenancePolicy.isDue(expiry: now + window + 1, now: now, attempts: 0, retryAt: nil))
		precondition(ZagAppleIDMaintenancePolicy.isDue(expiry: now + window, now: now, attempts: 0, retryAt: nil))
		precondition(ZagAppleIDMaintenancePolicy.isDue(expiry: now - 1, now: now, attempts: 0, retryAt: nil))
		precondition(!ZagAppleIDMaintenancePolicy.isDue(expiry: now + 24 * 3600, now: now, attempts: 0,
			retryAt: nil, lastSuccess: now - 3600))
		precondition(ZagAppleIDMaintenancePolicy.isDue(expiry: now + 6 * 3600, now: now, attempts: 0,
			retryAt: nil, lastSuccess: now - 3600))

		let firstRetry = ZagAppleIDMaintenancePolicy.retry(at: now, afterAttempts: 1, transient: true)
		precondition(firstRetry == now + 3600)
		precondition(!ZagAppleIDMaintenancePolicy.isDue(expiry: now, now: now, attempts: 1, retryAt: firstRetry))
		precondition(ZagAppleIDMaintenancePolicy.isDue(expiry: now, now: firstRetry, attempts: 1, retryAt: firstRetry))
		precondition(ZagAppleIDMaintenancePolicy.retry(at: now, afterAttempts: 2, transient: true) == now + 4 * 3600)
		precondition(ZagAppleIDMaintenancePolicy.retry(at: now, afterAttempts: 1, transient: false) == .distantFuture)
		precondition(!ZagAppleIDMaintenancePolicy.isDue(expiry: now, now: now, attempts: 3, retryAt: nil))
		let expiry = now + 72 * 3600
		let grouped = ZagAppleIDMaintenancePolicy.reminders(expiring: [expiry, expiry + 5], now: now)
		precondition(grouped.count == 4 && Set(grouped.keys.map(\.threshold)) == [48, 24, 6, 0])
		precondition(grouped.values.contains(expiry))
		let updated = ZagAppleIDMaintenancePolicy.reminders(expiring: [expiry + 7 * 86400], now: now)
		precondition(Set(grouped.keys).isDisjoint(with: updated.keys))
		let near = ZagAppleIDMaintenancePolicy.reminders(expiring: [now + 8 * 3600], now: now)
		precondition(Set(near.keys.map(\.threshold)) == [6, 0])
		precondition(ZagAppleIDMaintenancePolicy.reminders(expiring: [now - 1], now: now).isEmpty)
		print("PASS: automatic renewal window, retry limits, silent results and expiration reminder reconciliation")

		print("PASS: shared reservation, cancellation, cold/warm request consumption, and completion policies")
	}
}
