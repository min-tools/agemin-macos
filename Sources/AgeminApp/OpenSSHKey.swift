import CommonCrypto
import CryptoKit
import Foundation

/// Reads the length-prefixed fields of SSH's wire format.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    // init(data): Start reading at the beginning of data.
    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }
    /// What has not been read yet.
    var remaining: Data { data[offset...] }

    // readUInt32(): A big-endian 32-bit integer.
    mutating func readUInt32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw SSHKeyError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(data[offset])
            offset += 1
        }
        return value
    }

    // readString(): A length-prefixed byte string.
    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard data.endIndex - offset >= length else { throw SSHKeyError.truncated }
        let result = data[offset..<(offset + length)]
        offset += length
        return Data(result)
    }

    // readText(): A length-prefixed string, decoded as UTF-8.
    mutating func readText() throws -> String {
        guard let text = String(data: try readString(), encoding: .utf8) else { throw SSHKeyError.malformed }
        return text
    }

    // readMPInt(): A length-prefixed big-endian integer; a negative value is rejected.
    mutating func readMPInt() throws -> BigUInt {
        let bytes = try readString()
        // A set high bit without a leading zero byte would be a negative number.
        if let first = bytes.first, first & 0x80 != 0 { throw SSHKeyError.malformed }
        return BigUInt(bigEndian: bytes)
    }

    // skip(count): Skip count bytes.
    mutating func skip(_ count: Int) throws {
        guard data.endIndex - offset >= count else { throw SSHKeyError.truncated }
        offset += count
    }
}

/// Builds SSH wire format.
enum SSHWire {
    // string(data): A length-prefixed byte string.
    static func string(_ data: Data) -> Data {
        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) })
        result.append(data)
        return result
    }

    // mpint(value): A length-prefixed big-endian integer with a leading zero when needed.
    static func mpint(_ value: BigUInt) -> Data {
        var bytes = value.bigEndianBytes
        // Keep the number positive in two's complement.
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(bytes)
    }
}
