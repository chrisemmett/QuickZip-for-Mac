import Foundation
#if canImport(Compression)
import Compression
#endif

/// Decompresses a whole-archive stream (gzip, xz) a chunk at a time.
protocol WholeStreamDecoder: AnyObject {
    /// Feeds the next chunk of compressed bytes; decompressed bytes go to
    /// `output`. `isFinal` marks the last chunk, after which the stream must
    /// be complete.
    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws
}

#if canImport(Compression)

/// A `compression_stream` for decoding, which reports where the stream
/// ended so that what follows (a gzip trailer, a second member) can be read.
final class CompressionStreamDecoder {
    private static let outputCapacity = 256 * 1024

    private let algorithm: compression_algorithm
    private var stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: CompressionStreamDecoder.outputCapacity)
    private let path: String

    init(algorithm: compression_algorithm, path: String) throws {
        self.algorithm = algorithm
        self.path = path
        try start()
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }

    private func start() throws {
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.io("Could not initialise the decompressor.")
        }
    }

    /// Returns how many input bytes were left over if the stream ended in
    /// this chunk, or nil if it needs more input.
    func process(_ input: Data, isFinal: Bool, emit: (Data) throws -> Void) throws -> Int? {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            var placeholder: UInt8 = 0
            return try withUnsafePointer(to: &placeholder) { empty in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? empty
                stream.pointee.src_size = raw.count
                let flags = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                while true {
                    let before = stream.pointee.src_size
                    stream.pointee.dst_ptr = output
                    stream.pointee.dst_size = Self.outputCapacity
                    let status = compression_stream_process(stream, flags)
                    let produced = Self.outputCapacity - stream.pointee.dst_size
                    if produced > 0 { try emit(Data(bytes: output, count: produced)) }
                    switch status {
                    case COMPRESSION_STATUS_END:
                        return stream.pointee.src_size
                    case COMPRESSION_STATUS_OK:
                        // Output can be pending even when the buffer was not
                        // filled: keep going until a call yields nothing.
                        if produced == 0 && stream.pointee.src_size == before { return nil }
                    default:
                        throw ArchiveError.corruptData(path: path, reason: "the compressed data is invalid")
                    }
                }
            }
        }
    }
}

/// gzip (RFC 1952): a header, a raw DEFLATE stream, and a trailer holding
/// the CRC-32 and length, repeated for each member. The checksum is
/// verified, so a damaged download is reported rather than half-listed.
///
/// The DEFLATE stream is decoded with `DeflateDecoder` rather than the
/// system's: Compression.framework consumes all the input it is given even
/// after the stream ends, so it cannot say where the trailer or the next
/// member starts.
final class GzipStreamDecoder: WholeStreamDecoder {
    private enum State {
        case header
        case body
        case trailer
        case betweenMembers
    }

    private let path: String
    private var inflater: DeflateDecoder
    private var state = State.header
    private var pending = Data()
    private var crc = CRC32()
    private var length: UInt32 = 0

    init(path: String) throws {
        self.path = path
        inflater = DeflateDecoder(path: path, isDeflate64: false)
    }

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        var data = pending + input
        pending = Data()
        loop: while true {
            switch state {
            case .header:
                switch try headerLength(of: data) {
                case .some(let count):
                    data.removeFirst(count)
                    state = .body
                    crc = CRC32()
                    length = 0
                case .none:
                    pending = data
                    break loop
                }
            case .body:
                guard !data.isEmpty else { break loop }
                try inflater.process(data, isFinal: isFinal) { chunk in
                    crc.update(chunk)
                    length &+= UInt32(truncatingIfNeeded: chunk.count)
                    try output(chunk)
                }
                data = Data()
                if inflater.isFinished {
                    data = inflater.takeUnconsumed()
                    state = .trailer
                } else {
                    break loop
                }
            case .trailer:
                guard data.count >= 8 else { pending = data; break loop }
                let bytes = [UInt8](data.prefix(8))
                let storedCRC = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                let storedLength = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                guard storedCRC == crc.value, storedLength == length else {
                    throw ArchiveError.corruptData(path: path, reason: "its checksum does not match")
                }
                data.removeFirst(8)
                inflater = DeflateDecoder(path: path, isDeflate64: false)
                state = .betweenMembers
            case .betweenMembers:
                // Another member, or padding to ignore.
                if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
                    state = .header
                } else if data.count < 2 && !isFinal {
                    pending = data
                    break loop
                } else {
                    data = Data()
                    break loop
                }
            }
        }
        if isFinal, state != .betweenMembers {
            throw ArchiveError.corruptData(path: path, reason: "the compressed data ends unexpectedly")
        }
    }

    /// The size of the gzip header at the start of `data`, or nil if more
    /// bytes are needed to tell.
    private func headerLength(of data: Data) throws -> Int? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 10 else { return nil }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ArchiveError.corruptData(path: path, reason: "it is not gzip data")
        }
        let flags = bytes[3]
        var position = 10
        if flags & 0x04 != 0 {
            guard bytes.count >= position + 2 else { return nil }
            position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            guard let end = bytes[min(position, bytes.count)...].firstIndex(of: 0) else {
                if bytes.count >= 4096 { throw ArchiveError.corruptData(path: path, reason: "its header is implausibly long") }
                return nil
            }
            position = end + 1
        }
        if flags & 0x02 != 0 { position += 2 }
        return bytes.count >= position ? position : nil
    }
}

/// xz, through Compression.framework's `COMPRESSION_LZMA`, which reads the
/// `.xz` container (the framework does not read raw LZMA; see
/// `LZMADecompressor`). The container's own checks cover integrity.
final class XZStreamDecoder: WholeStreamDecoder {
    private let path: String
    private var decoder: CompressionStreamDecoder
    private var ended = false

    init(path: String) throws {
        self.path = path
        decoder = try CompressionStreamDecoder(algorithm: COMPRESSION_LZMA, path: path)
    }

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        var data = input
        while !data.isEmpty || (isFinal && !ended) {
            if ended {
                // A second stream, or the zero padding xz allows between them.
                data = Data(data.drop { $0 == 0 })
                if data.isEmpty { return }
                decoder = try CompressionStreamDecoder(algorithm: COMPRESSION_LZMA, path: path)
                ended = false
            }
            let leftover = try decoder.process(data, isFinal: isFinal, emit: output)
            if let leftover {
                ended = true
                data = Data(data.suffix(leftover))
            } else {
                return
            }
        }
        if isFinal && !ended {
            throw ArchiveError.corruptData(path: path, reason: "the compressed data ends unexpectedly")
        }
    }
}

#endif
