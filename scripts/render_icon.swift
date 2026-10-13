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
