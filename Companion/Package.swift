// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CompanionCore", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CompanionCore", targets: ["CompanionCore"])],
    targets: [.target(name: "CompanionCore", path: "Shared"),
              .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"], path: "Tests")])
