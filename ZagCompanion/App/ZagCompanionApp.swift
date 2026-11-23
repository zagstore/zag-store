import SwiftUI

#if ZAG_ZSIGN_STRICT
@main struct ZagCompanionApp: App {
	@StateObject private var model = ZagCompanionViewModel()
	var body: some Scene {
		WindowGroup("Zag Companion") {
			ContentView().environmentObject(model).frame(minWidth: 580, minHeight: 640)
		}
		.windowResizability(.contentSize)
	}
}
#else
// A GUI build must set ZAG_ZSIGN_STRICT to link the signing engine; fail loudly.
@main struct ZagCompanionApp: App {
	var body: some Scene {
		WindowGroup("Zag Companion") {
			Text("Zag Companion must be built with ZAG_ZSIGN_STRICT.").padding(40)
		}
	}
}
#endif
