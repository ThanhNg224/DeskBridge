// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskBridge", targets: ["DeskBridge"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(
            name: "DeskBridgeCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/DeskBridgeCore"
        ),
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
        .testTarget(
            name: "DeskBridgeTests",
            dependencies: ["DeskBridge"],
            path: "Tests/DeskBridgeTests"
        ),
    ]
)
