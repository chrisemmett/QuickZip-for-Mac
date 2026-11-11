// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "ArchiveKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
        .library(name: "QuickZipCLI", targets: ["QuickZipCLI"]),
        .executable(name: "quickzip", targets: ["quickzip"]),
        .executable(name: "archivekit-fuzz", targets: ["ArchiveKitFuzz"]),
        .executable(name: "archivekit-bench", targets: ["ArchiveKitBench"]),
    ],
    targets: [
        .target(
            name: "ArchiveKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "QuickZipCLI",
            dependencies: ["ArchiveKit"]
        ),
        .executableTarget(
            name: "quickzip",
            dependencies: ["QuickZipCLI"]
        ),
        .target(
            name: "ArchiveKitFuzzing",
            dependencies: ["ArchiveKit"]
        ),
        .executableTarget(
            name: "ArchiveKitFuzz",
            dependencies: ["ArchiveKitFuzzing"]
        ),
        .executableTarget(
            name: "ArchiveKitBench",
            dependencies: ["ArchiveKit"]
        ),
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit", "ArchiveKitFuzzing", "QuickZipCLI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
