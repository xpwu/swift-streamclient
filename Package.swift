// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "xpwu_stream",
		platforms: [.iOS(.v13), .macOS(.v10_15), .watchOS(.v6), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "xpwu_stream",
            targets: ["xpwu_stream"]),
    ],
		dependencies: [.package(name:"xpwu_x", path: "../swift-x"),
									 .package(name:"xpwu_concurrency", path: "../swift-concurrency"),],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "xpwu_stream",
						dependencies: [.product(name: "xpwu_x", package: "xpwu_x"),
													 .product(name: "xpwu_concurrency", package: "xpwu_concurrency")]),
        .testTarget(
            name: "xpwu_streamTests",
            dependencies: ["xpwu_stream"]),
    ]
)
