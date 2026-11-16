import SwiftUI

/// Inline expansion inside the existing update card; the outer Form owns scrolling.
struct ZagUpdateReleaseNotesView: View {
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    let blocks: [ZagUpdateReleaseNotes.Block]
    @State private var expanded = false
    @State private var measurements = ReleaseNotesMeasurements()

    init(markdown: String, version: String? = nil, build: String? = nil) {
        blocks = ZagUpdateReleaseNotes(markdown: markdown).inlineBlocks(version: version, build: build)
    }

    private var canExpand: Bool {
        guard let full = measurements.full, let fourLines = measurements.fourLines else { return false }
        return full > fourLines + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 12) {
                // This first block keeps the same view identity and attributed text
                // in both states. Only its native line limit changes.
                if let first = blocks.first {
                    blockContent(first, lineLimit: showsFullContent ? nil : 4)
                }
                if showsFullContent {
                    ForEach(Array(blocks.dropFirst())) { block in
                        blockContent(block)
                    }
                }
            }
            if canExpand {
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { expanded.toggle() }
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
        .onPreferenceChange(ReleaseNotesMeasurementsKey.self) { value in
            guard value != measurements else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { measurements = value }
        }
        .onAppear { expanded = false }
        .environment(\.openURL, OpenURLAction { url in
            ZagUpdateReleaseNotes.isSafeWebURL(url) ? .systemAction : .discarded
        })
    }

    private var showsFullContent: Bool {
        expanded || (measurements.full != nil && measurements.fourLines != nil && !canExpand)
    }

    private var formattedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockContent(block)
            }
        }
    }

    private func blockContent(_ block: ZagUpdateReleaseNotes.Block, lineLimit: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let marker = block.marker {
                Text(marker).accessibilityHidden(true)
            }
            Text(block.text)
                .font(block.heading == nil ? .body : .headline)
                .accessibilityAddTraits(block.heading == nil ? [] : .isHeader)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
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
