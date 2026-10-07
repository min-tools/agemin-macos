import CryptoKit
import Foundation

/// A key that can recover a file key from a header. Unwrapping returns nil when none of the
/// stanzas is for this identity, and throws for a malformed stanza, a wrong passphrase, or an
/// unsafe work factor.
protocol AgeIdentity {
    var kind: AgeKeyKind { get }
    /// The matching public key, when the identity knows it.
    var recipient: (any AgeRecipient)? { get }
    // unwrap(stanzas): The file key, or nil when no stanza is for this identity.
    func unwrap(_ stanzas: [AgeStanza]) throws -> Data?
}

/// An age native identity, the "AGE-SECRET-KEY-1…" form.
struct X25519Identity: AgeIdentity {
    static let hrp = "age-secret-key-"
    let secret: Data
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var kind: AgeKeyKind { .x25519 }
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var publicKeyLine: String { Bech32.encode(hrp: X25519Recipient.hrp, data: publicKey) }
    var recipient: (any AgeRecipient)? { try? X25519Recipient(publicKey: publicKey) }
    /// The uppercase secret key form that identity files hold.
    var line: String { Bech32.encode(hrp: Self.hrp, data: secret).uppercased() }

    // init(secret): From the 32 raw bytes.
    init(secret: Data) throws {
        guard secret.count == 32, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret) else {
            throw AgeError.invalidIdentity(localized("An age secret key has 32 bytes."))
        }
        self.secret = secret
        privateKey = key
    }

    // init(privateKey): Keep a newly generated key without re-parsing its fixed-size bytes.
    private init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        secret = privateKey.rawRepresentation
        self.privateKey = privateKey
    }

    // init(string): From the "AGE-SECRET-KEY-1…" form.
    init(string: String) throws {
        guard let decoded = Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines)), decoded.hrp == Self.hrp else {
            throw AgeError.invalidIdentity(localized("This is not a valid age secret key."))
        }
        try self.init(secret: decoded.data)
    }

    // generate(): A new random identity.
    static func generate() -> X25519Identity {
        X25519Identity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    // unwrap(stanzas): Try every X25519 stanza with this key.
    func unwrap(_ stanzas: [AgeStanza]) throws -> Data? {
        for stanza in stanzas where stanza.type == "X25519" {
            // A malformed X25519 stanza is a format error, not just a key that does not match.
            guard stanza.args.count == 1, let share = AgeBase64.decode(stanza.args[0]), share.count == 32 else {
                throw AgeError.invalidHeader(localized("An X25519 recipient entry is malformed."))
            }
            guard stanza.body.count == AgeHeaderCodec.fileKeySize + 16 else {
                throw AgeError.invalidHeader(localized("An X25519 recipient entry has the wrong size."))
            }
            // A low-order share is skipped rather than reported.
            guard let shared = try? X25519.agree(secret: privateKey, point: share) else { continue }
            let key = AgeKDF.derive(ikm: shared, salt: share + publicKey, info: X25519Recipient.label)
            // The first body that opens under this key holds the file key; one that does not
            // open belongs to another key.
            if let fileKey = AgeKDF.unwrap(stanza.body, with: key) { return fileKey }
        }
        return nil
    }
}

/// An SSH Ed25519 private key used as an age identity.
struct SSHEd25519Identity: AgeIdentity {
    let publicKey: SSHPublicKey
    private let scalar: Data
    private let curvePublicKey: Data

    var kind: AgeKeyKind { .sshEd25519 }
    var recipient: (any AgeRecipient)? { try? SSHEd25519Recipient(publicKey: publicKey) }

    // init(publicKey, seed): From the public key and the 32-byte Ed25519 seed.
    init(publicKey: SSHPublicKey, seed: Data) throws {
        guard seed.count == 32, let edwards = publicKey.ed25519PublicKey,
              let curve = Curve25519Conversion.montgomeryU(fromEdwardsPublicKey: edwards) else {
            throw AgeError.invalidIdentity(localized("The SSH key is not a valid Ed25519 key."))
        }
        self.publicKey = publicKey
        scalar = Curve25519Conversion.x25519Scalar(fromEdwardsSeed: seed)
        curvePublicKey = curve
    }

