import SwiftUI

/// Rounded 1.8-point strokes at the same 25-point footprint as the pairing icon.
struct ZagDeveloperModeIcon: View {
    var body: some View {
        ZagDeveloperModeHammer()
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }
}

private struct ZagDeveloperModeHammer: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 30, y: rect.minY + rect.height * y / 30)
        }
        var path = Path()
        // A single balanced head and a tapered handle, with no crossing outlines.
        path.move(to: point(13, 12))
        path.addLine(to: point(5, 24))
        path.addQuadCurve(to: point(8, 26), control: point(4.5, 27.5))
        path.addLine(to: point(16, 14))
        path.closeSubpath()

        path.move(to: point(7, 7))
        path.addLine(to: point(11, 3))
        path.addLine(to: point(20, 9))
        path.addQuadCurve(to: point(25, 14), control: point(24, 10))
        path.addLine(to: point(21, 13))
        path.addLine(to: point(18, 16))
        path.closeSubpath()
        return path
    }
}
