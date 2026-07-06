// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CounterCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CounterCore", targets: ["CounterCore"])
    ],
    targets: [
        // tools 5.9 builds in Swift 5 language mode by default — no explicit setting needed
        .target(name: "CounterCore"),
        .testTarget(name: "CounterCoreTests", dependencies: ["CounterCore"]),
    ]
)
