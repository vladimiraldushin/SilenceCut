// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SilenceCut",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SilenceCut", targets: ["SilenceCut"])
    ],
    targets: [
        .executableTarget(
            name: "SilenceCut",
            path: "SilenceCut",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SilenceCutTests",
            dependencies: ["SilenceCut"],
            path: "SilenceCutTests"
        )
    ]
)
