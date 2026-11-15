import SwiftUI

/// Native, initially collapsed help; never infers status from pairing or VPN state.
struct ZagDeveloperModeGuidanceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @State private var expanded = false
    @State private var indicatorRow: CGRect?
    @State private var columns = DeveloperModeColumns()
    @ScaledMetric(relativeTo: .footnote) private var numberSpacing = 4.0

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ZagDeveloperModeGuidance.steps.enumerated()), id: \.offset) { index, step in
                    Text(step)
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1).")
                                .alignmentGuide(.leading) { $0[.trailing] + numberSpacing }
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel("\(index + 1). \(step)")
                }
                Text(ZagDeveloperModeGuidance.availability)
                Text(ZagDeveloperModeGuidance.distinction)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .padding(.leading, columns.offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: DeveloperModeColumnsKey.self,
                        value: DeveloperModeColumns(content: geometry.frame(in: .global).minX))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("Developer Mode").foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize > .large ? nil : 1)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: DeveloperModeColumnsKey.self,
                                    value: DeveloperModeColumns(label: geometry.frame(in: .global).minX))
                            }
                        }
                } icon: {
                    ZagDeveloperModeIcon().frame(width: 25, height: 25).foregroundStyle(.tint)
                }
                .labelStyle(.titleAndIcon)
                .layoutPriority(1)
                Spacer()
                Text(ZagDeveloperModeGuidance.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(ZagDeveloperModeGuidance.accessibilityStatus)
            }
            .tint(Color(hex: themeColorHex))
            .anchorPreference(key: DeveloperModeRowBounds.self, value: .bounds) { $0 }
        }
        // Native iOS can render the disclosure glyph in secondary rather than tint.
        // Mask only its indicator column; native layout, hit testing and expansion stay intact.
        .mask {
            GeometryReader { geometry in
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    if let indicatorRow {
                        path.addRect(CGRect(x: indicatorRow.maxX, y: indicatorRow.minY,
                                            width: max(0, geometry.size.width - indicatorRow.maxX),
                                            height: indicatorRow.height))
                    }
                }
                .fill(style: FillStyle(eoFill: true))
            }
        }
        .overlayPreferenceValue(DeveloperModeRowBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    Color.clear.preference(key: DeveloperModeRowRect.self, value: geometry[anchor])
                    if indicatorRow != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .center)
                            .position(x: geometry.size.width - 11, y: geometry[anchor].midY)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onPreferenceChange(DeveloperModeRowRect.self) { value in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { indicatorRow = value }
        }
        .onPreferenceChange(DeveloperModeColumnsKey.self) { value in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let label = value.label { columns.label = label }
                if let content = value.content { columns.content = content }
            }
        }
    }
}

/// Measure the native disclosure's content inset instead of hardcoding a negative padding.
private struct DeveloperModeColumns: Equatable {
    var label: CGFloat?
    var content: CGFloat?
    var offset: CGFloat {
        guard let label, let content else { return 0 }
        return label - content
    }
}

private struct DeveloperModeColumnsKey: PreferenceKey {
    static let defaultValue = DeveloperModeColumns()
    static func reduce(value: inout DeveloperModeColumns, nextValue: () -> DeveloperModeColumns) {
        let next = nextValue()
        if let label = next.label { value.label = label }
        if let content = next.content { value.content = content }
    }
}

private struct DeveloperModeRowBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct DeveloperModeRowRect: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
