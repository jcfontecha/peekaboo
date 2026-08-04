// swift-tools-version: 6.2

import PackageDescription

let humanInputSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .unsafeFlags(["-parse-as-library"]),
]

// The repository root is the small public package consumed by Screeny. Peekaboo's
// own applications continue to compose the focused packages under Core/ directly.
let package = Package(
    name: "PeekabooHumanInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PeekabooHumanInput", targets: ["PeekabooHumanInput"]),
    ],
    targets: [
        .target(
            name: "PeekabooHumanInput",
            path: "Core/PeekabooHumanInput/Sources/PeekabooHumanInput",
            swiftSettings: humanInputSettings),
        .testTarget(
            name: "PeekabooHumanInputTests",
            dependencies: ["PeekabooHumanInput"],
            path: "Core/PeekabooHumanInput/Tests/PeekabooHumanInputTests",
            swiftSettings: humanInputSettings),
    ],
    swiftLanguageModes: [.v6])
