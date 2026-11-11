import Foundation

/// How to interpret entry names that are not explicitly marked as UTF-8.
///
/// Backs the **View → Text Encoding** override (HLD §18.1).
public enum FilenameEncoding: Sendable, Hashable {
    /// UTF-8 when the bytes are valid UTF-8, otherwise CP437 (the ZIP
    /// specification's default).
    case automatic
    /// IBM PC code page 437.
    case cp437
    /// IBM PC code page 866 (DOS Cyrillic), which Windows uses for ZIP names
    /// on Russian systems. Decoded by ArchiveKit itself, so it is available
    /// on every platform.
    case cp866
    /// Any encoding Foundation supports, for example `.shiftJIS`.
    case encoding(String.Encoding)
}

/// Decodes raw ZIP entry names (APPNOTE 4.4.4 bit 11, appendix D).
enum ZIPFilenameDecoder {
    /// Decodes a name. Priority: Info-ZIP Unicode Path extra field (when its
    /// CRC matches the raw name), then the UTF-8 flag, then `fallback`.
    ///
    /// With an `.automatic` fallback, names that are not valid UTF-8 are
    /// decoded with `detected` (see `FilenameEncodingDetector`) when given,
    /// otherwise as CP437.
    static func decode(
        raw: [UInt8],
        isUTF8Flagged: Bool,
        unicodePathExtra: [UInt8]?,
        fallback: FilenameEncoding,
        detected: FilenameEncoding? = nil
    ) -> String {
        if let extra = unicodePathExtra, let name = decodeUnicodePathExtra(extra, raw: raw) {
            return name
        }
        if isUTF8Flagged {
            return String(decoding: raw, as: UTF8.self)
        }
        switch fallback {
        case .automatic:
            if let utf8 = strictUTF8String(raw) {
                return utf8
            }
            if let detected, detected != .automatic {
                return decode(raw: raw, isUTF8Flagged: false, unicodePathExtra: nil, fallback: detected)
            }
            return decodeCP437(raw)
        case .cp437:
            return decodeCP437(raw)
        case .cp866:
            return decodeCP866(raw)
        case .encoding(let encoding):
            return String(bytes: raw, encoding: encoding) ?? decodeCP437(raw)
        }
    }

    /// Info-ZIP Unicode Path extra field (0x7075): version (1), CRC-32 of the
    /// raw name (4), UTF-8 name. A CRC mismatch means the name was changed by
    /// a tool unaware of the field, so the field is stale and ignored.
    private static func decodeUnicodePathExtra(_ extra: [UInt8], raw: [UInt8]) -> String? {
        var reader = BinaryReader(extra)
        guard let version = try? reader.readUInt8(), version == 1,
              let crc = try? reader.readUInt32(), crc == CRC32.checksum(raw),
              let bytes = try? reader.readBytes(reader.remaining)
        else { return nil }
        return strictUTF8String(bytes)
    }

    static func decodeCP437(_ raw: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in raw {
            let value = byte < 0x80 ? UInt32(byte) : UInt32(cp437High[Int(byte) - 0x80])
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }

    static func decodeCP866(_ raw: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in raw {
            let value: UInt32
            switch byte {
            case 0x00..<0x80: value = UInt32(byte)
            // А–Я, а–п
            case 0x80...0xAF: value = 0x0410 + UInt32(byte - 0x80)
            // Box drawing, shared with CP437.
            case 0xB0...0xDF: value = UInt32(cp437High[Int(byte) - 0x80])
            // р–я
            case 0xE0...0xEF: value = 0x0440 + UInt32(byte - 0xE0)
            default: value = UInt32(cp866Tail[Int(byte) - 0xF0])
            }
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }

    /// CP866 0xF0–0xFF.
    private static let cp866Tail: [UInt16] = [
        0x0401, 0x0451, 0x0404, 0x0454, 0x0407, 0x0457, 0x040E, 0x045E, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x2116, 0x00A4, 0x25A0, 0x00A0,
    ]

    private static let cp437High: [UInt16] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]
}

/// Strict UTF-8 decoding that fails on invalid sequences instead of
/// substituting replacement characters.
func strictUTF8String(_ bytes: [UInt8]) -> String? {
    var iterator = bytes.makeIterator()
    var decoder = UTF8()
    var scalars = String.UnicodeScalarView()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar): scalars.append(scalar)
        case .emptyInput: return String(scalars)
        case .error: return nil
        }
    }
}
