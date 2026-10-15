import CryptoKit
import Foundation

/// A stanza described for the interface: the kind of key it is for and its tag.
struct AgeStanzaSummary: Identifiable, Equatable {
    enum Kind: Equatable {
        case x25519
        case sshEd25519(tag: String)
        case sshRSA(tag: String)
        case scrypt(workFactor: Int?)
        case other(String)
    }

    let id: Int
    let kind: Kind

    // init(index, stanza): Summarize the stanza at the given header position.
    init(index: Int, stanza: AgeStanza) {
        id = index
        switch stanza.type {
        case "X25519": kind = .x25519
        case "ssh-ed25519": kind = .sshEd25519(tag: stanza.args.first ?? "")
        case "ssh-rsa": kind = .sshRSA(tag: stanza.args.first ?? "")
        case "scrypt": kind = .scrypt(workFactor: stanza.args.count == 2 ? Int(stanza.args[1]) : nil)
        default: kind = .other(stanza.type)
        }
    }

    /// The tag an SSH identity would have to match, if any.
    var sshTag: String? {
        switch kind {
        case .sshEd25519(let tag), .sshRSA(let tag): return tag
        default: return nil
        }
    }

    /// The key kind, for matching against known identities.
    var keyKind: AgeKeyKind {
        switch kind {
        case .x25519: return .x25519
        case .sshEd25519: return .sshEd25519
        case .sshRSA: return .sshRSA
        case .scrypt: return .scrypt
        case .other(let type): return .unsupported(type)
        }
    }
}

/// What the header of an encrypted file says, without any key.
struct AgeFileInfo: Equatable {
    let url: URL
    let size: Int64
    let isArmored: Bool
    let stanzas: [AgeStanza]
    /// The serialized recipient section and its MAC, retained so identities can be checked
    /// without reading or decrypting the payload.
    let authenticated: Data
    let mac: Data

    /// One summary per stanza, in header order.
    var recipients: [AgeStanzaSummary] {
        stanzas.enumerated().map { AgeStanzaSummary(index: $0.offset, stanza: $0.element) }
    }

    var needsPassphrase: Bool { stanzas.contains { $0.type == "scrypt" } }
}

/// The result of an encryption.
struct AgeEncryptOutcome: Equatable {
    let inputSize: Int64
    let outputSize: Int64
}

/// The result of a decryption.
struct AgeDecryptOutcome: Equatable {
    let outputSize: Int64
    /// The SHA-256 of the decrypted bytes, in lowercase hex.
    let sha256: String
}

/// Reads bytes from memory.
final class DataByteReader: ByteReader {
    private var data: Data

    // init(data): Read from the given bytes.
    init(_ data: Data) { self.data = data }

    // read(upTo count): The next bytes.
    func read(upTo count: Int) throws -> Data {
        let taken = data.prefix(count)
        data.removeFirst(taken.count)
        return Data(taken)
    }
}

/// Collects bytes in memory.
final class DataByteWriter: ByteWriter {
    private(set) var data = Data()

    // write(bytes): Append.
    func write(_ bytes: Data) throws { data.append(bytes) }

    // finish(): Nothing to flush.
    func finish() throws {}
}

/// Encrypts, decrypts, and inspects age files, streaming them chunk by chunk.
enum AgeEngine {
    /// Reports progress as input bytes done out of the input total.
    typealias Progress = (_ done: Int64, _ total: Int64) -> Void
    /// Polled between chunks; returning true stops the operation.
    typealias Cancellation = () -> Bool

    // MARK: Inspection

    // inspect(url): Read the header of an encrypted file.
    static func inspect(url: URL) throws -> AgeFileInfo {
        let size = fileSize(url)
        let (reader, armored) = try openInput(url)
        let header = try AgeHeaderCodec.parse(from: reader)
        return AgeFileInfo(
            url: url,
            size: size,
            isArmored: armored,
            stanzas: header.stanzas,
            authenticated: header.authenticated,
            mac: header.mac
        )
    }

