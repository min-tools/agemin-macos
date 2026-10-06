import Foundation

/// A source of bytes read in order, such as a file or an armored wrapper around one.
protocol ByteReader: AnyObject {
    // read(upTo count): The next bytes, at most count of them; empty data at the end of the input.
    func read(upTo count: Int) throws -> Data
}

/// A destination for bytes written in order.
protocol ByteWriter: AnyObject {
    // write(data): Append the bytes.
    func write(_ data: Data) throws
    // finish(): Flush what is pending and close the destination.
    func finish() throws
}

/// Reads a file through a file handle.
final class FileByteReader: ByteReader {
    private let handle: FileHandle

    // init(url): Open the file for reading.
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    // read(upTo count): Read up to count bytes from the file.
    func read(upTo count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        return try handle.read(upToCount: count) ?? Data()
    }

    // close(): Close the handle early; deinit closes it otherwise.
    func close() {
        try? handle.close()
    }

    // deinit(): Close the handle if close() was never called.
    deinit {
        try? handle.close()
    }
}

/// Writes a file through a file handle. The file is created with owner-only permissions, so an
/// encrypted or decrypted file is never readable by other accounts, and truncated when it exists.
final class FileByteWriter: ByteWriter {
    private let handle: FileHandle
    private var finished = false

    // init(url): Create or truncate the file with mode 0600 and open it for writing. The file is
    // opened with the POSIX call so the private mode applies from the moment it exists.
    init(url: URL) throws {
        // Replace any existing contents while keeping the chosen path; the panel already asked.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgeError.cannotWrite(url.lastPathComponent) }
        // A pre-existing file keeps its old mode; set the private one explicitly.
        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw AgeError.cannotWrite(url.lastPathComponent)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    // write(data): Append the bytes to the file.
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
    }

    // finish(): Close the file once.
    func finish() throws {
        guard !finished else { return }
        finished = true
        try handle.close()
    }

    // deinit(): Close the descriptor if finish() was never called.
    deinit {
        // An unfinished writer still closes its descriptor; a finished one is already closed.
        if !finished { try? handle.close() }
    }
}

/// Buffers a byte reader so lines and exact byte counts can be read from it.
final class BufferedReader {
    private let source: ByteReader
    private var buffer = Data()
    private var atEnd = false
    /// How many bytes one fill reads from the source.
    private let fillSize: Int

    // init(source, [fillSize = 65536]): Wrap a reader; fillSize is the read size per refill.
    init(_ source: ByteReader, fillSize: Int = 65536) {
        self.source = source
        self.fillSize = fillSize
    }

    // fill(): Read one more block from the source into the buffer; false once the source is done.
    @discardableResult
    private func fill() throws -> Bool {
        guard !atEnd else { return false }
        let more = try source.read(upTo: fillSize)
        // An empty read marks the end of the input.
        if more.isEmpty {
            atEnd = true
            return false
        }
        buffer.append(more)
        return true
    }

    // readLine([maximumLength = 1_048_576]): The next line without its newline, or nil at the end
    // of the input. A line longer than maximumLength is an error, so a corrupt file cannot make
    // the buffer grow without bound.
    func readLine(maximumLength: Int = 1_048_576) throws -> String? {
        while true {
            // Return the line once a newline is buffered.
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let text = String(data: line, encoding: .utf8) else {
                    throw AgeError.invalidHeader(localized("The header is not valid text."))
                }
                return text
            }
            // No newline yet: refuse a line that keeps growing past the limit.
            if buffer.count > maximumLength {
                throw AgeError.invalidHeader(localized("A header line is too long."))
            }
            // Read more; at the end of the input, what remains is the last line, if anything.
            if try !fill() {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = Data()
                guard let text = String(data: line, encoding: .utf8) else {
                    throw AgeError.invalidHeader(localized("The header is not valid text."))
                }
                return text
            }
        }
    }

    // read(exactly count): Exactly count bytes, or nil when the input ends first. The buffered
    // bytes stay in place in the nil case, so a later read still sees them.
    func read(exactly count: Int) throws -> Data? {
        while buffer.count < count {
            // The source ran out before count bytes were buffered.
            if try !fill() { return nil }
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    // read(upTo count): Up to count bytes; empty data at the end of the input.
    func read(upTo count: Int) throws -> Data {
        // Fill once when nothing is buffered, so the caller sees progress or the end.
        if buffer.isEmpty { try fill() }
        let taken = min(count, buffer.count)
        let result = Data(buffer.prefix(taken))
        buffer.removeFirst(taken)
        return result
    }

    // readToEnd(limit): Everything that remains, up to limit bytes; more than that is an error.
    func readToEnd(limit: Int) throws -> Data {
        while try fill() {
            // Stop a runaway input before it fills memory.
            if buffer.count > limit {
                throw AgeError.invalidHeader(localized("The input is larger than expected."))
            }
        }
        let result = buffer
        buffer = Data()
        return result
    }
}

/// The age ASCII armor markers.
enum AgeArmor {
    static let header = "-----BEGIN AGE ENCRYPTED FILE-----"
    static let footer = "-----END AGE ENCRYPTED FILE-----"
    static let lineWidth = 64

    // looksArmored(prefix): Whether the start of a file is the armor header, after any leading
    // whitespace or blank lines. A byte order mark is not whitespace, so it disqualifies a file.
    static func looksArmored(_ prefix: Data) -> Bool {
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.drop(while: { $0.isWhitespace || $0.isNewline }).hasPrefix(header)
    }
}
