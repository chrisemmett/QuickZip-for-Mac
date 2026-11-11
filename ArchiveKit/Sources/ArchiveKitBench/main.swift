import ArchiveKit
import Compression
import Foundation

// Benchmarks for the HLD §18.5 performance targets. Each scenario builds
// its own archive in a temporary folder, measures, and compares the result
// with the target:
//
//   Open an archive with 100,000 entries          < 1 s to first display
//   Filename search over 100,000 entries          < 16 ms per keystroke
//   Extract a large single entry                  flat memory use
//
// "First display" is the archive being opened, its folder tree built and
// its search index built. The fourth target, never blocking the main
// thread for more than 16 ms, is met by running all of this off the main
// actor; the figures here are what bound it.

let usage = """
usage: archivekit-bench [--entries N] [--large-gib N] [--json FILE] [--markdown FILE] [--check] [--slack X]

  --entries N      entries in the many-entries archive (default 100000)
  --large-gib N    uncompressed size of the single large entry (default 2; the HLD target is 10)
  --json FILE      write the results as JSON
  --markdown FILE  write the results as a Markdown table
  --check          exit 1 if a target is missed
  --slack X        with --check, allow X times each target (default 1). The HLD targets
                   are for a baseline Apple silicon Mac; a shared CI runner is slower, so
                   CI allows a multiple that still catches a real regression.
"""

struct Options {
    var entries = 100_000
    var largeGiB = 2
    var json: String?
    var markdown: String?
    var check = false
    var slack = 1.0
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    while let argument = arguments.popFirst() {
        switch argument {
        case "--entries": options.entries = arguments.popFirst().flatMap(Int.init) ?? options.entries
        case "--large-gib": options.largeGiB = arguments.popFirst().flatMap(Int.init) ?? options.largeGiB
        case "--json": options.json = arguments.popFirst()
        case "--markdown": options.markdown = arguments.popFirst()
        case "--check": options.check = true
        case "--slack": options.slack = arguments.popFirst().flatMap(Double.init) ?? options.slack
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(argument == "-h" || argument == "--help" ? 0 : 2)
        }
    }
    return options
}

// MARK: - Measurement

struct Result: Codable {
    var name: String
    var value: Double
    var unit: String
    var target: Double?
    var detail: String
    var passed: Bool { passes(slack: 1) }
    func passes(slack: Double) -> Bool { target.map { value <= $0 * slack } ?? true }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let value = try await body()
    return (value, seconds(start.duration(to: .now)))
}

/// The process's current resident memory in bytes.
func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int(info.resident_size) : 0
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    sorted[min(Int(Double(sorted.count) * fraction), sorted.count - 1)]
}

// MARK: - Building archives

