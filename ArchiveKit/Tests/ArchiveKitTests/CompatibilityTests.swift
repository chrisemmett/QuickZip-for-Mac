import CryptoKit
import XCTest
@testable import ArchiveKit

private let secret = "secret"
private let hello = "Hello, encrypted world!\n"

/// ZipCrypto, WinZip AES, LZMA and Deflate64 (HLD §20, Phase 5). The
/// fixtures come from independent writers (Info-ZIP, pyzipper, Python's
/// zipfile); see Scripts/make_fixtures.py.
final class EncryptionTests: XCTestCase {
    /// The 193,468-byte text every Phase 5 fixture contains.
    private func referenceText() async throws -> Data {
        let archive = try await openFixture("lzma")
        return try await archive.contents(of: archive.entry("big.txt"))
    }

    private func checkAll(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let reference = try await referenceText()
        let archive = try await openFixture(fixture)
        await archive.setPassword(secret)
        let big = try await archive.contents(of: archive.entry("big.txt"))
        XCTAssertEqual(big, reference, "\(fixture) big.txt", file: file, line: line)
        let text = try await archive.string("hello.txt")
        XCTAssertEqual(text, hello, file: file, line: line)
        let random = try await archive.contents(of: archive.entry("folder/random.bin"))
        XCTAssertEqual(random.count, 5000, file: file, line: line)
        let report = try await archive.verify()
        XCTAssertTrue(report.isIntact, "\(fixture): \(report.failures.map(\.error))", file: file, line: line)
        XCTAssertTrue(report.unverifiable.isEmpty, file: file, line: line)
    }

    func testZipCrypto() async throws {
        let archive = try await openFixture("zipcrypto")
        XCTAssertTrue(archive.entries.filter { $0.type == .file }.allSatisfy {
            if case .zipCrypto? = $0.encryption { return true } else { return false }
        })
        try await checkAll("zipcrypto")
    }

    func testZipCryptoWithDataDescriptorUsesTheTimeForItsCheckByte() async throws {
        let reference = try await referenceText()
        let archive = try await openFixture("zipcrypto_stream")
        await archive.setPassword(secret)
        let entry = try XCTUnwrap(archive.entries.first)
        let data = try await archive.contents(of: entry)
        XCTAssertEqual(data, reference)
    }

    func testWinZipAESAtEveryStrength() async throws {
        for (fixture, strength) in [("aes128", AESStrength.aes128), ("aes192", .aes192), ("aes256", .aes256)] {
            let archive = try await openFixture(fixture)
            XCTAssertEqual(try archive.entry("big.txt").encryption, .winZipAES(strength: strength, version: 2))
            try await checkAll(fixture)
        }
    }

    func testAE2HasNoCRCAndAE1Does() async throws {
        let ae2 = try await openFixture("aes128")
        XCTAssertNil(try ae2.entry("hello.txt").crc32)
        let ae1 = try await openFixture("aes_ae1")
        XCTAssertNotNil(try ae1.entry("hello.txt").crc32)
        XCTAssertEqual(try ae1.entry("hello.txt").encryption, .winZipAES(strength: .aes128, version: 1))
        try await checkAll("aes_ae1")
    }

    func testStoredAESEntryAndEmptyEntry() async throws {
        let stored = try await openFixture("aes_stored")
        await stored.setPassword(secret)
        let text = try await stored.string("stored.txt")
        XCTAssertEqual(text, hello)

        let archive = try await openFixture("aes256")
        await archive.setPassword(secret)
        let empty = try await archive.contents(of: archive.entry("empty.txt"))
        XCTAssertTrue(empty.isEmpty)
    }

    func testWrongPassword() async throws {
        for fixture in ["zipcrypto", "aes128", "aes256"] {
            let archive = try await openFixture(fixture)
            await archive.setPassword("not the password")
            let entry = try archive.entry("big.txt")
            await assertThrows(.invalidPassword(path: "big.txt")) { try await archive.contents(of: entry) }
        }
    }

    func testPasswordRequiredBeforeOneIsSet() async throws {
        let archive = try await openFixture("aes256")
        let entry = try archive.entry("hello.txt")
        await assertThrows(.passwordRequired(path: "hello.txt")) { try await archive.contents(of: entry) }
        await archive.setPassword(secret)
        await archive.setPassword(nil)
        await assertThrows(.passwordRequired(path: "hello.txt")) { try await archive.contents(of: entry) }
    }

