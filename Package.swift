// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Phosphor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Phosphor", targets: ["Phosphor"]),
        .executable(name: "osc", targets: ["osc"]),
    ],
    targets: [
        // Protocol client: identity, signing, HTTP + WebSocket. No UI, no Metal.
        .target(name: "OSCCore"),
        // The vector-display app.
        .executableTarget(name: "Phosphor", dependencies: ["OSCCore"]),
        // Plain-terminal client on the same core, for exercising the protocol without the 3D UI.
        .executableTarget(name: "osc", dependencies: ["OSCCore"]),
        // Run with `make test`: with only the Command Line Tools, Swift Testing needs extra search paths.
        .testTarget(name: "OSCCoreTests", dependencies: ["OSCCore"]),
    ],
    swiftLanguageModes: [.v5]
)
