// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowderMeetAPI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PowderMeetAPI", targets: ["PowderMeetAPI"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
    ],
    targets: [
        .target(
            name: "PowderMeetAPI",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
            ]
        ),
        .testTarget(
            name: "PowderMeetAPITests",
            dependencies: ["PowderMeetAPI"]
        ),
    ]
)
