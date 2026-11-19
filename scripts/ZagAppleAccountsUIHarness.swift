import SwiftUI

// Hosts the real debug Apple Accounts screen (ZagAppleAccountsDebugView.swift,
// unchanged) over the real wallpaper surface, presented by the same launch
// hook the app uses. The full app cannot link for the simulator: the
// RPPairing core library in the project is a device-only build.
@main
struct ZagAppleAccountsUIHarness: App {
	var body: some Scene {
		WindowGroup {
			ZStack {
				ZagWallpaperBackground()
				Color.clear
			}
			.modifier(ZagAppleAccountsDebugLaunchHook())
		}
	}
}
