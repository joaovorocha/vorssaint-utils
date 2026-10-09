// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Native, appearance-aware artwork inspired by the supplied rounded bars and
/// compact radio badges. No downloaded bitmap, web content or background tile.
enum TMobileGatewayIndicatorDrawing {
    private static let cache: NSCache<NSString, NSImage> = {
        let result = NSCache<NSString, NSImage>()
        result.countLimit = 100
        result.totalCostLimit = 1024 * 1024
        return result
    }()

    static func image(_ display: TMobileGatewayMenuBarSupport.ConnectionDisplay,
                      style: MenuBarBlockStyle) -> NSImage {
        let key = "\(display.badge)|\(display.bands)|\(display.bars ?? -1)|\(style)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let height: CGFloat = style == .readable ? 23 : 21
        let badgeFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        let bandFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let uc = display.badge == "5G UC"
        let badge = uc ? "5G" : display.badge
        let badgeWidth = ceil((badge as NSString).size(withAttributes: [.font: badgeFont]).width) + (uc ? 7 : 0)
        let bands = display.bands.isEmpty ? "—" : display.bands
        let bandWidth = max(18, ceil((bands as NSString).size(withAttributes: [.font: bandFont]).width))
        let barsWidth: CGFloat = 18
        let width = badgeWidth + barsWidth + bandWidth + 12
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.labelColor]
            let badgeSize = (badge as NSString).size(withAttributes: attributes)
            (badge as NSString).draw(at: NSPoint(x: 0, y: (height - badgeSize.height) / 2), withAttributes: attributes)
            if uc {
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 6, weight: .heavy),
                                                            .foregroundColor: NSColor.labelColor]
                ("U" as NSString).draw(at: NSPoint(x: badgeWidth - 6, y: height / 2 - 0.2), withAttributes: small)
                ("C" as NSString).draw(at: NSPoint(x: badgeWidth - 6, y: height / 2 - 6), withAttributes: small)
            }
            let barsX = badgeWidth + 4
            // Keep the gateway's actual 0...5 scale. Five rounded bars avoid
            // silently remapping a reported five-level reading to four levels.
            for index in 0..<5 {
                let barHeight = CGFloat(4 + index * 2)
                let rect = NSRect(x: barsX + CGFloat(index) * 3.6, y: (height - 12) / 2,
                                  width: 2.4, height: barHeight)
                let filled = display.bars.map { index < $0 } ?? false
                NSColor.labelColor.withAlphaComponent(filled ? 1 : 0.22).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
            }
            let bandAttributes: [NSAttributedString.Key: Any] = [.font: bandFont, .foregroundColor: NSColor.labelColor]
            let bandSize = (bands as NSString).size(withAttributes: bandAttributes)
            (bands as NSString).draw(at: NSPoint(x: badgeWidth + barsWidth + 8, y: (height - bandSize.height) / 2),
                                     withAttributes: bandAttributes)
            return true
        }
        image.isTemplate = false
        cache.setObject(image, forKey: key, cost: max(1, Int(width * height) * 16))
        return image
    }
}
