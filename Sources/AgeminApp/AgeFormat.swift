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

/// Random bytes from the system's cryptographic generator.
enum AgeRandom {
    // bytes(count): count random bytes.
    static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        // Encrypting with weak randomness is worse than stopping, so a generator failure is fatal.
        precondition(status == errSecSuccess, "The system random generator failed")
        return data
    }
}

/// Reads and writes the age v1 header: the intro line, the stanzas, and the MAC line.
enum AgeHeaderCodec {
    static let intro = "age-encryption.org/v1"
    static let fileKeySize = 16
    static let macSize = 32
    /// Preserve large recipient lists while bounding per-stanza allocation and matching work.
    static let maximumStanzas = 65_536
    /// The most header text a file may carry; real headers are a few kilobytes at most.
    static let maximumHeaderSize = 16 * 1024 * 1024
    /// Full body lines hold this many base64 characters; the last line is always shorter.
    static let bodyLineWidth = 64

    /// A parsed header plus the exact bytes the MAC covers.
    struct Parsed {
        var stanzas: [AgeStanza]
        var mac: Data
        /// The header text through "---", which the MAC authenticates.
        var authenticated: Data
    }

    // serialize(stanzas): The header text through the "---" marker, which the MAC covers.
    static func serialize(_ stanzas: [AgeStanza]) -> Data {
        var text = intro + "\n"
        for stanza in stanzas {
            text += "-> " + ([stanza.type] + stanza.args).joined(separator: " ") + "\n"
            text += bodyLines(stanza.body)
        }
        text += "---"
        return Data(text.utf8)
    }

    // bodyLines(body): The body as base64 in lines of 64 characters. The last line is always
    // shorter than 64 characters, which is how a reader knows the body has ended; a body whose
    // text fills its lines exactly therefore ends with an empty line.
    static func bodyLines(_ body: Data) -> String {
        let text = AgeBase64.encode(body)
        var lines: [String] = []
        var remaining = Substring(text)
        while remaining.count >= bodyLineWidth {
            lines.append(String(remaining.prefix(bodyLineWidth)))
            remaining = remaining.dropFirst(bodyLineWidth)
        }
        lines.append(String(remaining))
        return lines.joined(separator: "\n") + "\n"
    }

    // mac(fileKey, over authenticated): HMAC-SHA-256 of the header text under the header key.
    static func mac(fileKey: Data, over authenticated: Data) -> Data {
        let key = AgeKDF.derive(ikm: fileKey, salt: Data(), info: "header")
        return Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: SymmetricKey(data: key)))
    }

    // encode(stanzas, fileKey): The complete header, MAC line included.
    static func encode(_ stanzas: [AgeStanza], fileKey: Data) -> Data {
        let authenticated = serialize(stanzas)
        var header = authenticated
        header.append(Data((" " + AgeBase64.encode(mac(fileKey: fileKey, over: authenticated)) + "\n").utf8))
        return header
    }

    // parse(from reader): Read the header lines up to and including the MAC line.
    static func parse(from reader: BufferedReader) throws -> Parsed {
        // The intro line must match exactly; anything else is not an age v1 file.
        guard let first = try reader.readLine() else { throw AgeError.truncated }
        guard first == intro else {
            throw AgeError.invalidHeader(localized("The first line is not the age version marker."))
        }
        var authenticated = Data((intro + "\n").utf8)
        var stanzas: [AgeStanza] = []
        // Each further line starts a stanza or is the MAC line that closes the header.
        while true {
            guard let line = try reader.readLine() else { throw AgeError.truncated }
            // The MAC line closes the header.
            if line.hasPrefix("---") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "---", let mac = AgeBase64.decode(String(parts[1])), mac.count == macSize else {
                    throw AgeError.invalidHeader(localized("The header authentication line is malformed."))
                }
                authenticated.append(Data("---".utf8))
                return Parsed(stanzas: stanzas, mac: mac, authenticated: authenticated)
            }
            // Anything else must start a stanza.
            guard line.hasPrefix("-> ") else {
                throw AgeError.invalidHeader(localized("A header line is neither a recipient nor the closing marker."))
            }
            // The byte cap bounds input, while this higher count cap also bounds object overhead.
            guard stanzas.count < maximumStanzas else {
                throw AgeError.invalidHeader(localized("The header lists too many recipients."))
            }
            let fields = line.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // The type and arguments are single-space separated, non-empty, printable ASCII.
            guard let type = fields.first, !type.isEmpty,
                  fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "\u{7F}" && $0.asciiValue! > 0x20 } }) else {
                throw AgeError.invalidHeader(localized("A recipient line is malformed."))
            }
            authenticated.append(Data((line + "\n").utf8))
            // The body follows: full lines of 64 characters, ended by a shorter line.
            var bodyText = ""
            while true {
                guard let bodyLine = try reader.readLine() else { throw AgeError.truncated }
                authenticated.append(Data((bodyLine + "\n").utf8))
                guard bodyLine.count <= bodyLineWidth, bodyLine.allSatisfy({ $0.isASCII }) else {
                    throw AgeError.invalidHeader(localized("A recipient body line is malformed."))
                }
                // A body that never ends would otherwise be collected until memory runs out.
                guard authenticated.count <= maximumHeaderSize else {
                    throw AgeError.invalidHeader(localized("The header is too large to be an age file."))
                }
                bodyText += bodyLine
                // A short line, including an empty one, ends the body.
                if bodyLine.count < bodyLineWidth { break }
            }
            // The body is one base64 string spread over the lines and is decoded as a whole.
            guard let body = AgeBase64.decode(bodyText) else {
                throw AgeError.invalidHeader(localized("A recipient body is not valid base64."))
            }
            stanzas.append(AgeStanza(type: type, args: Array(fields.dropFirst()), body: body))
        }
    }
}

/// The STREAM payload: 64 KiB chunks under ChaCha20-Poly1305 with a counter nonce whose final
/// byte marks the last chunk.
enum AgePayload {
    static let chunkSize = 65536
    static let tagSize = 16
    static let nonceSize = 16

    // key(fileKey, nonce): The payload key derived from the file key and the 16-byte nonce.
    static func key(fileKey: Data, nonce: Data) -> SymmetricKey {
        SymmetricKey(data: AgeKDF.derive(ikm: fileKey, salt: nonce, info: "payload"))
    }

    // chunkNonce(counter, last): Eleven big-endian counter bytes and a final 0 or 1.
    static func chunkNonce(counter: UInt64, last: Bool) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        var value = counter
        // Fill the counter from its low end; bytes 0-2 stay zero and byte 11 is the flag.
        for index in stride(from: 10, through: 3, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        bytes[11] = last ? 1 : 0
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    // seal(chunk, key, counter, last): Encrypt one chunk; the result is ciphertext then tag.
    static func seal(_ chunk: Data, key: SymmetricKey, counter: UInt64, last: Bool) throws -> Data {
        let sealed = try ChaChaPoly.seal(chunk, using: key, nonce: chunkNonce(counter: counter, last: last))
        return sealed.ciphertext + sealed.tag
    }

    // open(chunk, key, counter, last): Decrypt one chunk, or nil when the tag does not verify.
    static func open(_ chunk: Data, key: SymmetricKey, counter: UInt64, last: Bool) -> Data? {
        guard chunk.count >= tagSize else { return nil }
        let box = try? ChaChaPoly.SealedBox(
            nonce: chunkNonce(counter: counter, last: last),
            ciphertext: chunk.prefix(chunk.count - tagSize),
            tag: chunk.suffix(tagSize)
        )
        guard let box else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}
