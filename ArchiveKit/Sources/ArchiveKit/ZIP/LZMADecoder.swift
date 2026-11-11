import Foundation

/// A streaming LZMA decoder for ZIP method 14.
///
/// Compression.framework's `COMPRESSION_LZMA` decodes the `.xz` container
/// and neither the raw LZMA ZIP stores nor the `.lzma` format, and a raw
/// LZMA1 stream cannot be wrapped in an `.xz` file (which carries LZMA2),
/// so this is a native decoder, written from the public LZMA specification.
///
/// A ZIP method 14 entry starts with a four-byte header (version, then the
/// size of the properties), five bytes of properties (`lc`/`lp`/`pb` and the
/// dictionary size), and then the range-coded stream, which may end with an
/// end marker. The entry's uncompressed size is known from the directory,
/// and decoding stops there.
///
/// One symbol needs at most about 60 input bytes, so a symbol is decoded
/// only once that many are buffered (or the entry's last chunk has
/// arrived), which makes rewinding unnecessary.
final class LZMADecompressor: ZIPDecompressor {
    private static let symbolBytes = 80
    private static let outputChunk = 64 * 1024
    private static let maximumWindow = 1 << 28

    private let path: String
    private let expectedSize: UInt64
    private var produced: UInt64 = 0
    private var buffer: [UInt8] = []
    private var position = 0
    private var isFinished = false

    // Header
    private var isConfigured = false
    private var literalContextBits = 0
    private var literalPositionBits = 0
    private var positionBits = 0

    // Range decoder
    private var isRangeStarted = false
    private var range: UInt32 = 0xFFFF_FFFF
    private var code: UInt32 = 0

    // Probabilities, in one array.
    private var probabilities = UnsafeMutablePointer<UInt16>.allocate(capacity: 1)
    private var probabilityCount = 1
    private var isMatch = 0, isRep = 0, isRepG0 = 0, isRepG1 = 0, isRepG2 = 0, isRep0Long = 0
    private var posSlot = 0, posSpecial = 0, align = 0
    private var lengthCoder = 0, repLengthCoder = 0, literal = 0

    // Decoder state
    private var state = 0
    private var rep0: UInt32 = 0, rep1: UInt32 = 0, rep2: UInt32 = 0, rep3: UInt32 = 0
    private var window = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var windowSize = 1
    private var windowMask = 0
    private var windowPosition = 0
    private var pendingOutput: [UInt8] = []

    deinit {
        probabilities.deallocate()
        window.deallocate()
    }

    init(path: String, uncompressedSize: UInt64) {
        self.path = path
        self.expectedSize = uncompressedSize
        pendingOutput.reserveCapacity(Self.outputChunk + 1024)
    }

    private func corrupt(_ reason: String = "the compressed data is invalid") -> ArchiveError {
        .corruptData(path: path, reason: reason)
    }

    // MARK: Streaming

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        guard !isFinished else { return }
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
        buffer.append(contentsOf: input)

        if !isConfigured {
            guard buffer.count >= 9 else {
                if isFinal { throw corrupt("the compressed data ends unexpectedly") }
                return
            }
            try configure()
        }
        if !isRangeStarted {
            guard buffer.count - position >= 5 else {
                if isFinal { throw corrupt("the compressed data ends unexpectedly") }
                return
            }
            guard buffer[position] == 0 else { throw corrupt() }
            code = UInt32(buffer[position + 1]) << 24 | UInt32(buffer[position + 2]) << 16
                | UInt32(buffer[position + 3]) << 8 | UInt32(buffer[position + 4])
            position += 5
            isRangeStarted = true
        }

        while produced < expectedSize {
            if buffer.count - position < Self.symbolBytes && !isFinal { break }
            if try decodeSymbol() { break }
            if pendingOutput.count >= Self.outputChunk { try flush(into: output) }
        }
        try flush(into: output)

