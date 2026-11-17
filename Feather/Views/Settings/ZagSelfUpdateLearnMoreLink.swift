import SwiftUI

/// The release card's Learn More link. It shares a Form row with the update
/// control, so its hit-testing must stay within its own frame.
struct ZagSelfUpdateLearnMoreLink: View {
    static let destination = URL(string: "https://github.com/zagorskey/zag-store-releases/releases")!
    let tint: Color

    var body: some View {
        Link("Learn More", destination: Self.destination)
            .font(.body)
            .foregroundStyle(tint)
            .tint(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            // In a Form row, a default-styled Link turns the whole row into its
            // tap target, so taps on the (non-interactive) update capsule and on
            // empty card space opened this link. Borderless keeps it to its own frame.
            .buttonStyle(.borderless)
    }
}
