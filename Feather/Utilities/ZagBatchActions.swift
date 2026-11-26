import AppIntents
import UIKit

@MainActor
final class ZagBatchQuickActions {
	static let shared = ZagBatchQuickActions()

	private var request = ZagBatchLaunchRequest()
	private var mainReady = false

	func receive(_ shortcut: UIApplicationShortcutItem) -> Bool {
		guard let operation = ZagBatchOperation(shortcutType: shortcut.type) else { return false }
		enqueue(operation)
		return true
	}

	func enqueue(_ operation: ZagBatchOperation) {
		request.enqueue(operation)
		drain()
	}

	func setMainReady(_ ready: Bool) {
		mainReady = ready
		drain()
	}

	func drain() {
		let ready = mainReady && UIApplication.shared.applicationState == .active
		guard let operation = request.takeIfReady(ready) else { return }
		ZagBatchCoordinator.shared.start(operation, origin: .quickAction)
	}
}

final class ZagBatchSceneDelegate: NSObject, UIWindowSceneDelegate {
	func windowScene(
		_ windowScene: UIWindowScene,
		performActionFor shortcutItem: UIApplicationShortcutItem,
		completionHandler: @escaping (Bool) -> Void
	) {
		completionHandler(ZagBatchQuickActions.shared.receive(shortcutItem))
	}

	func sceneDidBecomeActive(_ scene: UIScene) {
		Task { @MainActor in ZagBatchQuickActions.shared.drain() }
	}
}

struct ZagRefreshAllAppsIntent: AppIntent {
	static let title: LocalizedStringResource = "Refresh All Apps"
	static let openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		let report = await ZagBatchCoordinator.shared.run(.refresh, origin: .shortcut)
		return .result(value: report.message)
	}
}

struct ZagUpdateAllAppsIntent: AppIntent {
	static let title: LocalizedStringResource = "Update All Apps"
	static let openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		let report = await ZagBatchCoordinator.shared.run(.update, origin: .shortcut)
		return .result(value: report.message)
	}
}

struct ZagBatchShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: ZagRefreshAllAppsIntent(),
			phrases: ["Refresh all apps in \(.applicationName)"],
			shortTitle: "Refresh All Apps",
			systemImageName: "arrow.clockwise"
		)
		AppShortcut(
			intent: ZagUpdateAllAppsIntent(),
			phrases: ["Update all apps in \(.applicationName)"],
			shortTitle: "Update All Apps",
			systemImageName: "arrow.down.circle"
		)
	}
}
