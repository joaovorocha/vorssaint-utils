// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shadow Utilities contributors

// Draws an original S-shaped circuit mark. No upstream logo assets are used.
// Usage: swift Tools/MakeForkIcon.swift build/AppIcon.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(width: Int, height: Int, appIcon: Bool) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
        pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ShadowIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(width) / 100, y: CGFloat(height) / 100)
    if appIcon {
        let background = NSBezierPath(roundedRect: NSRect(x: 7, y: 7, width: 86, height: 86),
                                      xRadius: 21, yRadius: 21)
        NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.19, blue: 0.26, alpha: 1),
                            NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.13, alpha: 1)])?
            .draw(in: background, angle: -90)
    }
    let mark = NSBezierPath()
    mark.lineWidth = appIcon ? 8 : 9
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    mark.move(to: NSPoint(x: 69, y: 71))
    mark.line(to: NSPoint(x: 42, y: 71))
    mark.curve(to: NSPoint(x: 42, y: 50), controlPoint1: NSPoint(x: 26, y: 71),
               controlPoint2: NSPoint(x: 26, y: 50))
    mark.line(to: NSPoint(x: 58, y: 50))
    mark.curve(to: NSPoint(x: 58, y: 29), controlPoint1: NSPoint(x: 74, y: 50),
               controlPoint2: NSPoint(x: 74, y: 29))
    mark.line(to: NSPoint(x: 31, y: 29))
    (appIcon ? NSColor(calibratedRed: 0.38, green: 0.91, blue: 0.81, alpha: 1) : .black).setStroke()
    mark.stroke()
    for center in [NSPoint(x: 69, y: 71), NSPoint(x: 31, y: 29)] {
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        (appIcon ? NSColor.white : .black).setFill()
        dot.fill()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ShadowIcon", code: 2)
    }
    return png
}

let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
             ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
             ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
             ("icon_512x512@2x", 1024)]
for (name, size) in sizes {
    try render(width: size, height: size, appIcon: true)
        .write(to: output.appendingPathComponent("\(name).png"))
}
// PNG chunks avoid iconutil compatibility issues on newer macOS releases.
func bigEndian(_ value: Int) -> [UInt8] {
    let number = UInt32(value)
    return [UInt8((number >> 24) & 255), UInt8((number >> 16) & 255),
            UInt8((number >> 8) & 255), UInt8(number & 255)]
}
let chunks = [("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
              ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
var payload = Data()
for (kind, size) in chunks {
    let png = try render(width: size, height: size, appIcon: true)
    payload.append(contentsOf: kind.utf8)
    payload.append(contentsOf: bigEndian(png.count + 8))
    payload.append(png)
}
var icns = Data("icns".utf8)
icns.append(contentsOf: bigEndian(payload.count + 8))
icns.append(payload)
try icns.write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
for scale in [1, 2] {
    let suffix = scale == 1 ? "" : "@2x"
    try render(width: 26 * scale, height: 20 * scale, appIcon: false)
        .write(to: output.deletingLastPathComponent().appendingPathComponent("MenuBarIcon\(suffix).png"))
}
try render(width: 256, height: 256, appIcon: false)
    .write(to: output.deletingLastPathComponent().appendingPathComponent("BrandMark.png"))
print("Shadow Utilities icon assets ready")
