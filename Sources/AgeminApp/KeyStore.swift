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
