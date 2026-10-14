// Renders the Agemin app icon without AppKit and writes the ICNS container itself, so
// no window server, iconutil, or temporary system directory is needed.
// Usage: render_icon <output.icns> <preview.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// color(hex, [alpha = 1]): An sRGB color from a 0xRRGGBB value.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

// squircle(rect, radiusRatio): The macOS icon squircle, approximated with a rounded rectangle.
func squircle(_ rect: CGRect, radiusRatio: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * radiusRatio, cornerHeight: rect.height * radiusRatio, transform: nil)
}

// render(size): Draw the icon at size pixels: the green tile and a white padlock.
func render(size: Int) -> CGImage {
    // Draw in 1024-point coordinates and let the context scale to the requested pixel size, so
    // every slot shares one set of geometry.
    let scale = CGFloat(size) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Background: the standard macOS icon inset with a green gradient.
    let inset: CGFloat = 100
    let background = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    context.saveGState()
    context.addPath(squircle(background, radiusRatio: 0.2237))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0x3FD689), color(0x0E9A57)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024 - inset), end: CGPoint(x: 512, y: inset), options: [])
    // A soft highlight across the top keeps the surface from looking flat.
    let glow = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(glow, start: CGPoint(x: 512, y: 1024 - inset), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // The padlock: a shackle arc above a body, both white, with one shared drop shadow. The
    // whole lock is scaled to 95% and lifted 20 points above the center, because its visual
    // weight sits in the body, as the sibling icons do.
    context.saveGState()
    context.translateBy(x: 512, y: 532)
    context.scaleBy(x: 0.95, y: 0.95)
    context.translateBy(x: -512, y: -512)
    let bodyWidth: CGFloat = 400
    let bodyHeight: CGFloat = 300
    let body = CGRect(x: 512 - bodyWidth / 2, y: 236, width: bodyWidth, height: bodyHeight)
    let shackleWidth: CGFloat = 220
    let shackleStroke: CGFloat = 62
    let shackleRadius = shackleWidth / 2
    let shackleCenter = CGPoint(x: 512, y: body.maxY + 92)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0x05331C, alpha: 0.35))
    // The shackle is drawn first so the body covers its open ends.
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: shackleCenter.x - shackleRadius, y: body.maxY - 20))
    shackle.addLine(to: CGPoint(x: shackleCenter.x - shackleRadius, y: shackleCenter.y))
    shackle.addArc(center: shackleCenter, radius: shackleRadius, startAngle: .pi, endAngle: 0, clockwise: true)
    shackle.addLine(to: CGPoint(x: shackleCenter.x + shackleRadius, y: body.maxY - 20))
    context.addPath(shackle)
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(shackleStroke)
    context.setLineCap(.butt)
    context.strokePath()
    // The body, filled white under the same shadow as the shackle.
    context.addPath(squircle(body, radiusRatio: 0.2))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    // The body face gets a slight top-to-bottom gradient for depth, drawn without the shadow
    // and clipped to the body shape.
    context.saveGState()
    context.addPath(squircle(body, radiusRatio: 0.2))
    context.clip()
    let face = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF), color(0xE9F7EF)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(face, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // The keyhole: a circle and a tapered slot, in the tile's deep green.
    let keyhole = CGMutablePath()
    let holeCenter = CGPoint(x: 512, y: body.midY + 36)
    keyhole.addEllipse(in: CGRect(x: holeCenter.x - 44, y: holeCenter.y - 44, width: 88, height: 88))
    keyhole.move(to: CGPoint(x: holeCenter.x - 26, y: holeCenter.y - 24))
    keyhole.addLine(to: CGPoint(x: holeCenter.x + 26, y: holeCenter.y - 24))
    keyhole.addLine(to: CGPoint(x: holeCenter.x + 40, y: body.minY + 54))
    keyhole.addLine(to: CGPoint(x: holeCenter.x - 40, y: body.minY + 54))
    keyhole.closeSubpath()
    context.addPath(keyhole)
    context.setFillColor(color(0x0E9A57))
    context.fillPath()
    // Undo the padlock's translation and scale before the image is taken.
    context.restoreGState()

    return context.makeImage()!
}

// png(image): Encode an image as PNG data.
func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not encode PNG") }
    return data as Data
}

// bigEndian(value): The four-byte big-endian encoding ICNS uses for lengths.
func bigEndian(_ value: UInt32) -> Data {
    var bytes = value.bigEndian
    return Data(bytes: &bytes, count: 4)
}

// icns(entries): Build an ICNS file from PNG entries, each a type code and its data. The container
// is a header followed by the entries, every one length-prefixed; the type codes must be the
// modern PNG-capable ones.
func icns(_ entries: [(type: String, data: Data)]) -> Data {
    var body = Data()
    for entry in entries {
        body.append(contentsOf: Array(entry.type.utf8))
        body.append(bigEndian(UInt32(8 + entry.data.count)))
        body.append(entry.data)
    }
    var file = Data("icns".utf8)
    file.append(bigEndian(UInt32(8 + body.count)))
    file.append(body)
    return file
}

// Positional arguments: the ICNS file to write and a 1024 px PNG preview.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("usage: render_icon <output.icns> <preview.png>")
}
let output = URL(fileURLWithPath: arguments[1])
let preview = URL(fileURLWithPath: arguments[2])

// Each pixel size is rendered once and shared by the 1x and 2x slots that use it.
let rendered: [Int: Data] = Dictionary(uniqueKeysWithValues: [16, 32, 64, 128, 256, 512, 1024].map { ($0, png(render(size: $0))) })
// icp4 to icp6 are 16 to 64 px at 1x, ic07 to ic10 are 128 to 1024 px, ic11 to ic14 are the 2x
// slots for 16 to 256 pt.
let slots: [(type: String, size: Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("icp6", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]
try icns(slots.map { (type: $0.type, data: rendered[$0.size]!) }).write(to: output)
try rendered[1024]!.write(to: preview)

// Read the container back the way macOS does, so a malformed file fails here and not in Finder.
guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(source) >= slots.count,
      let largest = CGImageSourceCreateImageAtIndex(source, 0, nil), largest.width > 0 else {
    fatalError("The ICNS file could not be read back")
}
print("Wrote \(output.path) with \(CGImageSourceGetCount(source)) representations")