    func testCheckPassword() async throws {
        for fixture in ["zipcrypto", "aes256"] {
            let archive = try await openFixture(fixture)
            let big = try archive.entry("big.txt")
            let right = await archive.checkPassword(secret, for: big)
            let wrong = await archive.checkPassword("nope", for: big)
            XCTAssertEqual(right, true, fixture)
            XCTAssertEqual(wrong, false, fixture)
        }
        let plain = try await openFixture("basic")
        let first = try XCTUnwrap(plain.entries.first { $0.type == .file })
        let result = await plain.checkPassword("x", for: first)
        XCTAssertNil(result)
    }

    func testVerifyTreatsMissingPasswordAsNotChecked() async throws {
        let archive = try await openFixture("aes256")
        let report = try await archive.verify()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(Set(report.unverifiable.map(\.path)), ["hello.txt", "big.txt", "folder/random.bin", "empty.txt"])
    }

    func testTamperedAESDataFailsAuthentication() async throws {
        // Flip a bit in the middle of the encrypted data of a copy.
        let source = fixtureURL("aes128")
        var bytes = try Data(contentsOf: source)
        let archive = try await ZIPArchive.open(source)
        let entry = try archive.entry("big.txt")
        bytes[Int(entry.storageOffset) + 30 + entry.path.utf8.count + 11 + 20_000] ^= 0x01
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("tampered-\(UUID().uuidString).zip")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let tampered = try await ZIPArchive.open(copy)
        await tampered.setPassword(secret)
        do {
            _ = try await tampered.contents(of: tampered.entry("big.txt"))
            XCTFail("expected a failure")
        } catch let error as ArchiveError {
            switch error {
            case .corruptData, .sizeMismatch, .checksumMismatch: break
            default: XCTFail("unexpected \(error)")
            }
        }
    }

    func testExtractionWithPassword() async throws {
        let archive = try await openFixture("aes256")
        let folder = try makeTemporaryDirectory(self)
        let extractor = try ArchiveExtractor(destination: folder)
        let withoutPassword = try await extractor.extract(archive.entries, from: archive)
        XCTAssertEqual(withoutPassword.failures.count, 4)
        XCTAssertTrue(withoutPassword.failures.allSatisfy {
            if case .passwordRequired = $0.error { return true } else { return false }
        })

        await archive.setPassword(secret)
        let result = try await extractor.extract(archive.entries, from: archive)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.error))")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), hello)
    }

    func testRewritingKeepsEncryptedEntriesByteForByte() async throws {
        let archive = try await openFixture("aes256")
        let folder = try makeTemporaryDirectory(self)
        let output = folder.appendingPathComponent("out.zip")
        let extra = folder.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: extra)
        try await archive.rewrite(to: output, removing: [], adding: [ArchiveAddition(source: extra, path: "added.txt")])

        let rewritten = try await ZIPArchive.open(output)
        await rewritten.setPassword(secret)
        let text = try await rewritten.string("hello.txt")
        XCTAssertEqual(text, hello)
        let added = try await rewritten.string("added.txt")
        XCTAssertEqual(added, "added")
        XCTAssertEqual(try rewritten.entry("big.txt").encryption, try archive.entry("big.txt").encryption)
    }
}

final class LZMATests: XCTestCase {
    func testPythonWrittenArchive() async throws {
        let archive = try await openFixture("lzma")
        XCTAssertTrue(archive.entries.allSatisfy { $0.compressionMethod == .lzma })
        let hello = try await archive.string("hello.txt")
        XCTAssertEqual(hello, "Hello, encrypted world!\n")
        let one = try await archive.string("one.txt")
        XCTAssertEqual(one, "x")
        let empty = try await archive.contents(of: archive.entry("empty.txt"))
        XCTAssertTrue(empty.isEmpty)
        let big = try await archive.contents(of: archive.entry("big.txt"))
        XCTAssertEqual(big.count, 193_468)
        let report = try await archive.verify()
        XCTAssertTrue(report.isIntact, "\(report.failures.map(\.error))")
        XCTAssertTrue(report.unverifiable.isEmpty)
    }

    func testLargeEntryStreamsAcrossChunks() async throws {
        let archive = try await openFixture("lzma")
        let large = try archive.entry("large.txt")
        XCTAssertEqual(large.uncompressedSize, 7_738_720)
        var total: UInt64 = 0
        var chunks = 0
        try await archive.read(large) { total += UInt64($0.count); chunks += 1 }
        XCTAssertEqual(total, large.uncompressedSize)
        XCTAssertGreaterThan(chunks, 100, "output arrives in bounded chunks")
    }

    func testIncompressibleDataRoundTrips() async throws {
        let archive = try await openFixture("lzma")
        let random = try await archive.contents(of: archive.entry("folder/random.bin"))
        XCTAssertEqual(random.count, 5000)
    }

