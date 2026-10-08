import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// The twelve drawn avatars: a colored disc with a white glyph. Each is drawn from the geometry
/// of a 100 by 100 design, scaled to the avatar's size.
enum AvatarSymbol: String, Codable, CaseIterable {
    case orbit, chevron, waves, hex, diamond, rings, bolt, leaf, peaks, sun, clover, spark

    /// The disc color the glyph was designed on.
    var color: Color {
        switch self {
        case .orbit: return Color(red: 0xC4 / 255, green: 0x67 / 255, blue: 0x4A / 255)
        case .chevron: return Color(red: 0xCC / 255, green: 0x95 / 255, blue: 0x33 / 255)
        case .waves: return Color(red: 0x3A / 255, green: 0x9E / 255, blue: 0x95 / 255)
        case .hex: return Color(red: 0x3F / 255, green: 0x8B / 255, blue: 0xD9 / 255)
        case .diamond: return Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xD1 / 255)
        case .rings: return Color(red: 0x8E / 255, green: 0x5B / 255, blue: 0xC9 / 255)
        case .bolt: return Color(red: 0xD4 / 255, green: 0x70 / 255, blue: 0x5C / 255)
        case .leaf: return Color(red: 0x5E / 255, green: 0x9C / 255, blue: 0x5A / 255)
        case .peaks: return Color(red: 0x6F / 255, green: 0x83 / 255, blue: 0x96 / 255)
        case .sun: return Color(red: 0xB3 / 255, green: 0x5A / 255, blue: 0xA5 / 255)
        case .clover: return Color(red: 0x8F / 255, green: 0xA8 / 255, blue: 0x3C / 255)
        case .spark: return Color(red: 0xCE / 255, green: 0x5B / 255, blue: 0x86 / 255)
        }
    }

    /// The English name, for VoiceOver and tooltips.
    var title: String {
        switch self {
        case .orbit: return "Orbit"
        case .chevron: return "Chevron"
        case .waves: return "Waves"
        case .hex: return "Hexagon"
        case .diamond: return "Diamond"
        case .rings: return "Rings"
        case .bolt: return "Bolt"
        case .leaf: return "Leaf"
        case .peaks: return "Peaks"
        case .sun: return "Sun"
        case .clover: return "Clover"
        case .spark: return "Spark"
        }
    }

    // draw(in context, size): Paint the glyph into a graphics context whose origin is the
    // avatar's top-left corner, in white with the disc color for cut-outs.
    func draw(in context: inout GraphicsContext, size: CGFloat) {
        // Every glyph is drawn in 100-point design coordinates and scaled to the requested size.
        let scale = size / 100
        context.scaleBy(x: scale, y: scale)
        let white = GraphicsContext.Shading.color(.white)
        let base = GraphicsContext.Shading.color(color)
        // stroke(path, width): Stroke in white with round caps and joins.
        func stroke(_ path: Path, _ width: CGFloat) {
            context.stroke(path, with: white, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        // polygon(points): A closed path through the points.
        func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
            return path
        }
        // disc(x, y, r): A filled circle path.
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        switch self {
        case .orbit:
            stroke(disc(50, 50, 26), 7)
            context.fill(disc(50, 24, 9), with: white)
        case .chevron:
            // An open upward angle, stroked thick.
            var path = Path()
            path.move(to: CGPoint(x: 26, y: 61))
            path.addLine(to: CGPoint(x: 50, y: 37))
            path.addLine(to: CGPoint(x: 74, y: 61))
            stroke(path, 9)
        case .waves:
            var path = Path()
            // Three rows of two quadratic arcs, the second mirroring the first.
            for y in [37.0, 51.0, 65.0] {
                path.move(to: CGPoint(x: 24, y: y))
                path.addQuadCurve(to: CGPoint(x: 50, y: y), control: CGPoint(x: 37, y: y - 10))
                path.addQuadCurve(to: CGPoint(x: 76, y: y), control: CGPoint(x: 63, y: y + 10))
            }
            stroke(path, 7)
        case .hex:
            stroke(polygon([(50, 20), (76, 35), (76, 65), (50, 80), (24, 65), (24, 35)]), 7)
        case .diamond:
            // A rounded square turned 45 degrees, with a disc cut out of its center.
            let square = Path(roundedRect: CGRect(x: 29, y: 29, width: 42, height: 42), cornerSize: CGSize(width: 7, height: 7))
            let rotation = CGAffineTransform(translationX: 50, y: 50).rotated(by: .pi / 4).translatedBy(x: -50, y: -50)
            context.fill(square.applying(rotation), with: white)
            context.fill(disc(50, 50, 8), with: base)
        case .rings:
            stroke(disc(50, 50, 28), 7)
            context.fill(disc(50, 50, 10), with: white)
        case .bolt:
            // The thin stroke rounds the polygon's sharp corners.
            let path = polygon([(56, 16), (32, 54), (49, 54), (44, 84), (70, 44), (53, 44)])
            context.fill(path, with: white)
            stroke(path, 3)
        case .leaf:
            // Two mirrored curves make the leaf; the vein is cut through it in the disc color.
            var path = Path()
            path.move(to: CGPoint(x: 50, y: 20))
            path.addCurve(to: CGPoint(x: 50, y: 80), control1: CGPoint(x: 78, y: 28), control2: CGPoint(x: 82, y: 62))
            path.addCurve(to: CGPoint(x: 50, y: 20), control1: CGPoint(x: 18, y: 62), control2: CGPoint(x: 22, y: 28))
            path.closeSubpath()
            context.fill(path, with: white)
            var vein = Path()
            vein.move(to: CGPoint(x: 50, y: 32))
            vein.addLine(to: CGPoint(x: 50, y: 70))
            context.stroke(vein, with: base, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        case .peaks:
            // A mountain outline, filled and thinly stroked to soften the corners.
            let path = polygon([(20, 72), (44, 36), (58, 58), (67, 47), (80, 72)])
            context.fill(path, with: white)
            stroke(path, 4)
        case .sun:
            context.fill(disc(50, 50, 13), with: white)
            var rays = Path()
            // Eight rays at 45-degree steps, from radius 22 to 32.
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4
                rays.move(to: CGPoint(x: 50 + 22 * cos(angle), y: 50 + 22 * sin(angle)))
                rays.addLine(to: CGPoint(x: 50 + 32 * cos(angle), y: 50 + 32 * sin(angle)))
            }
            stroke(rays, 6)
        case .clover:
            // Four overlapping discs around the center.
            for (x, y) in [(50.0, 31.0), (69.0, 50.0), (50.0, 69.0), (31.0, 50.0)] {
                context.fill(disc(x, y, 14), with: white)
            }
        case .spark:
            // A four-pointed star: four concave curves between the points.
            var path = Path()
            path.move(to: CGPoint(x: 50, y: 16))
            path.addCurve(to: CGPoint(x: 84, y: 50), control1: CGPoint(x: 54, y: 42), control2: CGPoint(x: 58, y: 46))
            path.addCurve(to: CGPoint(x: 50, y: 84), control1: CGPoint(x: 58, y: 54), control2: CGPoint(x: 54, y: 58))
            path.addCurve(to: CGPoint(x: 16, y: 50), control1: CGPoint(x: 46, y: 58), control2: CGPoint(x: 42, y: 54))
            path.addCurve(to: CGPoint(x: 50, y: 16), control1: CGPoint(x: 42, y: 46), control2: CGPoint(x: 46, y: 42))
            path.closeSubpath()
            context.fill(path, with: white)
        }
    }
}

