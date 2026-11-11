#if !canImport(Compression)

/// A small, portable RFC 1951 (raw DEFLATE) decoder.
///
/// Only compiled where Compression.framework is unavailable, so that
/// ArchiveKit builds and its tests run on Linux. Structured after zlib's
/// reference `puff.c`: simple and strict rather than fast.
enum Inflater {
    enum Failure: Error {
        case truncated
        case invalid(String)
    }

    static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var state = State(input: input)
        try state.run()
        return state.output
    }

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        /// Builds a canonical code from per-symbol code lengths. Returns 0
        /// for a complete code, a positive value for an incomplete code and
        /// a negative value for an over-subscribed (invalid) code.
        init(lengths: ArraySlice<Int>, result: inout Int) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths { count[length] += 1 }
            if count[0] == lengths.count {
                result = 0
                return
            }
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= count[length]
                if left < 0 {
                    result = left
                    return
                }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 {
                offsets[length + 1] = offsets[length] + count[length]
            }
            for (index, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = index
                offsets[length] += 1
            }
            result = left
        }
    }

    private struct State {
        let input: [UInt8]
        var position = 0
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(input: [UInt8]) {
            self.input = input
        }

        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.count else { throw Failure.truncated }
                value |= UInt32(input[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            bitBuffer = need == 32 ? 0 : value >> UInt32(need)
            bitCount -= need
            return Int(value & ((1 << UInt32(need)) - 1))
        }

        mutating func run() throws {
            var isLast = false
            while !isLast {
                isLast = try bits(1) == 1
                switch try bits(2) {
                case 0: try stored()
                case 1: try fixed()
                case 2: try dynamic()
                default: throw Failure.invalid("invalid block type")
                }
            }
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw Failure.truncated }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            position += 4
            guard length == (~complement & 0xFFFF) else { throw Failure.invalid("stored block length mismatch") }
            guard position + length <= input.count else { throw Failure.truncated }
            output.append(contentsOf: input[position..<(position + length)])
            position += length
        }

        mutating func decode(_ huffman: Huffman) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                code |= try bits(1)
                let count = huffman.count[length]
                if code - count < first {
                    return huffman.symbol[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalid("invalid Huffman code")
        }

        static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        mutating func codes(_ lengthCode: Huffman, _ distanceCode: Huffman) throws {
            while true {
                var symbol = try decode(lengthCode)
                if symbol < 256 {
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return
                } else {
                    symbol -= 257
                    guard symbol < 29 else { throw Failure.invalid("invalid length symbol") }
                    let length = Self.lengthBase[symbol] + (try bits(Self.lengthExtra[symbol]))
                    let distanceSymbol = try decode(distanceCode)
                    guard distanceSymbol < 30 else { throw Failure.invalid("invalid distance symbol") }
                    let distance = Self.distanceBase[distanceSymbol] + (try bits(Self.distanceExtra[distanceSymbol]))
                    guard distance <= output.count else { throw Failure.invalid("distance too far back") }
                    var from = output.count - distance
                    for _ in 0..<length {
                        output.append(output[from])
                        from += 1
                    }
                }
            }
        }

        mutating func fixed() throws {
            var lengths = [Int](repeating: 8, count: 288)
            for i in 144..<256 { lengths[i] = 9 }
            for i in 256..<280 { lengths[i] = 7 }
            var result = 0
            let lengthCode = Huffman(lengths: lengths[...], result: &result)
            let distanceCode = Huffman(lengths: [Int](repeating: 5, count: 30)[...], result: &result)
            try codes(lengthCode, distanceCode)
        }

        mutating func dynamic() throws {
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            let lengthCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeCount = try bits(4) + 4
            guard lengthCount <= 286, distanceCount <= 30 else { throw Failure.invalid("bad code counts") }

            var lengths = [Int](repeating: 0, count: 320)
            for i in 0..<codeCount {
                lengths[order[i]] = try bits(3)
            }
            var result = 0
            let codeLengthCode = Huffman(lengths: lengths[0..<19], result: &result)
            guard result == 0 else { throw Failure.invalid("incomplete code length code") }

            var index = 0
            while index < lengthCount + distanceCount {
                var symbol = try decode(codeLengthCode)
                if symbol < 16 {
                    lengths[index] = symbol
                    index += 1
                } else {
                    var length = 0
                    if symbol == 16 {
                        guard index > 0 else { throw Failure.invalid("repeat with no previous length") }
                        length = lengths[index - 1]
                        symbol = 3 + (try bits(2))
                    } else if symbol == 17 {
                        symbol = 3 + (try bits(3))
                    } else {
                        symbol = 11 + (try bits(7))
                    }
                    guard index + symbol <= lengthCount + distanceCount else { throw Failure.invalid("too many lengths") }
                    for _ in 0..<symbol {
                        lengths[index] = length
                        index += 1
                    }
                }
            }
            guard lengths[256] != 0 else { throw Failure.invalid("no end-of-block code") }

            let lengthCode = Huffman(lengths: lengths[0..<lengthCount], result: &result)
            guard result >= 0, result == 0 || lengthCount == lengthCode.count[0] + lengthCode.count[1] else {
                throw Failure.invalid("bad literal/length code")
            }
            let distanceCode = Huffman(lengths: lengths[lengthCount..<(lengthCount + distanceCount)], result: &result)
            guard result >= 0, result == 0 || distanceCount == distanceCode.count[0] + distanceCode.count[1] else {
                throw Failure.invalid("bad distance code")
            }
            try codes(lengthCode, distanceCode)
        }
    }
}

#endif
