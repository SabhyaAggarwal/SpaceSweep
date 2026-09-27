// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanCore", targets: ["CleanCore"]),
        .executable(name: "SpaceSweep", targets: ["SpaceSweep"]),
    ],
    targets: [
        // Pure-Foundation scanning / cleaning engine. No AppKit, so it can be unit-tested anywhere.
        .target(
            name: "CleanCore",
            path: "Sources/CleanCore"
        ),
        // The SwiftUI macOS app.
        .executableTarget(
            name: "SpaceSweep",
            dependencies: ["CleanCore"],
            path: "Sources/SpaceSweep"
        ),
        .testTarget(
            name: "CleanCoreTests",
            dependencies: ["CleanCore"],
            path: "Tests/CleanCoreTests"
        ),
    ]
)
