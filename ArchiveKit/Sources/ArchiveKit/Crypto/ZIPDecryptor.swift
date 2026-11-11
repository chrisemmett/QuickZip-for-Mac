import Foundation

/// Turns an entry's stored bytes into the compressed data inside, one chunk
/// at a time, so decrypting a large entry needs no more memory than a small
/// one (HLD §18.5). Decryption applies to reading only: `RewritableArchive`
/// copies encrypted entries byte for byte (HLD §19).
protocol ZIPDecryptor: AnyObject {
    /// Decrypts the next chunk of stored bytes. May return fewer bytes than
    /// it was given (headers, and the authentication code at the end), and
    /// more on the final call. Throws `invalidPassword` as soon as the
    /// password is shown to be wrong, and `corruptData` if authentication
    /// fails once everything has been read.
    func process(_ input: Data, isFinal: Bool) throws -> Data
}

enum ZIPDecryptorFactory {
    static func make(for entry: ArchiveEntry, password: [UInt8]) throws -> ZIPDecryptor? {
        switch entry.encryption {
        case nil:
            if entry.isEncrypted { throw ArchiveError.encryptedEntry(path: entry.path) }
            return nil
        case .zipCrypto(let checkByte)?:
            return ZipCryptoDecryptor(password: password, checkByte: checkByte, path: entry.path)
        case .winZipAES(let strength, _)?:
            return try WinZipAESDecryptor(password: password, strength: strength, path: entry.path)
        case .unsupported?:
            throw ArchiveError.encryptedEntry(path: entry.path)
        }
    }
}

/// The traditional PKWARE stream cipher (APPNOTE 6.1). Three 32-bit keys
/// are seeded with the password and stirred by every plaintext byte; the
/// first twelve bytes of the entry are a random header whose last byte
/// should match the check byte.
final class ZipCryptoDecryptor: ZIPDecryptor {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890
    private var headerRemaining = 12
    private let checkByte: UInt8
    private let path: String

    init(password: [UInt8], checkByte: UInt8, path: String) {
        self.checkByte = checkByte
        self.path = path
        for byte in password { update(byte) }
    }

    private static func crc(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        CRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    private func update(_ byte: UInt8) {
        key0 = Self.crc(key0, byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc(key2, UInt8(truncatingIfNeeded: key1 >> 24))
    }

    private func decrypt(_ byte: UInt8) -> UInt8 {
        let temp = (key2 | 2) & 0xFFFF
        let plain = byte ^ UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
        update(plain)
        return plain
    }

    func process(_ input: Data, isFinal: Bool) throws -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        for byte in input {
            let plain = decrypt(byte)
            if headerRemaining > 0 {
                headerRemaining -= 1
                if headerRemaining == 0, plain != checkByte {
                    throw ArchiveError.invalidPassword(path: path)
                }
            } else {
                output.append(plain)
            }
        }
        if isFinal, headerRemaining > 0 {
            throw ArchiveError.corruptData(path: path, reason: "its encryption header is cut off")
        }
        return output
    }
}

extension ZIPArchive {
    /// Whether `password` opens `entry`, checked as cheaply as the scheme
    /// allows: the two-byte verifier for AES, the header check byte for
    /// ZipCrypto (which one wrong password in 256 passes), and for small
    /// entries a full read, whose checksum settles it. Nil if the entry is
    /// not encrypted with a scheme that has a password.
    public func checkPassword(_ password: String, for entry: ArchiveEntry) async -> Bool? {
        guard entry.needsPassword else { return nil }
        let candidate = Array(password.utf8)
        do {
            if entry.uncompressedSize <= 1 << 20 {
                try await read(entry, password: candidate) { _ in }
            } else {
                try readPrefix(of: entry, password: candidate)
            }
            return true
        } catch let error as ArchiveError {
            switch error {
            case .invalidPassword: return false
            // A wrong ZipCrypto password that passed the check byte.
            case .checksumMismatch, .corruptData: return false
            default: return nil
            }
        } catch {
            return nil
        }
    }

    /// Reads just enough of `entry` to authenticate the password.
    private func readPrefix(of entry: ArchiveEntry, password: [UInt8]) throws {
        let header = try file.read(at: entry.storageOffset, count: ZIPHeaderParser.localHeaderSize)
        let start = try ZIPHeaderParser.dataOffset(localHeader: header, headerOffset: entry.storageOffset)
        guard let decryptor = try ZIPDecryptorFactory.make(for: entry, password: password) else { return }
        let count = Int(min(entry.compressedSize, 64))
        _ = try decryptor.process(try file.read(at: start, count: count), isFinal: false)
    }
}
