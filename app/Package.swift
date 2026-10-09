// swift-tools-version: 6.0
// Audiobook Studio — native macOS front end for the local audiobook engine.
// Build:  ./scripts/bundle.sh      (creates build/AudiobookStudio.app)
// Dev:    swift run                (runs without a bundle; notifications disabled)
import PackageDescription

let package = Package(
    name: "AudiobookStudio",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AudiobookStudio",
            path: "Sources/AudiobookStudio",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AudiobookStudioTests",
            dependencies: ["AudiobookStudio"],
            path: "Tests/AudiobookStudioTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