/// A minimal ZIP writer for benchmark archives. Entries are stored, with
/// ZIP64 records when the archive needs them.
final class ZIPBuilder {
    private let handle: FileHandle
    private(set) var offset: UInt64 = 0
    private var directory = Data()
    private(set) var count: UInt64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func writeRaw(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Writes an entry whose payload the caller streams with `writePayload`.
    func addEntry(
        name: String,
        method: UInt16,
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        writePayload: () throws -> Void
    ) throws {
        let nameBytes = Data(name.utf8)
        let needsZIP64 = compressedSize >= 0xFFFF_FFFF || uncompressedSize >= 0xFFFF_FFFF
        var zip64Extra = Data()
        if needsZIP64 {
            zip64Extra = Self.le(UInt16(1)) + Self.le(UInt16(16)) + Self.le(uncompressedSize) + Self.le(compressedSize)
        }
        let size32: (UInt64) -> UInt32 = { needsZIP64 ? 0xFFFF_FFFF : UInt32($0) }
        let versionNeeded: UInt16 = needsZIP64 ? 45 : 20
        let entryOffset = offset

        var local = Data()
        local += Self.le(UInt32(0x0403_4B50)) + Self.le(versionNeeded) + Self.le(UInt16(0x0800)) + Self.le(method)
        local += Self.le(UInt16(0)) + Self.le(UInt16(0x5821)) // time, date
        local += Self.le(crc) + Self.le(size32(compressedSize)) + Self.le(size32(uncompressedSize))
        local += Self.le(UInt16(nameBytes.count)) + Self.le(UInt16(zip64Extra.count)) + nameBytes + zip64Extra
        try writeRaw(local)
        try writePayload()

        var record = Data()
        record += Self.le(UInt32(0x0201_4B50)) + Self.le(UInt16(0x031E)) + Self.le(versionNeeded)
        record += Self.le(UInt16(0x0800)) + Self.le(method) + Self.le(UInt16(0)) + Self.le(UInt16(0x5821))
        record += Self.le(crc) + Self.le(size32(compressedSize)) + Self.le(size32(uncompressedSize))
        record += Self.le(UInt16(nameBytes.count)) + Self.le(UInt16(zip64Extra.count)) + Self.le(UInt16(0))
        record += Self.le(UInt16(0)) + Self.le(UInt16(0)) + Self.le(UInt32(0o100644 << 16))
        record += Self.le(UInt32(min(entryOffset, 0xFFFF_FFFF)))
        record += nameBytes + zip64Extra
        directory += record
        count += 1
    }

    func finish() throws {
        let directoryOffset = offset
        try writeRaw(directory)
        let zip64RecordOffset = offset
        var tail = Data()
        tail += Self.le(UInt32(0x0606_4B50)) + Self.le(UInt64(44)) + Self.le(UInt16(45)) + Self.le(UInt16(45))
        tail += Self.le(UInt32(0)) + Self.le(UInt32(0)) + Self.le(count) + Self.le(count)
        tail += Self.le(UInt64(directory.count)) + Self.le(directoryOffset)
        tail += Self.le(UInt32(0x0706_4B50)) + Self.le(UInt32(0)) + Self.le(zip64RecordOffset) + Self.le(UInt32(1))
        tail += Self.le(UInt32(0x0605_4B50)) + Self.le(UInt16(0xFFFF)) + Self.le(UInt16(0xFFFF))
        tail += Self.le(UInt16(0xFFFF)) + Self.le(UInt16(0xFFFF))
        tail += Self.le(UInt32(0xFFFF_FFFF)) + Self.le(UInt32(0xFFFF_FFFF)) + Self.le(UInt16(0))
        try writeRaw(tail)
        try handle.close()
    }
}

/// A realistic tree: a few hundred folders, a couple of levels deep, with
/// mixed extensions and name lengths.
func entryName(_ index: Int) -> String {
    let extensions = ["swift", "txt", "pdf", "jpg", "png", "json", "md", "html", "css", "js", "c", "h"]
    let words = ["report", "invoice", "photo", "notes", "summary", "draft", "archive", "readme", "config", "main", "index", "data"]
    let top = "project\(index % 40)"
    let sub = "module\((index / 40) % 25)"
    return "\(top)/\(sub)/\(words[index % words.count])_\(index).\(extensions[(index / 7) % extensions.count])"
}

func buildManyEntries(_ url: URL, count: Int) throws {
    let builder = try ZIPBuilder(url: url)
    for index in 0..<count {
        try builder.addEntry(name: entryName(index), method: 0, crc: 0, compressedSize: 0, uncompressedSize: 0) {}
    }
    try builder.finish()
}

/// CRC-32 of `count` zero bytes without touching them, by multiplying
/// polynomials modulo the CRC polynomial (as zlib's crc32_combine does).
func crc32OfZeros(count: UInt64) -> UInt32 {
    func multiply(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var m: UInt32 = 1 << 31
        var p: UInt32 = 0
        var a = a, b = b
        while true {
            if a & m != 0 {
                p ^= b
                if a & (m - 1) == 0 { break }
            }
            m >>= 1
            b = b & 1 != 0 ? (b >> 1) ^ 0xEDB8_8320 : b >> 1
        }
        return p
    }
    // squares[k] is x^(2^k).
    var squares = [UInt32](repeating: 0, count: 32)
    var p: UInt32 = 1 << 30
    squares[0] = p
    for k in 1..<32 {
        p = multiply(p, p)
        squares[k] = p
    }
    // x^(8 * count)
    var power: UInt32 = 1 << 31
    var n = count
    var k = 3
    while n != 0 {
        if n & 1 != 0 { power = multiply(squares[k & 31], power) }
        n >>= 1
        k += 1
    }
    return multiply(power, 0xFFFF_FFFF) ^ 0xFFFF_FFFF
}

/// An archive with one DEFLATE entry of `size` zero bytes. The compressed
/// stream is produced in 1 MiB steps, so building it needs little memory.
func buildLargeEntry(_ url: URL, size: UInt64) throws {
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { compression_stream_destroy(stream) }

    // Compress to a temporary file first: the entry's compressed size is
    // needed for its header.
    let compressedURL = url.appendingPathExtension("deflate")
    FileManager.default.createFile(atPath: compressedURL.path, contents: nil)
    let compressedHandle = try FileHandle(forWritingTo: compressedURL)
    defer { try? FileManager.default.removeItem(at: compressedURL) }

    let chunk = [UInt8](repeating: 0, count: 1 << 20)
    var output = [UInt8](repeating: 0, count: 1 << 16)
    var compressedSize: UInt64 = 0
    var remaining = size

    try chunk.withUnsafeBufferPointer { input in
        while remaining > 0 {
            let count = Int(min(UInt64(input.count), remaining))
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = count
            // Feed the chunk, draining output until it is all consumed.
            while stream.pointee.src_size > 0 {
                let status: compression_status = output.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.dst_ptr = buffer.baseAddress!
                    stream.pointee.dst_size = buffer.count
                    return compression_stream_process(stream, 0)
                }
                guard status != COMPRESSION_STATUS_ERROR else { throw CocoaError(.fileWriteUnknown) }
                let produced = output.count - stream.pointee.dst_size
                if produced > 0 {
                    try compressedHandle.write(contentsOf: output[0..<produced])
                    compressedSize += UInt64(produced)
                }
            }
            remaining -= UInt64(count)
        }
        // Finish the stream.
        stream.pointee.src_ptr = input.baseAddress!
        stream.pointee.src_size = 0
        while true {
            let status: compression_status = output.withUnsafeMutableBufferPointer { buffer in
                stream.pointee.dst_ptr = buffer.baseAddress!
                stream.pointee.dst_size = buffer.count
                return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }
            guard status != COMPRESSION_STATUS_ERROR else { throw CocoaError(.fileWriteUnknown) }
            let produced = output.count - stream.pointee.dst_size
            if produced > 0 {
                try compressedHandle.write(contentsOf: output[0..<produced])
                compressedSize += UInt64(produced)
            }
            if status == COMPRESSION_STATUS_END { break }
        }
    }
    try compressedHandle.close()

