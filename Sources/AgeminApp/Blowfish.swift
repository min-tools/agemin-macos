import CryptoKit
import Foundation

/// The Blowfish cipher state, used only for bcrypt's key derivation, which OpenSSH applies to
/// passphrase-protected private keys.
struct Blowfish {
    private var p: [UInt32]
    /// The four S-boxes, flattened to 1024 words.
    private var s: [UInt32]

    // init(): The initial state, the hexadecimal digits of pi.
    init() {
        p = BlowfishTables.p
        s = BlowfishTables.s.flatMap { $0 }
    }

    // streamWord(data, position): Four bytes of data as a big-endian word, starting at position
    // and wrapping around to the start of data.
    private static func streamWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            // Cycle through the data as many times as needed.
            if position >= data.count { position = 0 }
            word = (word << 8) | UInt32(data[position])
            position += 1
        }
        return word
    }

    // f(x): The round function over the four S-boxes.
    @inline(__always) private func f(_ x: UInt32) -> UInt32 {
        let a = s[Int(x >> 24)]
        let b = s[0x100 + Int((x >> 16) & 0xFF)]
        let c = s[0x200 + Int((x >> 8) & 0xFF)]
        let d = s[0x300 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    // encipher(left, right): Encrypt one 64-bit block in place.
    func encipher(_ left: inout UInt32, _ right: inout UInt32) {
        var l = left ^ p[0]
        var r = right
        // Sixteen rounds, alternating which half takes the round function.
        for round in stride(from: 1, through: 16, by: 2) {
            r ^= f(l) ^ p[round]
            l ^= f(r) ^ p[round + 1]
        }
        // The halves end up swapped; the final subkey goes on the new left half.
        left = r ^ p[17]
        right = l
    }

    // expandState(data, key): bcrypt's salted key schedule: mix the key into the P-array, then
    // regenerate every entry by enciphering while also mixing in the salt data.
    mutating func expandState(data: [UInt8], key: [UInt8]) {
        // XOR the key into the P-array, cycling through the key as needed.
        var keyPosition = 0
        for index in 0..<18 { p[index] ^= Self.streamWord(key, &keyPosition) }
        // Regenerate the P-array by enciphering a running block that absorbs the salt data.
        var dataPosition = 0
        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in stride(from: 0, to: 18, by: 2) {
            left ^= Self.streamWord(data, &dataPosition)
            right ^= Self.streamWord(data, &dataPosition)
            encipher(&left, &right)
            p[index] = left
            p[index + 1] = right
        }
        // The S-boxes follow the same way, continuing through the data.
        for index in stride(from: 0, to: 1024, by: 2) {
            left ^= Self.streamWord(data, &dataPosition)
            right ^= Self.streamWord(data, &dataPosition)
            encipher(&left, &right)
            s[index] = left
            s[index + 1] = right
        }
    }

    // expand0State(key): The plain key schedule, without salt data.
    mutating func expand0State(key: [UInt8]) {
        // XOR the key into the P-array, cycling through the key as needed.
        var keyPosition = 0
        for index in 0..<18 { p[index] ^= Self.streamWord(key, &keyPosition) }
        // Regenerate the P-array by repeatedly enciphering a block that starts at zero.
        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in stride(from: 0, to: 18, by: 2) {
            encipher(&left, &right)
            p[index] = left
            p[index + 1] = right
        }
        // The S-boxes continue the same chain.
        for index in stride(from: 0, to: 1024, by: 2) {
            encipher(&left, &right)
            s[index] = left
            s[index + 1] = right
        }
    }

    // encryptBlocks(words): Encrypt consecutive pairs of words in place.
    func encryptBlocks(_ words: inout [UInt32]) {
        for index in stride(from: 0, to: words.count, by: 2) {
            var left = words[index]
            var right = words[index + 1]
            encipher(&left, &right)
            words[index] = left
            words[index + 1] = right
        }
    }
}
