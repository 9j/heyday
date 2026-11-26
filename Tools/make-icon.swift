// Makes Heyday's app icons from one piece of artwork: a sun looking over an envelope at dawn,
// for mail that arrives on a good day. The artwork is `Tools/icon-artwork.png`, a 1024-pixel
// square with the picture running to its edges.
//
// Writes the whole icon set into the directory given:
//   ios-1024.png: the artwork as it is, which is what iOS wants (the system rounds the corners);
//   mac-16.png up to mac-1024.png: the artwork on the Mac's rounded tile, with its margin and shadow.
//
// Usage: swift Tools/make-icon.swift Tools/icon-artwork.png App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift Tools/make-icon.swift <artwork.png> <icon set directory>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("cannot read \(arguments[1])")
    exit(1)
}

/// The size both masters are made at, and the largest icon in the set.
let full = 1024

func canvas(_ side: Int, opaque: Bool) -> CGContext {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
    )!
    context.interpolationQuality = .high
    return context
}

func write(_ image: CGImage, to name: String) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
}

// iOS: the artwork to the edges, no transparency.
let ios = canvas(full, opaque: true)
ios.draw(artwork, in: CGRect(x: 0, y: 0, width: full, height: full))
write(ios.makeImage()!, to: "ios-1024.png")

// macOS: an 824-point tile centred in the canvas, corners rounded, a shadow under it.
let mac = canvas(full, opaque: false)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
// Only its shadow shows: the artwork covers the tile itself.
mac.setFillColor(CGColor(gray: 0.5, alpha: 1))
mac.addPath(tilePath)
mac.fillPath()
mac.restoreGState()
mac.saveGState()
mac.addPath(tilePath)
mac.clip()
mac.draw(artwork, in: tile)
mac.restoreGState()
let macMaster = mac.makeImage()!

for side in [16, 32, 64, 128, 256, 512, 1024] {
    let scaled = canvas(side, opaque: false)
    scaled.draw(macMaster, in: CGRect(x: 0, y: 0, width: side, height: side))
    write(scaled.makeImage()!, to: "mac-\(side).png")
}
print("wrote ios-1024.png and mac-16.png to mac-1024.png")
