import AppKit

/// The policy window. Escape closes it.
private final class PrivacyPolicyPanel: NSPanel {
    // cancelOperation(sender): Close on Escape.
    override func cancelOperation(_ sender: Any?) { close() }
}

/// One native window surface keeps the policy title bar and document visually connected.
private final class PrivacyPolicyBackgroundView: NSView {
    /// Stands in for the native title bar separator, which is turned off, so the line sits on
    /// the shared surface at the same place.
    private final class HairlineView: NSView {
        // draw(dirtyRect): Fill one device pixel along the top edge. The rect comes from bounds,
        // not dirtyRect, so a partial redraw keeps the whole line.
        override func draw(_ dirtyRect: NSRect) {
            let thickness = 1 / (window?.backingScaleFactor ?? 2)
            NSColor.separatorColor.setFill()
            NSRect(
                x: 0,
                y: bounds.height - thickness,
                width: bounds.width,
                height: thickness
            ).fill()
        }

        // viewDidChangeEffectiveAppearance(): Redraw so the line's color follows light and
        // dark mode.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private let hairline = HairlineView()

    // init(frame frameRect): Build the surface in code.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMaterial()
        installHairline()
    }

    // init?(coder): The same setup when unarchived.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installMaterial()
        installHairline()
    }

    // installMaterial(): Fill the whole surface, title bar included, with the window background
    // material.
    private func installMaterial() {
        let material = NSVisualEffectView()
        material.material = .windowBackground
        material.blendingMode = .withinWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // installHairline(): Add the separator across the full width. Its vertical position is
    // pinned later, once the window knows where its title bar ends.
    private func installHairline() {
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // pinHairline(to titlebarBottom): Put the separator at the title bar's bottom edge.
    func pinHairline(to titlebarBottom: NSLayoutYAxisAnchor) {
        hairline.topAnchor.constraint(equalTo: titlebarBottom).isActive = true
    }
}

// privacyPolicyContentSize(size, in window): Add the title bar height to a document size. The window
// runs its content under the title bar, so this keeps the visible document at the given size.
private func privacyPolicyContentSize(_ size: NSSize, in window: NSWindow) -> NSSize {
    let titlebarHeight = max(
        0,
        (window.contentView?.bounds.height ?? 0) - window.contentLayoutRect.height
    )
    return NSSize(width: size.width, height: size.height + titlebarHeight)
}

// installPrivacyPolicyContent(in window): Make the title bar transparent with content running
// under it, install the shared surface, and return a container pinned below the title bar for
// the document and the button.
private func installPrivacyPolicyContent(in window: NSWindow) -> NSView {
    // Hide the native title bar chrome and let the content extend under it.
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)

    let surface = PrivacyPolicyBackgroundView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = surface

    // The container starts where the title bar ends, so the document never slides under it.
    let content = NSView(frame: window.contentLayoutRect)
    content.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(content)
    // contentLayoutGuide tracks the area below the title bar; it is typed as Any, hence the cast.
    if let guide = window.contentLayoutGuide as? NSLayoutGuide {
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: guide.topAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        surface.pinHairline(to: content.topAnchor)
    }
    return content
}
