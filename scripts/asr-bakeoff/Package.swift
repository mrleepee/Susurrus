// swift-tools-version: 6.2
// Standalone bake-off of non-Whisper recognizers on the eval corpora.
// Kept out of the app package so its dependencies don't touch the app.
import PackageDescription

let package = Package(
    name: "asr-bakeoff",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "asr-bakeoff",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
