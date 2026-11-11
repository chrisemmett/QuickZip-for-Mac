import Foundation
#if canImport(Compression)
import Compression
#endif

/// Incrementally turns compressed bytes into uncompressed bytes.
///
/// Input arrives in bounded chunks and output is emitted in bounded chunks,
/// so memory use stays flat regardless of entry size (HLD §7, §18.5).
protocol ZIPDecompressor: AnyObject {
    /// Feeds the next chunk of compressed input. `isFinal` marks the last
    /// chunk; the stream must be complete once it has been processed.
    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws
}

enum ZIPDecompressorFactory {
    static func make(for entry: ArchiveEntry) throws -> ZIPDecompressor {
        let path = entry.path
        switch entry.compressionMethod {
        case .stored:
            return StoredDecompressor()
        case .deflate:
            #if canImport(Compression)
            return try CompressionFrameworkInflater(path: path)
            #else
            return BufferedInflater(path: path)
            #endif
        case .deflate64:
            return DeflateDecoder(path: path, isDeflate64: true)
        case .lzma:
            return LZMADecompressor(path: path, uncompressedSize: entry.uncompressedSize)
        default:
            throw ArchiveError.unsupportedCompressionMethod(path: path, method: entry.compressionMethod)
        }
    }
}

/// Method 0: the data is not compressed.
final class StoredDecompressor: ZIPDecompressor {
    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        if !input.isEmpty { try output(input) }
    }
}

#if canImport(Compression)

/// Method 8 via Compression.framework. `COMPRESSION_ZLIB` is raw DEFLATE
/// (RFC 1951) with no zlib header, which is exactly what ZIP stores.
final class CompressionFrameworkInflater: ZIPDecompressor {
    private static let outputCapacity = 64 * 1024

    private let path: String
    private let stream: UnsafeMutablePointer<compression_stream>
    private let outputBuffer: UnsafeMutablePointer<UInt8>
    private var isFinished = false

    init(path: String) throws {
        self.path = path
        stream = .allocate(capacity: 1)
        outputBuffer = .allocate(capacity: Self.outputCapacity)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            outputBuffer.deallocate()
            throw ArchiveError.io("Could not initialise the decompressor.")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        outputBuffer.deallocate()
    }

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        // Anything after the end of the DEFLATE stream is padding we ignore;
        // the caller still checks the final size and CRC.
        guard !isFinished else { return }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var placeholder: UInt8 = 0
            try withUnsafePointer(to: &placeholder) { emptyInput in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? emptyInput
                stream.pointee.src_size = raw.count

                let flags = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                while true {
                    stream.pointee.dst_ptr = outputBuffer
                    stream.pointee.dst_size = Self.outputCapacity

                    let status = compression_stream_process(stream, flags)
                    let produced = Self.outputCapacity - stream.pointee.dst_size
                    if produced > 0 {
                        try output(Data(bytes: outputBuffer, count: produced))
                    }

                    switch status {
                    case COMPRESSION_STATUS_END:
                        isFinished = true
                        return
                    case COMPRESSION_STATUS_OK:
                        // A full output buffer may mean more output is
                        // pending; otherwise stop once input is consumed.
                        if produced < Self.outputCapacity && stream.pointee.src_size == 0 {
                            return
                        }
                    default:
                        throw ArchiveError.corruptData(path: path, reason: "the compressed data is invalid")
                    }
                }
            }
        }

        if isFinal && !isFinished {
            throw ArchiveError.corruptData(path: path, reason: "the compressed data ends unexpectedly")
        }
    }
}

#else

/// Method 8 on platforms without Compression.framework (Linux CI). It
/// buffers the compressed input, which is bounded by the entry's compressed
/// size, and decodes it with the portable `Inflater`. The app itself always
/// uses `CompressionFrameworkInflater`.
final class BufferedInflater: ZIPDecompressor {
    private let path: String
    private var buffer: [UInt8] = []

    init(path: String) {
        self.path = path
    }

    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        buffer.append(contentsOf: input)
        guard isFinal else { return }

        let decoded: [UInt8]
        do {
            decoded = try Inflater.inflate(buffer)
        } catch Inflater.Failure.truncated {
            throw ArchiveError.corruptData(path: path, reason: "the compressed data ends unexpectedly")
        } catch {
            throw ArchiveError.corruptData(path: path, reason: "the compressed data is invalid")
        }
        buffer = []

        let chunkSize = 64 * 1024
        var start = 0
        while start < decoded.count {
            let end = min(start + chunkSize, decoded.count)
            try output(Data(decoded[start..<end]))
            start = end
        }
    }
}

#endif
