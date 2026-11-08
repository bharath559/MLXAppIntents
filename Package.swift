// swift-tools-version: 6.0
import PackageDescription

// NOTE: swift-tools-version 6.0 defaults the package to Swift 6 language mode
// (complete strict concurrency). Verified against the Swift 6.0 release notes;
// if your toolchain disagrees, add `.swiftLanguageMode(.v6)` to each target's
// swiftSettings.
//
// v0.1 is runtime-first, NO macro target. The package has zero dependencies
// and compiles on Linux: no mlx-swift-lm, no MLX, no AppIntents, no
// FoundationModels in any compiled target. Apple-only surface lives behind
// `#if canImport(AppIntents)` in BridgedIntent.swift, and the model seam is
// the pluggable `ModelBackend` protocol (see Sources/MLXAppIntents/).

let package = Package(
    name: "MLXAppIntents",
    products: [
        .library(name: "MLXAppIntents", targets: ["MLXAppIntents"]),
        .library(name: "MLXAppIntentsTestKit", targets: ["MLXAppIntentsTestKit"]),
        .executable(name: "mlx-app-intents-example", targets: ["mlx-app-intents-example"]),
    ],
    targets: [
        .target(name: "MLXAppIntents"),
        .target(
            name: "MLXAppIntentsTestKit",
            dependencies: ["MLXAppIntents"]
        ),
        .testTarget(
            name: "MLXAppIntentsTests",
            dependencies: ["MLXAppIntents", "MLXAppIntentsTestKit"]
        ),
        .executableTarget(
            name: "mlx-app-intents-example",
            dependencies: ["MLXAppIntents", "MLXAppIntentsTestKit"]
        ),
    ]
)
