import AppKit
import Foundation

// Preserve the official artwork and composite a small USB-C cable badge.
let args = CommandLine.arguments
guard args.count == 3, let base = NSImage(contentsOfFile: args[1]) else { exit(1) }
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { rect in
    base.draw(in: rect)
    let badge = NSBezierPath(roundedRect: NSRect(x: 650, y: 56, width: 306, height: 306), xRadius: 76, yRadius: 76)
    NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
    badge.fill()
    let cable = NSBezierPath()
    cable.move(to: NSPoint(x: 805, y: 78))
    cable.curve(to: NSPoint(x: 805, y: 208), controlPoint1: NSPoint(x: 710, y: 145), controlPoint2: NSPoint(x: 805, y: 142))
    cable.lineWidth = 24
    cable.lineCapStyle = .round
    NSColor(calibratedWhite: 0.91, alpha: 1).setStroke()
    cable.stroke()
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 755, y: 175, width: 100, height: 104), xRadius: 19, yRadius: 19).fill()
    NSColor(calibratedWhite: 0.63, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 767, y: 265, width: 76, height: 47), xRadius: 17, yRadius: 17).fill()
    NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 778, y: 298, width: 54, height: 8), xRadius: 4, yRadius: 4).fill()
    return true
}
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
