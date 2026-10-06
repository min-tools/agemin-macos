import CommonCrypto
import CryptoKit
import Foundation

/// Reads the length-prefixed fields of SSH's wire format.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    // init(data): Start reading at the beginning of data.
    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }
    /// What has not been read yet.
    var remaining: Data { data[offset...] }

    // readUInt32(): A big-endian 32-bit integer.
    mutating func readUInt32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw SSHKeyError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(data[offset])
            offset += 1
        }
        return value
    }

    // readString(): A length-prefixed byte string.
    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard data.endIndex - offset >= length else { throw SSHKeyError.truncated }
        let result = data[offset..<(offset + length)]
        offset += length
        return Data(result)
    }

    // readText(): A length-prefixed string, decoded as UTF-8.
    mutating func readText() throws -> String {
        guard let text = String(data: try readString(), encoding: .utf8) else { throw SSHKeyError.malformed }
        return text
    }

    // readMPInt(): A length-prefixed big-endian integer; a negative value is rejected.
    mutating func readMPInt() throws -> BigUInt {
        let bytes = try readString()
        // A set high bit without a leading zero byte would be a negative number.
        if let first = bytes.first, first & 0x80 != 0 { throw SSHKeyError.malformed }
        return BigUInt(bigEndian: bytes)
    }

    // skip(count): Skip count bytes.
    mutating func skip(_ count: Int) throws {
        guard data.endIndex - offset >= count else { throw SSHKeyError.truncated }
        offset += count
    }
}

/// Builds SSH wire format.
enum SSHWire {
    // string(data): A length-prefixed byte string.
    static func string(_ data: Data) -> Data {
        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) })
        result.append(data)
        return result
    }

    // mpint(value): A length-prefixed big-endian integer with a leading zero when needed.
    static func mpint(_ value: BigUInt) -> Data {
        var bytes = value.bigEndianBytes
        // Keep the number positive in two's complement.
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(bytes)
    }
}

/// Problems with an SSH key file, reported through the age identity errors.
enum SSHKeyError: Error {
    case truncated
    case malformed
    case unsupportedAlgorithm(String)
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case encrypted
    case wrongPassphrase
    case legacyEncrypted
    case tooManyRounds(Int)

    /// The user-readable age error for this problem.
    var ageError: AgeError {
        switch self {
        case .truncated: return .invalidIdentity(localized("The key file ends early."))
        case .malformed: return .invalidIdentity(localized("The key file is malformed."))
        case .tooManyRounds(let rounds): return .invalidIdentity(localizedFormat("The key uses %lld key derivation rounds. Agemin supports up to %lld.", Int64(rounds), Int64(OpenSSHPrivateKey.maximumRounds)))
        case .unsupportedAlgorithm(let name): return .unsupportedKey(name)
        case .unsupportedCipher(let name): return .invalidIdentity(localizedFormat("The key is protected with the %@ cipher, which is not supported.", name))
        case .unsupportedKDF(let name): return .invalidIdentity(localizedFormat("The key uses the %@ key derivation, which is not supported.", name))
        case .encrypted: return .passphraseRequired
        case .wrongPassphrase: return .wrongPassphrase
        case .legacyEncrypted: return .invalidIdentity(localized("This passphrase-protected key uses the legacy PEM format. Convert it with ssh-keygen -p -o, or use an unprotected copy."))
        }
    }
}

/// An SSH public key: its wire encoding plus the parts age needs.
struct SSHPublicKey: Equatable {
    /// OpenSSH refuses RSA keys above this size; the same limit keeps imported keys from
    /// causing excessive arbitrary-precision work.
    static let maximumRSABits = 16_384

    let algorithm: String
    /// The wire encoding, which SSH fingerprints and age tags are computed over.
    let wire: Data
    let comment: String

    /// The 32-byte Ed25519 public key, for ssh-ed25519 keys.
    var ed25519PublicKey: Data? {
        guard algorithm == "ssh-ed25519" else { return nil }
        var reader = SSHWireReader(wire)
        guard (try? reader.readText()) == algorithm, let key = try? reader.readString(), key.count == 32 else { return nil }
        return key
    }

    /// The public exponent and modulus, for ssh-rsa keys.
    var rsaNumbers: (exponent: BigUInt, modulus: BigUInt)? {
        guard algorithm == "ssh-rsa" else { return nil }
        var reader = SSHWireReader(wire)
        guard (try? reader.readText()) == algorithm, let e = try? reader.readMPInt(), let n = try? reader.readMPInt() else { return nil }
        return (e, n)
    }

    /// The age recipient tag: the first four bytes of the SHA-256 fingerprint, in base64.
    var tag: String {
        AgeBase64.encode(Data(SHA256.hash(data: wire)).prefix(4))
    }

    /// The OpenSSH fingerprint, "SHA256:" followed by unpadded base64.
    var fingerprint: String {
        "SHA256:" + AgeBase64.encode(Data(SHA256.hash(data: wire)))
    }

    /// The authorized_keys line form: algorithm, base64 wire encoding, and the comment.
    var line: String {
        let parts = [algorithm, wire.base64EncodedString()] + (comment.isEmpty ? [] : [comment])
        return parts.joined(separator: " ")
    }

    // parse(line): A public key from its authorized_keys line form.
    static func parse(line: String) throws -> SSHPublicKey {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, let wire = Data(base64Encoded: String(fields[1])) else { throw SSHKeyError.malformed }
        let key = try parse(wire: wire, comment: fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : "")
        // The algorithm field must agree with the name inside the wire blob.
        guard key.algorithm == String(fields[0]) else { throw SSHKeyError.malformed }
        return key
    }

    // parse(wire, [comment = ""]): A public key from its wire encoding. A supported key must hold
    // exactly its fields: trailing bytes would make the tag and fingerprint differ from the
    // ones other tools compute for the same key.
    static func parse(wire: Data, comment: String = "") throws -> SSHPublicKey {
        var reader = SSHWireReader(wire)
        let algorithm = try reader.readText()
        guard !algorithm.isEmpty else { throw SSHKeyError.malformed }
        switch algorithm {
        case "ssh-ed25519":
            guard try reader.readString().count == 32, reader.isAtEnd else { throw SSHKeyError.malformed }
        case "ssh-rsa":
            _ = try reader.readMPInt()
            let modulus = try reader.readMPInt()
            guard modulus.bitWidth <= maximumRSABits, reader.isAtEnd else {
                throw SSHKeyError.malformed
            }
        default:
            // Other kinds are reported as unsupported by their callers; their layout is not checked.
            break
        }
        return SSHPublicKey(algorithm: algorithm, wire: wire, comment: comment)
    }
}
