// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Refrain",
    defaultLocalization: "en",
    // macOS 14, not 26: Pretype still runs on 14 and links RefrainKit. What needs 26
    // (Apple's SpeechAnalyzer) is gated with `@available` inside.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RefrainKit", targets: ["RefrainKit"]),
        .library(name: "RefrainServer", targets: ["RefrainServer"]),
    ],
    dependencies: [
        // Parakeet on the Neural Engine. Moves fast, so minor versions are taken by hand. No traits:
        // its NeMo text normalization (a prebuilt Rust framework) is for TTS, not for hearing.
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.17.7"), traits: []),
    ],
    targets: [
        .target(
            name: "RefrainKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            // Its errors' words, which Settings and Shortcuts show.
            resources: [.process("Localizable.xcstrings")]
        ),
        // The HTTP side, apart from the engines so Pretype doesn't carry it.
        .target(name: "RefrainServer", dependencies: ["RefrainKit"]),
        .testTarget(name: "RefrainKitTests", dependencies: ["RefrainKit", "RefrainServer"]),
    ]
)