        if produced >= expectedSize {
            isFinished = true
        } else if isFinal {
            // An end marker before the declared size, or no data left.
            throw corrupt("the compressed data ends unexpectedly")
        }
    }

    private func flush(into output: (Data) throws -> Void) throws {
        guard !pendingOutput.isEmpty else { return }
        let chunk = Data(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: true)
        try output(chunk)
    }

    // MARK: Setup

    private func configure() throws {
        // Version (2 bytes), properties size (2 bytes, 5), then the properties.
        guard buffer[2] == 5, buffer[3] == 0 else { throw corrupt() }
        var properties = Int(buffer[4])
        guard properties < 9 * 5 * 5 else { throw corrupt() }
        literalContextBits = properties % 9
        properties /= 9
        literalPositionBits = properties % 5
        positionBits = properties / 5
        let dictionarySize = UInt32(buffer[5]) | UInt32(buffer[6]) << 8 | UInt32(buffer[7]) << 16 | UInt32(buffer[8]) << 24
        position = 9

        // The window needs to reach back as far as the dictionary, but no
        // further than the entry is long.
        var size = 1 << 12
        let wanted = min(UInt64(max(dictionarySize, 1 << 12)), max(expectedSize, 1))
        while UInt64(size) < wanted && size < Self.maximumWindow { size <<= 1 }
        window.deallocate()
        window = .allocate(capacity: size)
        window.initialize(repeating: 0, count: size)
        windowSize = size
        windowMask = size - 1

        var total = 0
        func allocate(_ count: Int) -> Int {
            defer { total += count }
            return total
        }
        isMatch = allocate(12 << 4)
        isRep = allocate(12)
        isRepG0 = allocate(12)
        isRepG1 = allocate(12)
        isRepG2 = allocate(12)
        isRep0Long = allocate(12 << 4)
        posSlot = allocate(4 << 6)
        posSpecial = allocate(115)
        align = allocate(16)
        lengthCoder = allocate(Self.lengthCoderSize)
        repLengthCoder = allocate(Self.lengthCoderSize)
        literal = allocate(0x300 << (literalContextBits + literalPositionBits))
        probabilities.deallocate()
        probabilities = .allocate(capacity: total)
        probabilities.initialize(repeating: 1 << 10, count: total)
        probabilityCount = total
        isConfigured = true
    }

    // Length coder layout: choice, choice2, low[16][8], mid[16][8], high[256].
    private static let lengthCoderSize = 2 + 16 * 8 + 16 * 8 + 256

    // MARK: Range decoder

    @inline(__always)
    private func nextByte() throws -> UInt32 {
        guard position < buffer.count else { throw corrupt("the compressed data ends unexpectedly") }
        defer { position += 1 }
        return UInt32(buffer[position])
    }

    @inline(__always)
    private func normalize() throws {
        if range < 1 << 24 {
            range <<= 8
            code = code << 8 | (try nextByte())
        }
    }

    @inline(__always)
    private func bit(_ index: Int) throws -> Int {
        let probability = UInt32(probabilities[index])
        let bound = (range >> 11) * probability
        let result: Int
        if code < bound {
            range = bound
            probabilities[index] = UInt16(probability + ((2048 - probability) >> 5))
            result = 0
        } else {
            range -= bound
            code -= bound
            probabilities[index] = UInt16(probability - (probability >> 5))
            result = 1
        }
        try normalize()
        return result
    }

    private func directBits(_ count: Int) throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<count {
            range >>= 1
            code = code &- range
            let mask = 0 &- (code >> 31)
            code = code &+ (range & mask)
            guard code != range else { throw corrupt() }
            try normalize()
            result = result << 1 &+ mask &+ 1
        }
        return result
    }

    private func bitTree(_ base: Int, _ count: Int) throws -> Int {
        var m = 1
        for _ in 0..<count { m = m << 1 + (try bit(base + m)) }
        return m - (1 << count)
    }

    private func reverseBitTree(_ base: Int, _ count: Int) throws -> Int {
        var m = 1
        var symbol = 0
        for index in 0..<count {
            let b = try bit(base + m)
            m = m << 1 + b
            symbol |= b << index
        }
        return symbol
    }

    private func length(_ coder: Int, _ positionState: Int) throws -> Int {
        if try bit(coder) == 0 { return try bitTree(coder + 2 + positionState * 8, 3) }
        if try bit(coder + 1) == 0 { return 8 + (try bitTree(coder + 2 + 128 + positionState * 8, 3)) }
        return 16 + (try bitTree(coder + 2 + 256, 8))
    }

    // MARK: Output

    @inline(__always)
    private func put(_ byte: UInt8) {
        window[windowPosition] = byte
        windowPosition = (windowPosition + 1) & windowMask
        produced += 1
        pendingOutput.append(byte)
    }

    @inline(__always)
    private func byte(back distance: Int) -> UInt8 {
        window[(windowPosition - distance) & windowMask]
    }

    // MARK: Symbols

    /// Decodes one literal or match. Returns true at the end marker.
    private func decodeSymbol() throws -> Bool {
        let positionState = Int(produced) & ((1 << positionBits) - 1)

        if try bit(isMatch + (state << 4) + positionState) == 0 {
            try decodeLiteral()
            return false
        }

        var matchLength: Int
        if try bit(isRep + state) == 0 {
            // A new match: shift the distance history.
            rep3 = rep2; rep2 = rep1; rep1 = rep0
            matchLength = try length(lengthCoder, positionState)
            state = state < 7 ? 7 : 10
            rep0 = try decodeDistance(matchLength)
            if rep0 == 0xFFFF_FFFF { return true }
        } else {
            guard produced > 0 else { throw corrupt() }
            if try bit(isRepG0 + state) == 0 {
                if try bit(isRep0Long + (state << 4) + positionState) == 0 {
                    // A single byte from the last distance.
                    state = state < 7 ? 9 : 11
                    guard Int(rep0) < min(Int(produced), windowSize) else { throw corrupt() }
                    put(byte(back: Int(rep0) + 1))
                    return false
                }
            } else {
                let distance: UInt32
                if try bit(isRepG1 + state) == 0 {
                    distance = rep1
                } else {
                    if try bit(isRepG2 + state) == 0 {
                        distance = rep2
                    } else {
                        distance = rep3
                        rep3 = rep2
                    }
                    rep2 = rep1
                }
                rep1 = rep0
                rep0 = distance
            }
            matchLength = try length(repLengthCoder, positionState)
            state = state < 7 ? 8 : 11
        }

        matchLength += 2
        let distance = Int(rep0) + 1
        guard distance <= min(Int(clamping: produced), windowSize) else { throw corrupt() }
        let remaining = Int(clamping: expectedSize - produced)
        for _ in 0..<min(matchLength, remaining) {
            put(byte(back: distance))
        }
        return false
    }

    private func decodeLiteral() throws {
        let previous = produced > 0 ? Int(byte(back: 1)) : 0
        let literalState = ((Int(produced) & ((1 << literalPositionBits) - 1)) << literalContextBits)
            + (previous >> (8 - literalContextBits))
        let base = literal + 0x300 * literalState
        var symbol = 1
        if state >= 7 {
            guard Int(rep0) < min(Int(clamping: produced), windowSize) else { throw corrupt() }
            var matchByte = Int(byte(back: Int(rep0) + 1))
            repeat {
                let matchBit = (matchByte >> 7) & 1
                matchByte <<= 1
                let b = try bit(base + ((1 + matchBit) << 8) + symbol)
                symbol = symbol << 1 | b
                if matchBit != b { break }
            } while symbol < 0x100
        }
        while symbol < 0x100 {
            symbol = symbol << 1 | (try bit(base + symbol))
        }
        put(UInt8(truncatingIfNeeded: symbol))
        state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
    }

    private func decodeDistance(_ length: Int) throws -> UInt32 {
        let lengthState = min(length, 3)
        let slot = try bitTree(posSlot + lengthState * 64, 6)
        if slot < 4 { return UInt32(slot) }
        let directBitCount = (slot >> 1) - 1
        var distance = UInt32(2 | (slot & 1)) << UInt32(directBitCount)
        if slot < 14 {
            distance &+= UInt32(try reverseBitTree(posSpecial + Int(distance) - slot, directBitCount))
        } else {
            distance &+= (try directBits(directBitCount - 4)) << 4
            distance &+= UInt32(try reverseBitTree(align, 4))
        }
        return distance
    }
}
