// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MediaMindAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaMindCore", targets: ["MediaMindCore"]),
    ],
    targets: [
        .target(
            name: "MediaMindCore",
            path: "Sources",
            exclude: ["App", "UI"]
        ),
        .testTarget(
            name: "MediaMindCoreTests",
            dependencies: ["MediaMindCore"],
            path: "Tests/MediaMindCoreTests",
            resources: [
                .copy("naming_fixtures.json"),
            ]
        ),
    ]
)
