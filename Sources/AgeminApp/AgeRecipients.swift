import CryptoKit
import Foundation

/// The kinds of key age can encrypt to or decrypt with.
enum AgeKeyKind: Equatable {
    case x25519
    case sshEd25519
    case sshRSA
    case scrypt
    case unsupported(String)

    /// The short label shown in key lists.
    var label: String {
        switch self {
        case .x25519: return "age"
        case .sshEd25519: return "ssh-ed25519"
        case .sshRSA: return "ssh-rsa"
        case .scrypt: return localized("passphrase")
        case .unsupported(let name): return name
        }
    }

    /// Whether age can use keys of this kind.
    var isSupported: Bool {
        // Only the unsupported case names an algorithm age cannot use.
        if case .unsupported = self { return false }
        return true
    }
}

/// Someone a file can be encrypted for.
protocol AgeRecipient {
    var kind: AgeKeyKind { get }
    /// The public key in its line form, for display and for saving to a recipients file.
    var line: String { get }
    // wrap(fileKey): The stanza that lets this recipient recover the file key.
    func wrap(fileKey: Data) throws -> AgeStanza
}
