import AppKit
import SwiftUI

/// The Encrypt page: the file, who can open it, the options, and the result.
struct EncryptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore
    @ObservedObject private var runner: OperationRunner
    @ObservedObject private var avatars: AvatarStore
    /// A passphrase made by the Generate button, shown until the fields change.
    @State private var generatedPassphrase: String?

    // init(model): Observe the model, its key store, the runner, and the avatars.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
        _runner = ObservedObject(wrappedValue: model.runner)
        _avatars = ObservedObject(wrappedValue: model.avatars)
    }

    var body: some View {
        PageScroll {
            PageHeader(symbol: "lock.fill", title: "Encrypt", subtitle: "Encrypt a file for people using their public keys, or protect it with a passphrase. The result is a standard age file.")

            FileDropZone(
                file: model.encryptInput,
                prompt: "Drop a file here to encrypt it",
                symbol: "arrow.down.doc",
                onChoose: { model.chooseEncryptInput(in: NSApp.keyWindow) },
                onClear: { model.clearEncryptInput() },
                onDrop: { model.acceptDrop($0, for: .encrypt) }
            )
            .disabled(model.isBusy)

            recipientsCard
                .disabled(model.isBusy)
            optionsCard
                .disabled(model.isBusy)

            ActionBar(runner: runner, title: "Encrypt", blocker: model.encryptBlocker) {
                model.encrypt(in: NSApp.keyWindow)
            }

            // The last failure, until the next attempt.
            if let error = model.encryptError {
                NoticeCard(tone: .negative, symbol: "exclamationmark.triangle.fill", title: localized("Encryption failed"), detail: error)
            }
            // The last success, until the file or the inputs change.
            if let result = model.encryptResult {
                resultCard(result)
            }
        }
    }

    // MARK: Recipients

    /// The card that chooses between recipients and a passphrase and holds whichever is active.
    @ViewBuilder private var recipientsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeading("Encrypt for") {
                SegmentedControl(options: ["Recipients", "Passphrase"], selection: Binding(
                    get: { model.encryptMode.rawValue },
                    set: { model.encryptMode = AppModel.EncryptMode(rawValue: $0) ?? .recipients }
                ))
            }
            // Keys or a passphrase, never both: age does not mix a passphrase with other recipients.
            if model.encryptMode == .passphrase {
                passphraseSection
            } else {
                // The chips for the keys in the recipients folder.
                recipientList
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The recipient chips, or the prompt for the folder they come from.
    @ViewBuilder private var recipientList: some View {
        // Without a folder, offer to choose one; the chips need it.
        if store.recipientsFolder == nil {
            FolderPrompt(
                title: "No recipients folder yet",
                detail: "Choose the folder with the .pub files of the people you encrypt for, usually ~/.age.",
                buttonTitle: "Choose Folder"
            ) { store.chooseRecipientsFolder(in: NSApp.keyWindow) }
        } else {
            // With a folder, a status line comes first: a hint when it is empty, otherwise the
            // selection count with All and None.
            if store.recipients.isEmpty {
                Text(localized("The recipients folder holds no .pub files yet."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The selection count, with All and None for quick changes.
                HStack {
                    Text(selectionSummary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(localized("All")) { model.selectAllUsableRecipients() }
                        .buttonStyle(.agemin(.ghost, size: .small))
                        .keyboardFocusable()
                    Button(localized("None")) { model.deselectAllRecipients() }
                        .buttonStyle(.agemin(.ghost, size: .small))
                        .keyboardFocusable()
                }
            }
            // One chip per recipient, then the chip that opens the Recipients page to add one.
            FlowLayout(spacing: 8) {
                ForEach(store.recipients) { entry in
                    RecipientChip(entry: entry, selected: model.selectedRecipientIDs.contains(entry.id), isYou: model.isOwnKey(entry), avatars: avatars) {
                        model.toggleRecipient(entry)
                    }
                    .contextMenu {
                        Button(localized("Copy Key")) { model.copy(entry.line) }
                    }
                }
                AddRecipientChip { model.requestAddRecipient() }
            }
        }
    }

    /// How many recipients are selected, of how many usable ones.
    private var selectionSummary: String {
        let usable = store.recipients.filter(\.isUsable).count
        let selected = model.selectedRecipients.count
        return localizedFormat("%lld of %lld recipients selected", Int64(selected), Int64(usable))
    }

    // MARK: Passphrase

    /// The passphrase fields, the Generate button, and the generated passphrase while it stands.
    @ViewBuilder private var passphraseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Anyone with the passphrase can open the file. age runs it through scrypt, so a long passphrase matters more than a complex one."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Both fields must agree before encryption can start; Generate fills them together.
            HStack(spacing: 10) {
                PassphraseField(placeholder: "Passphrase", text: $model.passphrase)
                PassphraseField(placeholder: "Confirm passphrase", text: $model.passphraseConfirmation)
                Button(localized("Generate")) { generatePassphrase() }
                    .buttonStyle(.agemin(.secondary, size: .small))
                    .keyboardFocusable()
                    .help(localized("Fill both fields with a random passphrase and show it once"))
            }
            // A generated passphrase is shown once so the user can record it.
            if let generatedPassphrase, model.passphrase == generatedPassphrase {
                HStack(spacing: 10) {
                    Text(generatedPassphrase)
                        .font(Theme.mono(12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    Button(localized("Copy")) { model.copy(generatedPassphrase) }
                        .buttonStyle(.agemin(.ghost, size: .small))
                        .keyboardFocusable()
                    Spacer(minLength: 0)
                }
                Text(localized("Write it down or store it in a password manager. Agemin does not keep it."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // generatePassphrase(): Fill both fields with a random passphrase and keep it for display.
    private func generatePassphrase() {
        let passphrase = PassphraseGenerator.make()
        generatedPassphrase = passphrase
        model.passphrase = passphrase
        model.passphraseConfirmation = passphrase
    }

    // MARK: Options and result

    /// The armor toggle and the output name the save panel will suggest.
    @ViewBuilder private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading("Options")
            ToggleCard(title: "ASCII armor", subtitle: "Write the encrypted file as text instead of binary, for email, chat, and configuration files. age reads both.", isOn: $model.armorOutput)
            // The output name follows the age script; the save panel can change it.
            if let name = model.suggestedEncryptName {
                HStack(spacing: 8) {
                    Text(localized("Saved as"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Text(name)
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(localized("· you choose the folder when you encrypt"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // resultCard(result): The finished encryption: where it went, how big it is, and who can
    // open it.
    private func resultCard(_ result: EncryptResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The heading, with Reveal and a shortcut that hands the new file to the Decrypt page.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.success)
                Text(localized("Encrypted"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(localized("Reveal in Finder")) { store.revealInFinder(result.output) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
                Button(localized("Decrypt This File")) {
                    model.setDecryptInput(ChosenFile(url: result.output, size: result.outcome.outputSize, accessed: false))
                }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            DetailRow(label: "Output", value: KeyStore.abbreviate(result.output.path), mono: true) {
                Button(localized("Copy Path")) { model.copy(result.output.path) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            // The overhead is the header, plus the armor when the file was written as text.
            DetailRow(label: "Size", value: localizedFormat("%@ · %@ more than the original for the header%@", ByteCountText.string(result.outcome.outputSize), ByteCountText.string(result.overhead), result.armored ? localized(" and armor") : ""))
            // A passphrase file names the passphrase as its single opener instead of recipients.
            HStack(alignment: .top, spacing: 12) {
                Text(localized(result.usedPassphrase ? "Opens with" : "Recipients"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 110, alignment: .leading)
                FlowChips(items: result.recipientNames)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.success.opacity(0.35), lineWidth: 1))
    }
}

/// Chips laid out in rows, wrapping as needed.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        // A simple wrapping layout: chips flow left to right and wrap at the available width.
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Chip(text: item, mono: false, compact: true)
            }
        }
    }
}
