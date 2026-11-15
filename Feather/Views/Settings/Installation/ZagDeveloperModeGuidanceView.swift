import SwiftUI

/// Native, initially collapsed help; never infers status from pairing or VPN state.
struct ZagDeveloperModeGuidanceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ZagDeveloperModeGuidance.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
                Text(ZagDeveloperModeGuidance.availability)
                Text(ZagDeveloperModeGuidance.distinction)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("Developer Mode")
                        .lineLimit(dynamicTypeSize > .large ? nil : 1)
                } icon: {
                    ZagDeveloperModeIcon().frame(width: 25, height: 25)
                }
                .labelStyle(ZagInstallationRowLabelStyle(tinted: true))
                .layoutPriority(1)
                Spacer()
                Text(ZagDeveloperModeGuidance.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(ZagDeveloperModeGuidance.accessibilityStatus)
            }
        }
    }
}
