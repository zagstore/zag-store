import SwiftUI

/// Native, initially collapsed help; never infers status from pairing or VPN state.
struct ZagDeveloperModeGuidanceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        DisclosureGroup {
            Label {
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
            } icon: {
                Color.clear.frame(width: 25, height: 25)
            }
            .labelStyle(.titleAndIcon)
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("Developer Mode").foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize > .large ? nil : 1)
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
        }
    }
}