    let builder = try ZIPBuilder(url: url)
    try builder.addEntry(
        name: "zeros.bin",
        method: 8,
        crc: crc32OfZeros(count: size),
        compressedSize: compressedSize,
        uncompressedSize: size
    ) {
        let reader = try FileHandle(forReadingFrom: compressedURL)
        defer { try? reader.close() }
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty {
            try builder.writeRaw(data)
        }
    }
    try builder.finish()
}

// MARK: - Scenarios

func benchmarkMany(_ options: Options, in directory: URL) async throws -> [Result] {
    let url = directory.appendingPathComponent("many.zip")
    try buildManyEntries(url, count: options.entries)
    let label = options.entries.formatted()

    // Opening is a cold-ish read of a freshly written file; take the best of
    // three so a one-off scheduling hiccup doesn't decide the result.
    var best = (open: Double.infinity, tree: Double.infinity, index: Double.infinity)
    var archive: ZIPArchive?
    var tree: ArchiveTree?
    var index: ArchiveSearchIndex?
    for _ in 0..<3 {
        let (opened, openTime) = try await time { try await ZIPArchive.open(url) }
        let (built, treeTime) = await time { ArchiveTree(entries: opened.entries, archiveName: "many.zip") }
        let (indexed, indexTime) = await time { ArchiveSearchIndex(tree: built) }
        if openTime + treeTime + indexTime < best.open + best.tree + best.index {
            best = (openTime, treeTime, indexTime)
        }
        archive = opened; tree = built; index = indexed
    }
    guard let archive, let tree, let index, archive.entries.count == options.entries else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let firstDisplay = best.open + best.tree + best.index
    var results = [
        Result(
            name: "Open \(label) entries, to first display", value: firstDisplay * 1000, unit: "ms", target: 1000,
            detail: "directory \(Int(best.open * 1000)) ms, tree \(Int(best.tree * 1000)) ms, search index \(Int(best.index * 1000)) ms"
        ),
    ]

    // Typing "report" then a path then an extension: every prefix is a query.
    let queries = ["r", "re", "rep", "repo", "repor", "report", "report_1", "report_12", "project7/", "project7/module3/", "*.pdf", "ext:swift", "photo png", "zzzz"]
    var samples: [Double] = []
    let folder = tree.node(atPath: "project7")
    for _ in 0..<20 {
        for query in queries {
            let (matches, elapsed) = await time { index.search(query) }
            _ = matches.count
            samples.append(elapsed * 1000)
        }
        for query in queries.prefix(6) {
            let (_, elapsed) = await time { index.search(query, in: folder) }
            samples.append(elapsed * 1000)
        }
    }
    samples.sort()
    results.append(Result(
        name: "Search \(label) entries, per keystroke", value: percentile(samples, 0.99), unit: "ms (p99)", target: 16,
        detail: "median \(String(format: "%.2f", percentile(samples, 0.5))) ms, max \(String(format: "%.2f", samples.last ?? 0)) ms over \(samples.count) queries"
    ))
    return results
}

