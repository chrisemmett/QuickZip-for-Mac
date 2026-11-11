import Foundation

/// A streaming decoder for DEFLATE and Deflate64 (ZIP method 9).
///
/// Deflate64 differs from DEFLATE only in three ways: a 64 KiB window,
/// length code 285 meaning "3 plus 16 extra bits" instead of 258, and
/// distance codes 30 and 31 (14 extra bits each) for distances up to
/// 65,536. Compression.framework decodes only plain DEFLATE, so this
/// decoder exists for method 9; it also decodes plain DEFLATE, which is how
/// the tests check it against the framework.
///
/// Input arrives in chunks. Each block header and each symbol is decoded
/// as a unit: if the bytes for it are not all there yet, decoding rewinds to
/// the unit's start and waits for the next chunk.
final class DeflateDecoder: ZIPDecompressor {
    private struct NeedInput: Error {}

    private struct Huffman {
        static let fastBits = 9

        var counts = [UInt16](repeating: 0, count: 16)
        var symbols: [UInt16]
        /// Codes of up to `fastBits` bits decoded in one lookup: the symbol
        /// shifted left four, or'd with the code's length. Zero means the
        /// code is longer (or invalid), and decoding falls back to the slow path.
        var fast = [UInt16](repeating: 0, count: 1 << Huffman.fastBits)

        /// Builds a canonical code. Returns nil for an over-subscribed code.
        init?(lengths: ArraySlice<UInt8>) {
            symbols = [UInt16](repeating: 0, count: lengths.count)
            for length in lengths { counts[Int(length)] += 1 }
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= Int(counts[length])
                if left < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 17)
            for length in 1..<16 { offsets[length + 1] = offsets[length] + Int(counts[length]) }
            for (index, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[Int(length)]] = UInt16(index)
                offsets[Int(length)] += 1
            }

