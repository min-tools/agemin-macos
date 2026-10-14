#!/usr/bin/env python3
"""Check that the app follows the system appearance: semantic colors for text and explicit light/dark pairs for brand surfaces."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
# Scan every source for forced appearances, and the theme and the banner for required tokens.
sources = '\n'.join(path.read_text(encoding='utf-8') for path in (ROOT / 'Sources/AgeminApp').glob('*.swift'))
theme = (ROOT / 'Sources/AgeminApp/Theme.swift').read_text(encoding='utf-8')
banner = (ROOT / 'Sources/AgeminApp/AccessBanner.swift').read_text(encoding='utf-8')

# Search for the SwiftUI and AppKit calls that pin an appearance.
for forbidden in ('.preferredColorScheme(.dark)', 'NSAppearance(named: .darkAqua)', 'window.appearance ='):
    # A forced appearance would override the user's system setting.
    if forbidden in sources:
        print(f'FAIL: forced appearance remains: {forbidden}')
        sys.exit(1)

# Semantic AppKit colors follow the system appearance, including increased contrast, on their own.
required = (
    '.windowBackgroundColor', '.controlBackgroundColor', '.textBackgroundColor',
    '.labelColor', '.secondaryLabelColor', '.tertiaryLabelColor',
    '.separatorColor', '.controlAccentColor', '.alternateSelectedControlTextColor',
)
missing = [token for token in required if token not in theme]
# A missing token needs review; this text check cannot establish the rendered color.
if missing:
    print('FAIL: missing semantic theme tokens: ' + ', '.join(missing))
    sys.exit(1)

# Brand surfaces need Light/Dark pairs, also selected for high-contrast appearances.
adaptive_tokens = (
    'NSColor(name: nil)', '.accessibilityHighContrastDarkAqua',
    'static let sidebarBackground = adaptive(', 'static let badgeActiveBackground = adaptive(',
    'static let segmentSelected = adaptive(', 'static let labelText = adaptive(',
    'static let inputBackground = adaptive(', 'static let inputBorder = adaptive(',
    'static let inputPlaceholderNSColor = adaptiveNSColor(', 'static let keyCapTop = adaptive(',
)
missing = [token for token in adaptive_tokens if token not in theme]
# Report every missing palette entry at once.
if missing:
    print('FAIL: missing adaptive palette tokens: ' + ', '.join(missing))
    sys.exit(1)

# Declaring the sidebar token is not enough; the sidebar must actually draw with it.
if '.background(Theme.sidebarBackground)' not in sources:
    print('FAIL: sidebar does not use its adaptive background')
    sys.exit(1)

# The main window keeps the standard title bar instead of a custom full-size content layout.
standard_titlebar = (
    '.windowStyle(.titleBar)',
    'window.styleMask.remove(.fullSizeContentView)',
    'window.titleVisibility = .visible',
    'window.titlebarAppearsTransparent = false',
    'window.titlebarSeparatorStyle = .line',
)
missing = [token for token in standard_titlebar if token not in sources]
# Each setting undoes part of the full-size style; all of them are needed.
if missing:
    print('FAIL: main window no longer uses the standard title bar: ' + ', '.join(missing))
    sys.exit(1)

# The access banner tints the system orange, which adapts to dark mode on its own.
if 'Color(nsColor: .systemOrange).opacity(0.16)' not in banner:
    print('FAIL: the restricted-access banner no longer uses the semantic amber tint')
    sys.exit(1)
# The banner's purchase and restore buttons share the bordered style with no accent tint.
if banner.count('.buttonStyle(.bordered)') < 2 or '.tint(nil)' not in banner:
    print('FAIL: purchase and restore must use the same neutral native style')
    sys.exit(1)

# Result cards and drop targets tint semantic colors rather than fixed greens and blues.
for token in ('Theme.success.opacity(0.07)', 'Theme.accent.opacity(0.06)'):
    # A dropped tint means a surface went back to a fixed color.
    if token not in sources:
        print(f'FAIL: the result and drop surfaces no longer use the semantic tint {token}')
        sys.exit(1)

print('Adaptive light/dark appearance and semantic macOS colors verified.')
