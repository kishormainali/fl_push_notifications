// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// Flutter's SwiftPM integration links this package next to a generated
// `FlutterFramework` package (`../FlutterFramework`, through a symlinked
// copy of this directory). Outside a Flutter build that package does not
// exist, so the Flutter-free targets are tested with:
//
//     PUSH_NOTIFICATIONS_CORE_ONLY=1 swift test
//
// which leaves the Flutter plugin target out. (The manifest is evaluated at
// the real path, so the generated package cannot be detected on disk.)
let coreOnly = ProcessInfo.processInfo.environment["PUSH_NOTIFICATIONS_CORE_ONLY"] != nil

let coreTargets: [Target] = [
    // Pure logic shared by the plugin and the Notification Service Extension:
    // image download, notification content building, tap payload queue.
    .target(name: "PushNotificationsCore"),
    // Ready-made `UNNotificationServiceExtension` for host app extensions.
    .target(
        name: "PushNotificationsServiceExtension",
        dependencies: ["PushNotificationsCore"]
    ),
    .testTarget(
        name: "PushNotificationsCoreTests",
        dependencies: ["PushNotificationsCore", "PushNotificationsServiceExtension"]
    ),
]

let pluginTargets: [Target] = [
    .target(
        name: "push_notifications",
        dependencies: [
            "PushNotificationsCore",
            .product(name: "FlutterFramework", package: "FlutterFramework"),
        ],
        resources: [
            // Declares the UserDefaults required-reason API (CA92.1) used
            // for the badge counter, background config and launch ids.
            .process("PrivacyInfo.xcprivacy"),
        ]
    )
]

let extensionProduct: Product = .library(
    name: "PushNotificationsServiceExtension",
    targets: ["PushNotificationsServiceExtension"]
)

let package = Package(
    name: "push_notifications",
    platforms: [
        .iOS("15.0"),
        // Only so the Flutter-free targets can be tested with `swift test`.
        .macOS("12.0"),
    ],
    products: coreOnly
        ? [extensionProduct]
        : [
            .library(name: "push-notifications", targets: ["push_notifications"]),
            extensionProduct,
        ],
    dependencies: coreOnly
        ? []
        : [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: coreOnly ? coreTargets : pluginTargets + coreTargets
)
