// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SilenceCut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SilenceCut", targets: ["SilenceCutApp"]),
    ],
    targets: [
        // Domain models — ZERO AVFoundation dependency
        .target(name: "RECore", path: "Sources/RECore"),

        // AVFoundation composition builder
        .target(name: "RETimeline", dependencies: ["RECore"], path: "Sources/RETimeline"),

        // Audio analysis (silence detection, waveform)
        .target(name: "REAudioAnalysis", dependencies: ["RECore"], path: "Sources/REAudioAnalysis"),

        // Export (AVAssetWriter pipeline)
        .target(name: "REExport", dependencies: ["RECore", "RETimeline"], path: "Sources/REExport"),

        // UI components
        .target(name: "REUI", dependencies: ["RECore", "RETimeline", "REAudioAnalysis"], path: "Sources/REUI"),

        // App entry point
        .executableTarget(name: "SilenceCutApp", dependencies: ["RECore", "RETimeline", "REUI"], path: "Sources/SilenceCutApp"),

        // Tests
        .testTarget(name: "RECoreTests", dependencies: ["RECore"], path: "Tests/RECoreTests"),
    ]
)
