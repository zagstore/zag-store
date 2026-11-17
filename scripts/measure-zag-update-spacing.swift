#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

// Usage: swift measure-zag-update-spacing.swift <Apple.png> <ZagStore-before.png>
precondition(CommandLine.arguments.count == 3, "Provide the two original reference PNGs")
for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    precondition(image.width == 1290 && image.height == 2796, "Original @3x reference dimensions required")
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { memory in
        let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 3)])
    }
    let background = rgb(10, 1000) // outside the cards, within the page/sheet
    for x in [400, 645, 900] {
        var start: Int?
        var gaps: [(Int, Int)] = []
        for y in 600..<1000 {
            if rgb(x, y) == background {
                if start == nil { start = y }
            } else if let first = start {
                if y - first >= 12 { gaps.append((first, y)) }
                start = nil
            }
        }
        precondition(gaps.count == 1, "Expected one unambiguous background interval between flat section edges")
        let (bottom, top) = gaps[0]
        let expected = index == 0 ? (717, 765) : (828, 852)
        precondition(bottom == expected.0 && top == expected.1, "Original reference geometry has changed")
        print("\(index == 0 ? "Apple" : "Zag Store") 1290×2796 @3x X=\(x): bottom=\(bottom), top=\(top), gap=\(top-bottom)px = \(Double(top-bottom)/3)pt")
    }
    if index == 1 {
        let blueRows = (1500..<2000).filter { y in
            let value = rgb(645, y)
            return value[0] < 30 && value[1] > 60 && value[1] < 200 && value[2] > 200
        }
        precondition(!blueRows.isEmpty, "Reference primary button must be visible")
        let bottom = blueRows.last! + 1
        // Upper bound: charge all 44pt of the new link hit area as extra height,
        // plus the measured 8pt increase in section gap. Actual increase is smaller.
        let bound = bottom + (44 + 8) * 3
        let safeBottom = image.height - 34 * 3
        precondition(bound < safeBottom, "Collapsed Update Now must remain within the reference viewport")
        print("Update Now bottom=\(bottom)px; conservative new bottom≤\(bound)px; content safe bottom=\(safeBottom)px")
    }
}
