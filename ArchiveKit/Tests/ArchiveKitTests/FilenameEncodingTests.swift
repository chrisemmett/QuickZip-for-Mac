import Foundation
import XCTest
@testable import ArchiveKit

/// Legacy name encodings (HLD §18.1): detection and the View → Text Encoding
/// override.
final class FilenameEncodingTests: XCTestCase {
    func testDetectsShiftJIS() async throws {
        try skipUnlessDecodable(.shiftJIS)
        let archive = try await openFixture("shift_jis")
        XCTAssertEqual(archive.entries.map(\.path), ["日本語", "日本語/テスト.txt", "報告書.txt"])
        XCTAssertEqual(archive.detectedFilenameEncoding, .encoding(.shiftJIS))
    }

    func testDetectsGBK() async throws {
        guard let gb18030 = FilenameEncoding.gb18030StringEncoding else {
            throw XCTSkip("Foundation on this platform has no GB 18030 converter")
        }
        try skipUnlessDecodable(gb18030)
        let archive = try await openFixture("gbk")
        XCTAssertEqual(archive.entries.map(\.path), ["文件", "文件/报告.txt", "说明.txt"])
        XCTAssertEqual(archive.detectedFilenameEncoding, .encoding(gb18030))
    }

    func testDetectsCP866() async throws {
        let archive = try await openFixture("cp866")
        XCTAssertEqual(archive.entries.map(\.path), ["Документы", "Документы/Отчёт.txt", "readme.txt"])
        XCTAssertEqual(archive.detectedFilenameEncoding, .cp866)
    }

    func testAccentedLatinNamesStayCP437() async throws {
        let names = ["Größe.txt", "Übersicht.pdf", "naïve.txt", "Ångström.txt", "Fußball.doc", "château.txt", "Zürich.png"]
        for name in names {
            XCTAssertNil(FilenameEncodingDetector.detect([cp437(name)]), name)
        }
        XCTAssertNil(FilenameEncodingDetector.detect(names.map(cp437)))
        // The mixed fixture: one CP437 name and one Shift-JIS name.
        let archive = try await openFixture("names")
        XCTAssertNil(archive.detectedFilenameEncoding)
        XCTAssertEqual(archive.entries[1].path, "café.txt")
    }

    func testOverrideDisablesDetection() async throws {
        let archive = try await openFixture("cp866", options: ZIPArchiveOptions(filenameEncoding: .cp437))
        XCTAssertNil(archive.detectedFilenameEncoding)
        XCTAssertEqual(archive.entries[2].path, "readme.txt")
        XCTAssertNotEqual(archive.entries[1].path, "Документы/Отчёт.txt")
    }

    func testCP866Decoding() {
        XCTAssertEqual(ZIPFilenameDecoder.decodeCP866([0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2, 0x2E, 0xF1]), "Привет.ё")
        XCTAssertEqual(ZIPFilenameDecoder.decodeCP866([0xFC, 0x35]), "№5")
    }

    func testIgnoresUTF8AndASCIINames() {
        XCTAssertNil(FilenameEncodingDetector.detect([Array("plain.txt".utf8), Array("日本語.txt".utf8)]))
    }

    private func skipUnlessDecodable(_ encoding: String.Encoding) throws {
        guard String(bytes: [0x83, 0x65], encoding: encoding) != nil else {
            throw XCTSkip("Foundation on this platform cannot decode \(encoding)")
        }
    }

    private func cp437(_ text: String) -> [UInt8] {
        let table: [Character: UInt8] = [
            "ü": 0x81, "é": 0x82, "â": 0x83, "ä": 0x84, "à": 0x85, "å": 0x86, "ç": 0x87, "ï": 0x8B,
            "Å": 0x8F, "ö": 0x94, "Ü": 0x9A, "ß": 0xE1,
        ]
        return text.flatMap { character -> [UInt8] in
            if let byte = table[character] { return [byte] }
            return Array(String(character).utf8)
        }
    }
}
