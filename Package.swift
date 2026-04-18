// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppleViewModel",
    // The primary target is iOS, but macOS / tvOS / watchOS / visionOS are
    // declared as well so that:
    //   1. `swift test` runs natively on Mac for CI and local development.
    //   2. The Core layer has no UIKit dependency, so expanding to the rest
    //      of the Apple family is essentially free.
    //   3. UIKit-only files are guarded with `#if canImport(UIKit)`, so
    //      native macOS builds simply skip them.
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
