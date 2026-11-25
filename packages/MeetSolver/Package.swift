// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetSolver",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeetSolver", targets: ["MeetSolver"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
    ],
    targets: [
        .target(
            name: "MeetSolver",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
            ]
        ),
        .testTarget(
            name: "MeetSolverTests",
            dependencies: ["MeetSolver"]
        ),
    ]
)
