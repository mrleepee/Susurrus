// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Susurrus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Susurrus", targets: ["Susurrus"]),
        .library(name: "SusurrusKit", targets: ["SusurrusKit"]),
    ],
    dependencies: [
        // WhisperKit added for Phase 3 (on-device transcription)
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.4"),
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
            ]
        ),
        .testTarget(
            name: "SusurrusTests",
            dependencies: ["SusurrusKit"]
        ),
    ]
)
