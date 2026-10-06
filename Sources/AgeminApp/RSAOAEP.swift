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

/// RSA-OAEP with SHA-256, as age applies it to SSH RSA keys.
enum RSAOAEP {
    static let label = "age-encryption.org/v1/ssh-rsa"
    private static let hashLength = 32

    // mgf1(seed, length): The mask generation function over SHA-256.
    static func mgf1(seed: Data, length: Int) -> Data {
        var output = Data()
        var counter: UInt32 = 0
        // Hash the seed with a big-endian counter until the mask is long enough.
        while output.count < length {
            var input = seed
            input.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
            output.append(contentsOf: SHA256.hash(data: input))
            counter += 1
        }
        return output.prefix(length)
    }

    // encrypt(message, modulus, exponent): The ciphertext, as many bytes as the modulus.
    static func encrypt(message: Data, modulus: BigUInt, exponent: BigUInt) throws -> Data {
        // The message must fit beside two hashes and two framing bytes (RFC 8017, 7.1.1).
        let k = modulus.byteCount
        let capacity = k - 2 * hashLength - 2
        guard capacity >= message.count, exponent > BigUInt(1), modulus.isOdd else {
            throw AgeError.invalidRecipient(localized("The RSA key is too small or malformed."))
        }
        // DB = lHash || PS || 0x01 || M, where PS is as many zero bytes as needed.
        var db = Data(SHA256.hash(data: Data(label.utf8)))
        db.append(Data(count: capacity - message.count))
        db.append(0x01)
        db.append(message)
        // Mask DB with a fresh seed, then the seed with the masked DB.
        let seed = AgeRandom.bytes(hashLength)
        let maskedDB = xor(db, mgf1(seed: seed, length: k - hashLength - 1))
        let maskedSeed = xor(seed, mgf1(seed: maskedDB, length: hashLength))
        // EM = 0x00 || maskedSeed || maskedDB, then the raw RSA public operation.
        var encoded = Data([0x00])
        encoded.append(maskedSeed)
        encoded.append(maskedDB)
        let ciphertext = BigUInt(bigEndian: encoded).modPow(exponent, modulus: modulus)
        guard let bytes = ciphertext.bigEndianBytes(count: k) else {
            throw AgeError.invalidRecipient(localized("The RSA key is malformed."))
        }
        return bytes
    }

    // decrypt(ciphertext, key): The message, or nil when the ciphertext is not for this key.
    static func decrypt(ciphertext: Data, key: RSAPrivateKeyNumbers) -> Data? {
        // Reject lengths and values outside the modulus before the private operation.
        let k = key.modulus.byteCount
        guard ciphertext.count == k, k >= 2 * hashLength + 2 else { return nil }
        let value = BigUInt(bigEndian: ciphertext)
        guard value < key.modulus else { return nil }
        guard let encoded = key.decrypt(value).bigEndianBytes(count: k) else { return nil }
        // Unmask in reverse: recover the seed first, then DB.
        let maskedSeed = encoded[1..<(1 + hashLength)]
        let maskedDB = encoded[(1 + hashLength)...]
        let seed = xor(Data(maskedSeed), mgf1(seed: Data(maskedDB), length: hashLength))
        let db = xor(Data(maskedDB), mgf1(seed: seed, length: k - hashLength - 1))
        let expectedHash = Data(SHA256.hash(data: Data(label.utf8)))
        // The framing checks fold into one flag so a wrong ciphertext does not reveal which one
        // failed; only a missing separator returns early.
        var valid = encoded[0] == 0
        valid = valid && db.prefix(hashLength) == expectedHash
        let rest = db.dropFirst(hashLength)
        guard let separator = rest.firstIndex(of: 0x01) else { return nil }
        valid = valid && rest[rest.startIndex..<separator].allSatisfy { $0 == 0 }
        guard valid else { return nil }
        return Data(rest[rest.index(after: separator)...])
    }

    // xor(lhs, rhs): The bytewise exclusive or of two equal-length buffers.
    private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        precondition(lhs.count == rhs.count)
        var result = Data(count: lhs.count)
        for index in 0..<lhs.count {
            result[index] = lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return result
    }
}
