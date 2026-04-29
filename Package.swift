// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppleViewModel",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "AppleViewModel",
            targets: ["AppleViewModel"]
        )
    ],
    targets: [
        .target(
            name: "AppleViewModel",
            path: "Sources/AppleViewModel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AppleViewModelTests",
            dependencies: ["AppleViewModel"],
            path: "Tests/AppleViewModelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