/// The eight disc colors for initials.
enum AvatarPalette {
    static let colors: [Color] = [
        AvatarSymbol.bolt.color, AvatarSymbol.chevron.color, AvatarSymbol.waves.color, AvatarSymbol.hex.color,
        AvatarSymbol.diamond.color, AvatarSymbol.rings.color, AvatarSymbol.leaf.color, AvatarSymbol.spark.color,
    ]

    // color(at index): A palette color, wrapping out-of-range indexes.
    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// What a key's avatar shows: a drawn symbol, the name's initials on a colored disc, or an image
/// the user chose.
enum AvatarChoice: Codable, Equatable {
    case symbol(AvatarSymbol)
    case initials(colorIndex: Int)
    case image(fileName: String)
}

/// Remembers each key's avatar in the app container, keyed by the key's fingerprint, so a key
/// looks the same wherever it appears and nothing in the key folders changes. Images are copied
/// into the container, downscaled, and loaded on demand.
@MainActor
final class AvatarStore: ObservableObject {
    @Published private(set) var choices: [String: AvatarChoice] = [:]
    private var imageCache: [String: NSImage] = [:]
    private let defaults = UserDefaults.standard
    private static let choicesKey = "AgeminAvatars"
    /// Imported images are square and at most this many pixels on a side.
    private static let imageSide = 256

    // init(): Load the saved choices.
    init() {
        // A corrupt or missing record starts empty.
        if let data = defaults.data(forKey: Self.choicesKey), let saved = try? JSONDecoder().decode([String: AvatarChoice].self, from: data) {
            choices = saved
        }
    }

    /// The folder that holds imported images, inside the app container.
    private var imageDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Agemin/Avatars", isDirectory: true)
    }

    // choice(for key): The avatar for a key: the saved choice, or initials in a color that the
    // key itself determines, so the default is stable.
    func choice(for key: String) -> AvatarChoice {
        choices[key] ?? Self.defaultChoice(for: key)
    }

    // isCustom(for key): Whether the user chose this key's avatar.
    func isCustom(for key: String) -> Bool {
        choices[key] != nil
    }

