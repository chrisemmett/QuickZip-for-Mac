import Foundation

/// A temporary file holding the contents of an archive that can only be
/// read from the start: compressed tar and Apple Archive (HLD §18.4).
///
/// Opening such an archive decompresses it once, writing each item's data
/// here, so that previewing or extracting one item afterwards is a plain
/// read instead of decompressing everything before it again. The file is
/// private to the user, never holds more than the archive's own contents
/// and is deleted when the archive is closed.
public final class ArchiveSpool: @unchecked Sendable {
    /// Where spools live; cleared at launch in case a run ended without
    /// cleaning up.
    public static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveSpools", isDirectory: true)

    private let url: URL
    private var handle: FileHandle?
    private(set) var size: UInt64 = 0
    private var reader: RandomAccessFile?

    init() throws {
        try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
        url = Self.rootDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ArchiveError.io("A temporary file could not be created.")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle?.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Appends `data`, returning where it starts.
    @discardableResult
    func append(_ data: Data) throws -> UInt64 {
        guard let handle else { throw ArchiveError.io("The temporary file is closed.") }
        let offset = size
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ArchiveError.io("The temporary file could not be written: \(error.localizedDescription)")
        }
        size += UInt64(data.count)
        return offset
    }

    /// Ends writing and makes the contents readable.
    func finish() throws {
        try handle?.close()
        handle = nil
        reader = try RandomAccessFile(url: url)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard let reader else { throw ArchiveError.io("The temporary file is not ready.") }
        return try reader.read(at: offset, count: count)
    }

    /// Whether the volume holding spools has room for `bytes` more, with
    /// some left over for the system.
    static func hasRoom(for bytes: UInt64) -> Bool {
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        guard let available = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [key]).volumeAvailableCapacityForImportantUsage,
              available >= 0 else { return true }
        return UInt64(available) > bytes &+ (256 << 20)
    }

    public static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
