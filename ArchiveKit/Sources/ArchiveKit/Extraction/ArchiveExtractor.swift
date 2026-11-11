import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Options controlling how entries are written to disk.
public struct ExtractionOptions: Sendable, Hashable {
    /// What to do when an item already exists at the destination.
    public enum ConflictPolicy: Sendable, Hashable {
        case fail
        case skip
        case replace
        /// Writes "name 2.ext", "name 3.ext", … alongside the existing item.
        case keepBoth
    }

    public var conflictPolicy: ConflictPolicy
    /// Restore Unix permission bits. Setuid, setgid and sticky bits are
    /// always stripped (HLD §18.2).
    public var restorePermissions: Bool
    public var restoreModificationDates: Bool
    /// Merge each item's `__MACOSX` AppleDouble companion (Finder info,
    /// resource fork, extended attributes) back into it, as `ditto` does
    /// (HLD §18.2).
    public var restoreMacOSMetadata: Bool

    public init(
        conflictPolicy: ConflictPolicy = .fail,
        restorePermissions: Bool = true,
        restoreModificationDates: Bool = true,
        restoreMacOSMetadata: Bool = true
    ) {
        self.conflictPolicy = conflictPolicy
        self.restorePermissions = restorePermissions
        self.restoreModificationDates = restoreModificationDates
        self.restoreMacOSMetadata = restoreMacOSMetadata
    }
}

/// Progress of a multi-entry extraction.
public struct ExtractionProgress: Sendable, Hashable {
    public var completedEntries: Int
    public var totalEntries: Int
    public var completedBytes: UInt64
    public var totalBytes: UInt64

    public init(completedEntries: Int, totalEntries: Int, completedBytes: UInt64, totalBytes: UInt64) {
        self.completedEntries = completedEntries
        self.totalEntries = totalEntries
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes)
            : totalEntries > 0 ? Double(completedEntries) / Double(totalEntries) : 1
    }
}

/// The outcome of a multi-entry extraction.
public struct ExtractionResult: Sendable {
    public struct Failure: Sendable {
        public let entry: ArchiveEntry
        public let error: ArchiveError
    }

    /// URLs of the items written, in extraction order.
    public var extracted: [URL] = []
    /// Entries skipped because of a name conflict (`ConflictPolicy.skip`).
    public var skipped: [ArchiveEntry] = []
    /// Entries that could not be extracted, for example because they were
    /// unsafe, encrypted or corrupt. Other entries are still extracted.
    public var failures: [Failure] = []

    public init() {}
}

/// Writes archive entries to disk safely, for any `ArchiveProvider`.
///
/// Safety rules (HLD §13):
/// - Paths are sanitised: absolute paths and `..` components are refused.
/// - Nothing is written through an existing symlink: every directory on the
///   way to an item is checked with `lstat`, and files are created with
///   `O_NOFOLLOW | O_EXCL`.
/// - Symlink entries are only created if their target stays inside the
///   destination.
/// - Every item created carries the archive's quarantine attribute.
public struct ArchiveExtractor: Sendable {
    /// The extraction root, with symlinks in its own path resolved.
    public let destination: URL
    public let options: ExtractionOptions

    /// Symlink targets longer than this are treated as corrupt.
    static let maximumSymlinkTargetLength: UInt64 = 4096

