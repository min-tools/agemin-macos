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
