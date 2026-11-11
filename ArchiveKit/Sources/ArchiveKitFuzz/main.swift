import ArchiveKitFuzzing
import Foundation

// A fuzz target for the central directory parser and everything that runs
// on an untrusted archive when it is opened (HLD §18.5). Run in CI.

let usage = """
usage: archivekit-fuzz [--iterations N] [--seed S] <seed.zip>...

Mutates the given archives and opens each result, looking for crashes,
hangs and errors that are not ArchiveError. Exits 1 if any are found.
A crash aborts the process; repeat it with the printed --seed.
"""

var iterations = 10_000
var seed = UInt64(Date().timeIntervalSince1970)
var paths: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--iterations":
        guard let value = arguments.popFirst().flatMap(Int.init) else { fatalError(usage) }
        iterations = value
    case "--seed":
        guard let value = arguments.popFirst().flatMap(UInt64.init) else { fatalError(usage) }
        seed = value
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        paths.append(argument)
    }
}
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

let seeds = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
print("fuzzing \(seeds.count) seed archives, \(iterations) iterations, --seed \(seed)")
let fuzzer = ArchiveFuzzer(seeds: seeds)
let report = await fuzzer.run(iterations: iterations, seed: seed) { done in
    if done % 2_000 == 0 { print("  \(done) iterations") }
}
print("\(report.iterations) iterations: \(report.opened) opened, \(report.rejected) rejected")
for message in report.unexpectedErrors.prefix(20) { print("UNEXPECTED \(message)") }
for slow in report.slow.prefix(20) { print("SLOW iteration \(slow.iteration): \(slow.seconds) s") }
exit(report.isClean ? 0 : 1)
