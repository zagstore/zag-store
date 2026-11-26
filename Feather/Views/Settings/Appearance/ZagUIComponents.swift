import SwiftUI
import UIKit

// MARK: - Standard Zag Store Badge

struct ZagCountBadge: View {
	@AppStorage("zagStore.designer.standardBadge.size")
	private var badgeSize: Double = 22

	@AppStorage("zagStore.designer.standardBadge.fontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("zagStore.designer.standardBadge.foreground")
	private var badgeTextColorHex: String = "#FFFFFF"

	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	private let title: String
	private let tracking: CGFloat

	init(count: Int) { title = count.description; tracking = 0 }
	init(title: String, tracking: CGFloat = 0) { self.title = title; self.tracking = tracking }

	@Environment(\.colorScheme)
	private var colorScheme

	private var tint: Color {
		Color(hex: themeColorHex)
	}

	var body: some View {
		Text(title)
			.tracking(tracking)
			.font(.system(size: badgeFontSize, weight: .medium, design: .rounded))
			.monospacedDigit()
			.foregroundStyle(tint)
			.lineLimit(1)
			.fixedSize(horizontal: true, vertical: false)
			.padding(.horizontal, max(6, badgeSize * 0.27))
			.frame(minWidth: badgeSize, minHeight: badgeSize, maxHeight: badgeSize, alignment: .center)
			.background {
				Capsule(style: .continuous)
					.fill(
						tint.opacity(colorScheme == .dark ? 0.16 : 0.12)
					)
			}
			.overlay {
				Capsule(style: .continuous)
					.strokeBorder(tint.opacity(0.32), lineWidth: 0.75)
			}
			.shadow(color: tint.opacity(0.10), radius: 3, y: 1)
			.accessibilityLabel(Text(title))
	}
}


// MARK: - Update Badge

struct ZagUpdateBadge: View {
	@AppStorage("zagStore.designer.updateBadge.size")
	private var badgeSize: Double = 22

	@AppStorage("zagStore.designer.updateBadge.fontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("zagStore.designer.updateBadge.background")
	private var badgeColorHex: String = "#FF3B30"

	@AppStorage("zagStore.designer.updateBadge.foreground")
	private var badgeTextColorHex: String = "#FFFFFF"

	let count: Int

	var body: some View {
		Text(count.description)
			.font(.system(size: badgeFontSize, weight: .bold))
			.foregroundStyle(Color(hex: badgeTextColorHex))
			.frame(width: badgeSize, height: badgeSize)
			.background(
				Circle()
					.fill(Color(hex: badgeColorHex))
			)
	}
}


// MARK: - Standard Section Header

struct ZagSectionHeader: View {
	@AppStorage("zagStore.designer.header.gap")
	private var headerGap: Double = 8

	@AppStorage("zagStore.designer.header.alignment")
	private var headerAlignment: Int = 0

	let title: String
	let count: Int

	var body: some View {
		HStack(spacing: headerGap) {
			if headerAlignment == 1 || headerAlignment == 2 {
				Spacer(minLength: 0)
			}

			Text(title)
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(.primary)
				.textCase(nil)

			ZagCountBadge(count: count)

			if headerAlignment == 0 || headerAlignment == 1 {
				Spacer(minLength: 0)
			}
		}
	}
}


// MARK: - Standard Zag Store Action Pill

struct ZagActionPill: View {
	@AppStorage("Feather.userTintColor") private var actionTintHex: String = "#3F8EF7"
	let title: String
	var showsProgress: Bool = false
	var width: CGFloat? = 88
	var horizontalPadding: CGFloat = 14
	var backgroundColor: Color? = nil
	let action: () -> Void

	@Environment(\.colorScheme)
	private var colorScheme

	private var pillBackground: Color {
		if let backgroundColor {
			return backgroundColor
		}
		return colorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#EEEEF0")
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if showsProgress {
					ProgressView()
						.controlSize(.small)
				}

				Text(title)
					.font(.system(size: 17, weight: .bold))
					.lineLimit(1)
			}
			.padding(.horizontal, width == nil ? horizontalPadding : 0)
			.frame(width: width, height: 34)
			.foregroundStyle(ZagWideGamutTint.color(hex: actionTintHex))
			.background(pillBackground)
			.clipShape(Capsule())
			.contentShape(Capsule())
		}
		.buttonStyle(.borderless)
	}
}


struct ZagAppleIDMark: View {
	static var symbol: String { UIImage(systemName: "apple.logo") == nil ? "person.crop.circle" : "apple.logo" }

	var body: some View {
		Image(systemName: Self.symbol).accessibilityHidden(true)
	}
}

struct ZagSigningMethodLabel: View {
	let title: String
	let appleID: Bool

	var body: some View {
		HStack(spacing: 4) {
			if appleID { ZagAppleIDMark() }
			Text(title)
		}
		.lineLimit(1)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(title))
	}
}
