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
		print("PASS: shared reservation, cancellation, cold/warm request consumption, and completion policies")
	}
}
