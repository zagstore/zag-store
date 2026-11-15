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
        .disclosureGroupStyle(ZagInstallationDisclosureStyle())
    }
}

/// Avoid the native disclosure content indent: both labels use Control’s native icon column.
private struct ZagInstallationDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                Divider()
                configuration.content
            }
        }
    }
}
