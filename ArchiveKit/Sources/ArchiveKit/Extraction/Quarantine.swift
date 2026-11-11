import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads and propagates the `com.apple.quarantine` extended attribute
/// (HLD §13, Quarantine Propagation).
///
/// Without propagation, extracting a downloaded archive would strip
/// Gatekeeper checks from its contents. The attribute only exists on macOS;
/// elsewhere these functions do nothing.
public enum Quarantine {
    public static let attributeName = "com.apple.quarantine"

    /// The quarantine attribute of the file at `url`, if any.
    public static func attribute(of url: URL) -> Data? {
        #if canImport(Darwin)
        return url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read == size ? data : nil
        }
        #else
        return nil
        #endif
    }

    /// Applies `attribute` to the item at `url` without following symlinks.
    ///
    /// Inside the App Sandbox the system quarantines every item the app
    /// creates and refuses to let the app replace that attribute, so
    /// `setxattr` fails. The item is still quarantined, which is what
    /// propagation is for, so that is accepted; only an item left with no
    /// quarantine attribute at all is an error.
    public static func apply(_ attribute: Data, to url: URL) throws {
        #if canImport(Darwin)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return attribute.withUnsafeBytes {
                setxattr(path, attributeName, $0.baseAddress, attribute.count, 0, XATTR_NOFOLLOW)
            }
        }
        let code = errno
        guard result == 0 || Self.attribute(of: url) != nil else {
            let reason = String(cString: strerror(code))
            throw ArchiveError.io("Could not mark “\(url.lastPathComponent)” as downloaded from the internet: \(reason).")
        }
        #endif
    }
}
