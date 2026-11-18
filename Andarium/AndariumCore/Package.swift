// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-2.0-or-later

import PackageDescription

// The Andarium application's model and policy, with no UIKit, SwiftUI or
// runtime dependency: `swift test` runs it on macOS, and the application and
// its Simulator preview import it. It re-exports GuestHostCore, what both
// applications decide the same way.
let package = Package(
    name: "AndariumCore",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AndariumCore", targets: ["AndariumCore"]),
        // For the application's hosted tests only: neither application links it.
        // Dynamic like the application's own product: a static copy would
        // give the test bundle a second AndariumCore, whose types the
        // application's code does not recognise (`error as? AdbError`).
        .library(name: "AndariumCoreTestSupport", type: .dynamic, targets: ["AndariumCoreTestSupport"]),
    ],
    dependencies: [
        .package(path: "../../GuestHost/Core"),
    ],
    targets: [
        .target(
            name: "AndariumCore",
            dependencies: [.product(name: "GuestHostCore", package: "Core")],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // Simulated controllers and the guest end of the gamepad wire, for tests
        // and the probe tool. The application never links it (the App Store
        // bundle check refuses a build that does); the hosted tests do.
        .target(
            name: "AndariumCoreTestSupport",
            dependencies: ["AndariumCore"]
        ),
        // Send feedback's logic, for the package's tests only. Its sources are the
        // application's own, which the application compiles only where Send
        // feedback is compiled in (a symlink to Andarium/Shared/Feedback/Logic),
        // so no product of the package carries any of it; here the condition is
        // always set. Neither application links it.
        .target(
            name: "AndariumFeedbackLogic",
            dependencies: ["AndariumCore"],
            swiftSettings: [.define("FEEDBACK_MAIL")]
        ),
        // Buy me tokens' logic, for the package's tests only, built the way
        // Send feedback's is: its sources are the application's own (a symlink to
        // Andarium/Shared/TipJar/Logic), which the application compiles only where
        // the tip jar is compiled in, so no product of the package carries any of
        // it; here the condition is always set. Neither application links it.
        .target(
            name: "AndariumTipJarLogic",
            swiftSettings: [.define("TIP_JAR")]
        ),
        // Review on the App Store's logic, for the package's tests only, built the
        // same way (a symlink to Andarium/Shared/Review/Logic).
        .target(
            name: "AndariumReviewLogic",
            swiftSettings: [.define("APP_REVIEW")]
        ),
        // Follow developer on X's logic, for the package's tests only, by the same
        // rule (a symlink to Andarium/Shared/FollowX/Logic).
        .target(
            name: "AndariumFollowXLogic",
            swiftSettings: [.define("FOLLOW_X")]
        ),
        // The ICP filing footnote's logic, for the package's tests only, by the same
        // rule (a symlink to Andarium/Shared/ICP/Logic).
        .target(
            name: "AndariumICPLogic",
            swiftSettings: [.define("ICP_FILING")]
        ),
        // A test-only tool that plays a gamepad script to the guest's relay.
        .executableTarget(
            name: "andarium-gamepad-probe",
            dependencies: ["AndariumCore", "AndariumCoreTestSupport"]
        ),
        .testTarget(
            name: "AndariumCoreTests",
            dependencies: ["AndariumCore", "AndariumCoreTestSupport", "AndariumFeedbackLogic", "AndariumFollowXLogic", "AndariumICPLogic", "AndariumTipJarLogic", "AndariumReviewLogic"]
        ),
    ]
)
