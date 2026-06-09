// swift-tools-version: 6.0
// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "Typeset",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .executable(name: "Typeset", targets: ["TypesetApp"]),
        .library(name: "TypesetCore", targets: ["TypesetCore"]),
    ],
    targets: [
        .target(name: "TypesetCore"),
        .executableTarget(
            name: "TypesetApp",
            dependencies: ["TypesetCore"]
        ),
        .testTarget(
            name: "TypesetCoreTests",
            dependencies: ["TypesetCore"]
        ),
    ]
)
