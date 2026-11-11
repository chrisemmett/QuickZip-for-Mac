import Foundation

/// Safety limits applied before an entry is decompressed (HLD §13, ZIP bombs).
///
/// Independently of these limits, providers never emit more bytes than an
/// entry declares, so a lying header cannot cause unbounded output.
public struct ArchiveLimits: Sendable, Hashable {
    /// Entries declaring more uncompressed bytes than this are refused.
    public var maximumEntrySize: UInt64

    /// Entries larger than `compressionRatioThreshold` whose uncompressed /
    /// compressed ratio exceeds this are refused. DEFLATE cannot exceed about
    /// 1032:1, so the default only rejects sizes no real encoder produces.
    public var maximumCompressionRatio: UInt64

    /// Ratio checks only apply above this uncompressed size, since tiny
    /// files with extreme ratios are harmless.
    public var compressionRatioThreshold: UInt64

    public init(
        maximumEntrySize: UInt64 = 1 << 40,
        maximumCompressionRatio: UInt64 = 1_100,
        compressionRatioThreshold: UInt64 = 1 << 30
    ) {
        self.maximumEntrySize = maximumEntrySize
        self.maximumCompressionRatio = maximumCompressionRatio
        self.compressionRatioThreshold = compressionRatioThreshold
    }

    /// Throws `ArchiveError.exceedsLimits` if `entry` looks like a ZIP bomb.
    public func check(_ entry: ArchiveEntry) throws {
        if entry.uncompressedSize > maximumEntrySize {
            throw ArchiveError.exceedsLimits(
                path: entry.path,
                reason: "its declared size (\(entry.uncompressedSize) bytes) is larger than the \(maximumEntrySize)-byte limit"
            )
        }
        if entry.uncompressedSize > compressionRatioThreshold,
           entry.uncompressedSize / max(entry.compressedSize, 1) > maximumCompressionRatio {
            throw ArchiveError.exceedsLimits(
                path: entry.path,
                reason: "its compression ratio is implausibly high, which suggests a ZIP bomb"
            )
        }
    }
}
