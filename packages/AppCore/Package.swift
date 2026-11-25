// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
        .package(path: "../MeetSolver"),
        .package(path: "../DescentKit"),
        .package(path: "../MapScene"),
        .package(path: "../PowderMeetAPI"),
        .package(path: "../Support"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "MeetSolver", package: "MeetSolver"),
                .product(name: "DescentKit", package: "DescentKit"),
                .product(name: "MapScene", package: "MapScene"),
                .product(name: "PowderMeetAPI", package: "PowderMeetAPI"),
                .product(name: "PMLogging", package: "Support"),
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                "AppCore",
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "MeetSolver", package: "MeetSolver"),
                .product(name: "PowderMeetAPI", package: "PowderMeetAPI"),
                .product(name: "CZlib", package: "Support"),
            ]
        ),
    ]
)
