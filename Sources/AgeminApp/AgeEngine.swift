import CryptoKit
import Foundation

/// A stanza described for the interface: the kind of key it is for and its tag.
struct AgeStanzaSummary: Identifiable, Equatable {
    enum Kind: Equatable {
        case x25519
        case sshEd25519(tag: String)
        case sshRSA(tag: String)
        case scrypt(workFactor: Int?)
        case other(String)
    }

    let id: Int
    let kind: Kind

    // init(index, stanza): Summarize the stanza at the given header position.
    init(index: Int, stanza: AgeStanza) {
        id = index
        switch stanza.type {
        case "X25519": kind = .x25519
        case "ssh-ed25519": kind = .sshEd25519(tag: stanza.args.first ?? "")
        case "ssh-rsa": kind = .sshRSA(tag: stanza.args.first ?? "")
        case "scrypt": kind = .scrypt(workFactor: stanza.args.count == 2 ? Int(stanza.args[1]) : nil)
        default: kind = .other(stanza.type)
        }
    }

    /// The tag an SSH identity would have to match, if any.
    var sshTag: String? {
        switch kind {
        case .sshEd25519(let tag), .sshRSA(let tag): return tag
        default: return nil
        }
    }

    /// The key kind, for matching against known identities.
    var keyKind: AgeKeyKind {
        switch kind {
        case .x25519: return .x25519
        case .sshEd25519: return .sshEd25519
        case .sshRSA: return .sshRSA
        case .scrypt: return .scrypt
        case .other(let type): return .unsupported(type)
        }
    }
}
