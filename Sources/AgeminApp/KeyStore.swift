import AppKit
import Foundation

/// One public key the app can encrypt for: a line of a `.pub` file in the recipients folder.
struct RecipientEntry: Identifiable, Equatable {
    let id: String
    /// The file name without `.pub`.
    let name: String
    let line: String
    /// What kind of key the line holds; nil when the line is not a key at all.
    let kind: AgeKeyKind?
    /// Why the line cannot be used, when it cannot.
    let problem: String?
    /// The SSH fingerprint, or the age public key itself.
    let fingerprint: String?
    /// The age tag an SSH stanza would carry for this key.
    let tag: String?
    /// The `.pub` file.
    let url: URL
    /// Where the line sits in its file, for files that hold several keys.
    let lineNumber: Int

    var isUsable: Bool { problem == nil && (kind?.isSupported ?? false) }
    /// What the avatar is stored under: the fingerprint, or the key line itself.
    var avatarKey: String { fingerprint ?? KeyMaterial.normalized(line) }

    // init(name, line, url, lineNumber): Parse the line and record what it is.
    init(name: String, line: String, url: URL, lineNumber: Int) {
        self.name = name
        self.line = line
        self.url = url
        self.lineNumber = lineNumber
        id = url.path + "#\(lineNumber):" + line
        let kind = AgeRecipientParser.kind(of: line)
        self.kind = kind
        // Parse the key once to learn whether it is usable and what identifies it.
        do {
            let recipient = try AgeRecipientParser.parse(line)
            problem = nil
            switch recipient {
            case let ssh as SSHEd25519Recipient:
                fingerprint = ssh.publicKey.fingerprint
                tag = ssh.publicKey.tag
            case let ssh as SSHRSARecipient:
                fingerprint = ssh.publicKey.fingerprint
                tag = ssh.publicKey.tag
            default:
                // An age key has no SSH fingerprint; the public key itself identifies it.
                fingerprint = recipient.line
                tag = nil
            }
        } catch {
            // The reason the line cannot be used is kept for the user.
            problem = error.localizedDescription
            fingerprint = nil
            tag = nil
        }
    }

    // recipient(): The parsed recipient; nil when the line is unusable.
    func recipient() -> (any AgeRecipient)? {
        try? AgeRecipientParser.parse(line)
    }
}

/// One private key file the app can decrypt with.
struct IdentityEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let name: String
    let kind: AgeKeyKind?
    /// Whether a passphrase is needed before the key can be used.
    let isProtected: Bool
    /// Why the key cannot be used, when it cannot.
    let problem: String?
    /// The matching public key line, for display and matching.
    let publicKeyLine: String?
    let fingerprint: String?
    /// The age tag an SSH stanza would carry for this key.
    let tag: String?
    /// How many age identities the file holds, for identity files with several keys.
    let count: Int
    /// Whether the file was added individually rather than found in the identities folder.
    let isExtra: Bool

    var isUsable: Bool { problem == nil && (kind?.isSupported ?? false) }
    var displayPath: String { KeyStore.abbreviate(url.path) }
    /// What the avatar is stored under, the same value the matching recipient uses.
    var avatarKey: String { fingerprint ?? publicKeyLine.map(KeyMaterial.normalized) ?? url.path }
}

/// Owns the key folders and files the user granted access to, scans them for keys, and writes
/// new recipients and identities. Everything goes through security-scoped bookmarks, so the
/// folders stay accessible across launches.
@MainActor
final class KeyStore: ObservableObject {
    @Published private(set) var recipientsFolder: URL?
    @Published private(set) var identitiesFolder: URL?
    @Published private(set) var extraIdentityFiles: [URL] = []
    @Published private(set) var recipients: [RecipientEntry] = []
    @Published private(set) var identities: [IdentityEntry] = []
    /// Called whenever the folders or the keys in them change.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    /// URLs whose security scope is open; closed again before replacing them or on forget.
    private var accessedURLs: [URL] = []

