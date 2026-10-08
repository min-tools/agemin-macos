import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file the user chose or dropped, with the security scope that lets the sandbox read it.
struct ChosenFile: Equatable {
    let url: URL
    let size: Int64
    /// Whether the scope was opened for this file and must be closed when it is dropped.
    let accessed: Bool

    var name: String { url.lastPathComponent }
    var displayPath: String { KeyStore.abbreviate(url.path) }
    var sizeText: String { ByteCountText.string(size) }
}

/// The last finished encryption, shown until the next run.
struct EncryptResult: Equatable {
    let input: ChosenFile
    let output: URL
    let outcome: AgeEncryptOutcome
    let recipientNames: [String]
    let armored: Bool
    let usedPassphrase: Bool

    var overhead: Int64 { outcome.outputSize - outcome.inputSize }
}

/// The last finished decryption, shown until the next run.
struct DecryptResult: Equatable {
    let input: ChosenFile
    let output: URL
    let outcome: AgeDecryptOutcome
    let identityName: String
}

/// The interface state: the current page, the files chosen for encryption and decryption, the
/// chosen recipients and identities, and the results of the last operations.
@MainActor
final class AppModel: ObservableObject {
    /// The pages the sidebar switches between.
    enum Page: Hashable, CaseIterable {
        case encrypt, decrypt, recipients, identities
    }

    /// How the Encrypt page protects a file.
    enum EncryptMode: Int { case recipients = 0, passphrase = 1 }

    let store = KeyStore()
    let runner = OperationRunner()
    let avatars = AvatarStore()
    private let proStore = AgeminProStore.shared

    @Published var page: Page = .encrypt
    /// Set when the Encrypt page or the Keys menu asks for a new recipient; the Recipients page
    /// opens its form and clears it.
    @Published var addRecipientRequested = false

    // Encrypt page state.
    @Published private(set) var encryptInput: ChosenFile?
    @Published var encryptMode: EncryptMode = .recipients
    /// IDs of the recipient entries selected for encryption.
    @Published var selectedRecipientIDs: Set<String> = []
    @Published var passphrase = ""
    @Published var passphraseConfirmation = ""
    @Published var armorOutput = false
    @Published private(set) var encryptResult: EncryptResult?
    @Published private(set) var encryptError: String?

    // Decrypt page state.
    @Published private(set) var decryptInput: ChosenFile?
    @Published private(set) var decryptInfo: AgeFileInfo?
    @Published private(set) var decryptInspectionError: String?
    /// The identity file chosen for decryption; nil tries every usable identity.
    @Published var selectedIdentityID: String?
    @Published var decryptPassphrase = ""
    @Published private(set) var decryptResult: DecryptResult?
    @Published private(set) var decryptError: String?
    /// Whether identity files are being parsed or unlocked away from the main thread.
    @Published private(set) var isPreparingDecryption = false

    // Key pages.
    @Published var recipientFilter = ""
    @Published var identityFilter = ""
    /// The public half of a key created on the Identities page, shown until dismissed.
    @Published private(set) var generatedKey: (publicKey: String, savedTo: URL)?

    private var entitlementObserver: NSObjectProtocol?

    /// Whether key preparation or a file operation is in flight.
    var isBusy: Bool { isPreparingDecryption || runner.isRunning }

