// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DescentKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DescentKit", targets: ["DescentKit"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
        .package(path: "../Support"),
    ],
    targets: [
        .target(
            name: "DescentKit",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "CZlib", package: "Support"),
                .product(name: "CSQLite", package: "Support"),
            ]
        ),
        .testTarget(
            name: "DescentKitTests",
            dependencies: ["DescentKit", .product(name: "CSQLite", package: "Support")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
