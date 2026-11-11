import ArchiveKitFuzzing
import Foundation
import XCTest
@testable import ArchiveKit

/// A short, deterministic run of the fuzzer on every test run. CI runs a
/// much longer one with `archivekit-fuzz`.
final class FuzzTests: XCTestCase {
    func testMutatedFixturesNeverCrashOrHang() async throws {
        let names = ["basic", "zip64", "data_descriptor", "infozip", "implicit_dirs", "shift_jis", "symlinks", "mixed"]
        let seeds = try names.map { try Data(contentsOf: fixtureURL($0)) }
        let iterations = ProcessInfo.processInfo.environment["ARCHIVEKIT_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
        let report = await ArchiveFuzzer(seeds: seeds).run(iterations: iterations, seed: 20_261_006)
        XCTAssertEqual(report.unexpectedErrors, [])
        XCTAssertTrue(report.slow.isEmpty, "slow iterations: \(report.slow)")
        XCTAssertGreaterThan(report.opened, 0)
        XCTAssertGreaterThan(report.rejected, 0)
    }
}
