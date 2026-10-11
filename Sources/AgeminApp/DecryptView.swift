import AppKit
import SwiftUI

/// The Decrypt page: the encrypted file, who it was encrypted for, the key to use, and the result.
struct DecryptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore
    @ObservedObject private var runner: OperationRunner

    // init(model): Observe the model, its key store, and the runner.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
        _runner = ObservedObject(wrappedValue: model.runner)
    }

    var body: some View {
        PageScroll {
            PageHeader(symbol: "lock.open.fill", title: "Decrypt", subtitle: "Open an age file with one of your keys, or with the passphrase it was encrypted with.")

            FileDropZone(
                file: model.decryptInput,
                prompt: "Drop an age file here to decrypt it",
                symbol: "arrow.down.doc",
                onChoose: { model.chooseDecryptInput(in: NSApp.keyWindow) },
                onClear: { model.clearDecryptInput() },
                onDrop: { model.acceptDrop($0, for: .decrypt) }
            )
            .disabled(model.isBusy)

            // A file that is not an age file explains itself here.
            if let problem = model.decryptInspectionError {
                NoticeCard(tone: .negative, symbol: "doc.questionmark", title: localized("This file cannot be read as an age file"), detail: problem)
            }
            // The header tells who can open the file, before any key is used.
            if let info = model.decryptInfo {
                recipientsCard(info)
                identityCard(info)
                    .disabled(model.isBusy)
            }

            ActionBar(runner: runner, title: "Decrypt", blocker: model.decryptBlocker) {
                model.decrypt(in: NSApp.keyWindow)
            }

            // The last failure, until the next attempt.
            if let error = model.decryptError {
                NoticeCard(tone: .negative, symbol: "exclamationmark.triangle.fill", title: localized("Decryption failed"), detail: error)
            }
            // The last success, until the file changes.
            if let result = model.decryptResult {
                resultCard(result)
            }
        }
    }

    // MARK: Recipients

    // recipientsCard(info): The header's recipient entries, with the keys that match them.
    private func recipientsCard(_ info: AgeFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading("Encrypted for") {
                HStack(spacing: 6) {
                    // Armor and size describe the file itself.
                    if info.isArmored {
                        Chip(text: localized("ASCII armor"), mono: false, compact: true)
                    }
                    Chip(text: ByteCountText.string(info.size), mono: false, compact: true)
                }
            }
            // One row per header entry, with the keys that fit it.
            VStack(spacing: 2) {
                ForEach(info.recipients) { summary in
                    StanzaRow(summary: summary, matches: matches(for: summary))
                }
            }
            // No key is even a candidate: nothing matches, and no usable age key meets an age
            // entry. Say so, with the way out.
            if !info.needsPassphrase, store.matchingIdentities(for: info).isEmpty, !store.identities.contains(where: { $0.isUsable && $0.kind == .x25519 }) || !info.recipients.contains(where: { $0.keyKind == .x25519 }) {
                Text(localized("None of your identities matches this file. Add the key it was encrypted for on the Identities page."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // matches(for summary): The names of the identities whose tag fits the stanza; age stanzas
    // carry no tag, so every age identity is a candidate for them.
    private func matches(for summary: AgeStanzaSummary) -> [String] {
        store.identities.filter { entry in
            guard entry.isUsable else { return false }
            switch summary.kind {
            case .x25519: return entry.kind == .x25519
            case .sshEd25519(let tag), .sshRSA(let tag): return entry.tag == tag
            case .scrypt, .other: return false
            }
        }.map(\.name)
    }

    // MARK: Identity

    // identityCard(info): The passphrase field, or the key to decrypt with.
    @ViewBuilder private func identityCard(_ info: AgeFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading("Decrypt with")
            // A passphrase file takes its passphrase here; the work factor says how slow it is.
            if info.needsPassphrase {
                HStack(spacing: 10) {
                    PassphraseField(placeholder: "Passphrase", text: $model.decryptPassphrase)
                        .frame(maxWidth: 360)
                    Spacer(minLength: 0)
                }
                // A work factor above the limit is refused, so warn before the attempt.
                if case .scrypt(let workFactor?) = info.recipients.first?.kind, workFactor > ScryptIdentity.maximumWorkFactor {
                    Text(AgeError.workFactorTooHigh(workFactor).localizedDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                }
            } else if !store.identities.contains(where: \.isUsable) {
                // No keys at all: point at the two ways to add some.
                FolderPrompt(
                    title: "No identities yet",
                    detail: "Choose the folder with your SSH keys, usually ~/.ssh, or add an age identity file on the Identities page.",
                    buttonTitle: "Choose Folder"
                ) { store.chooseIdentitiesFolder(in: NSApp.keyWindow) }
            } else {
                // The radio list: try every key, or decrypt with one chosen key.
                VStack(spacing: 2) {
                    IdentityChoiceRow(
                        title: localized("Try every usable key"),
                        detail: localized("Matching keys first. Protected keys ask for their passphrase."),
                        kind: nil, protected: false, matches: false,
                        selected: model.selectedIdentityID == nil
                    ) { model.selectedIdentityID = nil }
                    ForEach(store.identities.filter(\.isUsable)) { entry in
                        IdentityChoiceRow(
                            title: entry.name,
                            detail: entry.fingerprint ?? entry.displayPath,
                            kind: entry.kind, protected: entry.isProtected,
                            matches: model.matchingIdentities.contains(where: { $0.id == entry.id }),
                            selected: model.selectedIdentityID == entry.id
                        ) { model.selectedIdentityID = entry.id }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Result

    // resultCard(result): The finished decryption: where it went, its size, and its checksum.
    private func resultCard(_ result: DecryptResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The heading and the way to the file.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.success)
                Text(localized("Decrypted"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(localized("Reveal in Finder")) { store.revealInFinder(result.output) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            DetailRow(label: "Output", value: KeyStore.abbreviate(result.output.path), mono: true) {
                Button(localized("Copy Path")) { model.copy(result.output.path) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            DetailRow(label: "Size", value: ByteCountText.string(result.outcome.outputSize))
            DetailRow(label: "SHA-256", value: result.outcome.sha256, mono: true) {
                Button(localized("Copy")) { model.copy(result.outcome.sha256) }
                    .buttonStyle(.agemin(.success, size: .small))
                    .keyboardFocusable()
            }
            // The key that opened the file, or how many were tried.
            DetailRow(label: "Key", value: result.identityName)
            Text(localized("The decrypted file is readable only by your user account. Compare the checksum with the sender's if they gave you one."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.success.opacity(0.35), lineWidth: 1))
    }
}

/// One recipient entry of a file's header and the keys that fit it.
private struct StanzaRow: View {
    let summary: AgeStanzaSummary
    let matches: [String]

    /// What the entry is, in words.
    private var title: String {
        switch summary.kind {
        case .x25519: return localized("age key")
        case .sshEd25519: return localized("SSH key (Ed25519)")
        case .sshRSA: return localized("SSH key (RSA)")
        case .scrypt(let workFactor):
            guard let workFactor else { return localized("Passphrase") }
            return localizedFormat("Passphrase · work factor %lld", Int64(workFactor))
        case .other(let type): return localizedFormat("Unknown recipient type “%@”", type)
        }
    }

    /// The icon for the entry's kind.
    private var symbol: String {
        switch summary.kind {
        case .x25519: return "key.horizontal.fill"
        case .sshEd25519, .sshRSA: return "terminal.fill"
        case .scrypt: return "textformat.abc"
        case .other: return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, size: 28, tint: Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    // SSH entries carry a short tag that identifies the key.
                    if let tag = summary.sshTag {
                        Chip(text: tag, compact: true)
                    }
                }
                // Which of the user's keys fit, if any.
                if !matches.isEmpty {
                    Text(localizedFormat("Matches %@", matches.joined(separator: ", ")))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.success)
                        .lineLimit(1)
                } else if case .scrypt = summary.kind {
                    // A passphrase entry has no key to match; the field below takes it.
                    Text(localized("Enter the passphrase below"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    // A key entry that none of the user's identities fits.
                    Text(localized("No matching key"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
