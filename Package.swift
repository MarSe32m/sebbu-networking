// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sebbu-networking",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "SebbuNetworking",
            targets: ["SebbuNetworking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MarSe32m/sebbu-c-libuv.git", from: "1.48.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "SebbuNetworking",
            dependencies: ["CSebbuNetworking",
                           .product(name: "SebbuCLibUV", package: "sebbu-c-libuv"), 
                           .product(name: "Atomics", package: "swift-atomics"),
                           .product(name: "DequeModule", package: "swift-collections")]
        ),
        .target(name: "CSebbuNetworking"),
        .testTarget(
            name: "SebbuNetworkingTests",
            dependencies: ["SebbuNetworking"]),
    ]
)
