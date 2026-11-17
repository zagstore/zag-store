import SwiftUI

/// The existing Mobile Data “Not Verified” font, shared by trailing statuses only.
enum ZagInstallationStatusStyle {
    static let font: Font = .subheadline
    static let indicatorColumn: CGFloat = 22
}

struct ZagInstallationStatusIndicator: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(ZagInstallationStatusStyle.font)
            .frame(width: ZagInstallationStatusStyle.indicatorColumn, alignment: .center)
    }
}