    // matchingStanzaIndexes(in info, identities, [isCancelled = nil]): The recipient entries
    // whose file key the identities can recover and authenticate.
    static func matchingStanzaIndexes(in info: AgeFileInfo, identities: [any AgeIdentity], isCancelled: Cancellation? = nil) throws -> Set<Int> {
        var matches: Set<Int> = []
        // Native age entries have no public identifier, so prove a match by opening each entry
        // and checking the recovered file key against the complete header MAC.
        for (index, stanza) in info.stanzas.enumerated() {
            if isCancelled?() == true { throw AgeError.cancelled }
            for identity in identities {
                if let fileKey = try identity.unwrap([stanza]), headerMACMatches(fileKey: fileKey, authenticated: info.authenticated, mac: info.mac) {
                    matches.insert(index)
                    break
                }
            }
        }
        return matches
    }

    // MARK: Encryption

    // encrypt(input, output, recipients, armor, [progress = nil], [isCancelled = nil]): Encrypt a
    // file for the recipients, writing the output file. A failure or cancellation removes the
    // output.
    static func encrypt(input: URL, output: URL, recipients: [any AgeRecipient], armor: Bool, progress: Progress? = nil, isCancelled: Cancellation? = nil) throws -> AgeEncryptOutcome {
        let total = fileSize(input)
        // An unreadable input is reported by name before any output file is created.
        let reader: FileByteReader
        do {
            reader = try FileByteReader(url: input)
        } catch {
            throw AgeError.cannotRead(input.lastPathComponent)
        }
        // The output passes through the armor encoder when asked.
        let fileWriter = try FileByteWriter(url: output)
        let writer: ByteWriter = armor ? ArmorWriter(sink: fileWriter) : fileWriter
        do {
            let written = try encryptStream(from: reader, to: writer, recipients: recipients, total: total, progress: progress, isCancelled: isCancelled)
            try writer.finish()
            return AgeEncryptOutcome(inputSize: total, outputSize: written)
        } catch {
            // Never leave a partial file behind.
            try? fileWriter.finish()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // encryptToMemory(data, recipients, [armor = false]): Encrypt bytes, for small inputs such as
    // identity files.
    static func encryptToMemory(_ data: Data, recipients: [any AgeRecipient], armor: Bool = false) throws -> Data {
        let sink = DataByteWriter()
        let writer: ByteWriter = armor ? ArmorWriter(sink: sink) : sink
        _ = try encryptStream(from: DataByteReader(data), to: writer, recipients: recipients, total: Int64(data.count), progress: nil, isCancelled: nil)
        try writer.finish()
        return sink.data
    }

    // encryptStream(from reader, to writer, recipients, total, progress,
    // isCancelled): Write the header and chunked payload. Returns the bytes handed
    // to the writer before armoring.
    private static func encryptStream(from reader: ByteReader, to writer: ByteWriter, recipients: [any AgeRecipient], total: Int64, progress: Progress?, isCancelled: Cancellation?) throws -> Int64 {
        guard !recipients.isEmpty else { throw AgeError.noRecipients }
        // A passphrase stands alone; age refuses to mix it with keys.
        if recipients.contains(where: { $0.kind == .scrypt }), recipients.count > 1 {
            throw AgeError.invalidRecipient(localized("A passphrase cannot be combined with other recipients."))
        }
        // A fresh file key is wrapped once per recipient, and the header MAC covers the stanzas.
        let fileKey = AgeRandom.bytes(AgeHeaderCodec.fileKeySize)
        let stanzas = try recipients.map { try $0.wrap(fileKey: fileKey) }
        var written: Int64 = 0
        let header = AgeHeaderCodec.encode(stanzas, fileKey: fileKey)
        try writer.write(header)
        written += Int64(header.count)
        // The 16-byte payload nonce follows the header and seeds the payload key.
        let nonce = AgeRandom.bytes(AgePayload.nonceSize)
        try writer.write(nonce)
        written += Int64(nonce.count)
        let key = AgePayload.key(fileKey: fileKey, nonce: nonce)
        // Read the first chunk; an empty input still produces one empty final chunk.
        var current = try readFull(reader, AgePayload.chunkSize)
        var counter: UInt64 = 0
        var done: Int64 = 0
        while true {
            // Stop between chunks when the user cancels.
            if isCancelled?() == true { throw AgeError.cancelled }
            // Look ahead one chunk to know whether this one is the last.
            let next = try readFull(reader, AgePayload.chunkSize)
            let last = next.isEmpty
            let sealed = try AgePayload.seal(current, key: key, counter: counter, last: last)
            try writer.write(sealed)
            written += Int64(sealed.count)
            done += Int64(current.count)
            progress?(done, total)
            // The final chunk has been written.
            if last { break }
            current = next
            counter += 1
        }
        return written
    }

    // MARK: Decryption

    // decrypt(input, output, identities, [progress = nil], [isCancelled = nil]): Decrypt a file
    // with the first identity that fits, writing the output file. A failure or cancellation
    // removes the output.
    static func decrypt(input: URL, output: URL, identities: [any AgeIdentity], progress: Progress? = nil, isCancelled: Cancellation? = nil) throws -> AgeDecryptOutcome {
        let total = fileSize(input)
        let (reader, _) = try openInput(input)
        // Read and unwrap the header before creating the output, so a wrong key leaves no file.
        let (stanzas, fileKey) = try unwrapHeader(from: reader, identities: identities)
        _ = stanzas
        let writer = try FileByteWriter(url: output)
        do {
            let outcome = try decryptPayload(from: reader, to: writer, fileKey: fileKey, total: total, progress: progress, isCancelled: isCancelled)
            try writer.finish()
            return outcome
        } catch {
            // Never leave a partial or corrupt file behind.
            try? writer.finish()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // decryptToMemory(data, identities): Decrypt bytes, for small inputs such as identity files.
    static func decryptToMemory(_ data: Data, identities: [any AgeIdentity]) throws -> Data {
        // Armor is detected from the first bytes, as for files.
        let armored = AgeArmor.looksArmored(data.prefix(64))
        let source: ByteReader = armored ? ArmorReader(source: DataByteReader(data)) : DataByteReader(data)
        let reader = BufferedReader(source)
        let (_, fileKey) = try unwrapHeader(from: reader, identities: identities)
        let sink = DataByteWriter()
        _ = try decryptPayload(from: reader, to: sink, fileKey: fileKey, total: Int64(data.count), progress: nil, isCancelled: nil)
        return sink.data
    }

    // unwrapHeader(from reader, identities): Parse the header, recover the file
    // key with the first identity that fits, and verify the header MAC.
    private static func unwrapHeader(from reader: BufferedReader, identities: [any AgeIdentity]) throws -> ([AgeStanza], Data) {
        let header = try AgeHeaderCodec.parse(from: reader)
        // A passphrase file has exactly one stanza; anything else is not a valid age file.
        if header.stanzas.contains(where: { $0.type == "scrypt" }), header.stanzas.count > 1 {
            throw AgeError.invalidHeader(localized("A passphrase entry must be the only recipient."))
        }
        var fileKey: Data?
        for identity in identities {
            // The first identity that fits wins; the others are not tried.
            if let key = try identity.unwrap(header.stanzas) {
                fileKey = key
                break
            }
        }
        guard let fileKey else {
            // A passphrase file without a passphrase identity needs one before anything else.
            if header.stanzas.contains(where: { $0.type == "scrypt" }), !identities.contains(where: { $0.kind == .scrypt }) {
                throw AgeError.passphraseRequired
            }
            throw AgeError.noMatchingIdentity
        }
        // The MAC check runs in constant time and proves the recovered file key is the right one.
        guard headerMACMatches(fileKey: fileKey, authenticated: header.authenticated, mac: header.mac) else {
            throw AgeError.headerMACMismatch
        }
        return (header.stanzas, fileKey)
    }

    // headerMACMatches(fileKey, authenticated, mac): Whether a recovered file key authenticates
    // the complete recipient section.
    private static func headerMACMatches(fileKey: Data, authenticated: Data, mac: Data) -> Bool {
        let expected = AgeHeaderCodec.mac(fileKey: fileKey, over: authenticated)
        return expected.count == mac.count && HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: authenticated,
            using: SymmetricKey(data: AgeKDF.derive(ikm: fileKey, salt: Data(), info: "header"))
        )
    }

    // decryptPayload(from reader, to writer, fileKey, total, progress,
    // isCancelled): Decrypt the chunks that follow the header.
    private static func decryptPayload(from reader: BufferedReader, to writer: ByteWriter, fileKey: Data, total: Int64, progress: Progress?, isCancelled: Cancellation?) throws -> AgeDecryptOutcome {
        // The 16-byte payload nonce comes right after the header and seeds the payload key.
        guard let nonce = try reader.read(exactly: AgePayload.nonceSize) else { throw AgeError.truncated }
        let key = AgePayload.key(fileKey: fileKey, nonce: nonce)
        let chunkSize = AgePayload.chunkSize + AgePayload.tagSize
        var current = try readFull(reader, chunkSize)
        // The payload always has at least one chunk, even for an empty file.
        guard !current.isEmpty else { throw AgeError.truncated }
        var counter: UInt64 = 0
        var written: Int64 = 0
        var hasher = SHA256()
        while true {
            // Stop between chunks when the user cancels.
            if isCancelled?() == true { throw AgeError.cancelled }
            let next = try readFull(reader, chunkSize)
            let last = next.isEmpty
            // Only the final chunk may be short.
            if !last, current.count != chunkSize { throw AgeError.payloadCorrupt }
            // An empty final chunk, a tag alone, is valid only when it is also the first.
            if last, current.count == AgePayload.tagSize, counter > 0 { throw AgeError.payloadCorrupt }
            guard let plain = AgePayload.open(current, key: key, counter: counter, last: last) else {
                throw AgeError.payloadCorrupt
            }
            try writer.write(plain)
            hasher.update(data: plain)
            written += Int64(plain.count)
            // Progress counts input bytes, estimated from the number of whole chunks.
            progress?(min(total, Int64(counter + 1) * Int64(chunkSize)), total)
            // The final chunk has been written.
            if last { break }
            current = next
            counter += 1
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return AgeDecryptOutcome(outputSize: written, sha256: digest)
    }

    // MARK: Helpers

    // openInput(url): A buffered reader over the file, through the armor decoder when the file
    // starts with the armor header.
    private static func openInput(_ url: URL) throws -> (BufferedReader, Bool) {
        // Peek at the first bytes with a throwaway handle, then open the real reader at the start.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AgeError.cannotRead(url.lastPathComponent)
        }
        let prefix = (try? handle.read(upToCount: 64)) ?? Data()
        try? handle.close()
        let armored = AgeArmor.looksArmored(prefix)
        let file: FileByteReader
        do {
            file = try FileByteReader(url: url)
        } catch {
            throw AgeError.cannotRead(url.lastPathComponent)
        }
        let source: ByteReader = armored ? ArmorReader(source: file) : file
        return (BufferedReader(source), armored)
    }

    // readFull(reader, count): Up to count bytes, reading again until the reader runs dry, so a
    // chunk is only short at the end of the input.
    private static func readFull(_ reader: ByteReader, _ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let more = try reader.read(upTo: count - result.count)
            // The input ended.
            if more.isEmpty { break }
            result.append(more)
        }
        return result
    }

    // readFull(reader, count): The same over a buffered reader.
    private static func readFull(_ reader: BufferedReader, _ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let more = try reader.read(upTo: count - result.count)
            // The input ended.
            if more.isEmpty { break }
            result.append(more)
        }
        return result
    }

    // fileSize(url): The file's size in bytes, or zero when it cannot be read.
    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
