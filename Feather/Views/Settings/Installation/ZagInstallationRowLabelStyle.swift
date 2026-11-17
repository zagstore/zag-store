import SwiftUI

/// One leading column for Installation status, control and guidance labels.
struct ZagInstallationRowLabelStyle: LabelStyle {
    var tinted = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Group {
                if tinted {
                    configuration.icon.foregroundStyle(.tint)
                } else {
                    configuration.icon
                }
            }
            .frame(width: 25, alignment: .center)
            if tinted {
                configuration.title.foregroundStyle(.primary)
            } else {
                configuration.title
            }
        }
    }
}