    public init(destination: URL, options: ExtractionOptions = ExtractionOptions()) throws {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.io("The destination “\(destination.path)” is not a folder.")
        }
        self.destination = resolved
        self.options = options
    }

    /// Extracts one entry, recreating its full archive path beneath the
    /// destination. Returns nil if it was skipped because of a conflict.
    @discardableResult
    public func extract<Provider: ArchiveProvider>(_ entry: ArchiveEntry, from provider: Provider) async throws -> URL? {
        let components = try PathSanitizer.safeComponents(of: entry.path)
        var directories: [(URL, ArchiveEntry)] = []
        let companions = await macOSMetadataEntries(in: provider)
        let url = try await write(entry, components: components, from: provider, companions: companions, directories: &directories) { _ in }
        finishDirectories(directories)
        return url
    }

    /// Extracts several entries, for example a folder's contents or the whole
    /// archive. `prefix` (an archive path such as `"Holiday"`) is removed from
    /// the start of every entry's path, so extracting `Holiday/Photos`
    /// relative to `Holiday` produces `destination/Photos`.
    ///
    /// Problems with individual entries are collected in the result rather
    /// than stopping the extraction. Cancellation and lack of disk space stop
    /// it and throw.
    public func extract<Provider: ArchiveProvider>(
        _ entries: [ArchiveEntry],
        from provider: Provider,
        removingPrefix prefix: String = "",
        progress: ((ExtractionProgress) -> Void)? = nil
    ) async throws -> ExtractionResult {
        let prefixComponents = prefix.isEmpty ? [] : try PathSanitizer.safeComponents(of: prefix)
        var state = ExtractionProgress(
            completedEntries: 0,
            totalEntries: entries.count,
            completedBytes: 0,
            // Declared sizes are untrusted, so sums saturate instead of overflowing.
            totalBytes: entries.reduce(0) { saturatingAdd($0, $1.type == .file ? $1.uncompressedSize : 0) }
        )
        // Only entries that can actually be written need space: one entry
        // refused for an absurd declared size must not block the rest.
        let writableBytes = entries.reduce(UInt64(0)) { total, entry in
            guard entry.type == .file, entry.isReadable, (try? provider.limits.check(entry)) != nil else { return total }
            return saturatingAdd(total, entry.uncompressedSize)
        }
        try checkFreeSpace(required: writableBytes)
        ArchiveLog.extraction.info("Extracting \(entries.count) items, \(writableBytes) bytes")
        progress?(state)

        var result = ExtractionResult()
        var directories: [(URL, ArchiveEntry)] = []
        let companions = await macOSMetadataEntries(in: provider)
        for entry in entries {
            try Task.checkCancellation()
            let bytesBefore = state.completedBytes
            do {
                var components = try PathSanitizer.safeComponents(of: entry.path)
                guard components.count > prefixComponents.count,
                      Array(components.prefix(prefixComponents.count)) == prefixComponents
                else {
                    throw ArchiveError.unsafePath(entry.path)
                }
                components.removeFirst(prefixComponents.count)

                let url = try await write(entry, components: components, from: provider, companions: companions, directories: &directories) { count in
                    state.completedBytes = saturatingAdd(state.completedBytes, UInt64(count))
                    progress?(state)
                }
                if let url {
                    result.extracted.append(url)
                } else {
                    result.skipped.append(entry)
                }
            } catch let error as ArchiveError {
                ArchiveLog.extraction.error("Item failed: \(error.logKind, privacy: .public)")
                result.failures.append(.init(entry: entry, error: error))
            }
            if entry.type == .file {
                state.completedBytes = saturatingAdd(bytesBefore, entry.uncompressedSize)
            }
            state.completedEntries += 1
            progress?(state)
        }
        finishDirectories(directories)
        ArchiveLog.extraction.info("Extracted \(result.extracted.count) items; \(result.skipped.count) skipped, \(result.failures.count) failed")
        return result
    }

    // MARK: Writing

    private func write<Provider: ArchiveProvider>(
        _ entry: ArchiveEntry,
        components: [String],
        from provider: Provider,
        companions: [String: ArchiveEntry],
        directories: inout [(URL, ArchiveEntry)],
        onBytesWritten: @escaping (Int) -> Void
    ) async throws -> URL? {
        let parent = try makeDirectories(components.dropLast(), quarantine: provider.sourceQuarantine)
        let url = parent.appendingPathComponent(components.last!, isDirectory: entry.type == .directory)

        switch entry.type {
        case .directory:
            switch fileType(at: url) {
            case S_IFDIR?:
                break
            case nil:
                try makeDirectory(at: url, quarantine: provider.sourceQuarantine)
                // Only folders this extraction created: existing ones are
                // the user's.
                await restoreMacOSMetadata(of: entry, at: url, companions: companions, from: provider)
            default:
                throw ArchiveError.destinationExists(url.path)
            }
            directories.append((url, entry))
            return url

        case .file:
            guard let target = try resolveConflict(at: url) else { return nil }
            try await writeFile(entry, to: target, from: provider, onBytesWritten: onBytesWritten)
            // Before `finish`, which may make the file read-only.
            await restoreMacOSMetadata(of: entry, at: target, companions: companions, from: provider)
            try finish(entry, at: target, quarantine: provider.sourceQuarantine)
            return target

        case .symlink:
            guard entry.uncompressedSize <= Self.maximumSymlinkTargetLength else {
                throw ArchiveError.corruptData(path: entry.path, reason: "the link target is too long")
            }
            let data = try await provider.contents(of: entry)
            guard let linkTarget = String(data: data, encoding: .utf8),
                  PathSanitizer.isSymlinkTargetContained(linkTarget, linkComponents: components)
            else {
                throw ArchiveError.unsafeSymlink(path: entry.path, target: String(decoding: data, as: UTF8.self))
            }
            guard let target = try resolveConflict(at: url) else { return nil }
            let status = target.withFileSystemPath { symlink(linkTarget, $0) }
            guard status == 0 else { throw posixError("Could not create the link “\(target.lastPathComponent)”") }
            if let quarantine = provider.sourceQuarantine {
                try Quarantine.apply(quarantine, to: target)
            }
            return target
        }
    }

    private func writeFile<Provider: ArchiveProvider>(
        _ entry: ArchiveEntry,
        to url: URL,
        from provider: Provider,
        onBytesWritten: @escaping (Int) -> Void
    ) async throws {
        let descriptor = url.withFileSystemPath {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError("Could not create “\(url.lastPathComponent)”") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try await provider.read(entry) { chunk in
                try handle.write(contentsOf: chunk)
                onBytesWritten(chunk.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            _ = url.withFileSystemPath { unlink($0) }
            if let error = error as? ArchiveError { throw error }
            if error is CancellationError { throw error }
            throw ArchiveError.io("Could not write “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// The archive's AppleDouble entries by path, or none if they are not
    /// to be merged.
    private func macOSMetadataEntries<Provider: ArchiveProvider>(in provider: Provider) async -> [String: ArchiveEntry] {
        guard options.restoreMacOSMetadata else { return [:] }
        let entries = await provider.entries
        // Most archives have none; avoid building a table for every preview.
        guard entries.contains(where: \.isMacOSMetadata) else { return [:] }
        var companions: [String: ArchiveEntry] = [:]
        for entry in entries where entry.isMacOSMetadata && entry.type == .file {
            companions[entry.path] = entry
        }
        return companions
    }

    /// Merges the AppleDouble companion of `entry`, if it has one, into the
    /// item written for it. Damaged or oversized metadata is ignored.
    private func restoreMacOSMetadata<Provider: ArchiveProvider>(
        of entry: ArchiveEntry,
        at url: URL,
        companions: [String: ArchiveEntry],
        from provider: Provider
    ) async {
        guard !entry.isMacOSMetadata,
              let companion = companions[AppleDouble.companionPath(for: entry.path)],
              companion.uncompressedSize <= AppleDouble.maximumSize,
              let data = try? await provider.contents(of: companion),
              let metadata = try? AppleDouble(data)
        else { return }
        metadata.apply(to: url)
    }

    /// Applies permissions, date and quarantine to a written file.
    private func finish(_ entry: ArchiveEntry, at url: URL, quarantine: Data?) throws {
        let recorded = options.restorePermissions ? entry.posixPermissions : nil
        // Strip setuid, setgid and sticky; always keep the file readable by
        // its owner.
        let mode = (recorded ?? 0o644) & 0o777 | 0o400
        _ = url.withFileSystemPath { chmod($0, mode_t(mode)) }
        if options.restoreModificationDates, let date = entry.modificationDate {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        if let quarantine {
            try Quarantine.apply(quarantine, to: url)
        }
    }

    /// Directory permissions and dates are applied last, deepest first,
    /// because writing their contents changes their modification dates.
    private func finishDirectories(_ directories: [(URL, ArchiveEntry)]) {
        for (url, entry) in directories.reversed() {
            if options.restorePermissions, let recorded = entry.posixPermissions {
                let mode = recorded & 0o777 | 0o700
                _ = url.withFileSystemPath { chmod($0, mode_t(mode)) }
            }
            if options.restoreModificationDates, let date = entry.modificationDate {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
    }

    // MARK: Filesystem helpers

    /// Creates (or walks) the directories leading to an item, refusing to
    /// pass through anything that is not a real directory.
    private func makeDirectories(_ components: ArraySlice<String>, quarantine: Data?) throws -> URL {
        var url = destination
        for component in components {
            url.appendPathComponent(component, isDirectory: true)
            switch fileType(at: url) {
            case S_IFDIR?:
                continue
            case nil:
                try makeDirectory(at: url, quarantine: quarantine)
            case S_IFLNK?:
                throw ArchiveError.unsafePath(url.path)
            default:
                throw ArchiveError.destinationExists(url.path)
            }
        }
        return url
    }

    private func makeDirectory(at url: URL, quarantine: Data?) throws {
        let status = url.withFileSystemPath { mkdir($0, mode_t(0o755)) }
        guard status == 0 else { throw posixError("Could not create the folder “\(url.lastPathComponent)”") }
        if let quarantine {
            try Quarantine.apply(quarantine, to: url)
        }
    }

    /// Returns where to write an item that would be written at `url`, or
    /// nil if it should be skipped.
    private func resolveConflict(at url: URL) throws -> URL? {
        guard fileType(at: url) != nil else { return url }
        switch options.conflictPolicy {
        case .fail:
            throw ArchiveError.destinationExists(url.path)
        case .skip:
            return nil
        case .replace:
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ArchiveError.io("Could not replace “\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
            return url
        case .keepBoth:
            let directory = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for counter in 2...10_000 {
                let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                let candidate = directory.appendingPathComponent(name)
                if fileType(at: candidate) == nil { return candidate }
            }
            throw ArchiveError.destinationExists(url.path)
        }
    }

    /// The `S_IFMT` type of the item at `url` without following symlinks, or
    /// nil if nothing is there.
    private func fileType(at url: URL) -> mode_t? {
        var info = stat()
        let status = url.withFileSystemPath { lstat($0, &info) }
        return status == 0 ? info.st_mode & S_IFMT : nil
    }

    private func checkFreeSpace(required: UInt64) throws {
        #if os(macOS)
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        if let available = try? destination.resourceValues(forKeys: [key]).volumeAvailableCapacityForImportantUsage,
           available >= 0, required > UInt64(available) {
            throw ArchiveError.insufficientDiskSpace(required: required, available: UInt64(available))
        }
        #endif
    }

    private func posixError(_ message: String) -> ArchiveError {
        ArchiveError.io("\(message): \(String(cString: strerror(errno))).")
    }
}

private func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : sum
}

extension URL {
    /// Calls `body` with the URL's path as a C string. When the path has no
    /// file system representation (it is empty, or holds a NUL), returns -1
    /// with `errno` set to EINVAL, as a failing system call would, instead
    /// of trapping on a nil pointer.
    fileprivate func withFileSystemPath(_ body: (UnsafePointer<CChar>) -> Int32) -> Int32 {
        withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return body(path)
        }
    }
}
