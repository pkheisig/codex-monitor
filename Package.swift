// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolUsageMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SolUsageCore", targets: ["SolUsageCore"]),
        .executable(name: "sol-usage", targets: ["sol-usage"]),
        .executable(name: "SolUsageMonitor", targets: ["SolUsageMonitor"])
    ],
    targets: [
        .target(name: "SolUsageCore"),
        .executableTarget(
            name: "sol-usage",
            dependencies: ["SolUsageCore"]
        ),
        .executableTarget(
            name: "SolUsageMonitor",
            dependencies: ["SolUsageCore"]
        ),
        .testTarget(
            name: "SolUsageCoreTests",
            dependencies: ["SolUsageCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
