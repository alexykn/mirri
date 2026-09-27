// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirriHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MirriHostCore", targets: ["MirriHostCore"]),
        .executable(name: "MirriNetworkInteropServer", targets: ["MirriNetworkInteropServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3")
    ],
    targets: [
        .target(name: "VirtualDisplayShim", path: "VirtualDisplayShim", publicHeadersPath: "include"),
        .target(name: "MirriHostCore", dependencies: [
            "VirtualDisplayShim", .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ], path: "Core"),
        .executableTarget(name: "MirriNetworkInteropServer", dependencies: ["MirriHostCore"], path: "Tools/NetworkInteropServer"),
        .testTarget(name: "MirriHostCoreTests", dependencies: ["MirriHostCore"], path: "Tests")
    ]
)