    // defaultChoice(for key): Initials on a disc whose color comes from a hash of the key.
    static func defaultChoice(for key: String) -> AvatarChoice {
        let digest = SHA256.hash(data: Data(key.utf8))
        return .initials(colorIndex: Int(Data(digest).first ?? 0) % AvatarPalette.colors.count)
    }

    // set(choice, for key): Save a choice, dropping the image file of a replaced image choice.
    func set(_ choice: AvatarChoice, for key: String) {
        // An image that is no longer referenced is deleted from the container.
        if case .image(let fileName) = choices[key] ?? .initials(colorIndex: 0), choice != .image(fileName: fileName) {
            removeImageFile(fileName)
        }
        choices[key] = choice
        save()
    }

    // reset(for key): Return to the default initials.
    func reset(for key: String) {
        // A saved image is deleted along with its record.
        if case .image(let fileName)? = choices[key] { removeImageFile(fileName) }
        choices[key] = nil
        save()
    }

    /// The largest image, in pixels per side, that an avatar is made from. Read from error text
    /// too, so it is not tied to the main actor.
    nonisolated static let maximumImageSide = 8192

    // importImage(from url, for key): Copy an image into the container as a square PNG and use it.
    // ImageIO decodes a reduced copy, so a huge image never fills memory.
    func importImage(from url: URL, for key: String) throws {
        // A file chosen in a panel or dropped from Finder may need its security scope opened.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw AvatarError.notAnImage
        }
        // The dimensions come from the header, before any pixels are decoded.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw AvatarError.notAnImage
        }
        guard width <= Self.maximumImageSide, height <= Self.maximumImageSide else { throw AvatarError.tooLarge }
        // Decode at twice the stored size so the downscale keeps detail; the transform applies the
        // EXIF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.imageSide * 2,
            kCGImageSourceShouldCache: false,
        ]
        guard let reduced = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AvatarError.notAnImage
        }
        // Store the square PNG and switch the key to it, dropping any stale cached copy.
        let png = try Self.squarePNG(from: reduced)
        let fileName = Self.fileName(for: key)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try png.write(to: imageDirectory.appendingPathComponent(fileName), options: [])
        imageCache[fileName] = nil
        choices[key] = .image(fileName: fileName)
        save()
    }

    // image(named fileName): The imported image, loaded once. A name that is not one Agemin
    // makes is ignored, so a corrupt record cannot reach outside the avatar folder.
    func image(named fileName: String) -> NSImage? {
        guard Self.isImageFileName(fileName) else { return nil }
        // Serve the cached copy when there is one.
        if let cached = imageCache[fileName] { return cached }
        guard let image = NSImage(contentsOf: imageDirectory.appendingPathComponent(fileName)) else { return nil }
        imageCache[fileName] = image
        return image
    }

    // fileName(for key): The first 12 bytes of the key's SHA-256 as hex plus `.png`, so each key
    // has one image file.
    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    // isImageFileName(name): Whether the name has the exact shape fileName(for:) produces: 24
    // lowercase hex digits and `.png`.
    private static func isImageFileName(_ name: String) -> Bool {
        name.count == 28 && name.hasSuffix(".png") && name.dropLast(4).allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    // squarePNG(from source): Center-crop the image to a square, scale it down, and encode PNG.
    private static func squarePNG(from source: CGImage) throws -> Data {
        let side = min(source.width, source.height)
        let target = min(side, imageSide)
        guard let context = CGContext(
            data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AvatarError.notAnImage }
        context.interpolationQuality = .high
        // Draw the centered square of the source scaled into the target.
        let crop = CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        guard let cropped = source.cropping(to: crop) else { throw AvatarError.notAnImage }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let result = context.makeImage() else { throw AvatarError.notAnImage }
        let bitmap = NSBitmapImageRep(cgImage: result)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AvatarError.notAnImage }
        return png
    }

    // removeImageFile(fileName): Delete an imported image and forget its cached copy. Only a
    // name Agemin makes is deleted, so a corrupt record cannot remove another file.
    private func removeImageFile(_ fileName: String) {
        imageCache[fileName] = nil
        guard Self.isImageFileName(fileName) else { return }
        try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(fileName))
    }

    // save(): Write the choices to preferences.
    private func save() {
        // Encoding a dictionary of simple enums cannot fail in practice; a failure keeps the old record.
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: Self.choicesKey) }
    }

    // initials(for name): Up to two letters: the first letters of the first two words, uppercased.
    // Words are split on spaces, dashes, underscores, and dots.
    static func initials(for name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }.filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }
}

/// Problems with an image chosen for an avatar.
enum AvatarError: LocalizedError {
    case notAnImage
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAnImage: return localized("That file is not an image Agemin can read.")
        case .tooLarge: return localizedFormat("The image is larger than %lld pixels on a side. Choose a smaller one.", Int64(AvatarStore.maximumImageSide))
        }
    }
}
