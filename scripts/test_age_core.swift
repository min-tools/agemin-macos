import CryptoKit
import Foundation

/// Drives the age core from the command line so scripts/test_age_core.py can check it against
/// fixed vectors and against the reference age tool. Compiled with the core sources only.
///
/// Commands:
///   selftest <vectors.json>
///   keygen <identity file> <public key file>
///   keyinfo <identity file> [passphrase]
///   inspect <age file>
///   encrypt <input> <output> <armor 0|1> <recipient line>...
///   encrypt-passphrase <input> <output> <passphrase> [work factor]
///   decrypt <input> <output> <identity file> [passphrase]
///   decrypt-passphrase <input> <output> <passphrase>
@main
enum AgeCoreTests {
    static var checks = 0

    // check(condition, message): Count a passed check; print the message and exit at the first
    // failure, so the driver sees exactly which expectation broke.
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
        checks += 1
    }

    // hex(data): Lowercase hex, the form the Python driver writes into the vectors.
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // data(hex): Bytes from hex text; the text is trusted to be even-length and well formed.
    static func data(hex: String) -> Data {
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    // identities(at path, passphrase): Every identity an identity file holds, decrypting it with
    // the passphrase when it is protected.
    static func identities(at path: String, passphrase: String?) throws -> [any AgeIdentity] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        switch try AgeIdentityFile.classify(data) {
        case .ageIdentities(let keys):
            return keys
        case .sshKey(let key):
            return [try key.identity(passphrase: passphrase)]
        case .legacyRSA(let identity):
            return [identity]
        case .encryptedAgeFile:
            // A passphrase-protected identity file is an age file that wraps plain age
            // identities; anything else inside it is refused.
            guard let passphrase else { throw AgeError.passphraseRequired }
            let plain = try AgeEngine.decryptToMemory(data, identities: [ScryptIdentity(passphrase: passphrase)])
            guard case .ageIdentities(let keys) = try AgeIdentityFile.classify(plain) else { throw AgeError.invalidIdentity("nested") }
            return keys
        }
    }

    // main(): Run the command; an error ends the process with its user-facing description on
    // stderr, which the driver compares for the refusal cases.
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data(("error: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    // run(): Dispatch the command line to the command listed in the file comment. Missing
    // positional arguments are a driver bug, so they are not validated.
    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print("usage: see the command list at the top of scripts/test_age_core.swift")
            exit(2)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "selftest":
            try selfTest(vectorsPath: rest[0])
        case "keygen":
            // Writes the identity file and the public key file, and prints the public line the
            // driver reads when age-keygen is not installed.
            let identity = X25519Identity.generate()
            try AgeIdentityFile.identityFileText(for: identity).write(toFile: rest[0], atomically: false, encoding: .utf8)
            try (identity.recipient!.line + "\n").write(toFile: rest[1], atomically: false, encoding: .utf8)
            print(identity.recipient!.line)
        case "keyinfo":
            // One line per identity: its kind and public line, or "-" when it has no recipient.
            for identity in try identities(at: rest[0], passphrase: rest.count > 1 ? rest[1] : nil) {
                print(identity.kind.label, identity.recipient?.line ?? "-")
            }
        case "inspect":
            // The format, size, and recipient stanza kinds, without any identity.
            let info = try AgeEngine.inspect(url: URL(fileURLWithPath: rest[0]))
            print(info.isArmored ? "armored" : "binary", info.size)
            for recipient in info.recipients { print(recipient.kind) }
        case "encrypt":
            // Every argument after the armor flag is a recipient line of any supported kind.
            let armor = rest[2] == "1"
            let recipients = try rest.dropFirst(3).map { try AgeRecipientParser.parse($0) }
            let outcome = try AgeEngine.encrypt(input: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]), recipients: recipients, armor: armor)
            print("encrypted", outcome.inputSize, outcome.outputSize)
        case "encrypt-passphrase":
            // The driver passes a small work factor; the production default is slow.
            let workFactor = rest.count > 3 ? Int(rest[3])! : ScryptRecipient.defaultWorkFactor
            let outcome = try AgeEngine.encrypt(input: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]), recipients: [ScryptRecipient(passphrase: rest[2], workFactor: workFactor)], armor: false)
            print("encrypted", outcome.inputSize, outcome.outputSize)
        case "decrypt":
            // The digest lets the driver compare the output with the original without reading it.
            let keys = try identities(at: rest[2], passphrase: rest.count > 3 ? rest[3] : nil)
            let outcome = try AgeEngine.decrypt(input: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]), identities: keys)
            print("decrypted", outcome.outputSize, outcome.sha256)
        case "decrypt-passphrase":
            let outcome = try AgeEngine.decrypt(input: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]), identities: [ScryptIdentity(passphrase: rest[2])])
            print("decrypted", outcome.outputSize, outcome.sha256)
        default:
            print("unknown command \(command)")
            exit(2)
        }
    }

    // selfTest(vectorsPath): Check the primitives against fixed vectors and the vectors the driver
    // computed in Python, then run the format and engine round trips in memory.
    static func selfTest(vectorsPath: String) throws {
        // Base64 as age writes it: no padding, canonical trailing bits.
        check(AgeBase64.encode(Data([0xFF, 0xFE])) == "//4", "base64 encode drops padding")
        check(AgeBase64.decode("//4") == Data([0xFF, 0xFE]), "base64 decode")
        check(AgeBase64.decode("//4=") == nil, "base64 rejects padding")
        check(AgeBase64.decode("//5") == nil, "base64 rejects non-canonical bits")
        check(AgeBase64.decode("") == Data(), "empty base64")

        // Bech32: the age-keygen example from the age README.
        let examplePublic = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
        let decoded = Bech32.decode(examplePublic)
        check(decoded?.hrp == "age" && decoded?.data.count == 32, "bech32 decodes an age key")
        check(Bech32.encode(hrp: "age", data: decoded!.data) == examplePublic, "bech32 round trip")
        check(Bech32.decode("age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8q") == nil, "bech32 checksum failure")
        check(Bech32.decode("Age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p") == nil, "bech32 mixed case")
        // A real key pair from the driver: made by age-keygen when it is installed, otherwise by
        // this harness's own keygen command.
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: vectorsPath))) as! [String: Any]
        let secretExample = vectors["age_secret"] as! String
        let secret = Bech32.decode(secretExample)
        check(secret?.hrp == "age-secret-key-" && secret?.data.count == 32, "bech32 decodes an uppercase secret key")
        check(Bech32.encode(hrp: "age-secret-key-", data: secret!.data).uppercased() == secretExample, "secret key round trip")
        try check(try X25519Identity(string: secretExample).recipient?.line == (vectors["age_public"] as! String), "the secret key derives its public key")

        // scrypt vectors from RFC 7914 section 12.
        let scrypt1 = Scrypt.derive(passphrase: Data(), salt: Data(), logN: 4, r: 1, p: 1, keyLength: 64)
        check(hex(scrypt1) == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906", "scrypt vector 1")
        let scrypt2 = Scrypt.derive(passphrase: Data("password".utf8), salt: Data("NaCl".utf8), logN: 10, r: 8, p: 16, keyLength: 64)
        check(hex(scrypt2) == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640", "scrypt vector 2")
        let scrypt3 = Scrypt.derive(passphrase: Data("pleaseletmein".utf8), salt: Data("SodiumChloride".utf8), logN: 14, r: 8, p: 1, keyLength: 64)
        check(hex(scrypt3) == "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887", "scrypt vector 3")
        // Salsa20/8 vector from RFC 7914 section 8, loaded and read back as little-endian words.
        var salsaWords = [UInt32](repeating: 0, count: 16)
        let salsaInput = data(hex: "7e879a214f3ec9867ca940e641718f26baee555b8c61c1b50df846116dcd3b1dee24f319df9b3d8514121e4b5ac5aa3276021d2909c74829edebc68db8b8c25e")
        salsaInput.withUnsafeBytes { raw in
            for index in 0..<16 { salsaWords[index] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
        }
        Scrypt.salsa20_8(&salsaWords)
        var salsaOutput = Data()
        for word in salsaWords { salsaOutput.append(contentsOf: withUnsafeBytes(of: word.littleEndian) { Data($0) }) }
        check(hex(salsaOutput) == "a41f859c6608cc993b81cacb020cef05044b2181a2fd337dfd7b1c6396682f29b4393168e3c9e6bcfe6bc5b7a06d96bae424cc102c91745c24ad673dc7618f81", "Salsa20/8 vector")

        // Big integers against Python-computed vectors, which include division edge cases.
        for entry in vectors["bigint"] as! [[String: String]] {
            let a = BigUInt(bigEndian: data(hex: entry["a"]!))
            let b = BigUInt(bigEndian: data(hex: entry["b"]!))
            let m = BigUInt(bigEndian: data(hex: entry["m"]!))
            check(hex((a * b).bigEndianBytes) == entry["mul"]!, "bigint multiply")
            check(hex((a + b).bigEndianBytes) == entry["add"]!, "bigint add")
            check(hex((a / b).bigEndianBytes) == entry["div"]!, "bigint divide")
            check(hex((a % b).bigEndianBytes) == entry["mod"]!, "bigint remainder")
            check(hex(a.modPow(b, modulus: m).bigEndianBytes) == entry["pow"]!, "bigint modPow")
            // Subtraction only when it stays non-negative.
            if a >= b { check(hex((a - b).bigEndianBytes) == entry["sub"]!, "bigint subtract") }
        }

        // Ed25519 to X25519: the conversion must agree with the vectors Python derived.
        for entry in vectors["ed25519"] as! [[String: String]] {
            let converted = Curve25519Conversion.montgomeryU(fromEdwardsPublicKey: data(hex: entry["edwards"]!))
            check(converted.map(hex) == entry["montgomery"]!, "ed25519 public key conversion")
        }

        // bcrypt_pbkdf has no vector here; the driver covers it by decrypting the
        // passphrase-protected OpenSSH keys it generates.

        // Header round trip with every stanza shape, including a body that fills its lines.
        let fileKey = AgeRandom.bytes(16)
        let longBody = AgeRandom.bytes(48)
        check(AgeHeaderCodec.bodyLines(longBody).hasSuffix("\n\n"), "a 64-character body ends with an empty line")
        let stanzas = [
            AgeStanza(type: "X25519", args: ["abc"], body: AgeRandom.bytes(32)),
            AgeStanza(type: "ssh-rsa", args: ["dGFn"], body: AgeRandom.bytes(256)),
            AgeStanza(type: "custom", args: ["a", "b", "c"], body: longBody),
            AgeStanza(type: "empty", args: [], body: Data()),
        ]
        let encoded = AgeHeaderCodec.encode(stanzas, fileKey: fileKey)
        let parsed = try AgeHeaderCodec.parse(from: BufferedReader(DataByteReader(encoded)))
        check(parsed.stanzas == stanzas, "header stanzas survive a round trip")
        check(parsed.mac == AgeHeaderCodec.mac(fileKey: fileKey, over: parsed.authenticated), "header MAC matches")
        check(parsed.authenticated == AgeHeaderCodec.serialize(stanzas), "authenticated bytes match the serialization")
        // age accepts recipient lists beyond the old 256-stanza limit. This 300-entry case stays
        // below the higher safety cap while checking compatibility with valid files.
        let manyStanzas = (0..<300).map {
            AgeStanza(type: "custom", args: [String($0)], body: Data([UInt8($0.isMultiple(of: 2) ? 0 : 1)]))
        }
        let manyEncoded = AgeHeaderCodec.encode(manyStanzas, fileKey: fileKey)
        let manyParsed = try AgeHeaderCodec.parse(from: BufferedReader(DataByteReader(manyEncoded)))
        check(manyParsed.stanzas == manyStanzas, "a 300-recipient header survives a round trip")
        // A body that never ends is refused once the header passes its size limit, instead of
        // being collected until memory runs out.
        let endlessLine = String(repeating: "A", count: AgeHeaderCodec.bodyLineWidth) + "\n"
        let endless = AgeHeaderCodec.intro + "\n-> X25519 abc\n" + String(repeating: endlessLine, count: AgeHeaderCodec.maximumHeaderSize / endlessLine.count + 2)
        do {
            _ = try AgeHeaderCodec.parse(from: BufferedReader(DataByteReader(Data(endless.utf8))))
            check(false, "an endless stanza body must be refused")
        } catch AgeError.invalidHeader {
            // The expected refusal; any other error propagates and fails the run.
            checks += 1
        }
        // An SSH public key wire with trailing bytes would carry a different tag than other
        // tools compute, so it is refused.
        let signing = Curve25519.Signing.PrivateKey()
        var edWire = SSHWire.string(Data("ssh-ed25519".utf8))
        edWire.append(SSHWire.string(signing.publicKey.rawRepresentation))
        check((try? SSHPublicKey.parse(wire: edWire)) != nil, "an exact ed25519 wire parses")
        check((try? SSHPublicKey.parse(wire: edWire + Data([0]))) == nil, "trailing bytes after an ed25519 wire are refused")
        // Match OpenSSH's 16384-bit RSA ceiling before the modulus reaches expensive RSA math.
        var maximumRSAWire = SSHWire.string(Data("ssh-rsa".utf8))
        maximumRSAWire.append(SSHWire.mpint(BigUInt(65_537)))
        maximumRSAWire.append(SSHWire.mpint(BigUInt(
            bigEndian: Data([0x80]) + Data(repeating: 0, count: 2_047)
        )))
        check((try? SSHPublicKey.parse(wire: maximumRSAWire)) != nil,
              "a 16384-bit RSA public key parses")
        var oversizedRSAWire = SSHWire.string(Data("ssh-rsa".utf8))
        oversizedRSAWire.append(SSHWire.mpint(BigUInt(65_537)))
        oversizedRSAWire.append(SSHWire.mpint(BigUInt(
            bigEndian: Data([0x01]) + Data(repeating: 0, count: 2_048)
        )))
        check((try? SSHPublicKey.parse(wire: oversizedRSAWire)) == nil,
              "an RSA public key above 16384 bits is refused")

        // Encryption round trips in memory, binary and armored, at sizes around the 64 KiB
        // payload chunk boundary.
        let identity = X25519Identity.generate()
        let recipient = try X25519Recipient(string: identity.recipient!.line)
        for size in [0, 1, 15, 65535, 65536, 65537, 131072, 200000] {
            let plain = AgeRandom.bytes(size)
            let encrypted = try AgeEngine.encryptToMemory(plain, recipients: [recipient])
            try check(try AgeEngine.decryptToMemory(encrypted, identities: [identity]) == plain, "X25519 round trip of \(size) bytes")
            let armored = try AgeEngine.encryptToMemory(plain, recipients: [recipient], armor: true)
            check(String(data: armored, encoding: .utf8)!.hasPrefix(AgeArmor.header + "\n"), "armor header")
            try check(try AgeEngine.decryptToMemory(armored, identities: [identity]) == plain, "armored round trip of \(size) bytes")
            // A flipped payload byte must fail authentication; an empty payload has no byte to
            // flip, so only the truncation check applies to it.
            if size > 0 {
                var tampered = encrypted
                tampered[tampered.count - 1] ^= 1
                check((try? AgeEngine.decryptToMemory(tampered, identities: [identity])) == nil, "payload tampering is detected")
            }
            // Dropping the end of the file cuts into the final chunk's tag, which must be noticed.
            var truncated = encrypted
            truncated.removeLast(8)
            check((try? AgeEngine.decryptToMemory(truncated, identities: [identity])) == nil, "truncation is detected")
        }
        // A flipped byte in the first stanza line must be refused, whether it is noticed as an
        // unknown stanza or as a failed header MAC.
        var headerTampered = try AgeEngine.encryptToMemory(Data("x".utf8), recipients: [recipient])
        headerTampered[AgeHeaderCodec.intro.count + 5] ^= 1
        check((try? AgeEngine.decryptToMemory(headerTampered, identities: [identity])) == nil, "header tampering is detected")

        // Several recipients: each identity recovers the same file; a stranger cannot.
        let second = X25519Identity.generate()
        let stranger = X25519Identity.generate()
        let shared = try AgeEngine.encryptToMemory(Data("shared".utf8), recipients: [recipient, second.recipient!])
        try check(try AgeEngine.decryptToMemory(shared, identities: [second]) == Data("shared".utf8), "second recipient decrypts")
        try check(try AgeEngine.decryptToMemory(shared, identities: [stranger, identity]) == Data("shared".utf8), "the matching identity is found among others")
        do {
            _ = try AgeEngine.decryptToMemory(shared, identities: [stranger])
            check(false, "a stranger must not decrypt")
        } catch AgeError.noMatchingIdentity {
            // The specific error matters: the app tells the user no identity matched.
            checks += 1
        }

        // Passphrases: a small work factor keeps the test quick; a wrong passphrase is reported.
        let passphrased = try AgeEngine.encryptToMemory(Data("secret".utf8), recipients: [ScryptRecipient(passphrase: "pw", workFactor: 10)])
        try check(try AgeEngine.decryptToMemory(passphrased, identities: [ScryptIdentity(passphrase: "pw")]) == Data("secret".utf8), "passphrase round trip")
        do {
            _ = try AgeEngine.decryptToMemory(passphrased, identities: [ScryptIdentity(passphrase: "no")])
            check(false, "a wrong passphrase must fail")
        } catch AgeError.wrongPassphrase {
            // A wrong passphrase is distinguished from a missing one so the app can ask again.
            checks += 1
        }
        do {
            _ = try AgeEngine.decryptToMemory(passphrased, identities: [identity])
            check(false, "a passphrase file needs a passphrase")
        } catch AgeError.passphraseRequired {
            // Key identities alone cannot open a passphrase file; the app prompts for one.
            checks += 1
        }
        do {
            _ = try AgeEngine.encryptToMemory(Data(), recipients: [ScryptRecipient(passphrase: "pw", workFactor: 10), recipient])
            check(false, "a passphrase cannot be combined with keys")
        } catch AgeError.invalidRecipient {
            // age forbids mixing a passphrase with other recipients, and so does the engine.
            checks += 1
        }

        // RSA-OAEP round trip with a 2048-bit key the driver generated into the vectors.
        let rsa = (vectors["rsa"] as! [String: String])
        let numbers = RSAPrivateKeyNumbers(
            modulus: BigUInt(bigEndian: data(hex: rsa["n"]!)), publicExponent: BigUInt(bigEndian: data(hex: rsa["e"]!)),
            privateExponent: BigUInt(bigEndian: data(hex: rsa["d"]!)), prime1: BigUInt(bigEndian: data(hex: rsa["p"]!)),
            prime2: BigUInt(bigEndian: data(hex: rsa["q"]!)), coefficient: BigUInt(bigEndian: data(hex: rsa["qinv"]!))
        )
        let message = AgeRandom.bytes(16)
        let ciphertext = try RSAOAEP.encrypt(message: message, modulus: numbers.modulus, exponent: numbers.publicExponent)
        check(RSAOAEP.decrypt(ciphertext: ciphertext, key: numbers) == message, "RSA-OAEP round trip")
        var wrong = ciphertext
        wrong[5] ^= 1
        check(RSAOAEP.decrypt(ciphertext: wrong, key: numbers) == nil, "RSA-OAEP rejects a changed ciphertext")
        // Without primes the plain private exponent must agree with the CRT path.
        let plainNumbers = RSAPrivateKeyNumbers(modulus: numbers.modulus, publicExponent: numbers.publicExponent, privateExponent: numbers.privateExponent, prime1: BigUInt(), prime2: BigUInt(), coefficient: BigUInt())
        check(RSAOAEP.decrypt(ciphertext: ciphertext, key: plainNumbers) == message, "RSA without CRT agrees")
        // A key file claiming a prime of one would make the CRT path reduce modulo zero; the
        // decoder must notice and take the plain exponent path instead.
        let hostileNumbers = RSAPrivateKeyNumbers(modulus: numbers.modulus, publicExponent: numbers.publicExponent, privateExponent: numbers.privateExponent, prime1: BigUInt(1), prime2: numbers.modulus, coefficient: BigUInt(1))
        check(RSAOAEP.decrypt(ciphertext: ciphertext, key: hostileNumbers) == message, "a prime of one falls back to the plain exponent")

        // Recipient parsing names common mistakes.
        check((try? AgeRecipientParser.parse(secretExample)) == nil, "a secret key is not a recipient")
        check(AgeRecipientParser.kind(of: "ecdsa-sha2-nistp256 AAAA") == .unsupported("ecdsa-sha2-nistp256"), "ecdsa is unsupported")
        check(AgeRecipientParser.kind(of: "hello") == nil, "text is not a key")
        check(AgeRecipientParser.kind(of: examplePublic) == .x25519, "age key kind")

        // Identity file text matches age-keygen's layout and parses back as a plain age identity.
        let text = AgeIdentityFile.identityFileText(for: identity)
        guard case .ageIdentities(let parsedIdentities) = try AgeIdentityFile.classify(Data(text.utf8)) else {
            check(false, "identity file classification")
            return
        }
        check(parsedIdentities.count == 1 && parsedIdentities[0].secret == identity.secret, "identity file round trip")

        // Armor reading tolerates blank lines between the lines, as pasted text often has, and
        // rejects text after the footer.
        let armoredText = String(data: try AgeEngine.encryptToMemory(Data("reflow".utf8), recipients: [recipient], armor: true), encoding: .utf8)!
        let reflowed = armoredText.replacingOccurrences(of: "\n", with: "\n\n")
        try check(try AgeEngine.decryptToMemory(Data(reflowed.utf8), identities: [identity]) == Data("reflow".utf8), "reflowed armor decodes")
        check((try? AgeEngine.decryptToMemory(Data((armoredText + "trailing\n").utf8), identities: [identity])) == nil, "text after the footer is rejected")

        print("age core: \(checks) checks passed")
    }
}
