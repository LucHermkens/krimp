// Draws Krimp's app icon as PNGs in every macOS icon size (run via `make icon`, which turns
// them into App/Resources/AppIcon.icns).
//
//     swift scripts/make_icon.swift <out-dir>
//
// A photo card with four arrows pointing inward ("krimp" is Dutch for shrink) on a warm
// gradient, on the macOS icon grid (824 pt body inside a 1024 canvas). Plain paths only.

import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // Flip so y grows downwards, like the design grid.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // Body: rounded square on the macOS grid, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0xF2386B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xFFB03A), color(0xFF6A3D), color(0xE8326E)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Photo card in the middle.
    let card = CGRect(x: 337, y: 377, width: 350, height: 270)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    // Sun.
    ctx.setFillColor(color(0xFFB03A))
    ctx.fillEllipse(in: CGRect(x: 580, y: 420, width: 62, height: 62))
    // Mountains.
    ctx.setFillColor(color(0xFF6A3D))
    ctx.move(to: CGPoint(x: 320, y: 660))
    ctx.addLine(to: CGPoint(x: 450, y: 495))
    ctx.addLine(to: CGPoint(x: 560, y: 660))
    ctx.fillPath()
    ctx.setFillColor(color(0xE8326E))
    ctx.move(to: CGPoint(x: 470, y: 660))
    ctx.addLine(to: CGPoint(x: 575, y: 540))
    ctx.addLine(to: CGPoint(x: 710, y: 660))
    ctx.fillPath()
    ctx.restoreGState()

    // Four arrows from the corners pointing inward at the card.
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 215, y: 215), CGPoint(x: 1, y: 1)),
        (CGPoint(x: 809, y: 215), CGPoint(x: -1, y: 1)),
        (CGPoint(x: 215, y: 809), CGPoint(x: 1, y: -1)),
        (CGPoint(x: 809, y: 809), CGPoint(x: -1, y: -1)),
    ]
    for (start, dir) in corners {
        let tip = CGPoint(x: start.x + dir.x * 100, y: start.y + dir.y * 100)
        ctx.move(to: start)
        ctx.addLine(to: tip)
        // Arrow head: two strokes back from the tip along the axes.
        ctx.move(to: CGPoint(x: tip.x - dir.x * 72, y: tip.y))
        ctx.addLine(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x, y: tip.y - dir.y * 72))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(drawIcon(size: points * scale), to: outDir.appendingPathComponent(name))
    }
}
