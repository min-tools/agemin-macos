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
