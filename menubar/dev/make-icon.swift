// Renders `Resources/PiMenuBar.icns`.
//
//   swift dev/make-icon.swift [output.icns]
//
// Notification Center shows the app icon next to the banner, so PiMenuBar needs one or
// macOS substitutes a generic application icon and the notification is harder to place.
// Kept as a script (no asset catalog, no Xcode) because the rest of this project builds
// with Command Line Tools only.

import AppKit
import Foundation

let defaultOutput = "Resources/PiMenuBar.icns"
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultOutput

/// The sizes macOS asks for, and the iconset file each one belongs in.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS-style rounded square with a small margin, filled with a warm gradient that
    // reads as "attention" at 16pt without being alarming.
    let size = CGFloat(pixels)
    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.55, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.86, green: 0.24, blue: 0.20, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.56, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
    let glyph = NSAttributedString(string: "π", attributes: attributes)
    let glyphSize = glyph.size()
    glyph.draw(at: NSPoint(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2))

    return rep.representation(using: .png, properties: [:])
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("PiMenuBar-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for variant in variants {
    guard let data = render(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(outputPath)")
