// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 luwenjie

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
        ),
        .plugin(
            name: "AppleViewModelDependencyCheck",
            targets: ["AppleViewModelDependencyCheck"]
        ),
        .plugin(
            name: "AppleViewModelLint",
            targets: ["AppleViewModelLint"]
        )
    ],
    dependencies: [
        // Used only by the optional source scanner, never by the runtime library.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.1"..<"605.0.0")
    ],
    targets: [
        .target(
            name: "AppleViewModel",
            path: "Sources/AppleViewModel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "DependencyScannerCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            path: "Tools/DependencyScannerCore"
        ),
        .executableTarget(
            name: "AppleViewModelDependencyScanner",
            dependencies: ["DependencyScannerCore"],
            path: "Tools/AppleViewModelDependencyScanner"
        ),
        .plugin(
            name: "AppleViewModelDependencyCheck",
            capability: .buildTool(),
            dependencies: ["AppleViewModelDependencyScanner"]
        ),
        .plugin(
            name: "AppleViewModelLint",
            capability: .buildTool(),
            dependencies: ["AppleViewModelDependencyScanner"]
        ),
        .testTarget(
            name: "DependencyScannerTests",
            dependencies: ["DependencyScannerCore"]
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
