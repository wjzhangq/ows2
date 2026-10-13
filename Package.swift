// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OWABridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OWABridge", targets: ["OWABridge"]),
    ],
    targets: [
        // Platform-neutral logic (HTTP parsing, routing, config, token, state machine).
        // Builds on Linux too so it can be unit-tested anywhere.
        .target(name: "OWABridgeCore"),
        // macOS menu-bar app: AppKit + WKWebView + Network.framework.
        .executableTarget(
            name: "OWABridge",
            dependencies: ["OWABridgeCore"]
        ),
        .testTarget(
            name: "OWABridgeCoreTests",
            dependencies: ["OWABridgeCore"]
        ),
    ]
)
