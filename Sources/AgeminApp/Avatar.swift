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
