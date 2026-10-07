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

/// An age native recipient, the "age1…" public key of an X25519 identity.
struct X25519Recipient: AgeRecipient, Equatable {
    static let hrp = "age"
    static let label = "age-encryption.org/v1/X25519"
    let publicKey: Data

    var kind: AgeKeyKind { .x25519 }
    var line: String { Bech32.encode(hrp: Self.hrp, data: publicKey) }

    // init(publicKey): From the 32 raw bytes.
    init(publicKey: Data) throws {
        guard publicKey.count == 32 else { throw AgeError.invalidRecipient(localized("An age public key has 32 bytes.")) }
        self.publicKey = publicKey
    }

    // init(string): From the "age1…" form.
    init(string: String) throws {
        guard let decoded = Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines)), decoded.hrp == Self.hrp else {
            throw AgeError.invalidRecipient(localized("This is not a valid age public key."))
        }
        try self.init(publicKey: decoded.data)
    }

    // wrap(fileKey): An ephemeral X25519 agreement with the recipient's key.
    func wrap(fileKey: Data) throws -> AgeStanza {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        let shared = try X25519.agree(secret: ephemeral, point: publicKey)
        // The wrap key binds both public values to the shared secret, as the format requires.
        let key = AgeKDF.derive(ikm: shared, salt: share + publicKey, info: Self.label)
        return AgeStanza(type: "X25519", args: [AgeBase64.encode(share)], body: try AgeKDF.wrap(fileKey, with: key))
    }
}

/// X25519 operations over raw byte strings, as the age stanzas need them.
enum X25519 {
    // agree(secret, point): The shared secret between a private key and a raw public value,
    // rejecting the all-zero result of a low-order point.
    static func agree(secret: Curve25519.KeyAgreement.PrivateKey, point: Data) throws -> Data {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: point)
        let shared = try secret.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        guard shared.contains(where: { $0 != 0 }) else {
            throw AgeError.invalidRecipient(localized("This key produces a weak shared secret and cannot be used."))
        }
        return shared
    }

    // agree(scalar, point): The same with a raw 32-byte scalar, which X25519 clamps itself.
    static func agree(scalar: Data, point: Data) throws -> Data {
        try agree(secret: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar), point: point)
    }
}

/// An SSH Ed25519 public key used as an age recipient.
struct SSHEd25519Recipient: AgeRecipient {
    static let label = "age-encryption.org/v1/ssh-ed25519"
    let publicKey: SSHPublicKey
    /// The key converted to its X25519 form.
    let curvePublicKey: Data

    var kind: AgeKeyKind { .sshEd25519 }
    var line: String { publicKey.line }

    // init(publicKey): From a parsed ssh-ed25519 public key.
    init(publicKey: SSHPublicKey) throws {
        guard let edwards = publicKey.ed25519PublicKey, let curve = Curve25519Conversion.montgomeryU(fromEdwardsPublicKey: edwards) else {
            throw AgeError.invalidRecipient(localized("The SSH key is not a valid Ed25519 key."))
        }
        self.publicKey = publicKey
        curvePublicKey = curve
    }

    // wrap(fileKey): The tweaked X25519 agreement that age defines for SSH keys.
    func wrap(fileKey: Data) throws -> AgeStanza {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        // The tweak comes from the SSH wire key, so the stanza is bound to this exact key.
        let tweak = AgeKDF.derive(ikm: Data(), salt: publicKey.wire, info: Self.label)
        // Apply the tweak to the ephemeral agreement, then derive the wrap key as for X25519.
        let shared = try X25519.agree(scalar: tweak, point: try X25519.agree(secret: ephemeral, point: curvePublicKey))
        let key = AgeKDF.derive(ikm: shared, salt: share + curvePublicKey, info: Self.label)
        return AgeStanza(type: "ssh-ed25519", args: [publicKey.tag, AgeBase64.encode(share)], body: try AgeKDF.wrap(fileKey, with: key))
    }
}

/// An SSH RSA public key used as an age recipient.
struct SSHRSARecipient: AgeRecipient {
    let publicKey: SSHPublicKey
    let modulus: BigUInt
    let exponent: BigUInt

    var kind: AgeKeyKind { .sshRSA }
    var line: String { publicKey.line }

