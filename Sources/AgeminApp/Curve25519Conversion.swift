import CryptoKit
import Foundation

/// Converts Ed25519 keys, which SSH uses, to the X25519 form age needs for key agreement.
enum Curve25519Conversion {
    /// The field prime 2^255 - 19.
    private static let prime: BigUInt = {
        var limbs = [UInt32](repeating: 0xFFFF_FFFF, count: 8)
        limbs[7] = 0x7FFF_FFFF
        limbs[0] = 0xFFFF_FFED
        return BigUInt(limbs: limbs)
    }()

    // montgomeryU(fromEdwardsPublicKey key): The X25519 public key for an Ed25519 public key,
    // u = (1 + y) / (1 - y) in the field, or nil for an encoding that is not a field element or
    // has no inverse.
    static func montgomeryU(fromEdwardsPublicKey key: Data) -> Data? {
        guard key.count == 32 else { return nil }
        var encoded = Data(key)
        // The top bit carries the sign of x, which the conversion does not need.
        encoded[31] &= 0x7F
        let y = BigUInt(littleEndian: encoded)
        guard y < prime else { return nil }
        // 1 + y and 1 - y, both reduced; adding the prime keeps the subtraction non-negative.
        let one = BigUInt(1)
        let numerator = (y + one) % prime
        let denominator = (prime + one - y) % prime
        // y = 1 has no inverse and is not a valid key.
        guard !denominator.isZero else { return nil }
        // Fermat's little theorem gives the inverse as d^(p - 2).
        let inverse = denominator.modPow(prime - BigUInt(2), modulus: prime)
        let u = (numerator * inverse) % prime
        return u.littleEndianBytes(count: 32)
    }

    // x25519Scalar(fromEdwardsSeed seed): The X25519 private scalar for an Ed25519 seed: the
    // first half of its SHA-512 digest, which X25519 clamps itself.
    static func x25519Scalar(fromEdwardsSeed seed: Data) -> Data {
        Data(SHA512.hash(data: seed)).prefix(32)
    }
}