    // init(): Restore the key folders, select every usable recipient, and forward key and access
    // changes to the views.
    init() {
        store.onChange = { [weak self] in self?.keysDidChange() }
        store.restore()
        selectAllUsableRecipients()
        // Access changes redraw everything that depends on the Free limit.
        entitlementObserver = NotificationCenter.default.addObserver(
            forName: AgeminProStore.entitlementDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    // deinit(): Stop observing access changes.
    deinit {
        // The observer exists from init onward.
        if let entitlementObserver { NotificationCenter.default.removeObserver(entitlementObserver) }
    }

    // MARK: Access

    /// True after the trial without a verified purchase, once StoreKit state is known.
    var isLimitedToFreeOperations: Bool { proStore.isLimitedToFreeOperations }
    /// How many Free operations are left today.
    var freeOperationsRemainingToday: Int { proStore.freeOperationsRemainingToday }

    // presentPro(for feature): Explain the requested feature in the Pro panel.
    func presentPro(for feature: AgeminProFeature) {
        proStore.present(feature: feature)
    }

    // beginOperation(): Count one operation against the Free allowance, or open the Pro panel
    // and refuse when the allowance is spent. Full access never counts.
    private func beginOperation() -> Bool {
        guard proStore.beginOperation() else {
            proStore.present(feature: .unlimitedOperations)
            return false
        }
        return true
    }

    // MARK: Keys

    /// The recipients the user has selected and that can be used.
    var selectedRecipients: [RecipientEntry] {
        store.recipients.filter { selectedRecipientIDs.contains($0.id) && $0.isUsable }
    }

    /// Recipients that match the filter on the Recipients page.
    var filteredRecipients: [RecipientEntry] {
        let query = recipientFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.recipients }
        return store.recipients.filter { $0.name.lowercased().contains(query) || $0.line.lowercased().contains(query) || ($0.fingerprint ?? "").lowercased().contains(query) }
    }

    /// Identities that match the filter on the Identities page.
    var filteredIdentities: [IdentityEntry] {
        let query = identityFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.identities }
        return store.identities.filter { $0.name.lowercased().contains(query) || ($0.publicKeyLine ?? "").lowercased().contains(query) || ($0.fingerprint ?? "").lowercased().contains(query) }
    }

    // isOwnKey(entry): Whether a recipient is one of the user's own identities, judged by the key
    // material.
    func isOwnKey(_ entry: RecipientEntry) -> Bool {
        let key = KeyMaterial.normalized(entry.line)
        return store.identities.contains { identity in
            guard let line = identity.publicKeyLine else { return false }
            return KeyMaterial.normalized(line) == key
        }
    }

    /// The identities that could decrypt the chosen file, by tag and kind.
    var matchingIdentities: [IdentityEntry] {
        guard let decryptInfo else { return [] }
        return store.matchingIdentities(for: decryptInfo)
    }

    // keysDidChange(): Drop selected recipients and the chosen identity whose keys disappeared,
    // then redraw. New keys are not selected on their own.
    private func keysDidChange() {
        let ids = Set(store.recipients.map(\.id))
        selectedRecipientIDs = selectedRecipientIDs.intersection(ids)
        // A chosen identity that disappeared falls back to trying every key.
        if let selectedIdentityID, !store.identities.contains(where: { $0.id == selectedIdentityID }) {
            self.selectedIdentityID = nil
        }
        objectWillChange.send()
    }

    // selectAllUsableRecipients(): Select every usable recipient, which is what the age script
    // encrypts for by default.
    func selectAllUsableRecipients() {
        selectedRecipientIDs = Set(store.recipients.filter(\.isUsable).map(\.id))
    }

    // deselectAllRecipients(): Clear the recipient selection.
    func deselectAllRecipients() {
        selectedRecipientIDs = []
    }

    // toggleRecipient(entry): Select or deselect one recipient.
    func toggleRecipient(_ entry: RecipientEntry) {
        guard entry.isUsable else { return }
        // Toggle membership in the selection.
        if selectedRecipientIDs.contains(entry.id) {
            selectedRecipientIDs.remove(entry.id)
        } else {
            // Not selected yet.
            selectedRecipientIDs.insert(entry.id)
        }
    }

    // requestAddRecipient(): Show the Recipients page with its add form open.
    func requestAddRecipient() {
        page = .recipients
        addRecipientRequested = true
    }