    func testTruncatedStreamIsCorruptNotACrash() async throws {
        let source = fixtureURL("lzma")
        let archive = try await ZIPArchive.open(source)
        let entry = try archive.entry("big.txt")
        // Overwrite the middle of the compressed data with zeros.
        var bytes = try Data(contentsOf: source)
        let start = Int(entry.storageOffset) + 30 + entry.path.utf8.count + 100
        for index in start..<(start + 5000) { bytes[index] = 0 }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lzma-\(UUID().uuidString).zip")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let damaged = try await ZIPArchive.open(copy)
        do {
            _ = try await damaged.contents(of: damaged.entry("big.txt"))
            XCTFail("expected a failure")
        } catch is ArchiveError {}
    }
}

/// A tiny writer for DEFLATE-family bit streams, so Deflate64 can be tested
/// without a Deflate64 encoder: tests build the exact streams they mean.
private struct BitWriter {
    var bytes: [UInt8] = []
    private var current: UInt32 = 0
    private var count = 0

    mutating func bits(_ value: Int, _ width: Int) {
        for index in 0..<width {
            current |= UInt32((value >> index) & 1) << UInt32(count)
            count += 1
            if count == 8 { bytes.append(UInt8(current)); current = 0; count = 0 }
        }
    }

    /// Huffman codes are written most significant bit first.
    mutating func code(_ value: Int, _ width: Int) {
        for index in stride(from: width - 1, through: 0, by: -1) { bits((value >> index) & 1, 1) }
    }

    /// A symbol in the fixed literal/length code (RFC 1951, 3.2.6).
    mutating func fixedSymbol(_ symbol: Int) {
        switch symbol {
        case 0...143: code(0x30 + symbol, 8)
        case 144...255: code(0x190 + symbol - 144, 9)
        case 256...279: code(symbol - 256, 7)
        default: code(0xC0 + symbol - 280, 8)
        }
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(current)); current = 0; count = 0 }
        return bytes
    }
}

final class Deflate64Tests: XCTestCase {
    private func decode(_ input: [UInt8], deflate64: Bool = true, chunk: Int = .max) throws -> [UInt8] {
        let decoder = DeflateDecoder(path: "t", isDeflate64: deflate64)
        var output: [UInt8] = []
        var offset = 0
        repeat {
            let end = min(offset + chunk, input.count)
            try decoder.process(Data(input[offset..<end]), isFinal: end == input.count) { output += $0 }
            offset = end
        } while offset < input.count
        return output
    }

    /// A stored block of `data` followed by a fixed-Huffman block holding one match.
    private func streamWithMatch(prefix: [UInt8], lengthSymbol: Int, lengthExtra: (Int, Int)?, distanceSymbol: Int, distanceExtra: (Int, Int)?) -> [UInt8] {
        var writer = BitWriter()
        writer.bits(0, 1); writer.bits(0, 2)          // stored, not last
        _ = writer.finish()
        var bytes = writer.bytes
        bytes += [UInt8(prefix.count & 0xFF), UInt8(prefix.count >> 8), UInt8(~prefix.count & 0xFF), UInt8((~prefix.count >> 8) & 0xFF)]
        bytes += prefix
        var tail = BitWriter()
        tail.bits(1, 1); tail.bits(1, 2)              // last, fixed Huffman
        tail.fixedSymbol(lengthSymbol)
        if let (value, width) = lengthExtra { tail.bits(value, width) }
        tail.code(distanceSymbol, 5)
        if let (value, width) = distanceExtra { tail.bits(value, width) }
        tail.fixedSymbol(256)
        return bytes + tail.finish()
    }

    func testLengthCode285MeansThreePlusSixteenBitsInDeflate64() throws {
        // 100 literal bytes, then a match of length 3 + 40,000 at distance 100.
        let prefix = (0..<100).map { UInt8($0) }
        let stream = streamWithMatch(prefix: prefix, lengthSymbol: 285, lengthExtra: (40_000, 16), distanceSymbol: 13, distanceExtra: (100 - 97, 5))
        let output = try decode(stream)
        XCTAssertEqual(output.count, 100 + 40_003)
        for index in 100..<output.count { XCTAssertEqual(output[index], output[index - 100]) }
        // In plain DEFLATE the same code means 258 and takes no extra bits,
        // so the stream means something else.
        XCTAssertNotEqual((try? decode(stream, deflate64: false))?.count, output.count)
    }

