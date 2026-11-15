import SwiftUI

/// The Apps Remove App sheet, shared without changing its default geometry.
struct ZagRemovalConfirmationSheet: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let confirm: () -> Void
    let cancel: () -> Void
    @ScaledMetric(relativeTo: .title2) private var titleSize = 22.0
    @ScaledMetric(relativeTo: .body) private var messageSize = 17.0
    @ScaledMetric(relativeTo: .title3) private var buttonSize = 20.0

    var body: some View { content }

    private var content: some View {
		VStack(spacing: 10) {
			Text(title)
			.font(.system(size: titleSize, weight: .semibold))
			.multilineTextAlignment(.center)

			Text(message)
				.font(.system(size: messageSize))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)

			Spacer().frame(height: 10)

			Button(action: confirm) {
				Text(destructiveTitle)
					.font(.system(size: buttonSize, weight: .semibold))
					.foregroundStyle(.red)
					.frame(maxWidth: .infinity)
					.frame(minHeight: 52)
					.background(
						Color(uiColor: .tertiarySystemFill),
						in: RoundedRectangle(cornerRadius: 26, style: .continuous)
					)
			}
			.buttonStyle(.plain)

			Button(action: cancel) {
				Text("Cancel")
					.font(.system(size: buttonSize, weight: .semibold))
					.foregroundStyle(.primary)
					.frame(maxWidth: .infinity)
					.frame(minHeight: 52)
					.background(
						Color(uiColor: .tertiarySystemFill),
						in: RoundedRectangle(cornerRadius: 26, style: .continuous)
					)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 20)
		.padding(.top, 24)
		.padding(.bottom, 8)
    }
}

struct ZagLocalPairingConfirmationPopup: View {
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZagRemovalConfirmationSheet(
            title: "Forget Local Pairing?",
            message: "Removes local pairing credentials. To fully unpair, also remove Zag Store in iOS Settings.",
            destructiveTitle: "Forget Local Pairing",
            confirm: confirm,
            cancel: cancel
        )
    }
}

/// Applied at both sheet presentation sites, including sheets nested in Settings.
/// Measure the ideal content rather than switching larger text sizes to a full-height detent.
struct ZagRemovalSheetPresentation: ViewModifier {
    // The original Apps detent is used only until the first content measurement.
    @State private var contentHeight: CGFloat = 302

    func body(content: Content) -> some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ZagRemovalSheetHeight.self, value: geometry.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ZagRemovalSheetHeight.self) { height in
            if height.isFinite && height > 0 { contentHeight = height }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
}

private struct ZagRemovalSheetHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
