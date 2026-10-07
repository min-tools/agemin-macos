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
