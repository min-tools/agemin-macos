import CryptoKit
import Foundation

/// Everything that can go wrong while reading keys or encrypting and decrypting files. Each case
/// carries user-readable text; the detail cases keep the specific reason.
enum AgeError: LocalizedError, Equatable {
    case invalidHeader(String)
    case invalidArmor(String)
    case invalidRecipient(String)
    case invalidIdentity(String)
    case unsupportedKey(String)
    case noMatchingIdentity
    case wrongPassphrase
    case headerMACMismatch
    case payloadCorrupt
    case truncated
    case cannotRead(String)
    case cannotWrite(String)
    case cancelled
    case noRecipients
    case workFactorTooHigh(Int)
    case passphraseRequired

    /// The message shown for each case; the detail cases append their specific reason.
    var errorDescription: String? {
        switch self {
        case .invalidHeader(let detail): return localizedFormat("This is not an age file. %@", detail)
        case .invalidArmor(let detail): return localizedFormat("The armored file could not be read. %@", detail)
        case .invalidRecipient(let detail): return localizedFormat("The recipient key could not be read. %@", detail)
        case .invalidIdentity(let detail): return localizedFormat("The identity could not be read. %@", detail)
        case .unsupportedKey(let kind): return localizedFormat("%@ keys are not supported by age.", kind)
        case .noMatchingIdentity: return localized("None of the identities can decrypt this file.")
        case .wrongPassphrase: return localized("The passphrase is incorrect.")
        case .headerMACMismatch: return localized("The file header was modified or the key is wrong.")
        case .payloadCorrupt: return localized("The encrypted data is corrupt or was modified.")
        case .truncated: return localized("The file ends early. It may be incomplete.")
        case .cannotRead(let name): return localizedFormat("%@ could not be read.", name)
        case .cannotWrite(let name): return localizedFormat("%@ could not be written.", name)
        case .cancelled: return localized("The operation was canceled.")
        case .noRecipients: return localized("Select at least one recipient.")
        case .workFactorTooHigh(let factor): return localizedFormat("The passphrase work factor %lld is too high to try safely.", Int64(factor))
        case .passphraseRequired: return localized("This file needs a passphrase.")
        }
    }
}

/// One recipient stanza of an age header: a type, its arguments, and a binary body.
struct AgeStanza: Equatable {
    var type: String
    var args: [String]
    var body: Data
}