    // unwrap(stanzas): Try the ssh-ed25519 stanzas whose tag names this key.
    func unwrap(_ stanzas: [AgeStanza]) throws -> Data? {
        let tag = publicKey.tag
        for stanza in stanzas where stanza.type == "ssh-ed25519" {
            // A malformed ssh-ed25519 stanza is a format error, whichever key it names.
            guard stanza.args.count == 2 else {
                throw AgeError.invalidHeader(localized("An ssh-ed25519 recipient entry is malformed."))
            }
            // The tag says which key the stanza is for.
            guard stanza.args[0] == tag else { continue }
            guard let share = AgeBase64.decode(stanza.args[1]), share.count == 32 else {
                throw AgeError.invalidHeader(localized("An ssh-ed25519 recipient entry is malformed."))
            }
            // The tweak and the two agreements mirror the recipient side; a low-order share is
            // skipped rather than reported.
            let tweak = AgeKDF.derive(ikm: Data(), salt: publicKey.wire, info: SSHEd25519Recipient.label)
            guard let inner = try? X25519.agree(scalar: scalar, point: share),
                  let shared = try? X25519.agree(scalar: tweak, point: inner) else { continue }
            let key = AgeKDF.derive(ikm: shared, salt: share + curvePublicKey, info: SSHEd25519Recipient.label)
            // The first body that opens under this key holds the file key.
            if let fileKey = AgeKDF.unwrap(stanza.body, with: key) { return fileKey }
        }
        return nil
    }
}

/// An SSH RSA private key used as an age identity.
struct SSHRSAIdentity: AgeIdentity {
    let publicKey: SSHPublicKey
    let numbers: RSAPrivateKeyNumbers

    var kind: AgeKeyKind { .sshRSA }
    var recipient: (any AgeRecipient)? { try? SSHRSARecipient(publicKey: publicKey) }

    // unwrap(stanzas): Try the ssh-rsa stanzas whose tag names this key.
    func unwrap(_ stanzas: [AgeStanza]) throws -> Data? {
        let tag = publicKey.tag
        for stanza in stanzas where stanza.type == "ssh-rsa" {
            // A malformed ssh-rsa stanza is a format error; the tag decides if it is for this key.
            guard stanza.args.count == 1 else {
                throw AgeError.invalidHeader(localized("An ssh-rsa recipient entry is malformed."))
            }
            guard stanza.args[0] == tag else { continue }
            // A body that does not decrypt to a 16-byte file key is not for this key after all.
            guard let fileKey = RSAOAEP.decrypt(ciphertext: stanza.body, key: numbers), fileKey.count == AgeHeaderCodec.fileKeySize else { continue }
            return fileKey
        }
        return nil
    }
}

/// A passphrase used to decrypt a passphrase-protected file.
struct ScryptIdentity: AgeIdentity {
    /// Work factors above this need gigabytes of memory and a long wait, so they are refused
    /// rather than attempted. The age tool applies the same limit by default.
    static let maximumWorkFactor = 22
    let passphrase: String

    var kind: AgeKeyKind { .scrypt }
    var recipient: (any AgeRecipient)? { nil }

    // init(passphrase): An identity for the passphrase.
    init(passphrase: String) {
        self.passphrase = passphrase
    }

    // unwrap(stanzas): Stretch the passphrase with the stanza's salt and work factor.
    func unwrap(_ stanzas: [AgeStanza]) throws -> Data? {
        for stanza in stanzas where stanza.type == "scrypt" {
            // A malformed passphrase stanza is a format error.
            guard stanza.args.count == 2, let salt = AgeBase64.decode(stanza.args[0]), salt.count == 16 else {
                throw AgeError.invalidHeader(localized("The passphrase entry is malformed."))
            }
            // The work factor is a plain decimal without a sign or leading zeros.
            let digits = stanza.args[1]
            guard let workFactor = Int(digits), workFactor > 0, digits.allSatisfy(\.isNumber), !digits.hasPrefix("0") else {
                throw AgeError.invalidHeader(localized("The passphrase work factor is malformed."))
            }
            // Refuse a work factor that would take too long before any stretching starts.
            guard workFactor <= Self.maximumWorkFactor else { throw AgeError.workFactorTooHigh(workFactor) }
            let key = ScryptRecipient.key(passphrase: passphrase, salt: salt, workFactor: workFactor)
            // The only stanza is this one, so a body that does not open means a wrong passphrase.
            guard let fileKey = AgeKDF.unwrap(stanza.body, with: key) else { throw AgeError.wrongPassphrase }
            return fileKey
        }
        return nil
    }
}

