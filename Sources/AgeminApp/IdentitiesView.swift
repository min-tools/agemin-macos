import AppKit
import SwiftUI

/// The Identities page: the private keys that decrypt files, and a way to make a new age key.
struct IdentitiesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore

    // init(model): Observe the model and its key store.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        PageScroll {
            PageHeader(symbol: "key.fill", title: "Identities", subtitle: "The private keys that open files encrypted for you: SSH keys from ~/.ssh and age identity files. Agemin reads them and never changes them.")

            // The folder, or the prompt to choose one.
            if let folder = store.identitiesFolder {
                FolderRow(
                    url: folder,
                    onChange: { store.chooseIdentitiesFolder(in: NSApp.keyWindow) },
                    onReveal: { store.revealInFinder(folder) },
                    onRefresh: { store.refresh() }
                )
            } else {
                // No folder yet: say what goes there and offer the chooser.
                FolderPrompt(
                    title: "Choose your SSH folder",
                    detail: "Agemin lists the private keys in that folder and uses them to decrypt files. This folder is usually ~/.ssh. You can add keys stored elsewhere individually.",
                    buttonTitle: "Choose Folder"
                ) { store.chooseIdentitiesFolder(in: NSApp.keyWindow) }
            }

            // A freshly made key, with its public half ready to share.
            if let generated = model.generatedKey {
                generatedCard(generated.publicKey, savedTo: generated.savedTo)
            }

            // The filter and the two ways to add a key: a file from anywhere, or a new age key.
            HStack(spacing: 10) {
                SearchField(placeholder: "Filter identities", text: $model.identityFilter, trailing: "⌘F", compact: true, focusOnWindowOpen: false, textVerticalOffset: 0)
                    .frame(maxWidth: 360)
                Spacer()
                Button(localized("Add Key File")) { store.addIdentityFile(in: NSApp.keyWindow) }
                    .buttonStyle(.agemin(.secondary, size: .small))
                    .keyboardFocusable()
                Button(localized("New age Key")) { model.generateIdentity(in: NSApp.keyWindow) }
                    .buttonStyle(.agemin(.primary, size: .small, shortcut: "⌘N"))
                    .keyboardFocusable()
            }

            list
        }
    }

    // generatedCard(publicKey, savedTo): Show the new key's public half and offer to add it as a
    // recipient.
    private func generatedCard(_ publicKey: String, savedTo url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The heading, with a way to hide the card.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.success)
                Text(localized("New age key saved"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                IconButton(symbol: "xmark", help: "Hide this card", variant: .ghost, size: .small) { model.dismissGeneratedKey() }
            }
            // The file and its public half, each with its action.
            DetailRow(label: "Identity file", value: KeyStore.abbreviate(url.path), mono: true) {
                Button(localized("Reveal")) { store.revealInFinder(url) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            DetailRow(label: "Public key", value: publicKey, mono: true) {
                Button(localized("Copy")) { model.copy(publicKey) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            // Saving the public half as a recipient lets the user encrypt for themselves.
            HStack(spacing: 10) {
                Button(localized("Add to Recipients")) { addAsRecipient(publicKey) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
                Text(localized("Share the public key with people who should encrypt files for you. Keep the identity file private because only your account can read it."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.success.opacity(0.35), lineWidth: 1))
    }

    // addAsRecipient(publicKey): Save the public key as a `.pub` file under a chosen name.
    private func addAsRecipient(_ publicKey: String) {
        // Without a folder there is nowhere to save; ask for one, and the user clicks again.
        guard store.recipientsFolder != nil else {
            store.chooseRecipientsFolder(in: NSApp.keyWindow)
            return
        }
        // Ask for the file name; the prompt returns nil when canceled.
        guard let name = NamePrompt.ask(
            title: localized("Save Recipient"),
            message: localized("The key is saved as <name>.pub in the recipients folder."),
            placeholder: localized("Name"),
            initial: "me",
            in: NSApp.keyWindow
        ) else { return }
        // The model also selects the saved key for encryption.
        do {
            try model.saveRecipient(name: name, line: publicKey)
        } catch {
            model.presentError(localized("The recipient could not be saved."), detail: error.localizedDescription)
        }
    }

    /// The identities that pass the filter, or why there are none, with the count below.
    @ViewBuilder private var list: some View {
        let entries = model.filteredIdentities
        VStack(alignment: .leading, spacing: 8) {
            // Nothing found, nothing added, or nothing matching the filter.
            if entries.isEmpty {
                Text(localized(store.identities.isEmpty ? "No private keys found yet. Choose the folder that holds them, add a key file, or create a new age key." : "No identities match the filter."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                // One row per identity, with copy, reveal, and remove for added files.
                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        IdentityRow(entry: entry, avatars: model.avatars) {
                            // Only a key with a known public half has something to copy.
                            if let line = entry.publicKeyLine { model.copy(line) }
                        } onReveal: {
                            store.revealInFinder(entry.url)
                        } onRemove: {
                            store.removeExtraIdentityFile(entry.url)
                        }
                    }
                }
                .padding(8)
                .card()
            }
            Text(countText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// How many identities were found and how many are usable.
    private var countText: String {
        let total = store.identities.count
        let usable = store.identities.filter(\.isUsable).count
        // Everything usable needs no second number.
        if total == usable { return total == 1 ? localized("1 identity") : localizedFormat("%lld identities", Int64(total)) }
        return localizedFormat("%lld identities · %lld usable", Int64(total), Int64(usable))
    }
}

/// One identity in the list: avatar, name, kind, protection, fingerprint or problem, and its
/// actions. The avatar is shared with the matching recipient, since both are stored under the
/// key's fingerprint.
private struct IdentityRow: View {
    let entry: IdentityEntry
    @ObservedObject var avatars: AvatarStore
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // A key whose public half is known gets an avatar; others keep a key tile.
            if entry.isUsable, entry.publicKeyLine != nil {
                AvatarButton(key: entry.avatarKey, name: entry.name, size: 34, store: avatars)
            } else {
                // A key tile, slashed when the file cannot be used.
                IconTile(symbol: entry.isUsable ? "key.fill" : "key.slash", size: 34, tint: entry.isUsable ? Theme.textSecondary : Theme.warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    KeyKindChip(kind: entry.kind, usable: entry.isUsable)
                    // Protected keys ask for their passphrase when used.
                    if entry.isProtected {
                        Chip(text: localized("passphrase"), mono: false, tone: .warning, compact: true)
                    }
                    // Files with several age keys say so.
                    if entry.count > 1 {
                        Chip(text: localizedFormat("%lld keys", Int64(entry.count)), mono: false, compact: true)
                    }
                    // Files added individually are marked, since only those can be removed.
                    if entry.isExtra {
                        Chip(text: localized("added"), mono: false, tone: .accent, compact: true)
                    }
                }
                // The fingerprint identifies the key; a problem replaces it.
                if let problem = entry.problem {
                    Text(problem)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                } else if let fingerprint = entry.fingerprint {
                    // The SSH fingerprint, or the age public key itself.
                    Text(fingerprint)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    // A protected age identity file has no known public key, so its path stands in.
                    Text(entry.displayPath)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            // The actions dim until the row is hovered but stay clickable and keyboard focusable.
            HStack(spacing: 4) {
                Button(localized("Copy Public Key")) { onCopy() }
                    .buttonStyle(.agemin(.ghost, size: .small))
                    .keyboardFocusable()
                    .disabled(entry.publicKeyLine == nil)
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder", variant: .ghost, size: .small, action: onReveal)
                // Only files added individually can be removed from the list.
                if entry.isExtra {
                    IconButton(symbol: "minus.circle", help: "Remove from the list", variant: .ghost, size: .small, action: onRemove)
                }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .hoverHighlight()
        .onHover { hovering = $0 }
    }
}
