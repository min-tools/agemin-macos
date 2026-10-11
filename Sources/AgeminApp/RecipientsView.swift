import AppKit
import SwiftUI

/// The Recipients page: the folder of `.pub` files and the keys in it.
struct RecipientsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore
    /// Whether the add form is open.
    @State private var isAdding = false
    /// Rises when the form appears, which moves keyboard focus into the Name field.
    @State private var focusName = false
    @State private var newName = ""
    @State private var newKey = ""
    /// Why the last save failed, shown in the form until it closes.
    @State private var addError: String?

    // init(model): Observe the model and its key store.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        PageScroll {
            PageHeader(symbol: "person.2.fill", title: "Recipients", subtitle: "Public keys for the people who can open your encrypted files. Each .pub file in the folder is one recipient, named after the file.")

            // The folder, or the prompt to choose one.
            if let folder = store.recipientsFolder {
                FolderRow(
                    url: folder,
                    onChange: { store.chooseRecipientsFolder(in: NSApp.keyWindow) },
                    onReveal: { store.revealInFinder(folder) },
                    onRefresh: { store.refresh() }
                )
            } else {
                // No folder yet: say what goes there and offer the chooser.
                FolderPrompt(
                    title: "Choose your recipients folder",
                    detail: "Agemin lists the .pub files there and lets you add new ones. Any folder works. ~/.age is a common choice.",
                    buttonTitle: "Choose Folder"
                ) { store.chooseRecipientsFolder(in: NSApp.keyWindow) }
            }

            // The filter, the add button, the form, and the list all need a folder.
            if store.recipientsFolder != nil {
                HStack(spacing: 10) {
                    SearchField(placeholder: "Filter recipients", text: $model.recipientFilter, trailing: "⌘F", compact: true, focusOnWindowOpen: false, textVerticalOffset: 0)
                        .frame(maxWidth: 360)
                    Spacer()
                    Button(localized("Add Recipient")) { isAdding.toggle() }
                        .buttonStyle(.agemin(isAdding ? .secondary : .primary, size: .small))
                        .keyboardFocusable()
                }
                // The add form folds out between the toolbar and the list.
                if isAdding {
                    addForm
                }
                list
            }
        }
        // The Encrypt page and the Keys menu ask for the form through the model.
        .onAppear(perform: openFormIfRequested)
        .onChange(of: model.addRecipientRequested) { openFormIfRequested() }
    }

    // openFormIfRequested(): Open the add form when another page or the menu asked for it.
    private func openFormIfRequested() {
        guard model.addRecipientRequested else { return }
        model.addRecipientRequested = false
        isAdding = true
    }

    // MARK: Adding

    /// The form for a new recipient: a name for the file and the public key line.
    @ViewBuilder private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading("New recipient")
            // The name becomes the file name; Return in the key field saves.
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Name"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    InputField(placeholder: "alice", text: $newName, requestedFocus: focusName)
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Public key"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    InputField(placeholder: "age1… or ssh-ed25519 AAAA… or ssh-rsa AAAA…", text: $newKey, mono: true, onSubmit: save)
                }
            }
            // The key is checked as it is typed, so a mistake shows before saving.
            if let hint = keyHint {
                Text(hint.text)
                    .font(.system(size: 12))
                    .foregroundStyle(hint.ok ? Theme.success : Theme.warning)
            }
            // A failed save keeps the form open with the reason.
            if let addError {
                Text(addError)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }
            // Save stays off until both fields hold something.
            HStack(spacing: 10) {
                Button(localized("Save")) { save() }
                    .buttonStyle(.agemin(.primary, size: .small))
                    .keyboardFocusable()
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(localized("Cancel")) { cancel() }
                    .buttonStyle(.agemin(.ghost, size: .small))
                    .keyboardFocusable()
                Spacer()
                Text(localized("Saved as <name>.pub in the recipients folder."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        // Typing can start at once; the flag drops with the form so the next opening focuses
        // again.
        .onAppear { focusName = true }
        .onDisappear { focusName = false }
    }

    /// What the typed key is, or why it is not usable.
    private var keyHint: (text: String, ok: Bool)? {
        let line = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        do {
            let recipient = try AgeRecipientParser.parse(line)
            return (localizedFormat("Valid %@ key", recipient.kind.label), true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    // save(): Write the new `.pub` file, select it for encryption, and close the form.
    private func save() {
        do {
            try model.saveRecipient(name: newName, line: newKey)
            cancel()
        } catch {
            addError = error.localizedDescription
        }
    }

    // cancel(): Close and clear the form.
    private func cancel() {
        isAdding = false
        newName = ""
        newKey = ""
        addError = nil
    }

    // MARK: List

    /// The recipients that pass the filter, or why there are none, with the count below.
    @ViewBuilder private var list: some View {
        let entries = model.filteredRecipients
        VStack(alignment: .leading, spacing: 8) {
            // Empty folder or empty filter result.
            if entries.isEmpty {
                Text(localized(store.recipients.isEmpty ? "No .pub files in this folder yet. Add a recipient, or copy a public key file in." : "No recipients match the filter."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                // One row per recipient, with copy, reveal, and delete.
                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        RecipientRow(entry: entry, avatars: model.avatars, isYou: model.isOwnKey(entry)) {
                            model.copy(entry.line)
                        } onReveal: {
                            store.revealInFinder(entry.url)
                        } onDelete: {
                            delete(entry)
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

    /// How many recipients the folder holds and how many are usable, with the avatar hint.
    private var countText: String {
        let total = store.recipients.count
        let usable = store.recipients.filter(\.isUsable).count
        let count: String
        // Everything usable needs no second number.
        if total == usable {
            count = total == 1 ? localized("1 recipient") : localizedFormat("%lld recipients", Int64(total))
        } else {
            // Some lines are not usable keys, so show both numbers.
            count = localizedFormat("%lld recipients · %lld usable", Int64(total), Int64(usable))
        }
        return count + " · " + localized("Click an avatar to change it, or drop an image onto it.")
    }

    // delete(entry): Confirm, then delete the `.pub` file behind the entry.
    private func delete(_ entry: RecipientEntry) {
        let url = entry.url
        // Confirm in an app-modal alert before touching the file.
        let alert = NSAlert()
        alert.messageText = localizedFormat("Delete %@?", url.lastPathComponent)
        alert.informativeText = localized("This deletes the file from the recipients folder. Files already encrypted for this key are not affected.")
        alert.addButton(withTitle: localized("Delete"))
        alert.addButton(withTitle: localized("Cancel"))
        // Delete is the first button.
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.removeRecipientFile(entry)
        } catch {
            model.presentError(localized("The recipient could not be deleted."), detail: error.localizedDescription)
        }
    }
}

/// One recipient in the list: avatar, name, kind, fingerprint or problem, and its actions.
private struct RecipientRow: View {
    let entry: RecipientEntry
    @ObservedObject var avatars: AvatarStore
    let isYou: Bool
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Unusable keys show a warning tile instead of an avatar.
            if entry.isUsable {
                AvatarButton(key: entry.avatarKey, name: entry.name, size: 34, store: avatars)
            } else {
                // A line that is not a usable key.
                IconTile(symbol: "person.fill.questionmark", size: 34, tint: Theme.warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    // The user's own key is marked.
                    if isYou {
                        Text(localized("you"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    KeyKindChip(kind: entry.kind, usable: entry.isUsable)
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
                }
            }
            Spacer(minLength: 8)
            // The actions dim until the row is hovered but stay clickable and keyboard focusable.
            HStack(spacing: 4) {
                Button(localized("Copy Key")) { onCopy() }
                    .buttonStyle(.agemin(.ghost, size: .small))
                    .keyboardFocusable()
                    .disabled(entry.line.isEmpty)
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder", variant: .ghost, size: .small, action: onReveal)
                IconButton(symbol: "trash", help: "Delete the .pub file", variant: .ghost, size: .small, action: onDelete)
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .hoverHighlight()
        .onHover { hovering = $0 }
    }
}
