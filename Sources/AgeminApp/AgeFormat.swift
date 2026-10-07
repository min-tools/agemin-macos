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

/// Base64 as age uses it in headers and keys: the standard alphabet without padding, decoded
/// strictly so a stanza cannot have two spellings.
enum AgeBase64 {
    // encode(data): Standard base64 without trailing padding.
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // decode(text): The bytes of unpadded base64, or nil for padding, stray characters, or
    // non-canonical trailing bits.
    static func decode(_ text: String) -> Data? {
        // Padding is never written, so its presence means the text came from somewhere else, and
        // a length of 4n+1 cannot be base64 at all.
        guard !text.contains("="), text.count % 4 != 1 else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: []) else { return nil }
        // Re-encoding must give the same text, which rejects nonzero unused bits.
        guard encode(data) == text else { return nil }
        return data
    }
}

/// HKDF-SHA-256 as the age format uses it for every derived key.
enum AgeKDF {
    // derive(ikm, salt, info, [count = 32]): count bytes of HKDF-SHA-256 output.
    static func derive(ikm: Data, salt: Data, info: String, count: Int = 32) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // wrap(fileKey, with key): ChaCha20-Poly1305 of the file key with a zero nonce, the way the
    // X25519, ssh-ed25519, and scrypt stanza bodies wrap it; ssh-rsa uses RSA-OAEP instead.
    static func wrap(_ fileKey: Data, with key: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(fileKey, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        return sealed.ciphertext + sealed.tag
    }

    // unwrap(body, with key): The file key from a stanza body, or nil when the key does not fit.
    static func unwrap(_ body: Data, with key: Data) -> Data? {
        // A wrapped key is the 16-byte ciphertext followed by the 16-byte tag; nothing else fits.
        guard body.count == AgeHeaderCodec.fileKeySize + 16 else { return nil }
        let box = try? ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
            ciphertext: body.prefix(AgeHeaderCodec.fileKeySize),
            tag: body.suffix(16)
        )
        guard let box, let opened = try? ChaChaPoly.open(box, using: SymmetricKey(data: key)) else { return nil }
        return opened
    }
}
