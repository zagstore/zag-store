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
    /// To the More Details label's 44 pt tap area, which adds ~11 pt above the text.
    @ScaledMetric(relativeTo: .title3) private var releaseToDetails: CGFloat = 17

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
            Button(action: showDetails) {
                Text("More Details")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
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
                    // One Text: both parts share a baseline and wrap together.
                    (Text(release.releaseName).fontWeight(.bold) + Text(" " + release.buildText))
                        .font(.title3)
                    if let dateText = release.dateText() {
                        Text(dateText)
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
        .zagAccountCloseButton()
    }
}

/// Software Update's close button (the account sheet's, see VariedTabbarView)
/// on the pages pushed from it, beside their back button. Only inside the
/// account sheet, which supplies the close action.
private struct ZagAccountCloseButton: ViewModifier {
    @Environment(\.zagAccountClose) private var closeAccount

    func body(content: Content) -> some View {
        content.toolbar {
            if let closeAccount {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: closeAccount) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

extension View {
    func zagAccountCloseButton() -> some View {
        modifier(ZagAccountCloseButton())
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
/// middle (measured).
///
/// The row's top is the List cell's, never its content's: while a cell
/// resizes, its content is centred in the old frame, so measuring the content
/// would feed the height back into the position it is computed from. Nothing is
/// frozen: the latest pass at rest wins, so the first presentation, which is
/// laid out once before the navigation bar's inset applies, settles in the same
/// update as a return from More Details. A position outside the visible Form
/// (a cell sized off screen) is ignored, and so is any pass while the list is
/// pulled or scrolled (iOS 18 and later), so pull to refresh never resizes it.
struct ZagUpToDateLayout: Equatable {
    /// The row's top at rest, in global coordinates.
    var top: CGFloat?
    var visibleBottom: CGFloat = 0
    /// The latest pass, kept so either geometry or scrolling can update `top`.
    private var rowTop: CGFloat?
    private var visibleHeight: CGFloat = 0
    /// Content offset plus top inset: 0 at rest.
    private var scrollDisplacement: CGFloat = 0
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

    /// One layout pass: the row's top (nil while the row is not shown) and the
    /// visible Form's bottom and height, all in global coordinates.
    mutating func measured(rowTop: CGFloat?, visibleBottom bottom: CGFloat, visibleHeight: CGFloat) {
        self.rowTop = rowTop
        if bottom > 0, visibleHeight > 0 {
            if abs(bottom - visibleBottom) > 0.5 { visibleBottom = bottom }
            self.visibleHeight = visibleHeight
        }
        update()
    }

    mutating func scrolled(displacement: CGFloat) {
        scrollDisplacement = displacement
        update()
    }

    private mutating func update() {
        guard let rowTop, visibleHeight > 0, abs(scrollDisplacement) <= 0.5,
              rowTop >= visibleBottom - visibleHeight - 0.5, rowTop <= visibleBottom else { return }
        if top.map({ abs($0 - rowTop) > 0.5 }) ?? true { top = rowTop }
    }
}

/// The up-to-date row's top and the visible Form's bottom and height, from the
/// same layout pass.
struct ZagUpToDateGeometry: Equatable {
    var rowTop: CGFloat?
    var visibleBottom: CGFloat = 0
    var visibleHeight: CGFloat = 0
}

private struct ZagUpToDateGeometryKey: PreferenceKey {
    static let defaultValue = ZagUpToDateGeometry()
    static func reduce(value: inout ZagUpToDateGeometry, nextValue: () -> ZagUpToDateGeometry) {
        let next = nextValue()
        if let top = next.rowTop { value.rowTop = top }
        if next.visibleHeight > 0 {
            value.visibleBottom = next.visibleBottom
            value.visibleHeight = next.visibleHeight
        }
    }
}

private struct ZagUpToDateForm: ViewModifier {
    @Binding var layout: ZagUpToDateLayout

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    // The Form is laid out inside the safe area.
                    let frame = geometry.frame(in: .global)
                    Color.clear.preference(key: ZagUpToDateGeometryKey.self,
                                           value: ZagUpToDateGeometry(visibleBottom: frame.maxY, visibleHeight: frame.height))
                }
            }
            .onPreferenceChange(ZagUpToDateGeometryKey.self) { geometry in
                layout.measured(rowTop: geometry.rowTop, visibleBottom: geometry.visibleBottom,
                                visibleHeight: geometry.visibleHeight)
            }
            .modifier(ZagUpToDateScrollTracking(layout: $layout))
    }
}

/// iOS 18 reports the list's scroll position; earlier versions measure every
/// pass.
private struct ZagUpToDateScrollTracking: ViewModifier {
    @Binding var layout: ZagUpToDateLayout

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, displacement in
                layout.scrolled(displacement: displacement)
            }
        } else {
            content
        }
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
            // Measured on the List cell, not on this content: while the cell
            // resizes, the content is centred in its old frame, so the
            // content's own top would follow the height it is used to set.
            .listRowBackground(GeometryReader { geometry in
                Color.clear.preference(key: ZagUpToDateGeometryKey.self,
                                       value: ZagUpToDateGeometry(rowTop: geometry.frame(in: .global).minY))
            })
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
