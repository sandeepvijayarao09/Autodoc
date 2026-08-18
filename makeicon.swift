// Generates Autodoc's app icon (a gradient squircle + a "running log" mark)
// as a full .iconset, then leaves it for iconutil to compile into .icns.
//   usage:  swift makeicon.swift <output.iconset-dir>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func makeIcon(size px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Squircle body with a small margin (matches macOS icon grid).
    let margin = s * 0.075
    let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()

    // Indigo → violet vertical gradient.
    let grad = CGGradient(colorsSpace: cs,
                          colors: [color(0.39, 0.40, 0.95), color(0.49, 0.23, 0.93)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Soft top highlight.
    let hi = CGGradient(colorsSpace: cs,
                        colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: s * 0.55), options: [])

    // "Running log" mark: left-aligned white lines with a red record bullet.
    let h = s * 0.050                       // line thickness
    let gap = h * 1.9
    let widths: [CGFloat] = [1.0, 0.70, 0.90, 0.52]
    let avail = body.width * 0.52
    let startX = body.minX + body.width * 0.30
    let blockH = CGFloat(widths.count) * h + CGFloat(widths.count - 1) * gap
    var y = body.midY + blockH / 2 - h        // top line first (bottom-up coords)

    for (i, w) in widths.enumerated() {
        let bar = CGRect(x: startX, y: y, width: avail * w, height: h)
        ctx.setFillColor(color(1, 1, 1, 0.94))
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.fillPath()

        if i == 0 {                            // red record dot as first bullet
            let r = h * 0.95
            let dot = CGRect(x: startX - r * 2.4, y: y + h / 2 - r, width: r * 2, height: r * 2)
            ctx.setFillColor(color(1.0, 0.27, 0.23, 1))
            ctx.fillEllipse(in: dot)
        }
        y -= (h + gap)
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Autodoc.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Apple's required iconset members.
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let url = URL(fileURLWithPath: "\(outDir)/\(spec.name).png")
    writePNG(makeIcon(size: spec.px), to: url)
}
print("wrote \(specs.count) images to \(outDir)")
