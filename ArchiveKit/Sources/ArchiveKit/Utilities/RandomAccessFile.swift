import Foundation

/// Positioned, bounds-checked reads from a file.
///
/// Not thread-safe; it is owned by a single actor.
final class RandomAccessFile {
    let url: URL
    let size: UInt64
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
        } catch {
            throw ArchiveError.io("“\(url.lastPathComponent)” could not be opened: \(error.localizedDescription)")
        }
    }

    deinit {
        try? handle.close()
    }

    /// Reads exactly `count` bytes starting at `offset`, or throws if the
    /// range extends past the end of the file.
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw ArchiveError.malformed("negative read length") }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= size else {
            throw ArchiveError.malformed("a structure points beyond the end of the file")
        }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw ArchiveError.malformed("the file is shorter than expected")
            }
            return data
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.io("The archive could not be read: \(error.localizedDescription)")
        }
    }
}