    private static let recipientsBookmarkKey = "AgeminRecipientsFolderBookmark"
    private static let identitiesBookmarkKey = "AgeminIdentitiesFolderBookmark"
    private static let extraIdentitiesBookmarkKey = "AgeminExtraIdentityBookmarks"
    /// Files in an SSH folder that are never keys.
    private static let skippedIdentityNames: Set<String> = [
        "config", "known_hosts", "known_hosts.old", "authorized_keys", "authorized_keys2", "environment", "rc", ".DS_Store",
    ]
    /// Identity files beyond this size are not read.
    private static let maximumIdentitySize = 1 << 20
    /// Recipient files beyond this size are not read.
    private static let maximumRecipientSize = 1 << 16

    /// The real home directory, because the sandbox container reports its own home.
    nonisolated static var realHomeDirectory: URL {
        // The password database knows the real home; Foundation's answer is the fallback.
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where the age script keeps recipient keys: `~/.age`.
    nonisolated static var defaultRecipientsDirectory: URL {
        realHomeDirectory.appendingPathComponent(".age", isDirectory: true)
    }

    /// Where SSH keeps keys: `~/.ssh`.
    nonisolated static var defaultIdentitiesDirectory: URL {
        realHomeDirectory.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Stands in for the real home directory in displayed paths. The screenshot renderer sets it
    /// so a fixture path reads like a user's own; the app leaves it nil.
    nonisolated(unsafe) static var displayHomeOverride: String?

    // abbreviate(path): Shorten the path with `~` when it is the home directory or lies inside it.
    nonisolated static func abbreviate(_ path: String) -> String {
        let home = displayHomeOverride ?? realHomeDirectory.path
        // The home directory itself.
        if path == home { return "~" }
        // Inside it; the slash keeps a sibling such as `/Users/ilia2` from matching.
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: Restore and forget

    // restore(): Resolve the bookmarks saved on an earlier launch and scan the folders.
    func restore() {
        stopAccessing()
        recipientsFolder = resolveBookmark(key: Self.recipientsBookmarkKey)
        identitiesFolder = resolveBookmark(key: Self.identitiesBookmarkKey)
        // Extra identity files are saved as a list of bookmarks, resolved one by one.
        let extras = (defaults.array(forKey: Self.extraIdentitiesBookmarkKey) as? [Data]) ?? []
        var files: [URL] = []
        var kept: [Data] = []
        for data in extras {
            // Bookmarks that no longer resolve are dropped from the list.
            if let url = resolveBookmarkData(data, refreshingKey: nil) {
                files.append(url)
                kept.append(data)
            }
        }
        // The saved list is rewritten only when a bookmark was dropped.
        if kept.count != extras.count { defaults.set(kept, forKey: Self.extraIdentitiesBookmarkKey) }
        extraIdentityFiles = files
        refresh()
    }

    // adoptWithoutBookmarks(recipientsFolder, identitiesFolder): Use folders without remembering
    // them, for the screenshot renderer and tests.
    func adoptWithoutBookmarks(recipientsFolder: URL?, identitiesFolder: URL?) {
        stopAccessing()
        self.recipientsFolder = recipientsFolder
        self.identitiesFolder = identitiesFolder
        extraIdentityFiles = []
        refresh()
    }

    // forgetAccess(): Close the scopes and clear every saved bookmark.
    func forgetAccess() {
        stopAccessing()
        defaults.removeObject(forKey: Self.recipientsBookmarkKey)
        defaults.removeObject(forKey: Self.identitiesBookmarkKey)
        defaults.removeObject(forKey: Self.extraIdentitiesBookmarkKey)
        recipientsFolder = nil
        identitiesFolder = nil
        extraIdentityFiles = []
        refresh()
    }

    // resolveBookmark(key): The folder a saved bookmark points to, with its scope opened.
    private func resolveBookmark(key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return resolveBookmarkData(data, refreshingKey: key)
    }

    // resolveBookmarkData(data, refreshingKey): Resolve a security-scoped bookmark without
    // prompting, open its scope, and store a fresh bookmark under the key when macOS reports it
    // stale.
    private func resolveBookmarkData(_ data: Data, refreshingKey key: String?) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        // Only URLs that actually grant a scope are remembered for release.
        if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
        // A stale bookmark still resolves; a fresh one spares later launches the same repair.
        if stale, let key, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(refreshed, forKey: key)
        }
        return url
    }

    // stopAccessing(): Close every open security scope.
    private func stopAccessing() {
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs = []
    }

    // MARK: Choosing folders and files

    // chooseRecipientsFolder(in window): Pick the folder that holds `.pub` recipient files.
    func chooseRecipientsFolder(in window: NSWindow?) {
        let panel = folderPanel(start: recipientsFolder ?? Self.defaultRecipientsDirectory)
        panel.message = localized("Choose the folder with the .pub files you encrypt for, usually ~/.age")
        panel.prompt = localized("Choose")
        present(panel, in: window) { [weak self] url in
            // Adopt the folder only once its bookmark is saved; a refusal was reported already.
            guard let self, self.saveBookmark(for: url, key: Self.recipientsBookmarkKey) else { return }
            self.recipientsFolder = url
            self.refresh()
        }
    }

    // chooseIdentitiesFolder(in window): Pick the folder that holds private keys, usually ~/.ssh.
    func chooseIdentitiesFolder(in window: NSWindow?) {
        let panel = folderPanel(start: identitiesFolder ?? Self.defaultIdentitiesDirectory)
        panel.message = localized("Choose the folder with your private keys, usually ~/.ssh")
        panel.prompt = localized("Choose")
        present(panel, in: window) { [weak self] url in
            // Adopt the folder only once its bookmark is saved; a refusal was reported already.
            guard let self, self.saveBookmark(for: url, key: Self.identitiesBookmarkKey) else { return }
            self.identitiesFolder = url
            self.refresh()
        }
    }

    // addIdentityFile(in window): Add one private key file kept somewhere else.
    func addIdentityFile(in window: NSWindow?) {
        // Several files may be picked at once; hidden files show because keys live in dot folders.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = identitiesFolder ?? Self.defaultIdentitiesDirectory
        panel.message = localized("Choose an age identity file or an SSH private key")
        panel.prompt = localized("Add")
        presentMultiple(panel, in: window) { [weak self] urls in
            guard let self else { return }
            var stored = (self.defaults.array(forKey: Self.extraIdentitiesBookmarkKey) as? [Data]) ?? []
            // Each new file gets its own bookmark; files already listed are skipped.
            for url in urls where !self.extraIdentityFiles.contains(url) {
                guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { continue }
                stored.append(bookmark)
                // Open the scope now; it is reopened from the bookmark on later launches.
                if url.startAccessingSecurityScopedResource() { self.accessedURLs.append(url) }
                self.extraIdentityFiles.append(url)
            }
            self.defaults.set(stored, forKey: Self.extraIdentitiesBookmarkKey)
            self.refresh()
        }
    }

    // addIdentityFileWithoutPanel(url): Add a key file the app itself just saved, whose URL came
    // from a save panel and therefore carries access.
    func addIdentityFileWithoutPanel(_ url: URL) {
        // A file already listed, or one macOS will not bookmark, only gets a rescan.
        guard !extraIdentityFiles.contains(url), let bookmark = try? url.bookmarkData(options: .withSecurityScope) else {
            refresh()
            return
        }
        var stored = (defaults.array(forKey: Self.extraIdentitiesBookmarkKey) as? [Data]) ?? []
        stored.append(bookmark)
        defaults.set(stored, forKey: Self.extraIdentitiesBookmarkKey)
        // Only a URL that actually grants a scope is remembered for release.
        if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
        extraIdentityFiles.append(url)
        refresh()
    }

    // removeExtraIdentityFile(url): Stop using a file added individually. The file is not deleted.
    func removeExtraIdentityFile(_ url: URL) {
        guard let index = extraIdentityFiles.firstIndex(of: url) else { return }
        extraIdentityFiles.remove(at: index)
        var stored = (defaults.array(forKey: Self.extraIdentitiesBookmarkKey) as? [Data]) ?? []
        // The bookmarks are kept in the same order as the files.
        if index < stored.count { stored.remove(at: index) }
        defaults.set(stored, forKey: Self.extraIdentitiesBookmarkKey)
        // The file's scope is no longer needed.
        if let accessed = accessedURLs.firstIndex(of: url) {
            accessedURLs[accessed].stopAccessingSecurityScopedResource()
            accessedURLs.remove(at: accessed)
        }
        refresh()
    }

    // folderPanel(start): A single-folder picker that shows hidden folders such as ~/.ssh.
    private func folderPanel(start: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = true
        panel.directoryURL = start
        return panel
    }

    // present(panel, in window, completion): Present a panel as a sheet when a window is given,
    // otherwise app-modally, and call completion with the chosen URL only on acceptance.
    private func present(_ panel: NSSavePanel, in window: NSWindow?, completion: @escaping (URL) -> Void) {
        presentMultiple(panel, in: window) { urls in
            // A single-selection panel yields at most one URL.
            if let url = urls.first { completion(url) }
        }
    }

    // presentMultiple(panel, in window, completion): Present a panel as a sheet when a window is
    // given, otherwise app-modally, and call completion with every chosen URL only on acceptance.
    private func presentMultiple(_ panel: NSSavePanel, in window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            // An open panel reports all its selections; a save panel has just one URL.
            let urls = (panel as? NSOpenPanel)?.urls ?? [panel.url].compactMap { $0 }
            completion(urls)
        }
        // A window makes a sheet possible.
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            // Without one the panel runs app-modally.
            handler(panel.runModal())
        }
    }

    // saveBookmark(for url, key): Remember a chosen folder; false when macOS refuses a bookmark.
    private func saveBookmark(for url: URL, key: String) -> Bool {
        // Without a bookmark the folder would be lost on relaunch, so the choice is refused.
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else {
            presentError(localized("macOS did not grant lasting access to that folder. Choose it again, or choose another folder."))
            return false
        }
        defaults.set(bookmark, forKey: key)
        // Open the scope now; later launches reopen it from the bookmark.
        if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
        return true
    }

    // presentError(message): Show a problem in a modal alert.
    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("Agemin could not use that folder")
        alert.informativeText = message
        alert.addButton(withTitle: localized("OK"))
        alert.runModal()
    }

    // MARK: Scanning

    // refresh(): Rescan both folders and the extra files.
    func refresh() {
        recipients = scanRecipients()
        identities = scanIdentities()
        onChange?()
    }

    // scanRecipients(): Every key line of every `.pub` file in the recipients folder, in file order.
    private func scanRecipients() -> [RecipientEntry] {
        guard let folder = recipientsFolder else { return [] }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var entries: [RecipientEntry] = []
        // Files are visited in Finder's natural order; a folder named like a key is skipped.
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where name.hasSuffix(".pub") {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let baseName = String(name.dropLast(4))
            // An unreadable, oversized, or non-UTF-8 file is still listed; its empty line reports a
            // problem.
            guard let data = Self.readFile(url, limit: Self.maximumRecipientSize), let text = String(data: data, encoding: .utf8) else {
                entries.append(RecipientEntry(name: baseName, line: "", url: url, lineNumber: 0))
                continue
            }
            // Comment lines and blank lines are not keys.
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let keyLines = lines.enumerated().filter { !$0.element.isEmpty && !$0.element.hasPrefix("#") }
            // An empty file is listed so the user sees why it is skipped.
            if keyLines.isEmpty {
                entries.append(RecipientEntry(name: baseName, line: "", url: url, lineNumber: 0))
                continue
            }
            for (index, line) in keyLines {
                // In a file with several keys, each key after the first is labeled with its line
                // number.
                let label = keyLines.count > 1 && index != keyLines[0].offset ? "\(baseName) #\(index + 1)" : baseName
                entries.append(RecipientEntry(name: label, line: line, url: url, lineNumber: index))
            }
        }
        return entries
    }

    // scanIdentities(): The key files in the identities folder plus the extra files.
    private func scanIdentities() -> [IdentityEntry] {
        var urls: [URL] = []
        // Folder files that are public keys, SSH configuration, or hidden are not candidates.
        if let folder = identitiesFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where !name.hasSuffix(".pub") && !Self.skippedIdentityNames.contains(name) && !name.hasPrefix(".") {
                urls.append(folder.appendingPathComponent(name))
            }
        }
        var entries = urls.compactMap { identityEntry(for: $0, isExtra: false) }
        entries.sort { lhs, rhs in
            // The keys the age script tries first come first, then the rest by name.
            let order = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"]
            let lhsRank = order.firstIndex(of: lhs.name) ?? order.count
            let rhsRank = order.firstIndex(of: rhs.name) ?? order.count
            // Equal ranks fall back to a natural name order.
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for url in extraIdentityFiles {
            // Extra files are listed even when they do not look like keys, so they can be removed.
            entries.append(identityEntry(for: url, isExtra: true) ?? IdentityEntry(
                id: url.path, url: url, name: url.lastPathComponent, kind: nil, isProtected: false,
                problem: localized("This file is not a key."), publicKeyLine: nil, fingerprint: nil, tag: nil, count: 0, isExtra: true
            ))
        }
        return entries
    }

    // identityEntry(for url, isExtra): Describe one file, or nil when it does not look like a key
    // at all and was only found by scanning a folder.
    private func identityEntry(for url: URL, isExtra: Bool) -> IdentityEntry? {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        guard let data = Self.readFile(url, limit: Self.maximumIdentitySize) else {
            // Unreadable files are not keys; extra files report the problem.
            return isExtra ? IdentityEntry(id: url.path, url: url, name: name, kind: nil, isProtected: false, problem: localized("The file could not be read."), publicKeyLine: nil, fingerprint: nil, tag: nil, count: 0, isExtra: true) : nil
        }
        // An encrypted identity file is binary, so it is recognized by its header before any text
        // check; other key files are text.
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeKey = AgeIdentityFile.isEncryptedAgeFile(data)
            || trimmed.hasPrefix("-----BEGIN") || trimmed.contains("AGE-SECRET-KEY-1")
        guard looksLikeKey || isExtra else { return nil }
        do {
            switch try AgeIdentityFile.classify(data) {
            case .ageIdentities(let keys):
                // A plain identity file: the first key's public key stands for the file.
                let first = keys[0]
                return IdentityEntry(id: url.path, url: url, name: name, kind: .x25519, isProtected: false, problem: nil,
                                     publicKeyLine: first.recipient?.line, fingerprint: first.recipient?.line, tag: nil, count: keys.count, isExtra: isExtra)
            case .sshKey(let key):
                // Only Ed25519 and RSA keys work with age; other algorithms are listed with why.
                let kind: AgeKeyKind = key.publicKey.algorithm == "ssh-ed25519" ? .sshEd25519 : key.publicKey.algorithm == "ssh-rsa" ? .sshRSA : .unsupported(key.publicKey.algorithm)
                let problem = kind.isSupported ? nil : AgeError.unsupportedKey(key.publicKey.algorithm).localizedDescription
                return IdentityEntry(id: url.path, url: url, name: name, kind: kind, isProtected: key.isEncrypted, problem: problem,
                                     publicKeyLine: key.publicKey.line, fingerprint: key.publicKey.fingerprint, tag: key.publicKey.tag, count: 1, isExtra: isExtra)
            case .legacyRSA(let identity):
                // A PEM RSA key; an encrypted one fails to parse, so it is never protected here.
                let recipient = identity.recipient as? SSHRSARecipient
                return IdentityEntry(id: url.path, url: url, name: name, kind: .sshRSA, isProtected: false, problem: nil,
                                     publicKeyLine: recipient?.publicKey.line, fingerprint: recipient?.publicKey.fingerprint, tag: recipient?.publicKey.tag, count: 1, isExtra: isExtra)
            case .encryptedAgeFile:
                // A passphrase-protected identity file; its public key is unknown until decrypted.
                return IdentityEntry(id: url.path, url: url, name: name, kind: .x25519, isProtected: true, problem: nil,
                                     publicKeyLine: nil, fingerprint: nil, tag: nil, count: 1, isExtra: isExtra)
            }
        } catch {
            // A file that looks like a key but cannot be parsed is listed with the parse error.
            return IdentityEntry(id: url.path, url: url, name: name, kind: nil, isProtected: false, problem: error.localizedDescription,
                                 publicKeyLine: nil, fingerprint: nil, tag: nil, count: 0, isExtra: isExtra)
        }
    }

    // readFile(url, limit): The file's bytes, or nil when it is missing, unreadable, or too large.
    nonisolated static func readFile(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Reading one byte past the limit tells a too-large file from one that just fits.
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    // MARK: Loading identities

    // loadIdentities(at url, named name, passphrase): Load identities without actor state so a
    // caller can parse and unlock a key away from the main thread.
    nonisolated static func loadIdentities(at url: URL, named name: String, passphrase: String?) throws -> [any AgeIdentity] {
        guard let data = readFile(url, limit: AgeIdentityFile.maximumSize) else { throw AgeError.cannotRead(name) }
        switch try AgeIdentityFile.classify(data) {
        case .ageIdentities(let keys):
            return keys
        case .sshKey(let key):
            return [try key.identity(passphrase: passphrase)]
        case .legacyRSA(let identity):
            return [identity]
        case .encryptedAgeFile:
            // A protected file is decrypted in memory with its passphrase first.
            guard let passphrase, !passphrase.isEmpty else { throw AgeError.passphraseRequired }
            let plain = try AgeEngine.decryptToMemory(data, identities: [ScryptIdentity(passphrase: passphrase)])
            // The decrypted file must itself be a plain identity file.
            guard case .ageIdentities(let keys) = try AgeIdentityFile.classify(plain) else {
                throw AgeError.invalidIdentity(localized("The decrypted file does not hold an age secret key."))
            }
            return keys
        }
    }

    // MARK: Writing keys

    // saveRecipient(name, line): Write `<name>.pub` into the recipients folder. The name is cleaned
    // into a plain file name; an existing file is never replaced.
    func saveRecipient(name: String, line: String) throws {
        guard let folder = recipientsFolder else { throw AgeError.cannotWrite(localized("The recipients folder")) }
        let cleaned = Self.cleanFileName(name)
        guard !cleaned.isEmpty else { throw AgeError.invalidRecipient(localized("Give the recipient a name.")) }
        // The line must parse before anything is written.
        _ = try AgeRecipientParser.parse(line)
        let url = folder.appendingPathComponent(cleaned + ".pub")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AgeError.invalidRecipient(localizedFormat("%@.pub already exists in the recipients folder.", cleaned))
        }
        // A write failure is reported by file name.
        do {
            try Data((line.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8).write(to: url, options: [])
        } catch {
            throw AgeError.cannotWrite(cleaned + ".pub")
        }
        refresh()
    }

    // removeRecipientFile(entry): Delete the `.pub` file behind an entry.
    func removeRecipientFile(_ entry: RecipientEntry) throws {
        let url = entry.url
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AgeError.cannotWrite(url.lastPathComponent)
        }
        refresh()
    }

    // cleanFileName(name): The name trimmed, with `/` and `:` turned into dashes, a `.pub` suffix
    // dropped, and leading dots removed so the file is not hidden.
    nonisolated static func cleanFileName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // A `.pub` suffix typed by the user is implied.
        if cleaned.lowercased().hasSuffix(".pub") { cleaned = String(cleaned.dropLast(4)) }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }

    // revealInFinder(url): Show a file or folder in Finder.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // matchingIdentities(for info): The identities whose public SSH tag names an entry. Native age
    // entries have no tag and need the private-key check performed by AppModel.
    func matchingIdentities(for info: AgeFileInfo) -> [IdentityEntry] {
        let summaries = info.recipients
        // A usable SSH identity matches when any stanza carries its tag.
        return identities.filter { entry in
            guard entry.isUsable else { return false }
            return summaries.contains { summary in
                switch summary.kind {
                case .x25519: return false
                case .sshEd25519(let tag), .sshRSA(let tag): return entry.tag == tag
                case .scrypt, .other: return false
                }
            }
        }
    }
}