/// What an identity file holds, before any passphrase is used.
enum AgeIdentityFileContents {
    /// One or more age secret keys.
    case ageIdentities([X25519Identity])
    /// An OpenSSH private key, possibly passphrase-protected.
    case sshKey(OpenSSHPrivateKey)
    /// A legacy PEM RSA key.
    case legacyRSA(any AgeIdentity)
    /// An identity file that was itself encrypted with a passphrase.
    case encryptedAgeFile
}

/// Classifies and parses identity files.
enum AgeIdentityFile {
    /// Identity files larger than this are not keys.
    static let maximumSize = 1 << 20

    // isEncryptedAgeFile(data): Whether the bytes start like an age file, binary or armored. A
    // binary file has a text header but binary payload, so this is checked before decoding text.
    static func isEncryptedAgeFile(_ data: Data) -> Bool {
        let prefix = data.prefix(64)
        return prefix.starts(with: Data(AgeHeaderCodec.intro.utf8)) || AgeArmor.looksArmored(prefix)
    }

    // classify(data): What the file holds.
    static func classify(_ data: Data) throws -> AgeIdentityFileContents {
        guard data.count <= maximumSize else { throw AgeError.invalidIdentity(localized("The file is too large to be a key.")) }
        // An encrypted identity file is an age file; it needs a passphrase first.
        if isEncryptedAgeFile(data) { return .encryptedAgeFile }
        guard let text = String(data: data, encoding: .utf8) else { throw AgeError.invalidIdentity(localized("The file is not text.")) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An OpenSSH key is parsed to its public half; the private half may need a passphrase.
        if OpenSSHPrivateKey.looksLikeKey(text) {
            // SSH parsing errors are reported in age terms; anything else passes through.
            do {
                return .sshKey(try OpenSSHPrivateKey.parse(pem: text))
            } catch let error as SSHKeyError {
                throw error.ageError
            }
        }
        // A legacy PEM RSA key must be unprotected; the parser reports an encrypted one.
        if LegacyRSAPrivateKey.looksLikeKey(text) {
            // SSH parsing errors are reported in age terms; anything else passes through.
            do {
                return .legacyRSA(try LegacyRSAPrivateKey.parse(pem: text))
            } catch let error as SSHKeyError {
                throw error.ageError
            }
        }
        // Other PEM keys, such as EC or PKCS#8 files, are named rather than mistaken for text.
        if trimmed.hasPrefix("-----BEGIN") {
            throw AgeError.invalidIdentity(localized("This key format is not supported. Use an OpenSSH private key or an age identity file."))
        }
        // Otherwise the file must be an age identity file: one secret key per line.
        var identities: [X25519Identity] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Comments and blank lines are allowed between keys.
            if line.isEmpty || line.hasPrefix("#") { continue }
            identities.append(try X25519Identity(string: line))
        }
        guard !identities.isEmpty else { throw AgeError.invalidIdentity(localized("The file holds no age secret key.")) }
        return .ageIdentities(identities)
    }

    // identityFileText(for identity, [createdAt = Date()]): The contents of a
    // new identity file in the layout age-keygen writes.
    static func identityFileText(for identity: X25519Identity, createdAt: Date = Date()) -> String {
        // Readers ignore the comment lines, so the UTC timestamp is informational only.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let created = formatter.string(from: createdAt)
        return "# created: \(created)\n# public key: \(identity.publicKeyLine)\n\(identity.line)\n"
    }
}