    // init(publicKey): From a parsed ssh-rsa public key.
    init(publicKey: SSHPublicKey) throws {
        guard let numbers = publicKey.rsaNumbers else {
            throw AgeError.invalidRecipient(localized("The SSH key is not a valid RSA key."))
        }
        self.publicKey = publicKey
        modulus = numbers.modulus
        exponent = numbers.exponent
    }

    // wrap(fileKey): RSA-OAEP of the file key.
    func wrap(fileKey: Data) throws -> AgeStanza {
        let body = try RSAOAEP.encrypt(message: fileKey, modulus: modulus, exponent: exponent)
        return AgeStanza(type: "ssh-rsa", args: [publicKey.tag], body: body)
    }
}

/// A passphrase, stretched with scrypt. A passphrase recipient must be the only one in a file.
struct ScryptRecipient: AgeRecipient {
    static let label = "age-encryption.org/v1/scrypt"
    static let defaultWorkFactor = 18
    let passphrase: String
    var workFactor = defaultWorkFactor

    var kind: AgeKeyKind { .scrypt }
    var line: String { localized("Passphrase") }

    // init(passphrase, [workFactor = 18]): A recipient for the passphrase.
    init(passphrase: String, workFactor: Int = defaultWorkFactor) {
        self.passphrase = passphrase
        self.workFactor = workFactor
    }

    // key(passphrase, salt, workFactor): The wrapping key for a salt and work factor. The salt is
    // prefixed with the stanza label, as the format requires; N is 2^workFactor with r = 8, p = 1.
    static func key(passphrase: String, salt: Data, workFactor: Int) -> Data {
        Scrypt.derive(passphrase: Data(passphrase.utf8), salt: Data(label.utf8) + salt, logN: workFactor)
    }

    // wrap(fileKey): A fresh 16-byte salt and the stretched passphrase.
    func wrap(fileKey: Data) throws -> AgeStanza {
        let salt = AgeRandom.bytes(16)
        let key = Self.key(passphrase: passphrase, salt: salt, workFactor: workFactor)
        return AgeStanza(type: "scrypt", args: [AgeBase64.encode(salt), String(workFactor)], body: try AgeKDF.wrap(fileKey, with: key))
    }
}

/// Turns a line of text into a recipient.
enum AgeRecipientParser {
    // kind(of line): What kind of key the line holds, or nil when it is not a key at all.
    static func kind(of line: String) -> AgeKeyKind? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // age public keys are lowercase bech32 with the "age" prefix.
        if trimmed.hasPrefix("age1") { return .x25519 }
        // SSH keys name their algorithm first.
        if let algorithm = trimmed.split(separator: " ").first.map(String.init), algorithm.contains("-") || algorithm.hasPrefix("ssh") {
            switch algorithm {
            case "ssh-ed25519": return .sshEd25519
            case "ssh-rsa": return .sshRSA
            default:
                // Anything else from ssh-keygen is a real key that age cannot use.
                return ["ssh-", "ecdsa-", "sk-"].contains(where: algorithm.hasPrefix) ? .unsupported(algorithm) : nil
            }
        }
        return nil
    }

    // parse(line): The recipient for a public key line.
    static func parse(_ line: String) throws -> any AgeRecipient {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgeError.invalidRecipient(localized("The key is empty.")) }
        // A pasted secret key is a common mistake worth naming.
        if trimmed.uppercased().hasPrefix("AGE-SECRET-KEY-1") {
            throw AgeError.invalidRecipient(localized("This is a secret key. Use the matching public key, which starts with age1."))
        }
        switch kind(of: trimmed) {
        case .x25519:
            return try X25519Recipient(string: trimmed)
        case .sshEd25519, .sshRSA:
            let key: SSHPublicKey
            do {
                key = try SSHPublicKey.parse(line: trimmed)
            } catch {
                throw AgeError.invalidRecipient(localized("The SSH public key is malformed."))
            }
            // The algorithm decides the stanza type.
            if key.algorithm == "ssh-ed25519" { return try SSHEd25519Recipient(publicKey: key) }
            return try SSHRSARecipient(publicKey: key)
        case .unsupported(let algorithm):
            throw AgeError.unsupportedKey(algorithm)
        case .scrypt, nil:
            // A passphrase is never written as a key line, so it reads as not a key at all.
            throw AgeError.invalidRecipient(localized("Expected an age public key (age1…) or an SSH public key (ssh-ed25519 or ssh-rsa)."))
        }
    }
}
