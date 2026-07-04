// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BlobCanvas",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BlobCanvas", targets: ["BlobCanvas"]),
    ],
    targets: [
        .target(
            name: "BlobCanvas",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BlobCanvasTests",
            dependencies: ["BlobCanvas"]
        ),
    ]
)
