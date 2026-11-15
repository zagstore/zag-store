import SwiftUI

/// Pairing adaptation of SettingsView's ZagPhoneSettingsIcon (.dock/.splash).
/// Keep its phone, island and Z proportions; add one mirrored radio arc per side.
struct ZagPairingIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.23, style: .continuous)
                    .strokeBorder(lineWidth: 1.8)
                    .frame(width: w * 0.68, height: h * 0.96)

                Capsule()
                    .frame(width: w * 0.18, height: h * 0.052)
                    .offset(y: -h * 0.35)

                ZagPairingZMark()
                    .stroke(style: StrokeStyle(lineWidth: min(w, h) * 0.34 * (5.8 / 30), lineCap: .round, lineJoin: .round))
                    .frame(width: w * 0.34, height: h * 0.34)

                Path { path in
                    for side in [CGFloat(1), -1] {
                        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                            CGPoint(x: (side == 1 ? x : 1 - x) * w, y: y * h)
                        }
                        path.move(to: point(0.09, 0.30))
                        path.addCurve(to: point(0.09, 0.70),
                                      control1: point(0.025, 0.42),
                                      control2: point(0.025, 0.58))
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            .frame(width: w, height: h)
        }
        .accessibilityHidden(true)
    }
}

/// Same 30-unit path and rounded terminals as ZagSourcesTabIcon, kept vector.
private struct ZagPairingZMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 30, y: rect.minY + rect.height * y / 30)
        }
        path.move(to: point(5.1, 6.6))
        path.addLine(to: point(24.7, 6.6))
        path.addLine(to: point(5.1, 23.4))
        path.addLine(to: point(24.7, 23.4))
        return path
    }
}
