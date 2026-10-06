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

/// bcrypt_pbkdf from OpenBSD, which OpenSSH uses to turn a passphrase into the key and IV that
/// protect a private key file.
enum BcryptPBKDF {
    private static let hashSize = 32
    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    // derive(passphrase, salt, rounds, keyLength): keyLength bytes derived from the passphrase.
    static func derive(passphrase: Data, salt: Data, rounds: Int, keyLength: Int) throws -> Data {
        // OpenBSD's parameter checks; the output is capped at 32 hashes of 32 bytes.
        guard rounds >= 1, !passphrase.isEmpty, !salt.isEmpty, keyLength > 0, keyLength <= hashSize * hashSize else {
            throw AgeError.invalidIdentity(localized("The key file's passphrase settings are invalid."))
        }
        // Each hash contributes amount bytes, spread across the key at the stride.
        let stride = (keyLength + hashSize - 1) / hashSize
        let amount = (keyLength + stride - 1) / stride
        let passphraseHash = Array(SHA512.hash(data: passphrase))
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            // The first round salts with the salt and the block counter.
            var counted = salt
            counted.append(contentsOf: withUnsafeBytes(of: count.bigEndian) { Data($0) })
            var saltHash = Array(SHA512.hash(data: counted))
            var latest = hash(passphraseHash, saltHash)
            var output = latest
            // Later rounds salt with the previous output and fold everything together.
            for _ in 1..<rounds {
                saltHash = Array(SHA512.hash(data: Data(latest)))
                latest = hash(passphraseHash, saltHash)
                for index in 0..<hashSize { output[index] ^= latest[index] }
            }
            // The output bytes are spread across the key with the given stride.
            let take = min(amount, remaining)
            var written = 0
            for index in 0..<take {
                let destination = index * stride + Int(count - 1)
                // The last block can run past the end of the key.
                if destination >= keyLength { break }
                key[destination] = output[index]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    // hash(passphraseHash, saltHash): One bcrypt hash: an expensive key schedule, then the magic
    // block enciphered 64 times.
    private static func hash(_ passphraseHash: [UInt8], _ saltHash: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: saltHash, key: passphraseHash)
        for _ in 0..<64 {
            state.expand0State(key: saltHash)
            state.expand0State(key: passphraseHash)
        }
        // Load the magic block as eight big-endian words, then encrypt it 64 times over.
        var words = [UInt32](repeating: 0, count: 8)
        var position = 0
        for index in 0..<8 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                word = (word << 8) | UInt32(magic[position])
                position += 1
            }
            words[index] = word
        }
        for _ in 0..<64 { state.encryptBlocks(&words) }
        // The output is little-endian, unlike the big-endian input words.
        var output = [UInt8](repeating: 0, count: hashSize)
        for (index, word) in words.enumerated() {
            output[4 * index] = UInt8(word & 0xFF)
            output[4 * index + 1] = UInt8((word >> 8) & 0xFF)
            output[4 * index + 2] = UInt8((word >> 16) & 0xFF)
            output[4 * index + 3] = UInt8((word >> 24) & 0xFF)
        }
        return output
    }
}
