// swift-tools-version: 6.2
// Audiobook Studio — native macOS front end for the local audiobook engine.
// Build:  ./scripts/bundle.sh      (creates build/AudiobookStudio.app)
// Dev:    swift run                (runs without a bundle; notifications disabled)
import PackageDescription

let package = Package(
    name: "AudiobookStudio",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates (checks an appcast, verifies an EdDSA signature, replaces the app, relaunches).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "AudiobookStudio",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AudiobookStudio",
            resources: [.process("Resources")],
            // The executable lives in Contents/MacOS; Sparkle.framework is copied to Contents/Frameworks by bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "AudiobookStudioTests",
            dependencies: ["AudiobookStudio"],
            path: "Tests/AudiobookStudioTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
