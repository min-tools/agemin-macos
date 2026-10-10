import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A key's avatar at a given size: a drawn symbol, initials on a colored disc, or the user's image.
struct AvatarView: View {
    let choice: AvatarChoice
    let name: String
    var size: CGFloat = 30
    @ObservedObject var store: AvatarStore

    var body: some View {
        ZStack {
            switch choice {
            case .symbol(let symbol):
                // The disc and its glyph are painted together in one canvas.
                Canvas { context, _ in
                    context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size)), with: .color(symbol.color))
                    symbol.draw(in: &context, size: size)
                }
            case .initials(let colorIndex):
                // Initials sit on a palette disc.
                Circle().fill(AvatarPalette.color(at: colorIndex))
                Text(AvatarStore.initials(for: name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            case .image(let fileName):
                // A missing image file falls back to the default initials.
                if let image = store.image(named: fileName) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                } else {
                    // The first palette color stands in until the image file is back.
                    Circle().fill(AvatarPalette.color(at: 0))
                    Text(AvatarStore.initials(for: name))
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        // The faint ring keeps a light image visible on a light background; the avatar is
        // decorative, so VoiceOver skips it and reads the owning control instead.
        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
