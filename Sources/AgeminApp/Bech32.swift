import Foundation

/// Bech32 encoding, which age uses for its native public keys and secret keys.
enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]

    // polymod(values): The BCH checksum state after absorbing the 5-bit values.
    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var checksum: UInt32 = 1
        // Shift in five bits, then fold in the generator for each set bit that fell off the top.
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1FF_FFFF) << 5) ^ UInt32(value)
            for index in 0..<5 where (top >> UInt32(index)) & 1 == 1 {
                checksum ^= generator[index]
            }
        }
        return checksum
    }

    // expand(hrp): The human-readable part as the checksum consumes it.
    private static func expand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    // convert(values, from, to, pad): Regroup bits between widths; nil when padding is wrong.
    private static func convert(_ values: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var result: [UInt8] = []
        let maximum = (1 << to) - 1
        for value in values {
            accumulator = (accumulator << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((accumulator >> bits) & maximum))
            }
        }
        // Encoding pads the final group; decoding requires the padding to be short and zero.
        if pad {
            // Only a partial group needs padding bits.
            if bits > 0 { result.append(UInt8((accumulator << (to - bits)) & maximum)) }
        } else if bits >= from || (accumulator << (to - bits)) & maximum != 0 {
            // Leftover bits must be fewer than one input group and all zero.
            return nil
        }
        return result
    }

    // encode(hrp, data): The lowercase Bech32 string for the bytes.
    static func encode(hrp: String, data: Data) -> String {
        let values = convert(Array(data), from: 8, to: 5, pad: true) ?? []
        // The checksum is the polymod over the expanded prefix, the data, and six empty slots,
        // xor the Bech32 constant 1, split into six 5-bit characters.
        let checksum = polymod(expand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksumValues = (0..<6).map { UInt8((checksum >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + (values + checksumValues).map { String(charset[Int($0)]) }.joined()
    }

    // decode(string): The human-readable part and bytes, or nil for mixed case, a bad character,
    // or a wrong checksum. age keys are longer than the 90 characters Bitcoin allows, so no
    // length limit is applied.
    static func decode(_ string: String) -> (hrp: String, data: Data)? {
        let lower = string.lowercased()
        // Mixed case is rejected; all-upper and all-lower are both accepted.
        guard lower == string || string.uppercased() == string else { return nil }
        // Split at the last separator; the prefix must be printable ASCII and the data part must
        // at least hold the checksum.
        guard let separator = lower.lastIndex(of: "1"), separator > lower.startIndex else { return nil }
        let hrp = String(lower[lower.startIndex..<separator])
        let dataPart = lower[lower.index(after: separator)...]
        guard dataPart.count >= 6, hrp.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        // Map each character to its 5-bit value.
        var values: [UInt8] = []
        for character in dataPart {
            guard let index = charset.firstIndex(of: character) else { return nil }
            values.append(UInt8(index))
        }
        // Verify the checksum, then drop it and regroup the rest into bytes.
        guard polymod(expand(hrp) + values) == 1 else { return nil }
        guard let bytes = convert(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(bytes))
    }
}
