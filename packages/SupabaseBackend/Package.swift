// swift-tools-version: 6.0
import PackageDescription

// The only package that imports the Supabase SDK (`specs/01-ARCHITECTURE.md`
// section 4). It is linked by the app alone and is not part of the Linux CI loop.
let package = Package(
    name: "SupabaseBackend",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SupabaseBackend", targets: ["SupabaseBackend"]),
    ],
    dependencies: [
        .package(path: "../MountainCore"),
        .package(path: "../PowderMeetAPI"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.30.0"),
    ],
    targets: [
        .target(
            name: "SupabaseBackend",
            dependencies: [
                .product(name: "MountainCore", package: "MountainCore"),
                .product(name: "PowderMeetAPI", package: "PowderMeetAPI"),
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
    ]
)
