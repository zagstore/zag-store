import AppKit

guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Expected input and output PNG paths")
}
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot allocate icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor.clear.setFill()
canvas.fill(using: .copy)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 184, yRadius: 184)
shape.addClip()
source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
