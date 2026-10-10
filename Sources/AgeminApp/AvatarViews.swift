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

/// An avatar that opens the picker when clicked and takes a dropped image.
struct AvatarButton: View {
    /// The key the avatar belongs to, usually its fingerprint.
    let key: String
    let name: String
    var size: CGFloat = 30
    @ObservedObject var store: AvatarStore
    @State private var isPicking = false
    @State private var targeted = false
    @State private var dropError: String?

    var body: some View {
        Button {
            isPicking = true
        } label: {
            AvatarView(choice: store.choice(for: key), name: name, size: size, store: store)
                .overlay(Circle().stroke(Theme.accent, lineWidth: targeted ? 2 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.bare)
        .keyboardFocusable()
        .help(localized("Click to change the avatar, or drop an image on it"))
        .accessibilityLabel(localizedFormat("Avatar for %@", name))
        .popover(isPresented: $isPicking, arrowEdge: .trailing) {
            AvatarPicker(key: key, name: name, store: store)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            drop(providers)
        }
        // A rejected drop is explained in an alert, since the button has no room for text.
        .alert(localized("The image could not be used"), isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button(localized("OK")) { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
    }

    // drop(providers): Import the first dropped file as the avatar image.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            // The item arrives as URL data or as a URL, depending on the source.
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                // Some sources hand over the URL object itself.
                url = item as? URL
            }
            guard let url else { return }
            // The import touches the store and view state, so it runs on the main actor.
            Task { @MainActor in
                do {
                    try store.importImage(from: url, for: key)
                } catch {
                    dropError = error.localizedDescription
                }
            }
        }
        // The drop is accepted before the file loads; a bad image is reported by the alert.
        return true
    }
}
