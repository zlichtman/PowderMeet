// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapScene",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MapScene", targets: ["MapScene"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
        .package(path: "../MeetSolver"),
    ],
    targets: [
        .target(
            name: "MapScene",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "MeetSolver", package: "MeetSolver"),
            ]
        ),
        .testTarget(
            name: "MapSceneTests",
            dependencies: ["MapScene"]
        ),
    ]
)
