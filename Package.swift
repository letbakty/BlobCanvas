// swift-tools-version: 6.0
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
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BlobCanvasTests",
            dependencies: ["BlobCanvas"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
