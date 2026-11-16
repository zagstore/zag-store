import SwiftUI

/// Native digit rolling for a changing count, shared by the Sources app count
/// and the update percentage. iOS 16 falls back to a short ease; Reduce Motion
/// replaces digits without rolling them.
struct ZagNumericTextTransition: ViewModifier {
	let value: Int
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	@ViewBuilder
	func body(content: Content) -> some View {
		if reduceMotion {
			content
		} else if #available(iOS 17.0, *) {
			content
				.contentTransition(.numericText(value: Double(value)))
				.animation(.snappy(duration: 0.35), value: value)
		} else {
			content
				.animation(.easeInOut(duration: 0.2), value: value)
		}
	}
}
