import AppKit

/// The app icon as an image. It becomes the Dock icon at launch, and alerts pick it up from
/// there.
enum AppIcon {
    // make([size = 128]): The bundled icon when resources are present, at its own size; otherwise
    // a drawn stand-in of the given size, for isolated source fixtures without resources.
    static func make(size: CGFloat = 128) -> NSImage {
        // Use the bundled icon for shipped builds and previews that include resources.
        if let url = AppResources.resourcesURL?.appendingPathComponent("AgeminIcon.icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Keep a development fallback for isolated source fixtures without bundled resources:
        // a rounded accent-colored square with a white lock symbol.
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                     xRadius: size * 0.23, yRadius: size * 0.23).fill()
        // The shield symbol is only a fallback for a symbol set without the lock glyph.
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Agemin")?
            .withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: "Agemin")!
        symbol.draw(in: NSRect(x: size * 0.26, y: size * 0.24, width: size * 0.48, height: size * 0.52))
        image.unlockFocus()
        return image
    }
}
