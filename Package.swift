// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Susurrus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Susurrus", targets: ["Susurrus"]),
        .library(name: "SusurrusKit", targets: ["SusurrusKit"]),
        .executable(name: "susurrus-eval", targets: ["SusurrusEval"]),
    ],
    dependencies: [
        // WhisperKit added for Phase 3 (on-device transcription)
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        // Parakeet (NVIDIA TDT) and Silero VAD on the Neural Engine. ASR + VAD
        // only: `traits: []` drops diarization and the other engines.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
        // Qwen3-ASR (MLX) for the stop-time decode with vocabulary context.
        // Pinned to a commit: the package tracks main and has no releases.
        .package(url: "https://github.com/soniqo/speech-swift", revision: "d53bcb333882ebbd7444ae059b270127565594a0"),
    ],
    targets: [
        .executableTarget(
            name: "Susurrus",
            dependencies: ["SusurrusKit"]
        ),
        .target(
            name: "SusurrusKit",
            dependencies: [
                // WhisperKit linked for Phase 3
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ]
        ),
        // Offline accuracy harness — see docs/transcription-quality-plan.md.
        .executableTarget(
            name: "SusurrusEval",
            dependencies: [
                "SusurrusKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "SusurrusTests",
            dependencies: [
                "Susurrus",
                "SusurrusKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
