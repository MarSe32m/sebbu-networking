// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sebbu-networking",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SebbuNetworking",
            targets: ["SebbuNetworking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MarSe32m/sebbu-c-libuv.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
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
