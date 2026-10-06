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

/// An OpenSSH private key file ("openssh-key-v1"), parsed as far as its public half and cipher
/// settings. The private half is decrypted on request.
struct OpenSSHPrivateKey {
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let pemFooter = "-----END OPENSSH PRIVATE KEY-----"
    /// The most bcrypt rounds a protected key may ask for. ssh-keygen uses 16 by default and
    /// a few hundred at most in practice; the cap bounds the time a hostile key file can cost.
    static let maximumRounds = 4096
    private static let magic = Data("openssh-key-v1\0".utf8)

    let publicKey: SSHPublicKey
    let cipherName: String
    let kdfName: String
    private let kdfOptions: Data
    private let privateSection: Data

    var isEncrypted: Bool { cipherName != "none" }

    /// Whether this key's algorithm can serve as an age identity.
    var isSupportedAlgorithm: Bool { ["ssh-ed25519", "ssh-rsa"].contains(publicKey.algorithm) }

    // looksLikeKey(text): Whether the text is an OpenSSH private key file.
    static func looksLikeKey(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(pemHeader)
    }

    // parse(pem): The key from its PEM text.
    static func parse(pem: String) throws -> OpenSSHPrivateKey {
        // Strip the PEM armor and check the container magic.
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: pemHeader), let end = lines.firstIndex(of: pemFooter), start < end else {
            throw SSHKeyError.malformed
        }
        guard let blob = Data(base64Encoded: lines[(start + 1)..<end].joined()) else { throw SSHKeyError.malformed }
        guard blob.starts(with: magic) else { throw SSHKeyError.malformed }
        var reader = SSHWireReader(blob)
        try reader.skip(magic.count)
        // The header names the cipher and KDF, then carries the KDF options and the key count.
        let cipherName = try reader.readText()
        let kdfName = try reader.readText()
        let kdfOptions = try reader.readString()
        let count = try reader.readUInt32()
        // The format allows several keys, but OpenSSH only ever writes one.
        guard count == 1 else { throw SSHKeyError.malformed }
        // The key is its public wire form followed by the private section, encrypted or not.
        let publicWire = try reader.readString()
        let privateSection = try reader.readString()
        guard reader.isAtEnd else { throw SSHKeyError.malformed }
        let publicKey = try SSHPublicKey.parse(wire: publicWire)
        return OpenSSHPrivateKey(publicKey: publicKey, cipherName: cipherName, kdfName: kdfName, kdfOptions: kdfOptions, privateSection: privateSection)
    }

    // decryptedSection(passphrase): The private section, decrypted when the file is protected.
    // An encrypted key without a passphrase reports that one is needed.
    private func decryptedSection(passphrase: String?) throws -> Data {
        // An unprotected key stores the section as is.
        if cipherName == "none" {
            guard kdfName == "none" else { throw SSHKeyError.unsupportedKDF(kdfName) }
            guard kdfOptions.isEmpty else { throw SSHKeyError.malformed }
            return privateSection
        }
        // A protected key needs a passphrase and the bcrypt KDF, the only one OpenSSH writes.
        guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.encrypted }
        guard kdfName == "bcrypt" else { throw SSHKeyError.unsupportedKDF(kdfName) }
        // Only AES in CTR or CBC mode is supported; the name fixes the key size and mode.
        let (keyLength, blockSize, mode): (Int, Int, CCMode)
        switch cipherName {
        case "aes256-ctr": (keyLength, blockSize, mode) = (32, 16, CCMode(kCCModeCTR))
        case "aes192-ctr": (keyLength, blockSize, mode) = (24, 16, CCMode(kCCModeCTR))
        case "aes128-ctr": (keyLength, blockSize, mode) = (16, 16, CCMode(kCCModeCTR))
        case "aes256-cbc": (keyLength, blockSize, mode) = (32, 16, CCMode(kCCModeCBC))
        case "aes192-cbc": (keyLength, blockSize, mode) = (24, 16, CCMode(kCCModeCBC))
        case "aes128-cbc": (keyLength, blockSize, mode) = (16, 16, CCMode(kCCModeCBC))
        default: throw SSHKeyError.unsupportedCipher(cipherName)
        }
        // The KDF options carry the salt and the round count.
        var options = SSHWireReader(kdfOptions)
        let salt = try options.readString()
        let rounds = Int(try options.readUInt32())
        guard options.isAtEnd else { throw SSHKeyError.malformed }
        // The rounds come from the file; a hostile count would keep the derivation busy for days.
        guard rounds >= 1, rounds <= Self.maximumRounds else { throw SSHKeyError.tooManyRounds(rounds) }
        // bcrypt_pbkdf yields the cipher key followed by the IV.
        let derived = try BcryptPBKDF.derive(passphrase: Data(passphrase.utf8), salt: salt, rounds: rounds, keyLength: keyLength + blockSize)
        guard privateSection.count % blockSize == 0 else { throw SSHKeyError.malformed }
        return try Self.aesDecrypt(privateSection, key: derived.prefix(keyLength), iv: derived.suffix(blockSize), mode: mode)
    }

    // aesDecrypt(data, key, iv, mode): AES in CTR or CBC mode without padding, through CommonCrypto.
    private static func aesDecrypt(_ data: Data, key: Data, iv: Data, mode: CCMode) throws -> Data {
        // A one-shot decryptor; the CTR option selects the big-endian counter OpenSSH uses.
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw SSHKeyError.malformed }
        defer { CCCryptorRelease(cryptor) }
        // The buffer leaves room for one extra block, the most CommonCrypto could flush at the end.
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        var total = 0
        let updateStatus = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, out.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { throw SSHKeyError.malformed }
        total = moved
        // Finishing moves nothing without padding, but it still reports a stray partial block.
        let finalStatus = output.withUnsafeMutableBytes { out in
            CCCryptorFinal(cryptor, out.baseAddress! + total, out.count - total, &moved)
        }
        guard finalStatus == kCCSuccess else { throw SSHKeyError.malformed }
        total += moved
        return output.prefix(total)
    }

    // identity(passphrase): The age identity for this key, decrypting the private section with
    // the passphrase when the file is protected. Failures are reported as age errors.
    func identity(passphrase: String?) throws -> any AgeIdentity {
        do {
            return try makeIdentity(passphrase: passphrase)
        } catch let error as SSHKeyError {
            throw error.ageError
        }
    }

    // makeIdentity(passphrase): The identity, with the key format's own errors.
    private func makeIdentity(passphrase: String?) throws -> any AgeIdentity {
        guard isSupportedAlgorithm else { throw SSHKeyError.unsupportedAlgorithm(publicKey.algorithm) }
        let section = try decryptedSection(passphrase: passphrase)
        var reader = SSHWireReader(section)
        // Two equal check values confirm the passphrase; a mismatch means it was wrong.
        let check1 = try reader.readUInt32()
        let check2 = try reader.readUInt32()
        guard check1 == check2 else { throw isEncrypted ? SSHKeyError.wrongPassphrase : SSHKeyError.malformed }
        // The private half repeats the algorithm name; it must match the public half.
        let algorithm = try reader.readText()
        guard algorithm == publicKey.algorithm else { throw SSHKeyError.malformed }
        let identity: any AgeIdentity
        switch algorithm {
        case "ssh-ed25519":
            let publicPart = try reader.readString()
            let privatePart = try reader.readString()
            // The private part is the seed followed by a copy of the public key.
            guard publicPart.count == 32, privatePart.count == 64, privatePart.suffix(32) == publicPart,
                  publicKey.ed25519PublicKey == publicPart else { throw SSHKeyError.malformed }
            identity = try SSHEd25519Identity(publicKey: publicKey, seed: privatePart.prefix(32))
        case "ssh-rsa":
            // OpenSSH stores n, e, d, iqmp, p, and q in that order.
            let n = try reader.readMPInt()
            let e = try reader.readMPInt()
            let d = try reader.readMPInt()
            let iqmp = try reader.readMPInt()
            let p = try reader.readMPInt()
            let q = try reader.readMPInt()
            guard let numbers = publicKey.rsaNumbers, numbers.modulus == n, numbers.exponent == e else { throw SSHKeyError.malformed }
            // The private half must belong to the public half: real primes whose product is the
            // modulus, a valid CRT coefficient, and a nonzero private exponent below it.
            let one = BigUInt(1)
            guard p > one, q > one, p * q == n, (iqmp * q) % p == one,
                  !d.isZero, d < n else { throw SSHKeyError.malformed }
            let key = RSAPrivateKeyNumbers(modulus: n, publicExponent: e, privateExponent: d, prime1: p, prime2: q, coefficient: iqmp)
            identity = SSHRSAIdentity(publicKey: publicKey, numbers: key)
        default:
            throw SSHKeyError.unsupportedAlgorithm(algorithm)
        }
        // The comment follows the private fields. An already aligned section has no padding;
        // otherwise the rest must be OpenSSH's 1, 2, 3… sequence.
        _ = try reader.readText()
        let padding = reader.remaining
        guard padding.count <= 255,
              padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else {
            throw SSHKeyError.malformed
        }
        return identity
    }
}
