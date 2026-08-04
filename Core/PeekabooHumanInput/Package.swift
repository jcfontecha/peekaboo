// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .unsafeFlags(["-parse-as-library"]),
]

let package = Package(
    name: "PeekabooHumanInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PeekabooHumanInput", targets: ["PeekabooHumanInput"]),
    ],
    targets: [
        .target(name: "PeekabooHumanInput", swiftSettings: swiftSettings),
        .testTarget(
            name: "PeekabooHumanInputTests",
            dependencies: ["PeekabooHumanInput"],
            swiftSettings: swiftSettings + [.enableExperimentalFeature("SwiftTesting")]),
    ],
    swiftLanguageModes: [.v6])
