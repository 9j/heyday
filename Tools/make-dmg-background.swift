// Draws the Retina background for Heyday's macOS disk image: a calm dawn-lit canvas
// with a subtle sunrise gradient arrow and a landing frame for the Applications alias.
//
// Writes `background-1x.png` (660×420) and `background-2x.png` (1320×840) into the
// output directory so `tiffutil -cathidpicheck` can combine them into one Retina TIFF
// that Finder renders crisply on both standard and Retina displays.
//
// Usage: swift Tools/make-dmg-background.swift <output directory> [version]
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift Tools/make-dmg-background.swift <output directory> [version]\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
let version = args.count >= 3 ? args[2] : ""

let canvasWidth: CGFloat = 660
let canvasHeight: CGFloat = 420
/// Finder icon center coordinates (top-left origin), matched by `Tools/make-dmg.sh`.
let appCenter = CGPoint(x: 178, y: 222)
let appsCenter = CGPoint(x: 482, y: 228)
let arrowCenterY: CGFloat = 220

/// Converts a top-left y coordinate (Finder convention) to CoreGraphics bottom-left y.
func flipY(_ y: CGFloat) -> CGFloat { canvasHeight - y }

func drawBackground(scale: CGFloat) -> CGImage {
    let pixelW = Int(canvasWidth * scale)
    let pixelH = Int(canvasHeight * scale)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(
        data: nil,
        width: pixelW,
        height: pixelH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: scale, y: scale)

    let bounds = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

    // 1. Base silk-dawn gradient (clean off-white with whisper of lavender -> warm peach).
    let baseGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.980, green: 0.974, blue: 0.996, alpha: 1),
            CGColor(srgbRed: 0.976, green: 0.976, blue: 0.984, alpha: 1),
            CGColor(srgbRed: 0.996, green: 0.968, blue: 0.952, alpha: 1),
        ] as CFArray,
        locations: [0.0, 0.52, 1.0]
    )!
    ctx.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: 0, y: canvasHeight),
        end: CGPoint(x: canvasWidth, y: 0),
        options: []
    )

    // 2. Soft atmospheric dawn glows echoing Heyday's app icon palette.
    func drawGlow(center: CGPoint, radius: CGFloat, color: CGColor) {
        let transparent = color.copy(alpha: 0)!
        let glow = CGGradient(colorsSpace: colorSpace, colors: [color, transparent] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }

    drawGlow(
        center: CGPoint(x: 130, y: flipY(80)),
        radius: 260,
        color: CGColor(srgbRed: 0.66, green: 0.34, blue: 0.97, alpha: 0.085)
    )
    drawGlow(
        center: CGPoint(x: 540, y: flipY(350)),
        radius: 270,
        color: CGColor(srgbRed: 1.00, green: 0.52, blue: 0.30, alpha: 0.095)
    )
    drawGlow(
        center: CGPoint(x: appCenter.x, y: flipY(appCenter.y)),
        radius: 120,
        color: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.30, alpha: 0.10)
    )

    // 3. Subtle drop-target pad centered behind the Applications alias.
    let padSize: CGFloat = 148
    let padRect = CGRect(
        x: appsCenter.x - padSize / 2,
        y: flipY(appsCenter.y) - padSize / 2,
        width: padSize,
        height: padSize
    )
    let padPath = CGPath(roundedRect: padRect, cornerWidth: 32, cornerHeight: 32, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.56))
    ctx.addPath(padPath)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(srgbRed: 0.52, green: 0.44, blue: 0.62, alpha: 0.22))
    ctx.setLineWidth(1.5)
    ctx.setLineDash(phase: 0, lengths: [6, 5])
    ctx.addPath(padPath)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Clean dawn-gradient arrow from Heyday.app to Applications.
    let arrowY = flipY(arrowCenterY)
    let arrowStartX: CGFloat = 294
    let arrowEndX: CGFloat = 366
    let headSize: CGFloat = 11

    let arrowPath = CGMutablePath()
    arrowPath.move(to: CGPoint(x: arrowStartX, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
    arrowPath.move(to: CGPoint(x: arrowEndX - headSize, y: arrowY + headSize))
    arrowPath.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: arrowEndX - headSize, y: arrowY - headSize))

    let strokedArrow = arrowPath.copy(
        strokingWithWidth: 3.0,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )
    ctx.saveGState()
    ctx.addPath(strokedArrow)
    ctx.clip()
    let arrowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.67, green: 0.34, blue: 0.96, alpha: 0.72),
            CGColor(srgbRed: 0.95, green: 0.39, blue: 0.55, alpha: 0.88),
            CGColor(srgbRed: 0.99, green: 0.52, blue: 0.27, alpha: 0.94),
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        arrowGradient,
        start: CGPoint(x: arrowStartX, y: arrowY),
        end: CGPoint(x: arrowEndX + 2, y: arrowY),
        options: []
    )
    ctx.restoreGState()

    // 5. Typography rendered via NSGraphicsContext (flipped top-left coordinates).
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    func drawCenteredText(
        _ text: String,
        yFromTop: CGFloat,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let size = attrStr.size()
        let drawY = canvasHeight - yFromTop - size.height
        attrStr.draw(in: CGRect(x: 0, y: drawY, width: canvasWidth, height: size.height + 2))
    }

    drawCenteredText(
        "Heyday",
        yFromTop: 38,
        font: NSFont.systemFont(ofSize: 30, weight: .bold),
        color: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1),
        kern: -0.6
    )

    drawCenteredText(
        "Drag Heyday into Applications to install",
        yFromTop: 78,
        font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
        color: NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
    )

    // Quiet footer line + metadata, kept well clear of the bottom edge.
    let footerRuleY = flipY(356)
    ctx.saveGState()
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.08))
    ctx.fill(CGRect(x: 180, y: footerRuleY, width: canvasWidth - 360, height: 1))
    ctx.restoreGState()

    let footer = version.isEmpty ? "macOS 15+  ·  Universal" : "Heyday \(version)  ·  macOS 15+  ·  Universal"
    drawCenteredText(
        footer,
        yFromTop: 368,
        font: NSFont.systemFont(ofSize: 11, weight: .medium),
        color: NSColor(srgbRed: 0.54, green: 0.54, blue: 0.58, alpha: 1),
        kern: 0.1
    )

    NSGraphicsContext.restoreGraphicsState()
    _ = bounds
    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (scale, name) in [(CGFloat(1.0), "background-1x.png"), (CGFloat(2.0), "background-2x.png")] {
    let image = drawBackground(scale: scale)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: canvasWidth, height: canvasHeight)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: outputDir.appending(path: name))
}

print("wrote background-1x.png and background-2x.png to \(outputDir.path)")
