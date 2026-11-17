import SwiftUI

/// A single line whose changes use the update status line's fast crossfade
/// (`ZagUpdateStatusTiming`): fade out, swap while invisible, fade in. Rapid
/// changes coalesce to the newest text; the line never resizes its container.
struct ZagUpdateCrossfadeText: View {
    let text: String
    /// Bookkeeping only; the view renders `shown` and `visible`, changed in
    /// separate transactions exactly like the update status line.
    @State private var model: ZagCrossfadeTextState
    @State private var shown: String
    @State private var visible = true

    init(_ text: String) {
        self.text = text
        _model = State(initialValue: ZagCrossfadeTextState(text))
        _shown = State(initialValue: text)
    }

    var body: some View {
        Text(shown)
            .lineLimit(1)
            .opacity(visible ? 1 : 0)
            .modifier(ZagAnimationArrival(value: visible ? 1 : 0) { if $0 == 0 { fadeOutArrived() } })
            // VoiceOver reads the current state, never the text fading out.
            .accessibilityLabel(text)
            .onChange(of: text) { next in
                guard model.request(next) else { return }
                withAnimation(.easeIn(duration: ZagUpdateStatusTiming.fadeOut)) { visible = false }
            }
    }

    private func fadeOutArrived() {
        guard model.fadeOutArrived() else { return }
        // The swap is not animated: the old text is already invisible.
        withTransaction(Transaction()) { shown = model.shown }
        model.reveal()
        withAnimation(.easeOut(duration: ZagUpdateStatusTiming.fadeIn)) { visible = true }
    }
}
