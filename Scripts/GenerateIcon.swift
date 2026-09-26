// Generates the app icon as a .iconset directory, ready for iconutil.
//
// The icon is drawn in code rather than committed as a binary asset. Without an
// icon the app shows as a blank generic document in System Settings' privacy
// lists, which makes it hard to identify when granting Accessibility.
//
// Usage: swift Scripts/GenerateIcon.swift <output.iconset>

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

/// Renders the icon at a given pixel size. Drawing at each size, rather than
/// downscaling one master image, keeps the bar edges crisp at 16 and 32 px.
func renderIcon(pixels: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a bitmap context")
    }

    let side = CGFloat(pixels)
    // macOS app icons leave a margin inside their canvas.
    let inset = side * 0.055
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * 0.225

    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.36, green: 0.44, blue: 1.00, alpha: 1),
            CGColor(red: 0.56, green: 0.26, blue: 0.91, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: [])
    context.restoreGState()

    // A five-bar waveform, tallest in the middle.
    let heights: [CGFloat] = [0.26, 0.46, 0.70, 0.46, 0.26]
    let barWidth = plate.width * 0.082
    let gap = plate.width * 0.058
    let span = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = plate.midX - span / 2

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for height in heights {
        let barHeight = plate.height * height
        let bar = CGRect(x: x, y: plate.midY - barHeight / 2, width: barWidth, height: barHeight)
        context.addPath(CGPath(
            roundedRect: bar,
            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    context.fillPath()

    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("could not encode the icon as PNG")
    }
    return data
}

// The sizes iconutil expects in an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for variant in variants {
    let data = renderIcon(pixels: variant.pixels)
    try data.write(to: output.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(variants.count) images to \(output.path)")
