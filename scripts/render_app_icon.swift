import AppKit
import Foundation
import CoreGraphics

/// GrokBar app icon:
/// official Grok mark + menu-bar status-item capsule with a partial usage fill.
func renderIcon(size: CGFloat, grokSVG: URL) -> NSImage {
    let w = Int(size.rounded())
    let h = Int(size.rounded())
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    nsCtx.imageInterpolation = .high
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    let space = CGColorSpaceCreateDeviceRGB()
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)

    // Plate
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1),
            CGColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size * 0.5, y: size),
            end: CGPoint(x: size * 0.5, y: 0),
            options: []
        )
    }

    if let glow = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.28, green: 0.40, blue: 0.85, alpha: 0.28),
            CGColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 0.0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: size * 0.5, y: size * 0.58),
            startRadius: 0,
            endCenter: CGPoint(x: size * 0.5, y: size * 0.58),
            endRadius: size * 0.42,
            options: []
        )
    }

    let isTiny = size <= 32
    let isSmall = size <= 64

    // --- Grok mark (upper) ---
    if let markSource = NSImage(contentsOf: grokSVG) {
        let markPx = max(Int(size * 0.75), 96)
        let markRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: markPx,
            pixelsHigh: markPx,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        markRep.size = NSSize(width: markPx, height: markPx)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: markRep)
        markSource.draw(
            in: NSRect(x: 0, y: 0, width: markPx, height: markPx),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: markPx, height: markPx).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()

        let whiteMark = NSImage(size: NSSize(width: markPx, height: markPx))
        whiteMark.addRepresentation(markRep)

        let markSide = size * (isTiny ? 0.50 : 0.48)
        let markRect = NSRect(
            x: (size - markSide) / 2,
            y: size * (isTiny ? 0.40 : 0.39),
            width: markSide,
            height: markSide
        )
        whiteMark.draw(
            in: markRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    // --- Menu-bar status item + usage meter (lower) ---
    // Outer capsule ≈ status item chrome
    let pillH = size * (isTiny ? 0.15 : (isSmall ? 0.12 : 0.105))
    let pillW = size * (isTiny ? 0.62 : 0.58)
    let pillX = (size - pillW) / 2
    let pillY = size * (isTiny ? 0.14 : 0.155)
    let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
    let radius = pillH / 2
    let trackPath = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Status-item body (darker inset chrome)
    ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.19, blue: 0.24, alpha: 1))
    ctx.addPath(trackPath)
    ctx.fillPath()

    // Inner track well
    let insetY = pillH * 0.22
    let insetX = pillH * 0.28
    let well = CGRect(
        x: pillX + insetX,
        y: pillY + insetY,
        width: pillW - insetX * 2,
        height: pillH - insetY * 2
    )
    let wellRadius = well.height / 2
    let wellPath = CGPath(roundedRect: well, cornerWidth: wellRadius, cornerHeight: wellRadius, transform: nil)
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1))
    ctx.addPath(wellPath)
    ctx.fillPath()

    // Usage fill — only left portion of the well (~58%)
    let fillRatio: CGFloat = 0.58
    ctx.saveGState()
    ctx.addPath(wellPath)
    ctx.clip()
    let fillWidth = well.width * fillRatio
    ctx.clip(to: CGRect(x: well.minX, y: well.minY, width: fillWidth, height: well.height))
    if let fillGrad = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.42, green: 0.75, blue: 1.00, alpha: 1),
            CGColor(srgbRed: 0.58, green: 0.50, blue: 0.98, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            fillGrad,
            start: CGPoint(x: well.minX, y: well.midY),
            end: CGPoint(x: well.minX + fillWidth, y: well.midY),
            options: []
        )
    }
    ctx.restoreGState()

    // Outer status-item border
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: isTiny ? 0.22 : 0.16))
    ctx.setLineWidth(max(1, size * 0.007))
    ctx.addPath(trackPath)
    ctx.strokePath()

    // Soft top sheen on status item (menu-bar glass hint)
    if size >= 64 {
        ctx.saveGState()
        ctx.addPath(trackPath)
        ctx.clip()
        if let sheen = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                sheen,
                start: CGPoint(x: pillRect.midX, y: pillRect.maxY),
                end: CGPoint(x: pillRect.midX, y: pillRect.midY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    // Plate rim
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(max(1, size * 0.008))
    let rim = size * 0.02
    ctx.addPath(CGPath(
        roundedRect: bounds.insetBy(dx: rim, dy: rim),
        cornerWidth: size * 0.22,
        cornerHeight: size * 0.22,
        transform: nil
    ))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
          let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "icon", code: 1) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let outDir = URL(fileURLWithPath: root)
let svg = outDir.appendingPathComponent("Resources/GrokIcon.svg")

let master = renderIcon(size: 1024, grokSVG: svg)
try writePNG(master, to: outDir.appendingPathComponent("Resources/AppIcon.png"))
try writePNG(master, to: outDir.appendingPathComponent("Resources/AppIcon-1024.png"))

let names: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("diana.k@example.org", 32),
    ("icon_32x32.png", 32),
    ("ivan.p@example.net", 64),
    ("icon_128x128.png", 128),
    ("wendy.h@example.net", 256),
    ("icon_256x256.png", 256),
    ("wendy.h@example.net", 512),
    ("icon_512x512.png", 512),
    ("walt.e@example.net", 1024),
]

let iconset = outDir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in names {
    try writePNG(renderIcon(size: px, grokSVG: svg), to: iconset.appendingPathComponent(name))
}

let icnsSet = outDir.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: icnsSet)
try FileManager.default.createDirectory(at: icnsSet, withIntermediateDirectories: true)
for (name, px) in names {
    try writePNG(renderIcon(size: px, grokSVG: svg), to: icnsSet.appendingPathComponent(name))
}
print("OK")
