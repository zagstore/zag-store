import SwiftUI

/// Software Update when nothing newer is available, after iOS Settings: a grey
/// checkmark disc, the heading, the installed release and More Details.
/// Measured against iOS 26 Settings (iPhone, Dynamic Type xLarge): disc 43 pt,
/// heading Title 3 bold, release Title 3 secondary, More Details body.
struct ZagSoftwareUpToDateView: View {
    let release: ZagInstalledRelease
    let showDetails: () -> Void
    @ScaledMetric(relativeTo: .title3) private var disc: CGFloat = 39
    @ScaledMetric(relativeTo: .title3) private var check: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var discToHeading: CGFloat = 21
    @ScaledMetric(relativeTo: .title3) private var releaseToDetails: CGFloat = 27

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: check, weight: .bold))
                .foregroundStyle(Color(uiColor: .systemGroupedBackground))
                .frame(width: disc, height: disc)
                .background(Circle().fill(Color(uiColor: .systemGray)))
                .accessibilityHidden(true)
            Text("Zag Store is up to date")
                .font(.title3.weight(.bold))
                .padding(.top, discToHeading)
            Text(release.label)
                .font(.title3)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .padding(.top, 4)
            Button("More Details", action: showDetails)
                .font(.body)
                .foregroundStyle(Color(uiColor: .systemBlue))
                // Only the label is the tap target, never the whole row.
                .buttonStyle(.borderless)
                .padding(.top, releaseToDetails)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// More Details: the installed release, after iOS Settings' version page.
/// Only verified details are shown; anything unknown is left out.
struct ZagInstalledVersionView: View {
    let release: ZagInstalledRelease

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    Text(release.title)
                        .font(.title3.weight(.semibold))
                    if let installedAt = release.installedAt {
                        Text(ZagInstalledRelease.installedText(installedAt))
                            .font(.body)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .padding(.top, 4)
                    }
                    Group {
                        if let whatsNew = release.whatsNew {
                            ZagInstalledReleaseNotes(markdown: whatsNew)
                        } else {
                            Text("Release notes for this version are not available.")
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                        }
                    }
                    .font(.body)
                    .padding(.top, 19)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
                .padding(.bottom, 32)
            } header: {
                Text("Zag Store Version")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .textCase(nil)
            }
        }
        .navigationTitle("Zag Store Version")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The installed release's What's New in full, with the parsing and link
/// policy of the update card's release notes.
private struct ZagInstalledReleaseNotes: View {
    let blocks: [ZagUpdateReleaseNotes.Block]

    init(markdown: String) {
        blocks = ZagUpdateReleaseNotes(markdown: markdown).blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group) { block in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let marker = block.marker {
                                Text(marker).accessibilityHidden(true)
                            }
                            Text(block.text)
                                .font(block.heading == nil ? .body : .headline)
                                .accessibilityAddTraits(block.heading == nil ? [] : .isHeader)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ZagUpdateReleaseNotes.isSafeWebURL(url) ? .systemAction : .discarded
        })
    }

    /// Paragraphs stand apart as in iOS; the items of one list stay together.
    private var groups: [[ZagUpdateReleaseNotes.Block]] {
        var result: [[ZagUpdateReleaseNotes.Block]] = []
        for block in blocks {
            if block.marker != nil, let last = result.last?.last, last.marker != nil {
                result[result.count - 1].append(block)
            } else {
                result.append([block])
            }
        }
        return result
    }
}

/// Places the up-to-date state as iOS Settings does: centred in the visible
/// space between the section above and the bottom safe area, 3 pt below its
/// middle (measured). The row's top is measured once at rest, so pulling to
/// refresh never resizes it; size or text-size changes re-measure.
struct ZagUpToDateLayout: Equatable {
    var top: CGFloat?
    var visibleBottom: CGFloat = 0
    /// The row starts this far below the section above (`listSectionSpacing`).
    static let sectionSpacing: CGFloat = 16
    /// Left free for the Form's bottom margin, so the page does not scroll.
    static let bottomMargin: CGFloat = 36
    static let belowCentre: CGFloat = 3
    /// Space above the state inside the row, moving its centre to the target.
    static let topInset = bottomMargin - sectionSpacing + 2 * belowCentre

    /// The state's own frame below `topInset`.
    var height: CGFloat? {
        guard let top, visibleBottom - top - Self.bottomMargin > Self.topInset else { return nil }
        return visibleBottom - top - Self.bottomMargin - Self.topInset
    }
}

private struct ZagUpToDateTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ZagVisibleBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ZagUpToDateForm: ViewModifier {
    @Binding var layout: ZagUpToDateLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    // The Form is laid out inside the safe area.
                    Color.clear.preference(key: ZagVisibleBottomKey.self, value: geometry.frame(in: .global).maxY)
                }
            }
            .onPreferenceChange(ZagUpToDateTopKey.self) { top in
                if layout.top == nil, top > 0 { layout.top = top }
            }
            .onPreferenceChange(ZagVisibleBottomKey.self) { bottom in
                guard abs(bottom - layout.visibleBottom) > 0.5 else { return }
                layout.visibleBottom = bottom
                layout.top = nil
            }
            .onChange(of: dynamicTypeSize) { _ in layout.top = nil }
    }
}

extension View {
    /// On the Form that holds the up-to-date state.
    func zagUpToDateForm(_ layout: Binding<ZagUpToDateLayout>) -> some View {
        modifier(ZagUpToDateForm(layout: layout))
    }

    /// On the up-to-date state itself: a transparent, full-width row.
    func zagUpToDateRow(_ layout: ZagUpToDateLayout) -> some View {
        frame(maxWidth: .infinity)
            .frame(minHeight: layout.height)
            .padding(.top, layout.height == nil ? 0 : ZagUpToDateLayout.topInset)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ZagUpToDateTopKey.self, value: geometry.frame(in: .global).minY)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
