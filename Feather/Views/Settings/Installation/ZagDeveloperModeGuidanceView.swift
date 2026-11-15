import SwiftUI

/// Native, initially collapsed help; never infers status from pairing or VPN state.
struct ZagDeveloperModeGuidanceView: View {
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
                Image(systemName: "hammer")
                    .foregroundStyle(.tint)
                    .frame(width: 25)
                    .accessibilityHidden(true)
                Text("Developer Mode")
                    .foregroundStyle(.primary)
                Spacer()
                Text(ZagDeveloperModeGuidance.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
