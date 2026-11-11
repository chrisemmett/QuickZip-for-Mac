import ArchiveKit
import Foundation

/// A deterministic xorshift generator, so a failing run can be repeated
/// from its seed.
public struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Mutation-based fuzzing of everything ArchiveKit does with an untrusted
/// archive on opening: finding the end-of-central-directory record,
/// parsing the central directory, recovering damaged archives, building
/// the folder tree and search index, and reading entries (HLD §18.5).
///
/// The target is a crash, a hang or runaway memory, not a particular
/// result: damaged input may open, open partly, or throw an `ArchiveError`,
/// and all three are fine. Mutations favour the end of the file, where the
/// directory lives, and the field values parsers most often trust.
public struct ArchiveFuzzer {
    public struct Report: Sendable {
        public var iterations = 0
        public var opened = 0
        public var rejected = 0
        /// Errors other than `ArchiveError`, which the engine should not leak.
        public var unexpectedErrors: [String] = []
        /// Iterations that took longer than `slowThreshold`.
        public var slow: [(iteration: Int, seconds: Double)] = []
        public var isClean: Bool { unexpectedErrors.isEmpty && slow.isEmpty }
    }

    public var seeds: [Data]
    public var slowThreshold: Double

    public init(seeds: [Data], slowThreshold: Double = 5) {
        precondition(!seeds.isEmpty, "the fuzzer needs at least one seed archive")
        self.seeds = seeds
        self.slowThreshold = slowThreshold
    }

    public func run(iterations: Int, seed: UInt64, progress: ((Int) -> Void)? = nil) async -> Report {
        var random = FuzzRandom(seed: seed)
        var report = Report()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveKitFuzz-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.zip")

        for iteration in 0..<iterations {
            var data = seeds[Int(random.next() % UInt64(seeds.count))]
            for _ in 0..<Int(1 + random.next() % 4) {
                Self.mutate(&data, using: &random)
            }
            let started = ContinuousClock.now
            do {
                try data.write(to: file)
                try await Self.exercise(file, report: &report)
            } catch {
                // Writing the input is the fuzzer's own failure.
                report.unexpectedErrors.append("iteration \(iteration): could not write input: \(error)")
            }
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds > slowThreshold {
                report.slow.append((iteration, seconds))
            }
            report.iterations += 1
            progress?(iteration + 1)
        }
        return report
    }

    /// Opens `file` and does what the application does next.
    private static func exercise(_ file: URL, report: inout Report) async throws {
        let limits = ArchiveLimits(maximumEntrySize: 4 << 20)
        let archive: any ArchiveProvider
        do {
            archive = try await ArchiveOpener.open(file, options: ArchiveOpenOptions(limits: limits))
        } catch is ArchiveError {
            report.rejected += 1
            return
        } catch {
            report.unexpectedErrors.append("open threw \(type(of: error)): \(error)")
            return
        }
        report.opened += 1
        // So that decryption, LZMA and Deflate64 run on damaged input too.
        await archive.setPassword("secret")

        let entries = await archive.entries
        let tree = ArchiveTree(entries: entries, archiveName: "fuzz")
        let index = ArchiveSearchIndex(tree: tree)
        _ = index.search("a")
        _ = index.search("*.txt")
        _ = index.search("x/y")
        for node in tree.root.directoryChildren.prefix(4) {
            _ = tree.entries(under: node)
        }
        _ = await archive.safetyReport()
        for entry in entries.prefix(8) where entry.type != .directory {
            do {
                try await archive.read(entry) { _ in }
            } catch is ArchiveError {
                // Corrupt, encrypted, unsupported or over the limit.
            } catch {
                report.unexpectedErrors.append("read threw \(type(of: error)): \(error)")
            }
        }
    }

    // MARK: Mutation

    private static let interestingValues: [UInt64] = [
        0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x1_0000,
        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x1_0000_0000,
        0x7FFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF,
    ]

    static func mutate(_ data: inout Data, using random: inout FuzzRandom) {
        guard !data.isEmpty else {
            data.append(UInt8(truncatingIfNeeded: random.next()))
            return
        }
        // Half the time aim at the last 4 KiB, where the directory is.
        func position() -> Int {
            if random.next() & 1 == 0 {
                let window = min(data.count, 4096)
                return data.count - window + Int(random.next() % UInt64(window))
            }
            return Int(random.next() % UInt64(data.count))
        }

        switch random.next() % 9 {
        case 0: // flip a bit
            data[position()] ^= UInt8(1) << UInt8(random.next() % 8)
        case 1: // random byte
            data[position()] = UInt8(truncatingIfNeeded: random.next())
        case 2, 3: // an interesting 16, 32 or 64-bit value
            let width = [2, 4, 8][Int(random.next() % 3)]
            let value = interestingValues[Int(random.next() % UInt64(interestingValues.count))]
            let start = min(position(), max(data.count - width, 0))
            for byte in 0..<min(width, data.count - start) {
                data[start + byte] = UInt8(truncatingIfNeeded: value >> UInt64(8 * byte))
            }
        case 4: // truncate
            data.removeLast(Int(random.next() % UInt64(min(data.count, 2048))) + 1)
        case 5: // delete a run
            let start = position()
            let length = min(Int(random.next() % 64) + 1, data.count - start)
            data.removeSubrange(start..<start + length)
        case 6: // duplicate a run
            let start = position()
            let length = min(Int(random.next() % 64) + 1, data.count - start)
            data.insert(contentsOf: data[start..<start + length], at: start)
        case 7: // overwrite a run with another part of the file
            let from = position()
            let to = position()
            let length = min(Int(random.next() % 32) + 1, data.count - from, data.count - to)
            let run = Data(data[from..<from + length])
            data.replaceSubrange(to..<to + length, with: run)
        default: // append junk
            data.append(contentsOf: (0..<Int(random.next() % 64)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        }
    }
}
