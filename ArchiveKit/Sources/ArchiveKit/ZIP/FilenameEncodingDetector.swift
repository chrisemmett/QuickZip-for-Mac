import Foundation

extension FilenameEncoding {
    /// GB 18030, the superset of GBK and GB 2312 used for Simplified Chinese
    /// names. Nil where Foundation has no converter for it.
    public static let gb18030: FilenameEncoding? = gb18030StringEncoding.map { .encoding($0) }

    static let gb18030StringEncoding: String.Encoding? = {
        #if canImport(Darwin)
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: encoding)
        #else
        return nil
        #endif
    }()
}

/// Guesses the legacy encoding of entry names that are neither marked as
/// UTF-8 nor valid UTF-8 (HLD §18.1).
///
/// Archives made by Windows Explorer store names in the system's OEM code
/// page. CP437 is the specification's default, but archives from Japanese,
/// Chinese and Russian systems use Shift-JIS, GBK and CP866. The archive's
/// names are judged together, because a single short name is ambiguous.
enum FilenameEncodingDetector {
    /// At most this many names are examined; the rest of a large archive
    /// almost always comes from the same system.
    static let sampleLimit = 2_000

    /// The encoding that best explains `names`, or nil when nothing fits
    /// better than CP437. Names that are ASCII or valid UTF-8 are ignored.
    static func detect(_ names: [[UInt8]]) -> FilenameEncoding? {
        let legacy = Array(names.lazy.filter(isLegacy).prefix(sampleLimit))
        guard !legacy.isEmpty else { return nil }

        if let japanese = decodeAll(legacy, as: .shiftJIS), DoubleByteText(japanese).isPlausible {
            return .encoding(.shiftJIS)
        }
        // Before GBK, which decodes most Cyrillic CP866 bytes without error.
        if looksLikeCP866(legacy) {
            return .cp866
        }
        if let gb18030 = FilenameEncoding.gb18030StringEncoding,
           let chinese = decodeAll(legacy, as: gb18030), DoubleByteText(chinese).isPlausible,
           gb2312PairFraction(legacy) >= 0.8 {
            return .encoding(gb18030)
        }
        return nil
    }

    private static func isLegacy(_ name: [UInt8]) -> Bool {
        name.contains { $0 >= 0x80 } && strictUTF8String(name) == nil
    }

    /// Every name decoded with `encoding`, or nil if any is invalid in it.
    private static func decodeAll(_ names: [[UInt8]], as encoding: String.Encoding) -> [String]? {
        var result: [String] = []
        result.reserveCapacity(names.count)
        for name in names {
            guard let string = String(bytes: name, encoding: encoding) else { return nil }
            result.append(string)
        }
        return result
    }

    /// What names look like when decoded with a double-byte encoding.
    ///
    /// Accented Latin names in CP437 often decode without error as
    /// Shift-JIS or GBK: "Größe" becomes "Gr批e". The giveaway is that the
    /// resulting characters sit between ASCII letters, where an accented
    /// letter belongs and a real kanji or hanzi rarely does.
    private struct DoubleByteText {
        var nonASCII = 0
        /// Kana, kanji and hanzi.
        var cjk = 0
        /// Single-byte katakana: rare in real names, but what accented
        /// letters and GBK text become when misread as Shift-JIS.
        var halfwidthKatakana = 0
        /// Characters next to an ASCII letter.
        var embedded = 0

        init(_ names: [String]) {
            for name in names {
                let scalars = Array(name.unicodeScalars)
                for (index, scalar) in scalars.enumerated() where !scalar.isASCII {
                    nonASCII += 1
                    switch scalar.value {
                    case 0x3040...0x30FF, 0x4E00...0x9FFF: cjk += 1
                    case 0xFF61...0xFF9F: halfwidthKatakana += 1
                    default: break
                    }
                    if (index > 0 && Self.isASCIILetter(scalars[index - 1]))
                        || (index + 1 < scalars.count && Self.isASCIILetter(scalars[index + 1])) {
                        embedded += 1
                    }
                }
            }
        }

        var isPlausible: Bool {
            halfwidthKatakana == 0 && embedded * 10 < nonASCII * 6 && cjk * 2 >= nonASCII
        }

        private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }

    /// Russian names in CP866 are mostly Cyrillic letters, which occupy
    /// 0x80–0xAF and 0xE0–0xF1, in runs. CP437 names share some of those
    /// bytes for accented Latin letters, but use them singly among ASCII
    /// letters.
    private static func looksLikeCP866(_ names: [[UInt8]]) -> Bool {
        var high = 0
        var cyrillic = 0
        var inRuns = 0
        var asciiLetters = 0
        for name in names {
            for (index, byte) in name.enumerated() {
                guard byte >= 0x80 else {
                    if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) { asciiLetters += 1 }
                    continue
                }
                high += 1
                if (0x80...0xAF).contains(byte) || (0xE0...0xF1).contains(byte) { cyrillic += 1 }
                if (index > 0 && name[index - 1] >= 0x80) || (index + 1 < name.count && name[index + 1] >= 0x80) {
                    inRuns += 1
                }
            }
        }
        return high > 0 && cyrillic * 20 >= high * 19 && inRuns * 2 >= high && cyrillic * 2 >= asciiLetters
    }

    /// The fraction of double-byte characters in the GB 2312 area (both
    /// bytes 0xA1–0xFE), where nearly all Simplified Chinese text lies.
    /// Shift-JIS text mostly uses lead bytes below 0xA0.
    private static func gb2312PairFraction(_ names: [[UInt8]]) -> Double {
        var pairs = 0
        var gb2312 = 0
        for name in names {
            var index = 0
            while index < name.count {
                let lead = name[index]
                guard lead >= 0x81, index + 1 < name.count else {
                    index += 1
                    continue
                }
                let trail = name[index + 1]
                pairs += 1
                if (0xA1...0xFE).contains(lead) && (0xA1...0xFE).contains(trail) { gb2312 += 1 }
                index += 2
            }
        }
        return pairs == 0 ? 0 : Double(gb2312) / Double(pairs)
    }
}
