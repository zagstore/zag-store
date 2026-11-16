import SwiftUI

/// Inline expansion inside the existing update card; the outer Form owns scrolling.
struct ZagUpdateReleaseNotesView: View {
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    let document: ZagUpdateReleaseNotes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var measurements = ReleaseNotesMeasurements()

    init(markdown: String) { document = ZagUpdateReleaseNotes(markdown: markdown) }

    private var canExpand: Bool {
        guard let full = measurements.full, let fourLines = measurements.fourLines else { return false }
        return full > fourLines + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if expanded || (measurements.full != nil && measurements.fourLines != nil && !canExpand) {
                formattedContent
            } else {
                Text(document.preview)
                    .font(.body)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canExpand {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "less" : "more")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .font(.body)
                .foregroundStyle(ZagWideGamutTint.color(hex: themeColorHex))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(expanded ? "Show fewer release notes" : "Show full release notes")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            formattedContent
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ReleaseNotesMeasurementsKey.self,
                                               value: ReleaseNotesMeasurements(full: geometry.size.height))
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .background(alignment: .topLeading) {
            Text("Line\nLine\nLine\nLine")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ReleaseNotesMeasurementsKey.self,
                                               value: ReleaseNotesMeasurements(fourLines: geometry.size.height))
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onPreferenceChange(ReleaseNotesMeasurementsKey.self) { measurements = $0 }
        .onAppear { expanded = false }
        .environment(\.openURL, OpenURLAction { url in
            ZagUpdateReleaseNotes.isSafeWebURL(url) ? .systemAction : .discarded
        })
    }

    private var formattedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = block.marker {
                        Text(marker).accessibilityHidden(true)
                    }
                    Text(block.text)
                        .font(block.heading == nil ? .body : .headline)
                        .accessibilityAddTraits(block.heading == nil ? [] : .isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.body)
    }
}

private struct ReleaseNotesMeasurements: Equatable {
    var full: CGFloat?
    var fourLines: CGFloat?
}

private struct ReleaseNotesMeasurementsKey: PreferenceKey {
    static let defaultValue = ReleaseNotesMeasurements()
    static func reduce(value: inout ReleaseNotesMeasurements, nextValue: () -> ReleaseNotesMeasurements) {
        let next = nextValue()
        if let full = next.full { value.full = full }
        if let fourLines = next.fourLines { value.fourLines = fourLines }
    }
}
