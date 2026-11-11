import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS metadata that archives made on a Mac keep in `__MACOSX/…/._name`
/// AppleDouble entries: Finder info, the resource fork and extended
/// attributes such as Finder tags (HLD §18.2).
///
/// On extraction it is merged back into the file it belongs to, as `ditto`
/// does, instead of appearing as a separate `._name` file.
public struct AppleDouble: Sendable, Equatable {
    public struct Attribute: Sendable, Equatable {
        public let name: String
        public let value: Data
    }

    /// The 32-byte Finder info, or nil when absent or all zeros.
    public var finderInfo: Data?
    /// The resource fork, or nil when absent or empty.
    public var resourceFork: Data?
    public var attributes: [Attribute] = []

    /// AppleDouble files larger than this are not merged.
    public static let maximumSize: UInt64 = 64 << 20

    /// Attributes never taken from an archive: an archive must not be able
    /// to remove or replace the quarantine applied to what it contains
    /// (HLD §13), nor set attributes that only the system manages.
    static let refusedAttributes: Set<String> = [
        "com.apple.quarantine",
        "com.apple.macl",
        "com.apple.provenance",
        "com.apple.rootless",
        resourceForkAttribute,
        finderInfoAttribute,
    ]

    static let resourceForkAttribute = "com.apple.ResourceFork"
    static let finderInfoAttribute = "com.apple.FinderInfo"

    private static let magic: UInt32 = 0x0005_1607
    private static let attributesMagic: UInt32 = 0x4154_5452 // "ATTR"
    private static let resourceForkID: UInt32 = 2
    private static let finderInfoID: UInt32 = 9
    private static let finderInfoLength = 32

    /// The archive path of the AppleDouble entry holding metadata for the
    /// item at `path`: `a/b.txt` → `__MACOSX/a/._b.txt`.
    public static func companionPath(for path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.popLast() else { return "" }
        return (["__MACOSX"] + components + ["._" + name]).joined(separator: "/")
    }

    /// Parses an AppleDouble file. Malformed parts are ignored where the rest
    /// is still usable; a file that is not AppleDouble at all throws.
    public init(_ data: Data) throws {
        let reader = BigEndianReader([UInt8](data))
        guard reader.uint32(at: 0) == Self.magic, let count = reader.uint16(at: 24) else {
            throw ArchiveError.malformed("the macOS metadata is not in AppleDouble format")
        }
        for index in 0..<Int(count) {
            let descriptor = 26 + index * 12
            guard let id = reader.uint32(at: descriptor),
                  let offset = reader.uint32(at: descriptor + 4).map({ Int($0) }),
                  let length = reader.uint32(at: descriptor + 8).map({ Int($0) }),
                  let bytes = reader.bytes(at: offset, count: length)
            else {
                throw ArchiveError.malformed("the macOS metadata is damaged")
            }
            switch id {
            case Self.resourceForkID where !bytes.isEmpty:
                resourceFork = Data(bytes)
            case Self.finderInfoID where bytes.count >= Self.finderInfoLength:
                let info = bytes.prefix(Self.finderInfoLength)
                if info.contains(where: { $0 != 0 }) { finderInfo = Data(info) }
                // Extended attributes follow the Finder info, 4-byte aligned.
                attributes = Self.parseAttributes(reader, headerOffset: (offset + Self.finderInfoLength + 3) & ~3)
            default:
                break
            }
        }
    }

    /// The attribute header and entries `copyfile` writes after the Finder
    /// info. Offsets are from the start of the file.
    private static func parseAttributes(_ reader: BigEndianReader, headerOffset: Int) -> [Attribute] {
        guard reader.uint32(at: headerOffset) == attributesMagic,
              let count = reader.uint16(at: headerOffset + 34)
        else { return [] }
        var attributes: [Attribute] = []
        var entry = headerOffset + 36
        for _ in 0..<count {
            guard let offset = reader.uint32(at: entry).map({ Int($0) }),
                  let length = reader.uint32(at: entry + 4).map({ Int($0) }),
                  let nameLength = reader.bytes(at: entry + 10, count: 1)?.first.map({ Int($0) }),
                  let rawName = reader.bytes(at: entry + 11, count: nameLength),
                  let value = reader.bytes(at: offset, count: length)
            else { break }
            // The name includes its terminating NUL.
            let name = String(decoding: rawName.prefix(while: { $0 != 0 }), as: UTF8.self)
            if !name.isEmpty, !refusedAttributes.contains(name) {
                attributes.append(Attribute(name: name, value: Data(value)))
            }
            entry += (11 + nameLength + 3) & ~3
        }
        return attributes
    }

    /// Applies the metadata to the item at `url` without following
    /// symlinks. Best effort: an attribute the system refuses is skipped,
    /// because the item's contents matter more than its metadata.
    public func apply(to url: URL) {
        #if canImport(Darwin)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            func set(_ name: String, _ value: Data) {
                _ = value.withUnsafeBytes {
                    setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
                }
            }
            for attribute in attributes {
                set(attribute.name, attribute.value)
            }
            if let finderInfo { set(Self.finderInfoAttribute, finderInfo) }
            if let resourceFork { set(Self.resourceForkAttribute, resourceFork) }
        }
        #endif
    }
}

/// Bounds-checked big-endian reads at absolute offsets: AppleDouble, unlike
/// ZIP, is big-endian and addressed by offsets rather than read in order.
private struct BigEndianReader {
    private let storage: [UInt8]

    init(_ storage: [UInt8]) {
        self.storage = storage
    }

    func bytes(at offset: Int, count: Int) -> ArraySlice<UInt8>? {
        guard offset >= 0, count >= 0, offset <= storage.count, count <= storage.count - offset else { return nil }
        return storage[offset..<offset + count]
    }

    func uint16(at offset: Int) -> UInt16? {
        guard let slice = bytes(at: offset, count: 2) else { return nil }
        return slice.reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
    }

    func uint32(at offset: Int) -> UInt32? {
        guard let slice = bytes(at: offset, count: 4) else { return nil }
        return slice.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
