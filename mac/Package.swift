// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskBridge", targets: ["DeskBridge"]),
    ],
    targets: [
        .target(name: "DeskBridgeCore", path: "Sources/DeskBridgeCore"),
        .executableTarget(
            name: "DeskBridge",
            dependencies: ["DeskBridgeCore"],
            path: "Sources/DeskBridge"
        ),
        .testTarget(
            name: "DeskBridgeCoreTests",
            dependencies: ["DeskBridgeCore"],
            path: "Tests/DeskBridgeCoreTests"
        ),
    ]
)
