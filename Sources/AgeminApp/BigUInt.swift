import Foundation

/// An arbitrary-precision unsigned integer, enough for RSA and for the Curve25519 field. Limbs
/// are 32 bits, least significant first, with no trailing zero limbs, so zero has none.
struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    private(set) var limbs: [UInt32]

    // init(): Zero.
    init() { limbs = [] }

    // init(value): From a machine integer.
    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    // init(limbs): From little-endian limbs, dropping trailing zeros.
    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    // init(bigEndian data): From big-endian bytes, as SSH and RSA encode numbers.
    init(bigEndian data: Data) {
        self.init(littleEndian: Data(data.reversed()))
    }

    // init(littleEndian data): From little-endian bytes, as Curve25519 encodes field elements.
    init(littleEndian data: Data) {
        var result: [UInt32] = []
        result.reserveCapacity((data.count + 3) / 4)
        var index = data.startIndex
        while index < data.endIndex {
            var limb: UInt32 = 0
            // Pack up to four bytes into one limb, lowest byte first.
            for shift in stride(from: 0, to: 32, by: 8) where index < data.endIndex {
                limb |= UInt32(data[index]) << UInt32(shift)
                index = data.index(after: index)
            }
            result.append(limb)
        }
        limbs = result
        normalize()
    }

    // normalize(): Drop trailing zero limbs so equal values have equal limbs.
    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }
    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// The number of significant bits.
    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    /// The number of bytes needed to hold the value.
    var byteCount: Int { (bitWidth + 7) / 8 }

    var description: String {
        isZero ? "0" : "0x" + limbs.reversed().map { String($0, radix: 16) }.joined()
    }

    // bit(at index): Whether the given bit is set.
    func bit(at index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    // littleEndianBytes(count): The value in count little-endian bytes, or nil when it does not fit.
    func littleEndianBytes(count: Int) -> Data? {
        guard byteCount <= count else { return nil }
        var data = Data(count: count)
        for (limbIndex, limb) in limbs.enumerated() {
            for byte in 0..<4 {
                let position = limbIndex * 4 + byte
                // The top limb may extend past the requested size only with zero bytes.
                if position < count { data[position] = UInt8(truncatingIfNeeded: limb >> UInt32(byte * 8)) }
            }
        }
        return data
    }

    // bigEndianBytes(count): The value in count big-endian bytes, or nil when it does not fit.
    func bigEndianBytes(count: Int) -> Data? {
        littleEndianBytes(count: count).map { Data($0.reversed()) }
    }

    /// The minimal big-endian encoding, empty for zero.
    var bigEndianBytes: Data { bigEndianBytes(count: byteCount) ?? Data() }

    // MARK: Comparison

    // <(lhs, rhs): Whether lhs is smaller; limb counts decide first, then the top differing limb.
    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        // More limbs means a larger value, since there are no leading zero limbs.
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        // Same length: compare from the most significant limb down.
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    // MARK: Arithmetic

    // +(lhs, rhs): The sum, with one extra limb for the final carry.
    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let (long, short) = lhs.limbs.count >= rhs.limbs.count ? (lhs.limbs, rhs.limbs) : (rhs.limbs, lhs.limbs)
        var result = [UInt32](repeating: 0, count: long.count + 1)
        var carry: UInt64 = 0
        // Walk the longer operand, adding the shorter one's limbs while they last.
        for index in 0..<long.count {
            let sum = UInt64(long[index]) + (index < short.count ? UInt64(short[index]) : 0) + carry
            result[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        result[long.count] = UInt32(carry)
        return BigUInt(limbs: result)
    }

    // -(lhs, rhs): lhs minus rhs; the caller guarantees lhs is not smaller.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction would be negative")
        var result = lhs.limbs
        var borrow: Int64 = 0
        for index in 0..<result.count {
            let difference = Int64(result[index]) - (index < rhs.limbs.count ? Int64(rhs.limbs[index]) : 0) - borrow
            // A negative difference wraps and borrows from the next limb.
            if difference < 0 {
                result[index] = UInt32(truncatingIfNeeded: difference + (1 << 32))
                borrow = 1
            } else {
                // No borrow; the difference fits the limb.
                result[index] = UInt32(difference)
                borrow = 0
            }
        }
        return BigUInt(limbs: result)
    }

    // *(lhs, rhs): The product, which needs at most both operands' limb counts together.
    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        lhs.limbs.withUnsafeBufferPointer { a in
            rhs.limbs.withUnsafeBufferPointer { b in
                result.withUnsafeMutableBufferPointer { out in
                    // Schoolbook multiplication; each partial product fits a 64-bit accumulator.
                    for i in 0..<a.count {
                        var carry: UInt64 = 0
                        let ai = UInt64(a[i])
                        for j in 0..<b.count {
                            let t = ai * UInt64(b[j]) + UInt64(out[i + j]) + carry
                            out[i + j] = UInt32(truncatingIfNeeded: t)
                            carry = t >> 32
                        }
                        out[i + b.count] = UInt32(carry)
                    }
                }
            }
        }
        return BigUInt(limbs: result)
    }

    // quotientAndRemainder(dividingBy divisor): Long division (Knuth's algorithm D).
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt division by zero")
        // A smaller dividend divides to zero.
        if self < divisor { return (BigUInt(), self) }
        // A single-limb divisor needs only the simple loop.
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var quotient = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let current = (remainder << 32) | UInt64(limbs[index])
                quotient[index] = UInt32(current / d)
                remainder = current % d
            }
            return (BigUInt(limbs: quotient), BigUInt(UInt64(remainder)))
        }
        let n = divisor.limbs.count
        let m = limbs.count - n
        // Normalize so the divisor's top limb has its high bit set.
        let shift = UInt32(divisor.limbs[n - 1].leadingZeroBitCount)
        let vn = Self.shiftedLimbs(divisor.limbs, by: shift, extra: 0)
        var un = Self.shiftedLimbs(limbs, by: shift, extra: 1)
        var quotient = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32
        for j in stride(from: m, through: 0, by: -1) {
            // Estimate the quotient limb from the top two limbs, then correct it at most twice.
            let numerator = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = numerator / UInt64(vn[n - 1])
            var rhat = numerator % UInt64(vn[n - 1])
            while qhat >= base || qhat * UInt64(vn[n - 2]) > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                // Once rhat overflows a limb the estimate is certainly small enough.
                if rhat >= base { break }
            }
            // Multiply and subtract the estimate from the running remainder.
            var borrow: Int64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(vn[i])
                let t = Int64(un[i + j]) - borrow - Int64(product & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = Int64(product >> 32) - (t >> 32)
            }
            let t = Int64(un[j + n]) - borrow
            un[j + n] = UInt32(truncatingIfNeeded: t)
            quotient[j] = UInt32(truncatingIfNeeded: qhat)
            // The estimate was one too large: add the divisor back.
            if t < 0 {
                quotient[j] &-= 1
                var carry: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(un[i + j]) + UInt64(vn[i]) + carry
                    un[i + j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + carry)
            }
        }
        // Undo the normalization shift to recover the remainder.
        var remainder = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let low = UInt64(un[i]) >> UInt64(shift)
            let high = shift == 0 ? 0 : UInt64(un[i + 1]) << UInt64(32 - shift)
            remainder[i] = UInt32(truncatingIfNeeded: low | high)
        }
        return (BigUInt(limbs: quotient), BigUInt(limbs: remainder))
    }

    // shiftedLimbs(limbs, by shift, extra): The limbs shifted left by shift bits, with extra
    // zero limbs appended to hold the overflow.
    private static func shiftedLimbs(_ limbs: [UInt32], by shift: UInt32, extra: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: limbs.count + extra)
        // A zero shift is a plain copy; shifting a 32-bit value by 32 is undefined.
        if shift == 0 {
            for (index, limb) in limbs.enumerated() { result[index] = limb }
            return result
        }
        var carry: UInt32 = 0
        for (index, limb) in limbs.enumerated() {
            result[index] = (limb << shift) | carry
            carry = limb >> (32 - shift)
        }
        // The final carry lands in the extra limb when one was requested.
        if extra > 0 { result[limbs.count] = carry }
        return result
    }

    // /(lhs, rhs): The quotient.
    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt { lhs.quotientAndRemainder(dividingBy: rhs).quotient }
    // %(lhs, rhs): The remainder.
    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt { lhs.quotientAndRemainder(dividingBy: rhs).remainder }

    // modPow(exponent, modulus): self to the exponent modulo modulus, by square and multiply.
    // Not constant time: the work depends on the exponent's bits.
    func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "BigUInt modPow with a zero modulus")
        // Everything is congruent to zero modulo one.
        if modulus == BigUInt(1) { return BigUInt() }
        var result = BigUInt(1)
        let base = self % modulus
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            // A set exponent bit multiplies the base in.
            if exponent.bit(at: index) { result = (result * base) % modulus }
        }
        return result
    }

    // subtractingMod(other, modulus): self minus other modulo modulus, both already reduced.
    func subtractingMod(_ other: BigUInt, modulus: BigUInt) -> BigUInt {
        // Borrow one modulus when the subtraction would go negative.
        self >= other ? self - other : (self + modulus) - other
    }
}
