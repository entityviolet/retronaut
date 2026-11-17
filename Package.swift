// SPDX-License-Identifier: GPL-3.0-or-later
// Retronaut — https://github.com/entityviolet/retronaut
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Retronaut",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Retronaut", targets: ["Retronaut"]),
    ],
    targets: [
        .target(
            name: "Retronaut",
            path: "Sources/Retronaut",
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("GameController"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
