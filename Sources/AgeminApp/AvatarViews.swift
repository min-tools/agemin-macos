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

/// The popover that chooses a key's avatar: the drawn symbols, initials in the palette colors,
/// or an image.
struct AvatarPicker: View {
    let key: String
    let name: String
    @ObservedObject var store: AvatarStore
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?

    private var current: AvatarChoice { store.choice(for: key) }
    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 10), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The current avatar and the key's name head the popover.
            HStack(spacing: 10) {
                AvatarView(choice: current, name: name, size: 34, store: store)
                Text(localizedFormat("Avatar for %@", name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }

            // The drawn symbols, the chosen one ringed in the accent color.
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AvatarSymbol.allCases, id: \.self) { symbol in
                    choiceButton(.symbol(symbol), label: symbol.title) {
                        AvatarView(choice: .symbol(symbol), name: name, size: 44, store: store)
                    }
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Initials: a preview in the current color, then the palette.
            HStack(spacing: 10) {
                Text(localized("Initials"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                choiceButton(.initials(colorIndex: initialsColorIndex), label: localized("Initials")) {
                    AvatarView(choice: .initials(colorIndex: initialsColorIndex), name: name, size: 32, store: store)
                }
                ForEach(0..<AvatarPalette.colors.count, id: \.self) { index in
                    Button {
                        store.set(.initials(colorIndex: index), for: key)
                    } label: {
                        Circle()
                            .fill(AvatarPalette.color(at: index))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: current == .initials(colorIndex: index) ? 2 : 0).padding(-3))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.bare)
                    .keyboardFocusable()
                    .accessibilityLabel(localizedFormat("Initials color %lld", Int64(index + 1)))
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Choose Image imports a file; Use Initials drops the saved choice.
            HStack(spacing: 10) {
                Button {
                    chooseImage()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                        Text(localized("Choose Image"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.agemin(.secondary, size: .small))
                .keyboardFocusable()
                Button(localized("Use Initials")) {
                    store.reset(for: key)
                }
                .buttonStyle(.agemin(.secondary, size: .small))
                .keyboardFocusable()
                .frame(maxWidth: .infinity)
            }
            // An image that could not be read is reported here.
            if let importError {
                Text(importError)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }
            Text(localized("Agemin stores the avatar under this key's fingerprint. Nothing in your key folders is changed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 372)
    }

    /// The palette index of the current initials choice, or the key's default color.
    private var initialsColorIndex: Int {
        // A chosen initials color wins.
        if case .initials(let index) = current { return index }
        // Otherwise the color the key's hash picks, which is always initials.
        if case .initials(let index) = AvatarStore.defaultChoice(for: key) { return index }
        return 0
    }

    // choiceButton(choice, label, content): A ringed button that applies the choice.
    private func choiceButton<Content: View>(_ choice: AvatarChoice, label: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            store.set(choice, for: key)
        } label: {
            content()
                .overlay(Circle().stroke(Theme.accent, lineWidth: current == choice ? 2.5 : 0).padding(-4))
                .contentShape(Circle())
        }
        .buttonStyle(.bare)
        .keyboardFocusable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(current == choice ? .isSelected : [])
    }

    // chooseImage(): Pick an image file and import it.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.image]
        panel.message = localized("Choose an image for this key's avatar")
        panel.prompt = localized("Use Image")
        // If the popover closes behind the panel, the result still applies, since the store is
        // updated by key.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importImage(from: url, for: key)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}