    // saveRecipient(name, line): Write a `.pub` file for the key and select it.
    func saveRecipient(name: String, line: String) throws {
        try store.saveRecipient(name: name, line: line)
        // Select the saved key by its line.
        if let entry = store.recipients.first(where: { $0.line == line.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            selectedRecipientIDs.insert(entry.id)
        }
    }

    // MARK: Choosing files

    // chooseEncryptInput(in window): Pick the file to encrypt.
    func chooseEncryptInput(in window: NSWindow?) {
        guard !isBusy else { return }
        chooseFile(in: window, message: localized("Choose the file to encrypt")) { [weak self] file in
            self?.setEncryptInput(file)
        }
    }

    // chooseDecryptInput(in window): Pick the encrypted file.
    func chooseDecryptInput(in window: NSWindow?) {
        guard !isBusy else { return }
        chooseFile(in: window, message: localized("Choose the encrypted file, usually ending in .age")) { [weak self] file in
            self?.setDecryptInput(file)
        }
    }

    // chooseFile(in window, message, completion): A single-file open panel.
    private func chooseFile(in window: NSWindow?, message: String, completion: @escaping (ChosenFile) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = message
        panel.prompt = localized("Choose")
        // Only a confirmed choice reaches the completion; a panel URL needs no security scope.
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(ChosenFile(url: url, size: AgeEngine.fileSize(url), accessed: false))
        }
        // A window makes a sheet possible; otherwise the panel runs app-modally.
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            // No window to attach to.
            handler(panel.runModal())
        }
    }

    // acceptDrop(providers, for page): Take the first dropped file for the given page.
    func acceptDrop(_ providers: [NSItemProvider], for page: Page) -> Bool {
        guard !isBusy else { return false }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        // The provider delivers the item off the main thread; the model is updated back on it.
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            // The item arrives as URL data or as a URL, depending on the source.
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                // Some sources hand over the URL itself.
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var isDirectory: ObjCBool = false
                // Folders cannot be encrypted directly; the user archives them first.
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    self.reportDropError(localized("Drop a file, not a folder. Compress the folder first, then drop the archive."), for: page)
                    return
                }
                let accessed = url.startAccessingSecurityScopedResource()
                let file = ChosenFile(url: url, size: AgeEngine.fileSize(url), accessed: accessed)
                // The drop goes to the page it landed on.
                if page == .decrypt {
                    self.setDecryptInput(file)
                } else {
                    // Only the Encrypt and Decrypt pages take drops.
                    self.setEncryptInput(file)
                }
            }
        }
        return true
    }

    // reportDropError(message, for page): Show a drop problem on the page's error line.
    private func reportDropError(_ message: String, for page: Page) {
        // Each page keeps its own error line.
        if page == .decrypt {
            decryptError = message
        } else {
            // Only the Encrypt and Decrypt pages take drops.
            encryptError = message
        }
    }

    // setEncryptInput(file): Use the file on the Encrypt page, clear the last result, and show
    // that page.
    func setEncryptInput(_ file: ChosenFile) {
        // A dropped file may already own a security scope, so release it when an active operation
        // prevents the replacement.
        guard !isBusy else {
            release(file)
            return
        }
        release(encryptInput)
        encryptInput = file
        encryptResult = nil
        encryptError = nil
        page = .encrypt
    }

    // setDecryptInput(file): Use the file on the Decrypt page, show that page, read the header,
    // and pick a key.
    func setDecryptInput(_ file: ChosenFile) {
        // Keep the input and inspection state stable until the current operation completes.
        guard !isBusy else {
            release(file)
            return
        }
        release(decryptInput)
        decryptInput = file
        decryptResult = nil
        decryptError = nil
        decryptInfo = nil
        decryptInspectionError = nil
        decryptPassphrase = ""
        page = .decrypt
        do {
            let info = try AgeEngine.inspect(url: file.url)
            decryptInfo = info
            // Prefer the first identity whose tag or kind matches the file.
            selectedIdentityID = store.matchingIdentities(for: info).first?.id
        } catch {
            // A file that is not a valid age file keeps its error for the blocker text.
            decryptInspectionError = error.localizedDescription
        }
    }

    // showEncryptResult(result): Show a finished encryption. The screenshot renderer uses this
    // with a result it produced itself; the app sets results through encrypt(in:).
    func showEncryptResult(_ result: EncryptResult) {
        encryptResult = result
        encryptError = nil
    }

    // clearEncryptInput(): Forget the chosen file on the Encrypt page.
    func clearEncryptInput() {
        guard !isBusy else { return }
        release(encryptInput)
        encryptInput = nil
        encryptResult = nil
        encryptError = nil
    }

    // clearDecryptInput(): Forget the chosen file on the Decrypt page.
    func clearDecryptInput() {
        guard !isBusy else { return }
        release(decryptInput)
        decryptInput = nil
        decryptInfo = nil
        decryptInspectionError = nil
        decryptResult = nil
        decryptError = nil
    }

    // release(file): Close the security scope a drop opened.
    private func release(_ file: ChosenFile?) {
        guard let file, file.accessed else { return }
        file.url.stopAccessingSecurityScopedResource()
    }

    // MARK: Encrypting

    /// The output name the age script would choose: the input name plus `.age`.
    var suggestedEncryptName: String? {
        encryptInput.map { $0.name + ".age" }
    }

    /// Why encryption cannot start yet, or nil when it can.
    var encryptBlocker: String? {
        guard !isPreparingDecryption else { return localized("Loading keys…") }
        guard encryptInput != nil else { return localized("Choose a file to encrypt.") }
        switch encryptMode {
        case .recipients:
            guard !selectedRecipients.isEmpty else { return localized("Select at least one recipient.") }
        case .passphrase:
            guard !passphrase.isEmpty else { return localized("Enter a passphrase.") }
            guard passphrase == passphraseConfirmation else { return localized("The passphrases do not match.") }
        }
        return nil
    }

    /// Whether encryption can start: nothing blocks it and no operation is running.
    var canEncrypt: Bool { encryptBlocker == nil && !isBusy }

    // encrypt(in window): Ask where to save the encrypted file, then encrypt in the background.
    func encrypt(in window: NSWindow?) {
        guard canEncrypt, let input = encryptInput else { return }
        let usedPassphrase = encryptMode == .passphrase
        let passphraseUsed = passphrase
        let confirmationUsed = passphraseConfirmation
        let recipients: [any AgeRecipient]
        let names: [String]
        // Build the recipient list before asking for the output, so a bad key fails early.
        if usedPassphrase {
            recipients = [ScryptRecipient(passphrase: passphraseUsed)]
            names = [localized("Passphrase")]
        } else {
            // Recipient mode: every selected key must parse, and at least one is needed.
            let entries = selectedRecipients
            recipients = entries.compactMap { $0.recipient() }
            names = entries.map(\.name)
            guard recipients.count == entries.count, !recipients.isEmpty else {
                encryptError = AgeError.noRecipients.localizedDescription
                return
            }
        }
        // Offer the input's folder and the age script's output name; the user may change both.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedEncryptName ?? "encrypted.age"
        panel.directoryURL = input.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.message = localized("Choose where to save the encrypted file")
        panel.prompt = localized("Encrypt")
        let armored = armorOutput
        presentSave(panel, in: window) { [weak self] output in
            guard let self else { return }
            // The same file as the input would destroy the original while reading it.
            guard !Self.isSameFile(output, input.url) else {
                self.encryptError = localized("The encrypted file cannot replace the original. Choose a different name.")
                return
            }
            // Another operation started while the panel was open; count nothing and refuse.
            guard !self.runner.isRunning else {
                self.encryptError = localized("Wait for the current operation to finish.")
                return
            }
            guard self.beginOperation() else { return }
            self.encryptError = nil
            self.encryptResult = nil
            // Encrypt in the background; the result or error lands on the Encrypt page.
            self.runner.run(.encrypt, work: { progress, isCancelled in
                try AgeEngine.encrypt(input: input.url, output: output, recipients: recipients, armor: armored, progress: progress, isCancelled: isCancelled)
            }, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    self.encryptResult = EncryptResult(input: input, output: output, outcome: outcome, recipientNames: names, armored: armored, usedPassphrase: usedPassphrase)
                    // Clear only the passphrase that was used. A later edit belongs to the next
                    // operation and must not be destroyed by this completion.
                    if usedPassphrase, self.passphrase == passphraseUsed,
                       self.passphraseConfirmation == confirmationUsed {
                        self.passphrase = ""
                        self.passphraseConfirmation = ""
                    }
                case .failure(let error):
                    self.encryptError = error.localizedDescription
                }
            })
        }
    }

    // MARK: Decrypting

    /// The output name the age script would choose: the input without `.age`, or with
    /// `.decrypted` when it has no such suffix.
    var suggestedDecryptName: String? {
        guard let name = decryptInput?.name else { return nil }
        // Strip the age suffix, or mark the file as decrypted when there is none.
        if name.lowercased().hasSuffix(".age"), name.count > 4 { return String(name.dropLast(4)) }
        return name + ".decrypted"
    }

    /// The identity entry chosen for decryption, if one is.
    var selectedIdentity: IdentityEntry? {
        guard let selectedIdentityID else { return nil }
        return store.identities.first { $0.id == selectedIdentityID }
    }

    /// Why decryption cannot start yet, or nil when it can.
    var decryptBlocker: String? {
        guard !isPreparingDecryption else { return localized("Loading keys…") }
        guard decryptInput != nil else { return localized("Choose an encrypted file.") }
        guard let decryptInfo else { return decryptInspectionError ?? localized("The file is being read.") }
        // A passphrase file needs its passphrase; anything else needs a usable key.
        if decryptInfo.needsPassphrase {
            guard !decryptPassphrase.isEmpty else { return localized("Enter the file's passphrase.") }
        } else if selectedIdentityID == nil {
            // No key chosen: the scan needs at least one usable identity to try.
            guard store.identities.contains(where: \.isUsable) else { return localized("Add an identity that can decrypt this file.") }
        }
        return nil
    }

    /// Whether decryption can start: nothing blocks it and no operation is running.
    var canDecrypt: Bool { decryptBlocker == nil && !isBusy }

    // decrypt(in window): Prepare passphrase decryption immediately, or load key identities away
    // from the main thread before asking where to save.
    func decrypt(in window: NSWindow?) {
        guard canDecrypt, let input = decryptInput, let info = decryptInfo else { return }
        let passphraseUsed = decryptPassphrase
        // A passphrase-protected file stretches its passphrase inside the background file run.
        if info.needsPassphrase {
            presentDecryptSave(
                input: input,
                identities: [ScryptIdentity(passphrase: passphraseUsed)],
                identityName: localized("Passphrase"),
                passphraseUsed: passphraseUsed,
                in: window
            )
            return
        }

        // Loading a protected OpenSSH key can spend seconds in its KDF, so keep it off the main
        // actor. The chosen key alone, or every candidate in preference order, is captured now.
        let chosenIdentity = selectedIdentity
        let candidates = chosenIdentity.map { [$0] } ?? preferredIdentities(for: info)
        isPreparingDecryption = true
        decryptError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prepared = await self.prepareIdentities(candidates, reportFailures: chosenIdentity != nil, in: window)
            self.isPreparingDecryption = false
            guard let prepared else { return }
            self.presentDecryptSave(
                input: input,
                identities: prepared.identities,
                identityName: prepared.name,
                passphraseUsed: passphraseUsed,
                in: window
            )
        }
    }

    // prepareIdentities(candidates, reportFailures, in window): Load candidate files in order and
    // return their identities and result label. A chosen key reports its error; scan errors skip.
    private func prepareIdentities(_ candidates: [IdentityEntry], reportFailures: Bool, in window: NSWindow?) async -> (identities: [any AgeIdentity], name: String)? {
        var identities: [any AgeIdentity] = []
        var identityName = ""
        for entry in candidates {
            do {
                let loaded = try await loadIdentity(entry, in: window)
                // The user canceled a passphrase prompt; skip that key.
                guard let loaded else { continue }
                identities.append(contentsOf: loaded)
                // The first loaded key names the attempt; the engine picks the one that fits.
                if identityName.isEmpty { identityName = entry.name }
            } catch {
                // A chosen key that fails is reported; a scanned one is skipped.
                if reportFailures {
                    decryptError = error.localizedDescription
                    return nil
                }
            }
        }
        guard !identities.isEmpty else {
            decryptError = AgeError.noMatchingIdentity.localizedDescription
            return nil
        }
        // Several candidates: the result reports how many files were tried, since the engine does
        // not say which identity fit.
        if candidates.count > 1 { identityName = localizedFormat("%lld keys tried", Int64(candidates.count)) }
        return (identities, identityName)
    }

    // presentDecryptSave(input, identities, identityName, passphraseUsed, in window): Ask for the
    // output, count the operation, and decrypt the file on the operation runner.
    private func presentDecryptSave(input: ChosenFile, identities: [any AgeIdentity], identityName: String, passphraseUsed: String, in window: NSWindow?) {
        // Offer the input's folder and the age script's output name; the user may change both.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedDecryptName ?? "decrypted"
        panel.directoryURL = input.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.message = localized("Choose where to save the decrypted file")
        panel.prompt = localized("Decrypt")
        let identityBox = IdentityBox(identities: identities)
        presentSave(panel, in: window) { [weak self] output in
            guard let self else { return }
            // The same file as the input would destroy the encrypted file while reading it.
            guard !Self.isSameFile(output, input.url) else {
                self.decryptError = localized("The decrypted file cannot replace the encrypted file. Choose a different name.")
                return
            }
            // Another operation started while the panel was open; count nothing and refuse.
            guard !self.runner.isRunning else {
                self.decryptError = localized("Wait for the current operation to finish.")
                return
            }
            guard self.beginOperation() else { return }
            self.decryptError = nil
            self.decryptResult = nil
            // Decrypt in the background; the box carries the loaded keys to the worker.
            self.runner.run(.decrypt, work: { progress, isCancelled in
                try AgeEngine.decrypt(input: input.url, output: output, identities: identityBox.identities, progress: progress, isCancelled: isCancelled)
            }, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    self.decryptResult = DecryptResult(input: input, output: output, outcome: outcome, identityName: identityName)
                    // Keep a passphrase entered for a later operation.
                    if self.decryptPassphrase == passphraseUsed { self.decryptPassphrase = "" }
                case .failure(let error):
                    self.decryptError = error.localizedDescription
                }
            })
        }
    }

    // preferredIdentities(for info): The keys to try when none is chosen: matching ones first,
    // then every other usable key, so a file for an untagged age key still decrypts.
    private func preferredIdentities(for info: AgeFileInfo) -> [IdentityEntry] {
        let matching = store.matchingIdentities(for: info)
        let others = store.identities.filter { entry in entry.isUsable && !matching.contains(where: { $0.id == entry.id }) }
        return matching + others
    }

    // loadIdentity(entry, in window): Load a key file away from the main actor, asking for a
    // passphrase on the main actor when needed. Nil when the user cancels the prompt.
    private func loadIdentity(_ entry: IdentityEntry, in window: NSWindow?) async throws -> [any AgeIdentity]? {
        guard entry.isProtected else { return try await loadIdentityInBackground(entry, passphrase: nil) }
        var message = localizedFormat("%@ is protected with a passphrase.", entry.name)
        // Ask until the passphrase works or the user gives up.
        while true {
            guard let passphrase = PassphrasePrompt.ask(title: localizedFormat("Unlock %@", entry.name), message: message, in: window) else { return nil }
            do {
                return try await loadIdentityInBackground(entry, passphrase: passphrase)
            } catch AgeError.wrongPassphrase {
                // Only a wrong passphrase asks again; any other error reaches the caller.
                message = localizedFormat("The passphrase for %@ is incorrect. Try again.", entry.name)
            }
        }
    }

    // loadIdentityInBackground(entry, passphrase): Read, parse, and unlock one identity file on a
    // worker thread. IdentityBox is the sendable boundary for the parsed key values.
    private func loadIdentityInBackground(_ entry: IdentityEntry, passphrase: String?) async throws -> [any AgeIdentity] {
        let url = entry.url
        let name = entry.name
        let box = try await Task.detached(priority: .userInitiated) {
            IdentityBox(identities: try KeyStore.loadIdentities(at: url, named: name, passphrase: passphrase))
        }.value
        return box.identities
    }

    // presentSave(panel, in window, completion): A save panel as a sheet or app-modally.
    private func presentSave(_ panel: NSSavePanel, in window: NSWindow?, completion: @escaping (URL) -> Void) {
        // Only a confirmed choice reaches the completion.
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        // A window makes a sheet possible; otherwise the panel runs app-modally.
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            // No window to attach to.
            handler(panel.runModal())
        }
    }

    // isSameFile(a, b): Whether two URLs name one file, through symbolic links, hard links, and
    // case differences on a case-insensitive volume. Used before an output replaces its input.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let left = a.resolvingSymlinksInPath().standardizedFileURL
        let right = b.resolvingSymlinksInPath().standardizedFileURL
        // Equal normalized paths need no file-system lookup.
        if left == right { return true }
        // Different paths can still be one file; compare the identities when both exist.
        let manager = FileManager.default
        guard let first = try? manager.attributesOfItem(atPath: left.path),
              let second = try? manager.attributesOfItem(atPath: right.path),
              let firstNode = first[.systemFileNumber] as? NSNumber,
              let secondNode = second[.systemFileNumber] as? NSNumber,
              let firstDevice = first[.systemNumber] as? NSNumber,
              let secondDevice = second[.systemNumber] as? NSNumber else { return false }
        return firstNode == secondNode && firstDevice == secondDevice
    }

    // MARK: Key generation

    // generateIdentity(in window): Create an age key pair, save the identity file where the user
    // chooses, and offer its public key as a recipient.
    func generateIdentity(in window: NSWindow?) {
        let identity = X25519Identity.generate()
        // Start in the identities folder; hidden files show so a dot-folder such as `~/.ssh`
        // can be reached.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agemin-key.txt"
        panel.directoryURL = store.identitiesFolder ?? KeyStore.defaultIdentitiesDirectory
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.message = localized("Save the new identity file somewhere private because it holds the secret key")
        panel.prompt = localized("Save Key")
        presentSave(panel, in: window) { [weak self] url in
            guard let self else { return }
            // Write the identity file in the age text format.
            do {
                let writer = try FileByteWriter(url: url)
                try writer.write(Data(AgeIdentityFile.identityFileText(for: identity).utf8))
                try writer.finish()
            } catch {
                // A failed write can leave a partial secret key file behind. Remove it before
                // reporting the error so the user cannot mistake it for a valid identity.
                try? FileManager.default.removeItem(at: url)
                self.presentError(localized("The identity file could not be saved."), detail: error.localizedDescription)
                return
            }
            // Keep only the public half in view state after the secret has been written.
            self.generatedKey = (identity.publicKeyLine, url)
            // A key saved in the identities folder appears on a rescan.
            if let folder = self.store.identitiesFolder, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                self.store.refresh()
            } else {
                // Anywhere else, it is added as a standalone file so it is still listed.
                self.store.addIdentityFileWithoutPanel(url)
            }
            self.page = .identities
        }
    }

    // dismissGeneratedKey(): Hide the new-key card.
    func dismissGeneratedKey() {
        generatedKey = nil
    }

    // presentError(message, detail): Show a problem in a modal alert.
    func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: localized("OK"))
        alert.runModal()
    }

    // copy(text): Put text on the general pasteboard.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // forgetAccess(): Drop every saved folder and file permission.
    func forgetAccess() {
        store.forgetAccess()
        selectedRecipientIDs = []
        selectedIdentityID = nil
    }
}

/// Carries loaded identities into the background task; the identities hold only key material
/// and are not touched by the main thread while the task runs.
private final class IdentityBox: @unchecked Sendable {
    let identities: [any AgeIdentity]

    // init(identities): Wrap the identities.
    init(identities: [any AgeIdentity]) {
        self.identities = identities
    }
}
