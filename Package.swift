// swift-tools-version:5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sebbu-networking",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SebbuNetworking",
            targets: ["SebbuNetworking"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", .branch("main")),
        .package(url: "https://github.com/apple/swift-collections.git", .branch("main")),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", .branch("main")),
        .package(url: "https://github.com/MarSe32m/sebbu-ts-ds.git", .branch("main")),
        .package(url: "https://github.com/vapor/websocket-kit.git", .branch("main"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "SebbuNetworking",
            dependencies: [
    .product(name: "NIO", package: "swift-nio", condition: .when(platforms: [.macOS, .iOS, .watchOS, .tvOS, .linux, /*.windows*/])),
    .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS, .iOS, .watchOS, .tvOS, .linux, /*.windows*/])),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services", condition: .when(platforms: [.macOS, .iOS, .watchOS, .tvOS])),
                           .product(name: "DequeModule", package: "swift-collections"),
                           .product(name: "SebbuTSDS", package: "sebbu-ts-ds"),
    .product(name: "WebSocketKit", package: "websocket-kit", condition: .when(platforms: [.macOS, .iOS, .watchOS, .tvOS, .linux, /*.windows*/])),
    "CSebbuNetworking"]
        ),
        .target(name: "CSebbuNetworking"),
        .testTarget(
            name: "SebbuNetworkingTests",
            dependencies: ["SebbuNetworking"]),
    ]
)
