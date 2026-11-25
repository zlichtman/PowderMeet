// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Support",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CZlib", targets: ["CZlib"]),
        .library(name: "CSQLite", targets: ["CSQLite"]),
        .library(name: "PMLogging", targets: ["PMLogging"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"])]
        ),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "PMLogging"),
        .testTarget(
            name: "PMLoggingTests",
            dependencies: ["PMLogging", "CZlib", "CSQLite"]
        ),
    ]
)
