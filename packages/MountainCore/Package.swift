// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MountainCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MountainCore", targets: ["MountainCore"]),
    ],
    dependencies: [
        .package(path: "../Support"),
    ],
    targets: [
        .target(
            name: "MountainCore",
            dependencies: [
                .product(name: "CZlib", package: "Support"),
            ]
        ),
        .testTarget(
            name: "MountainCoreTests",
            dependencies: [
                "MountainCore",
                .product(name: "CZlib", package: "Support"),
            ]
        ),
    ]
)