            // Canonical codes, in the bit order the stream reads them.
            var nextCode = [Int](repeating: 0, count: 17)
            var code = 0
            for length in 1..<16 {
                code = (code + (length == 1 ? 0 : Int(counts[length - 1]))) << 1
                nextCode[length] = code
            }
            for (symbol, length) in lengths.enumerated() where length != 0 && Int(length) <= Self.fastBits {
                let value = nextCode[Int(length)]
                nextCode[Int(length)] += 1
                var reversed = 0
                for bit in 0..<Int(length) where value & (1 << bit) != 0 { reversed |= 1 << (Int(length) - 1 - bit) }
                var index = reversed
                while index < fast.count {
                    fast[index] = UInt16(symbol << 4) | UInt16(length)
                    index += 1 << Int(length)
                }
            }
        }
    }

    private enum Phase {
        case blockHeader
        case stored(remaining: Int)
        case codes
        case finished
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Enough bytes for any one symbol (two codes of 15 bits and 30 extra
    /// bits is 60 bits), so a symbol decoded with this many buffered cannot
    /// run out of input.
    private static let symbolBytes = 8
    /// Enough for any dynamic block header (at most about 2,300 bits).
    private static let headerBytes = 320
    private static let outputChunk = 64 * 1024

    private let path: String
    private let isDeflate64: Bool
    private let windowSize: Int
    private let window: UnsafeMutablePointer<UInt8>
    private var windowPosition = 0
    private var produced = 0
    /// Decoded bytes waiting to be handed on. The longest match is 65,538
    /// bytes, so this has room for one more after a flush is due.
    private let pending: UnsafeMutablePointer<UInt8>
    private var pendingCount = 0

    private var buffer: [UInt8] = []
    private var position = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0

    private var phase = Phase.blockHeader
    private var isLastBlock = false
    private var literalCode: Huffman?
    private var distanceCode: Huffman?

    init(path: String, isDeflate64: Bool) {
        self.path = path
        self.isDeflate64 = isDeflate64
        windowSize = isDeflate64 ? 1 << 16 : 1 << 15
        window = .allocate(capacity: windowSize)
        window.initialize(repeating: 0, count: windowSize)
        pending = .allocate(capacity: Self.outputChunk + 70_000)
    }

    deinit {
        window.deallocate()
        pending.deallocate()
    }

    /// Whether the final block has been decoded.
    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// The input bytes after the end of the stream (a gzip trailer, the
    /// next member), once `isFinished`.
    func takeUnconsumed() -> Data {
        // Whole bytes the bit buffer read ahead belong to what follows.
        position -= bitCount / 8
        bitBuffer = 0
        bitCount = 0
        let rest = Data(buffer[position...])
        buffer = []
        position = 0
        return rest
    }

    private func corrupt(_ reason: String = "the compressed data is invalid") -> ArchiveError {
        .corruptData(path: path, reason: reason)
    }

    // MARK: Streaming

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        if case .finished = phase { return }
        // Once the stream ends, whatever follows stays in the buffer for
        // `takeUnconsumed`.
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
        buffer.append(contentsOf: input)

        decoding: while true {
            switch phase {
            case .finished:
                break decoding

            case .blockHeader:
                let available = buffer.count - position
                if available < Self.headerBytes && !isFinal { break decoding }
                let snapshot = (position, bitBuffer, bitCount)
                do {
                    try readBlockHeader()
                } catch is NeedInput {
                    (position, bitBuffer, bitCount) = snapshot
                    if isFinal { throw corrupt("the compressed data ends unexpectedly") }
                    break decoding
                }

            case .stored(let remaining):
                let available = buffer.count - position
                if remaining == 0 {
                    phase = isLastBlock ? .finished : .blockHeader
                    continue
                }
                if available == 0 {
                    if isFinal { throw corrupt("the compressed data ends unexpectedly") }
                    break decoding
                }
                let count = min(remaining, available)
                for index in position..<(position + count) {
                    put(buffer[index])
                    if pendingCount >= Self.outputChunk { try flush(into: output, force: false) }
                }
                position += count
                phase = .stored(remaining: remaining - count)
                try flush(into: output, force: false)

            case .codes:
                // Decode symbols while a whole one is certain to be there.
                while true {
                    if buffer.count - position < Self.symbolBytes && !isFinal { break decoding }
                    do {
                        if try decodeSymbol() { continue decoding }
                    } catch is NeedInput {
                        throw corrupt("the compressed data ends unexpectedly")
                    }
                    if pendingCount >= Self.outputChunk { try flush(into: output, force: false) }
                }
            }
            try flush(into: output, force: false)
        }
        try flush(into: output, force: true)

        if isFinal {
            guard case .finished = phase else { throw corrupt("the compressed data ends unexpectedly") }
        }
    }

    private func flush(into output: (Data) throws -> Void, force: Bool) throws {
        guard pendingCount > 0, force || pendingCount >= Self.outputChunk else { return }
        let chunk = Data(bytes: pending, count: pendingCount)
        pendingCount = 0
        try output(chunk)
    }

    // MARK: Bits

    private func bits(_ count: Int) throws -> Int {
        while bitCount < count {
            guard position < buffer.count else { throw NeedInput() }
            bitBuffer |= UInt64(buffer[position]) << UInt64(bitCount)
            position += 1
            bitCount += 8
        }
        let value = Int(bitBuffer & ((1 << UInt64(count)) - 1))
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    private func decode(_ code: Huffman) throws -> Int {
        // Most codes are short: look one up from the next few bits when
        // they are all there.
        while bitCount < Huffman.fastBits, position < buffer.count {
            bitBuffer |= UInt64(buffer[position]) << UInt64(bitCount)
            position += 1
            bitCount += 8
        }
        if bitCount >= Huffman.fastBits {
            let entry = code.fast[Int(bitBuffer & ((1 << UInt64(Huffman.fastBits)) - 1))]
            if entry != 0 {
                let length = Int(entry & 0xF)
                bitBuffer >>= UInt64(length)
                bitCount -= length
                return Int(entry >> 4)
            }
        }
        var value = 0
        var first = 0
        var index = 0
        for length in 1..<16 {
            value |= try bits(1)
            let count = Int(code.counts[length])
            if value - count < first { return Int(code.symbols[index + (value - first)]) }
            index += count
            first += count
            first <<= 1
            value <<= 1
        }
        throw corrupt()
    }

    // MARK: Output

    private func put(_ byte: UInt8) {
        window[windowPosition] = byte
        windowPosition = (windowPosition + 1) & (windowSize - 1)
        produced += 1
        pending[pendingCount] = byte
        pendingCount += 1
    }

    // MARK: Blocks

    private func readBlockHeader() throws {
        isLastBlock = try bits(1) == 1
        switch try bits(2) {
        case 0:
            // Discard the rest of the current byte, then give back whole
            // bytes the bit buffer read ahead.
            _ = try bits(bitCount % 8)
            position -= bitCount / 8
            bitBuffer = 0
            bitCount = 0
            guard buffer.count - position >= 4 else { throw NeedInput() }
            let length = Int(buffer[position]) | Int(buffer[position + 1]) << 8
            let complement = Int(buffer[position + 2]) | Int(buffer[position + 3]) << 8
            position += 4
            guard length == (~complement & 0xFFFF) else { throw corrupt("a stored block has the wrong length") }
            phase = .stored(remaining: length)
        case 1:
            var lengths = [UInt8](repeating: 8, count: 288)
            for index in 144..<256 { lengths[index] = 9 }
            for index in 256..<280 { lengths[index] = 7 }
            literalCode = Huffman(lengths: lengths[...])
            distanceCode = Huffman(lengths: [UInt8](repeating: 5, count: 32)[...])
            phase = .codes
        case 2:
            try readDynamicTables()
            phase = .codes
        default:
            throw corrupt()
        }
    }

    private func readDynamicTables() throws {
        let literalCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeLengthCount = try bits(4) + 4
        guard literalCount <= 286, distanceCount <= (isDeflate64 ? 32 : 30) else { throw corrupt() }

        var lengths = [UInt8](repeating: 0, count: 320)
        for index in 0..<codeLengthCount {
            lengths[Self.codeLengthOrder[index]] = UInt8(try bits(3))
        }
        guard let codeLengthCode = Huffman(lengths: lengths[0..<19]) else { throw corrupt() }
        lengths = [UInt8](repeating: 0, count: 320)

        var index = 0
        while index < literalCount + distanceCount {
            var symbol = try decode(codeLengthCode)
            if symbol < 16 {
                lengths[index] = UInt8(symbol)
                index += 1
            } else {
                var length: UInt8 = 0
                if symbol == 16 {
                    guard index > 0 else { throw corrupt() }
                    length = lengths[index - 1]
                    symbol = 3 + (try bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try bits(3))
                } else {
                    symbol = 11 + (try bits(7))
                }
                guard index + symbol <= literalCount + distanceCount else { throw corrupt() }
                for _ in 0..<symbol {
                    lengths[index] = length
                    index += 1
                }
            }
        }
        guard lengths[256] != 0 else { throw corrupt() }
        guard let literals = Huffman(lengths: lengths[0..<literalCount]),
              let distances = Huffman(lengths: lengths[literalCount..<(literalCount + distanceCount)])
        else { throw corrupt() }
        literalCode = literals
        distanceCode = distances
    }

    /// Decodes one symbol and its match, if any. Returns true at the end
    /// of the block.
    private func decodeSymbol() throws -> Bool {
        guard let literalCode, let distanceCode else { throw corrupt() }
        var symbol = try decode(literalCode)
        if symbol < 256 {
            put(UInt8(symbol))
            return false
        }
        if symbol == 256 {
            phase = isLastBlock ? .finished : .blockHeader
            return true
        }
        symbol -= 257
        guard symbol < 29 else { throw corrupt() }
        let length: Int
        if symbol == 28 && isDeflate64 {
            length = 3 + (try bits(16))
        } else {
            length = Self.lengthBase[symbol] + (try bits(Self.lengthExtra[symbol]))
        }
        let distanceSymbol = try decode(distanceCode)
        guard distanceSymbol < (isDeflate64 ? 32 : 30) else { throw corrupt() }
        let distance = Self.distanceBase[distanceSymbol] + (try bits(Self.distanceExtra[distanceSymbol]))
        guard distance <= min(produced, windowSize) else { throw corrupt("a repeated section points before the start") }
        var source = (windowPosition - distance + windowSize) & (windowSize - 1)
        for _ in 0..<length {
            put(window[source])
            source = (source + 1) & (windowSize - 1)
        }
        return false
    }
}
