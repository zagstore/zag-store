import SwiftUI

// Hosts the real debug sign-in screen (ZagFreeAccountDebugSignInView.swift,
// unchanged) over the real wallpaper surface, presented by the same launch
// hook the app uses. The full app cannot link for the simulator: the
// RPPairing core library in the project is a device-only build.
@main
struct ZagFreeAccountSignInUIHarness: App {
	var body: some Scene {
		WindowGroup {
			ZStack {
				ZagWallpaperBackground()
				Color.clear
			}
			.modifier(ZagFreeAccountDebugLaunchHook())
		}
	}
}
