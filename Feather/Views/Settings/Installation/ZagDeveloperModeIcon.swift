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
        // Slim handle, angled head and a short claw; shared rounded terminals.
        path.move(to: point(12, 12))
        path.addLine(to: point(4.7, 25.2))
        path.addQuadCurve(to: point(5.2, 27.2), control: point(4, 26.4))
        path.addQuadCurve(to: point(7.3, 26.9), control: point(6.4, 28))
        path.addLine(to: point(16, 15))
        path.move(to: point(7, 6))
        path.addLine(to: point(11, 2))
        path.addLine(to: point(19, 10))
        path.addLine(to: point(22, 9))
        path.addLine(to: point(26, 13))
        path.addLine(to: point(23, 16))
        path.addLine(to: point(19, 12))
        path.addLine(to: point(16, 15))
        path.closeSubpath()
        return path
    }
}
