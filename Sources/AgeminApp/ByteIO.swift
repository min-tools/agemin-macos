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