func benchmarkLargeEntry(_ options: Options, in directory: URL) async throws -> [Result] {
    let size = UInt64(options.largeGiB) << 30
    let url = directory.appendingPathComponent("large.zip")
    let (_, buildTime) = try await time { try buildLargeEntry(url, size: size) }
    let archiveSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

    let archive = try await ZIPArchive.open(url)
    guard let entry = archive.entries.first, entry.uncompressedSize == size else {
        throw CocoaError(.fileReadCorruptFile)
    }
    // The high-water mark (`ru_maxrss`) would include building the archive,
    // so sample the current size as each chunk arrives instead.
    let baseline = residentBytes()
    var peak = baseline
    var total: UInt64 = 0
    var chunks = 0
    let (_, elapsed) = try await time {
        try await archive.read(entry) { chunk in
            total += UInt64(chunk.count)
            chunks += 1
            if chunks % 16 == 0 { peak = max(peak, residentBytes()) }
        }
    }
    guard total == size else { throw CocoaError(.fileReadCorruptFile) }
    let growth = Double(max(peak - baseline, 0)) / 1_048_576

    return [
        Result(
            name: "Read a \(options.largeGiB) GiB entry, memory growth", value: growth, unit: "MiB", target: 64,
            detail: "decompressed and CRC-checked in \(String(format: "%.1f", elapsed)) s (\(Int(Double(size) / 1_048_576 / elapsed)) MiB/s); archive is \(archiveSize / 1024) KiB; built in \(Int(buildTime)) s"
        ),
    ]
}

// MARK: - Output

func render(_ results: [Result]) -> String {
    var lines = ["| Scenario | Result | Target | |", "|---|---|---|---|"]
    for result in results {
        let value = String(format: result.value < 10 ? "%.2f" : "%.0f", result.value)
        let target = result.target.map { "< \(Int($0)) \(result.unit.split(separator: " ")[0])" } ?? "–"
        lines.append("| \(result.name) | \(value) \(result.unit) | \(target) | \(result.passed ? "✓" : "✗ missed") |")
    }
    return lines.joined(separator: "\n")
}

let options = parseOptions()
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ArchiveKitBench-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

var results: [Result] = []
do {
    print("Building and measuring a \(options.entries.formatted())-entry archive…")
    results += try await benchmarkMany(options, in: directory)
    print("Building and measuring a \(options.largeGiB) GiB entry…")
    results += try await benchmarkLargeEntry(options, in: directory)
} catch {
    FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
    exit(2)
}

print()
print(render(results))
print()
for result in results { print("\(result.name): \(result.detail)") }

if let path = options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: path))
}
if let path = options.markdown {
    try (render(results) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}
if options.check, !results.allSatisfy({ $0.passes(slack: options.slack) }) {
    print("\nTargets missed.")
    exit(1)
}