    func testDistanceCodes30And31ReachBackPast32KiB() throws {
        // 40,000 distinct-ish bytes, then copy 10 bytes from 33,000 back
        // (distance code 30: base 32,769, 14 extra bits).
        let prefix = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 8) }
        // Stored blocks hold at most 65,535 bytes: fine for 40,000.
        let stream = streamWithMatch(prefix: prefix, lengthSymbol: 264, lengthExtra: nil, distanceSymbol: 30, distanceExtra: (33_000 - 32_769, 14))
        let output = try decode(stream)
        XCTAssertEqual(output.count, 40_010)
        XCTAssertEqual(Array(output[40_000...]), Array(prefix[(40_000 - 33_000)..<(40_000 - 33_000 + 10)]))
        // Plain DEFLATE has no distance code 30.
        XCTAssertThrowsError(try decode(stream, deflate64: false))
    }

    func testStreamingInTinyChunksMatchesOneShot() throws {
        let prefix = (0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let stream = streamWithMatch(prefix: prefix, lengthSymbol: 285, lengthExtra: (1000, 16), distanceSymbol: 14, distanceExtra: (500 - 129, 6))
        let whole = try decode(stream)
        for chunk in [1, 2, 7, 64] {
            XCTAssertEqual(try decode(stream, chunk: chunk), whole, "chunk \(chunk)")
        }
    }

    func testRejectsDistanceBeforeTheStartAndTruncation() throws {
        let stream = streamWithMatch(prefix: [1, 2, 3], lengthSymbol: 264, lengthExtra: nil, distanceSymbol: 10, distanceExtra: (3, 4))
        XCTAssertThrowsError(try decode(stream))
        let good = streamWithMatch(prefix: [1, 2, 3], lengthSymbol: 264, lengthExtra: nil, distanceSymbol: 2, distanceExtra: nil)
        XCTAssertNoThrow(try decode(good))
        XCTAssertThrowsError(try decode(Array(good.dropLast(2))))
    }

    func testAgreesWithCompressionFrameworkOnPlainDeflate() async throws {
        // The same decoder, in plain DEFLATE mode, against the system's.
        for name in ["python_zipfile", "mixed", "infozip", "zeros", "zip64"] {
            let archive = try await openFixture(name)
            for entry in archive.entries where entry.type == .file && entry.compressionMethod == .deflate && !entry.isEncrypted {
                let expected = try await archive.contents(of: entry)
                let bytes = try Data(contentsOf: fixtureURL(name))
                let header = bytes[Int(entry.storageOffset)..<Int(entry.storageOffset) + 30]
                let start = try ZIPHeaderParser.dataOffset(localHeader: Data(header), headerOffset: entry.storageOffset)
                let compressed = [UInt8](bytes[Int(start)..<Int(start + entry.compressedSize)])
                let ours = try decode(compressed, deflate64: false, chunk: 4096)
                XCTAssertEqual(ours.count, expected.count, "\(name)/\(entry.path)")
                XCTAssertEqual(CRC32.checksum(ours), CRC32.checksum(expected), "\(name)/\(entry.path)")
            }
        }
    }

    func testInsideAnArchive() async throws {
        // A Deflate64 entry written by hand: one stored block.
        let payload = Data("hello deflate64".utf8)
        var stream: [UInt8] = [0b0000_0001]   // last block, stored
        stream += [UInt8(payload.count), 0, UInt8(~payload.count & 0xFF), 0xFF]
        stream += payload
        let url = try makeTemporaryDirectory(self).appendingPathComponent("d64.zip")
        try Self.zip(name: "d64.txt", method: 9, payload: Data(stream), data: payload).write(to: url)
        let archive = try await ZIPArchive.open(url)
        XCTAssertEqual(try archive.entry("d64.txt").compressionMethod, .deflate64)
        let text = try await archive.string("d64.txt")
        XCTAssertEqual(text, "hello deflate64")
    }

    /// A one-entry ZIP with the given raw method and payload.
    private static func zip(name: String, method: UInt16, payload: Data, data: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let crc = CRC32.checksum(data)
        let nameBytes = Data(name.utf8)
        var local = le(UInt32(0x0403_4B50)) + le(UInt16(20)) + le(UInt16(0x0800)) + le(method) + le(UInt32(0))
        local += le(crc) + le(UInt32(payload.count)) + le(UInt32(data.count)) + le(UInt16(nameBytes.count)) + le(UInt16(0)) + nameBytes
        var central = le(UInt32(0x0201_4B50)) + le(UInt16(20)) + le(UInt16(20)) + le(UInt16(0x0800)) + le(method) + le(UInt32(0))
        central += le(crc) + le(UInt32(payload.count)) + le(UInt32(data.count)) + le(UInt16(nameBytes.count)) + le(UInt16(0)) + le(UInt16(0))
        central += le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(UInt32(0)) + nameBytes
        let directoryOffset = local.count + payload.count
        var end = le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(1)) + le(UInt16(1))
        end += le(UInt32(central.count)) + le(UInt32(directoryOffset)) + le(UInt16(0))
        return local + payload + central + end
    }
}
