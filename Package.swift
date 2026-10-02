// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexGauge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexGauge", targets: ["CodexGauge"]),
        .executable(name: "GaugeProbe", targets: ["GaugeProbe"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "CodexGauge", dependencies: ["UsageCore"]),
        .executableTarget(name: "GaugeProbe", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "CodexGaugeTests", dependencies: ["CodexGauge"])
    ]
)
