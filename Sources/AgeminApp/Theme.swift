import AppKit
import SwiftUI

/// Status colors used by chips, pills, notice cards, and status dots.
enum Tone { case neutral, accent, positive, warning, negative }

/// Design tokens shared by every screen. Text and status colors are macOS semantic colors;
/// branded surfaces use fixed Light/Dark pairs so controls keep their hierarchy.
enum Theme {
    // Page and sidebar backgrounds are fixed pairs; surfaces, borders, text, the accent, and the
    // status colors are macOS semantic colors, so they follow the system and its accent setting.
    static let background = adaptive(light: 0xFBFBFD, dark: 0x1C1C1E)
    static let sidebarBackground = adaptive(light: 0xF5F5F7, dark: 0x232325)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .underPageBackgroundColor)
    static let surfaceSunken = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let borderStrong = Color(nsColor: .gridColor)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)
    static let accentBright = Color(nsColor: .controlAccentColor)
    static let accentDeep = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let cyan = Color(nsColor: .systemTeal)

    // Fixed Light/Dark pairs for sidebar states, inputs, badges, segments, and key caps.
    static let sidebarSelection = adaptive(light: 0xE3ECFA, dark: 0x22324A)
    static let sidebarHover = adaptive(light: 0xEDEDF0, dark: 0x2C2C2E)
    static let labelText = adaptive(light: 0x86868B, dark: 0xA1A1A6)
    static let inputBackground = adaptive(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let inputBorder = adaptive(light: 0xC7C7CC, dark: 0x545458)
    static let checkboxBorder = adaptive(light: 0x86868B, dark: 0x8E8E93)
    static let inputPlaceholderNSColor = adaptiveNSColor(light: 0x86868B, dark: 0xA1A1A6)
    static let inputPlaceholder = Color(nsColor: inputPlaceholderNSColor)
    static let badgeBackground = adaptive(light: 0xFFFFFF, dark: 0x303033)
    static let badgeBorder = adaptive(light: 0xD1D1D6, dark: 0x545458)
    static let badgeText = adaptive(light: 0x3A3A3C, dark: 0xE5E5EA)
    static let badgeActiveBackground = adaptive(light: 0xEEF4FF, dark: 0x16304F)
    static let badgeActiveBorder = adaptive(light: 0xB9D2F7, dark: 0x2F5A8F)
    static let badgeActiveText = adaptive(light: 0x0A5FCC, dark: 0x64A8FF)
    static let segmentTrack = adaptive(light: 0xE5E5EA, dark: 0x2C2C2E)
    static let segmentSelected = adaptive(light: 0xFFFFFF, dark: 0x5A5A5E)
    static let keyCapTop = adaptive(light: 0xFFFFFF, dark: 0x3A3A3E)
    static let keyCapBottom = adaptive(light: 0xEBEBEF, dark: 0x2A2A2E)
    static let keyCapEdge = adaptive(light: 0xC2C2C8, dark: 0x1A1A1C)

    // Corner radii and control heights shared by every control.
    static let radius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let controlHeight: CGFloat = 34
    static let smallControlHeight: CGFloat = 28

    /// The top-to-bottom accent fill of primary buttons, switches, and checked boxes.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.88), accent], startPoint: .top, endPoint: .bottom)
    }

    // mono([size = 12.5], [weight = .regular]): The monospaced system font used for shortcuts,
    // keys, fingerprints, and paths.
    static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // color(for tone): The text or tint color that stands for a status tone.
    static func color(for tone: Tone) -> Color {
        switch tone {
        case .neutral: return textPrimary
        case .accent: return accent
        case .positive: return success
        case .warning: return warning
        case .negative: return danger
        }
    }

    // adaptive(light, dark): A SwiftUI color from two 0xRRGGBB values, resolved through AppKit so
    // windows update immediately when macOS changes appearance. High-contrast appearances keep
    // the same pair; components add stronger strokes themselves.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    // adaptiveNSColor(light, dark): The AppKit form of adaptive(light:dark:), for custom controls
    // that cannot take a SwiftUI `Color`, such as the placeholder drawn by `StableInputTextView`.
    static func adaptiveNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            // Both dark appearances take the dark value; anything else, including an unknown
            // appearance, takes the light one.
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .aqua,
            ])
            let value = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                ? dark : light
            // Unpack 0xRRGGBB into sRGB components.
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

// MARK: - Buttons

/// How a button is filled: `primary` is the accent call to action, `secondary` the default,
/// `ghost` has no resting fill, `danger` is tinted red, `success` is tinted green for the buttons
/// on a result card, and `link` reads as text.
enum ButtonVariant { case primary, secondary, ghost, danger, success, link }
/// Regular buttons are `Theme.controlHeight` tall, small ones `Theme.smallControlHeight`.
enum ButtonSize { case regular, small }

/// The single button style of the app. Hover changes the fill or glow but never the shape, and a
/// button's own shortcut is printed on it as a chip.
struct AgeminButtonStyle: ButtonStyle {
    var variant: ButtonVariant = .secondary
    var size: ButtonSize = .regular
    var shortcut: String? = nil

    // makeBody(configuration): Hand the label to AgeminButtonBody, a view that can track hover.
    func makeBody(configuration: Configuration) -> some View {
        AgeminButtonBody(configuration: configuration, variant: variant, size: size, shortcut: shortcut)
    }
}

extension ButtonStyle where Self == AgeminButtonStyle {
    // agemin([variant = .secondary], [size = .regular], [shortcut = nil]): Dot-syntax access to the
    // style, as in `.buttonStyle(.agemin(.primary))`.
    static func agemin(_ variant: ButtonVariant = .secondary, size: ButtonSize = .regular, shortcut: String? = nil) -> AgeminButtonStyle {
        AgeminButtonStyle(variant: variant, size: size, shortcut: shortcut)
    }
}

/// A label-only style for rows, chips, and segments that draw their own states. Unlike the
/// system's plain style it adds no hover capsule, so custom fills keep their exact shape.
struct BareButtonStyle: ButtonStyle {
    // makeBody(configuration): Show the label as is and only dim it while pressed.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == BareButtonStyle {
    /// Dot-syntax access to the style, as in `.buttonStyle(.bare)`.
    static var bare: BareButtonStyle { BareButtonStyle() }
}

extension View {
    // keyboardFocusable(): Opt a custom control into macOS keyboard navigation even when the
    // system preference only tabs between text fields. Buttons keep their native Space and Return
    // activation behavior.
    func keyboardFocusable() -> some View {
        focusable(true, interactions: .activate)
    }
}
