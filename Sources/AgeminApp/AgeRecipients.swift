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
