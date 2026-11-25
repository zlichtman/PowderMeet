// swift-tools-version: 6.0
import PackageDescription

// The only package that imports MapboxMaps (`specs/01-ARCHITECTURE.md` section 4).
// It is linked by the app alone, builds for iOS only and is not part of the Linux
// CI loop. Resolving the SDK needs a Mapbox downloads token in `~/.netrc`.
let package = Package(
    name: "MapboxAdapter",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MapboxAdapter", targets: ["MapboxAdapter"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
        .package(path: "../MapScene"),
        .package(path: "../Support"),
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", exact: "11.19.0"),
    ],
    targets: [
        .target(
            name: "MapboxAdapter",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "MapScene", package: "MapScene"),
                .product(name: "PMLogging", package: "Support"),
                .product(name: "MapboxMaps", package: "mapbox-maps-ios"),
            ]
        ),
    ]
)
