import Foundation

/// Reads a tar archive from a stream of decompressed bytes, writing each
/// entry's data to a spool as it passes and keeping the index (HLD §18.4).
final class TarStreamParser {
    /// Thrown to stop reading once the archive's end, or damage, is found.
    struct Stop: Error {}

    private enum State {
        case header
        case metadata(kind: UInt8, size: Int)
        case data(remaining: UInt64, padding: Int)
        case skip(Int)
        case ended
    }

    private(set) var indexer = TarIndexer()
    private(set) var warnings: [String] = []
    private(set) var totalOut: UInt64 = 0

    private let spool: ArchiveSpool
    private let limits: ArchiveLimits
    private var state = State.header
    private var buffer = Data()
    private var sawHeader = false
    private var currentWritten: UInt64 = 0
    private var currentDeclared: UInt64 = 0
    private var bytesSinceRoomCheck: UInt64 = 0

    init(spool: ArchiveSpool, limits: ArchiveLimits) {
        self.spool = spool
        self.limits = limits
    }

    func feed(_ chunk: Data) throws {
        totalOut &+= UInt64(chunk.count)
        var rest = chunk[...]
        while !rest.isEmpty {
            switch state {
            case .ended:
                return

            case .header:
                let take = min(TarHeader.blockSize - buffer.count, rest.count)
                buffer.append(rest.prefix(take))
                rest = rest.dropFirst(take)
                if buffer.count == TarHeader.blockSize {
                    let block = [UInt8](buffer)
                    buffer = Data()
                    try handleHeader(block)
                }

            case .metadata(let kind, let size):
                let take = min(size - buffer.count, rest.count)
                buffer.append(rest.prefix(take))
                rest = rest.dropFirst(take)
                if buffer.count == size {
                    indexer.metadata(kind: kind, data: [UInt8](buffer))
                    buffer = Data()
                    let padding = Self.padding(UInt64(size))
                    state = padding > 0 ? .skip(padding) : .header
                }

            case .data(let remaining, let padding):
                let take = Int(min(UInt64(rest.count), remaining))
                try write(rest.prefix(take))
                rest = rest.dropFirst(take)
                if UInt64(take) == remaining {
                    state = padding > 0 ? .skip(padding) : .header
                } else {
                    state = .data(remaining: remaining - UInt64(take), padding: padding)
                }

            case .skip(let count):
                let take = min(count, rest.count)
                rest = rest.dropFirst(take)
                state = take == count ? .header : .skip(count - take)
            }
        }
    }

    /// Call when the stream has ended, to note anything left unfinished.
    func finish() {
        switch state {
        case .ended:
            break
        case .header where buffer.isEmpty:
            break
        case .data:
            indexer.truncateLast(to: currentWritten)
            warnings.append(String(localized: "The archive ends in the middle of an item, which is cut short.", bundle: .archiveKitStrings))
        default:
            warnings.append(String(localized: "The archive ends unexpectedly.", bundle: .archiveKitStrings))
        }
    }

    private static func padding(_ size: UInt64) -> Int {
        Int((UInt64(TarHeader.blockSize) - size % UInt64(TarHeader.blockSize)) % UInt64(TarHeader.blockSize))
    }

    /// Bytes to skip for `size` bytes of data and their padding. A pax
    /// `size` record can declare up to UInt64.max, so this saturates
    /// instead of overflowing; skipping Int.max bytes consumes the rest of
    /// any stream.
    private static func skipLength(_ size: UInt64) -> Int {
        let (total, overflow) = Int(clamping: size).addingReportingOverflow(padding(size))
        return overflow ? Int.max : total
    }

    private func handleHeader(_ block: [UInt8]) throws {
        let next: TarIndexer.Next
        do {
            next = try indexer.header(block)
        } catch {
            if !sawHeader { throw ArchiveError.notAnArchive }
            warnings.append(String(localized: "The archive is damaged after \(indexer.records.count) items; the rest cannot be listed.", bundle: .archiveKitStrings))
            state = .ended
            throw Stop()
        }
        sawHeader = true
        switch next {
        case .end:
            state = .ended
            throw Stop()
        case .metadata(let kind, let size):
            state = size == 0 ? .header : .metadata(kind: kind, size: size)
        case .skip(let dataSize):
            let total = Self.skipLength(dataSize)
            state = total > 0 ? .skip(total) : .header
        case .entry(let dataSize):
            currentWritten = 0
            currentDeclared = dataSize
            // An absurd size is listed (and refused when read) but not kept.
            if dataSize > limits.maximumEntrySize {
                indexer.commit(dataOffset: 0)
                state = .skip(Self.skipLength(dataSize))
            } else {
                indexer.commit(dataOffset: spool.size)
                state = dataSize > 0 ? .data(remaining: dataSize, padding: Self.padding(dataSize)) : .header
            }
        }
    }

    private func write(_ data: Data) throws {
        bytesSinceRoomCheck += UInt64(data.count)
        if bytesSinceRoomCheck >= 64 << 20 {
            bytesSinceRoomCheck = 0
            guard ArchiveSpool.hasRoom(for: 64 << 20) else {
                throw ArchiveError.insufficientDiskSpace(required: spool.size + (64 << 20), available: 0)
            }
        }
        try spool.append(Data(data))
        currentWritten += UInt64(data.count)
    }
}
