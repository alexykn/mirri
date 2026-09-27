// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirriHost",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MirriHostCore", targets: ["MirriHostCore"])],
    targets: [
        .target(name: "VirtualDisplayShim", path: "VirtualDisplayShim", publicHeadersPath: "include"),
        .target(name: "MirriHostCore", dependencies: ["VirtualDisplayShim"], path: "Core"),
        .testTarget(name: "MirriHostCoreTests", dependencies: ["MirriHostCore"], path: "Tests")
    ]
)
