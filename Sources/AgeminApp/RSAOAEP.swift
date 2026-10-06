import CryptoKit
import Foundation

/// The numbers of an RSA private key as OpenSSH stores them.
struct RSAPrivateKeyNumbers: Equatable {
    var modulus: BigUInt
    var publicExponent: BigUInt
    var privateExponent: BigUInt
    var prime1: BigUInt
    var prime2: BigUInt
    /// The inverse of prime2 modulo prime1.
    var coefficient: BigUInt

    // decrypt(ciphertext): The raw RSA private operation, with the Chinese remainder theorem when
    // the primes are present.
    func decrypt(_ ciphertext: BigUInt) -> BigUInt {
        let one = BigUInt(1)
        // Without usable primes, use the private exponent directly. A prime of one would divide
        // by zero below, so a key file claiming one takes the slow path too.
        guard prime1 > one, prime2 > one, !coefficient.isZero, prime1 * prime2 == modulus else {
            return ciphertext.modPow(privateExponent, modulus: modulus)
        }
        // The CRT exponents are d mod (p - 1) and d mod (q - 1); each half is a smaller modPow.
        let dp = privateExponent % (prime1 - one)
        let dq = privateExponent % (prime2 - one)
        let m1 = (ciphertext % prime1).modPow(dp, modulus: prime1)
        let m2 = (ciphertext % prime2).modPow(dq, modulus: prime2)
        // Garner's recombination: m = m2 + q * (qinv * (m1 - m2) mod p).
        let h = (coefficient * m1.subtractingMod(m2 % prime1, modulus: prime1)) % prime1
        return m2 + h * prime2
    }
}
