// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "GroundKeeperCore", platforms: [.macOS(.v14)],
    products: [.library(name: "GroundKeeperCore", targets: ["GroundKeeperCore"])],
    dependencies: [.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0")],
    targets: [
        .target(name: "GroundKeeperCore", dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
                resources: [.process("Resources")]),
        .testTarget(name: "GroundKeeperCoreTests", dependencies: ["GroundKeeperCore"])
    ])
