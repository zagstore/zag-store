import SwiftUI

/// The Apps Remove App sheet, shared without changing its default geometry.
struct ZagRemovalConfirmationSheet: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let confirm: () -> Void
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize = 22.0
    @ScaledMetric(relativeTo: .body) private var messageSize = 17.0
    @ScaledMetric(relativeTo: .title3) private var buttonSize = 20.0

    var body: some View {
        Group {
            if dynamicTypeSize > .large {
                ScrollView { content }
            } else {
                content
            }
        }
        .presentationDetents(dynamicTypeSize > .large ? [.large] : [.height(302)])
        .presentationDragIndicator(.visible)
    }

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
