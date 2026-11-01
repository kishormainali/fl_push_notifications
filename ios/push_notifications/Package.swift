// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "push_notifications",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "push-notifications", targets: ["push_notifications"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "push_notifications",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Declares the UserDefaults required-reason API (CA92.1) used
                // for the badge counter, background config and launch ids.
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
