// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "GroundKeeperCore", platforms: [.macOS(.v14)],
    products: [.library(name: "GroundKeeperCore", targets: ["GroundKeeperCore"]),
               .executable(name: "ReceiptPilot", targets: ["ReceiptPilot"]),
               .executable(name: "MerchantQueryPilot", targets: ["MerchantQueryPilot"]),
               .executable(name: "MerchantTrainingQueryPilot", targets: ["MerchantTrainingQueryPilot"])],
    dependencies: [.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0")],
    targets: [
        .target(name: "GroundKeeperCore", dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
                resources: [.process("Resources")]),
        .executableTarget(name: "ReceiptPilot", dependencies: ["GroundKeeperCore"]),
        .executableTarget(name: "MerchantQueryPilot", dependencies: ["GroundKeeperCore"]),
        .executableTarget(name: "MerchantTrainingQueryPilot", dependencies: ["GroundKeeperCore"]),
        .testTarget(name: "GroundKeeperCoreTests", dependencies: ["GroundKeeperCore"])
    ])
