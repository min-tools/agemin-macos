import CryptoKit
import Foundation

/// scrypt (RFC 7914), which age uses for passphrase recipients.
enum Scrypt {
    // derive(passphrase, salt, logN, [r = 8], [p = 1], [keyLength = 32]): The derived key. logN is
    // the base-two logarithm of the cost parameter N; callers bound it, since memory grows with N.
    static func derive(passphrase: Data, salt: Data, logN: Int, r: Int = 8, p: Int = 1, keyLength: Int = 32) -> Data {
        precondition(logN > 0 && logN < 64 && r > 0 && p > 0, "invalid scrypt parameters")
        let n = 1 << logN
        let blockWords = 32 * r
        // The passphrase and salt expand to p blocks of 128r bytes.
        var b = PBKDF2.sha256(passphrase: passphrase, salt: salt, keyLength: p * 128 * r)
        var words = [UInt32](repeating: 0, count: p * blockWords)
        b.withUnsafeBytes { raw in
            for index in 0..<words.count {
                words[index] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            }
        }
        // ROMix each of the p blocks in place; the work buffers are shared across blocks.
        var v = [UInt32](repeating: 0, count: n * blockWords)
        var x = [UInt32](repeating: 0, count: blockWords)
        var y = [UInt32](repeating: 0, count: blockWords)
        var scratch = [UInt32](repeating: 0, count: 16)
        for block in 0..<p {
            let start = block * blockWords
            roMix(&words, offset: start, r: r, n: n, v: &v, x: &x, y: &y, scratch: &scratch)
        }
        // Write the mixed blocks back as bytes for the final expansion.
        b.withUnsafeMutableBytes { raw in
            for (index, word) in words.enumerated() {
                raw.storeBytes(of: word.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        return PBKDF2.sha256(passphrase: passphrase, salt: b, keyLength: keyLength)
    }

    // roMix(words, offset, r, n, v, x, y, scratch): The memory-hard mixing of one block in place.
    private static func roMix(_ words: inout [UInt32], offset: Int, r: Int, n: Int, v: inout [UInt32], x: inout [UInt32], y: inout [UInt32], scratch: inout [UInt32]) {
        let blockWords = 32 * r
        for index in 0..<blockWords { x[index] = words[offset + index] }
        // Fill the table with successive mixes of the block.
        for i in 0..<n {
            let base = i * blockWords
            for index in 0..<blockWords { v[base + index] = x[index] }
            blockMix(&x, &y, r: r, scratch: &scratch)
        }
        // Then mix in table entries chosen by the block itself.
        let mask = UInt64(n - 1)
        for _ in 0..<n {
            let j = Int(integerify(x, r: r) & mask)
            let base = j * blockWords
            for index in 0..<blockWords { x[index] ^= v[base + index] }
            blockMix(&x, &y, r: r, scratch: &scratch)
        }
        for index in 0..<blockWords { words[offset + index] = x[index] }
    }

    // integerify(x, r): The first 64 bits of the last 64-byte block, little-endian.
    private static func integerify(_ x: [UInt32], r: Int) -> UInt64 {
        let base = (2 * r - 1) * 16
        return UInt64(x[base]) | (UInt64(x[base + 1]) << 32)
    }

    // blockMix(b, y, r, scratch): Salsa20/8 each 64-byte block chained to the previous output,
    // then interleave even and odd results back into b. y holds the intermediate results.
    private static func blockMix(_ b: inout [UInt32], _ y: inout [UInt32], r: Int, scratch: inout [UInt32]) {
        // Chain from the last block: each block is XORed into the running state, then hashed.
        let last = (2 * r - 1) * 16
        for index in 0..<16 { scratch[index] = b[last + index] }
        for block in 0..<(2 * r) {
            let base = block * 16
            for index in 0..<16 { scratch[index] ^= b[base + index] }
            salsa20_8(&scratch)
            for index in 0..<16 { y[base + index] = scratch[index] }
        }
        // Even blocks first, then odd blocks.
        for block in 0..<r {
            for index in 0..<16 {
                b[block * 16 + index] = y[block * 32 + index]
                b[(r + block) * 16 + index] = y[block * 32 + 16 + index]
            }
        }
    }

    // salsa20_8(x): The Salsa20/8 core applied in place to 16 words.
    static func salsa20_8(_ x: inout [UInt32]) {
        x.withUnsafeMutableBufferPointer { b in
            var z = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
            // rotl(value, count): Rotate left.
            @inline(__always) func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
            for _ in 0..<4 {
                // Column round.
                z.4 ^= rotl(z.0 &+ z.12, 7);  z.8 ^= rotl(z.4 &+ z.0, 9)
                z.12 ^= rotl(z.8 &+ z.4, 13); z.0 ^= rotl(z.12 &+ z.8, 18)
                z.9 ^= rotl(z.5 &+ z.1, 7);   z.13 ^= rotl(z.9 &+ z.5, 9)
                z.1 ^= rotl(z.13 &+ z.9, 13); z.5 ^= rotl(z.1 &+ z.13, 18)
                z.14 ^= rotl(z.10 &+ z.6, 7); z.2 ^= rotl(z.14 &+ z.10, 9)
                z.6 ^= rotl(z.2 &+ z.14, 13); z.10 ^= rotl(z.6 &+ z.2, 18)
                z.3 ^= rotl(z.15 &+ z.11, 7); z.7 ^= rotl(z.3 &+ z.15, 9)
                z.11 ^= rotl(z.7 &+ z.3, 13); z.15 ^= rotl(z.11 &+ z.7, 18)
                // Row round.
                z.1 ^= rotl(z.0 &+ z.3, 7);   z.2 ^= rotl(z.1 &+ z.0, 9)
                z.3 ^= rotl(z.2 &+ z.1, 13);  z.0 ^= rotl(z.3 &+ z.2, 18)
                z.6 ^= rotl(z.5 &+ z.4, 7);   z.7 ^= rotl(z.6 &+ z.5, 9)
                z.4 ^= rotl(z.7 &+ z.6, 13);  z.5 ^= rotl(z.4 &+ z.7, 18)
                z.11 ^= rotl(z.10 &+ z.9, 7); z.8 ^= rotl(z.11 &+ z.10, 9)
                z.9 ^= rotl(z.8 &+ z.11, 13); z.10 ^= rotl(z.9 &+ z.8, 18)
                z.12 ^= rotl(z.15 &+ z.14, 7); z.13 ^= rotl(z.12 &+ z.15, 9)
                z.14 ^= rotl(z.13 &+ z.12, 13); z.15 ^= rotl(z.14 &+ z.13, 18)
            }
            // Add the mixed state back to the input.
            b[0] &+= z.0; b[1] &+= z.1; b[2] &+= z.2; b[3] &+= z.3
            b[4] &+= z.4; b[5] &+= z.5; b[6] &+= z.6; b[7] &+= z.7
            b[8] &+= z.8; b[9] &+= z.9; b[10] &+= z.10; b[11] &+= z.11
            b[12] &+= z.12; b[13] &+= z.13; b[14] &+= z.14; b[15] &+= z.15
        }
    }
}
