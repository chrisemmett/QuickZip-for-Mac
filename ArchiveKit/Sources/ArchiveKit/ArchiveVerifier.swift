import Foundation

/// The result of "Verify Archive" (HLD §18.1).
public struct VerificationReport: Sendable {
    public struct Failure: Sendable {
        public let entry: ArchiveEntry
        public let error: ArchiveError
    }

    /// Entries that decompressed with the expected size and checksum.
    public var verifiedCount = 0
    /// Entries that could not be checked: encrypted or using an unsupported
    /// compression method.
    public var unverifiable: [ArchiveEntry] = []
    /// Entries that are corrupt or unsafe to read.
    public var failures: [Failure] = []

    public var isIntact: Bool { failures.isEmpty }
}

extension ArchiveProvider {
    /// Decompresses every entry and checks its size and checksum, without
    /// writing anything to disk.
    ///
    /// - Parameter progress: called after each entry with the number of
    ///   entries processed so far.
    public func verify(progress: ((Int) -> Void)? = nil) async throws -> VerificationReport {
        var report = VerificationReport()
        let entries = await self.entries
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            defer { progress?(index + 1) }
            guard entry.type != .directory else { continue }
            guard entry.isReadable else {
                report.unverifiable.append(entry)
                continue
            }
            do {
                try await read(entry) { _ in }
                report.verifiedCount += 1
            } catch ArchiveError.passwordRequired {
                report.unverifiable.append(entry)
            } catch ArchiveError.invalidPassword {
                report.unverifiable.append(entry)
            } catch let error as ArchiveError {
                report.failures.append(.init(entry: entry, error: error))
            }
        }
        return report
    }
}
