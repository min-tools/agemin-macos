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
