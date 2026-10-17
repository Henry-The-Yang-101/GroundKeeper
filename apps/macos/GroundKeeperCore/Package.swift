// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "GroundKeeperCore", platforms: [.macOS(.v14)],
    products: [.library(name: "GroundKeeperCore", targets: ["GroundKeeperCore"])],
    targets: [
        .target(name: "GroundKeeperCore",
                resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "GroundKeeperCoreTests", dependencies: ["GroundKeeperCore"])
    ])
