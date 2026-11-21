// swift-tools-version: 6.0
import PackageDescription

// Release builds treat warnings as errors in every target, the app and its tests included.
let settings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .release)),
]

let package = Package(
    name: "SuperSparrow",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SuperSparrow", targets: ["SuperSparrowApp"]),
        .library(name: "SSCore", targets: ["SSCore"]),
        .library(name: "SSGmail", targets: ["SSGmail"]),
        .library(name: "SSGraph", targets: ["SSGraph"]),
        .library(name: "SSDesign", targets: ["SSDesign"]),
        .library(name: "SSAI", targets: ["SSAI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
        // Crash reporting (docs/ARCHITECTURE.md, "Crash reports"): the static binary SDK, scrubbed before every send.
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.35.0"),
        // Product analytics (docs/ARCHITECTURE.md, "Analytics"): a closed catalog of signals, behind the same switch.
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK.git", from: "2.14.2"),
    ],
    targets: [
        .target(
            name: "SSCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            swiftSettings: settings
        ),
        .target(name: "SSGmail", dependencies: ["SSCore"], swiftSettings: settings),
        .target(name: "SSGraph", dependencies: ["SSCore"], swiftSettings: settings),
        // Help Me Write's adapters (docs/ARCHITECTURE.md, "AI"): the Anthropic and OpenAI APIs over URLSession, and
        // the user's Claude Code and Codex CLIs as processes. Foundation only, like the mail adapters.
        .target(name: "SSAI", dependencies: ["SSCore"], swiftSettings: settings),
        // The Quire design runtime. Kept out of the executable so it can be unit-tested, and free of
        // SSCore, GRDB and WebKit so tokens never pull the mail stack into a test or a preview.
        .target(
            name: "SSDesign",
            swiftSettings: settings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "SuperSparrowApp",
            dependencies: [
                "SSCore", "SSGmail", "SSGraph", "SSDesign", "SSAI",
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            swiftSettings: settings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "SSCoreTests", dependencies: ["SSCore"], swiftSettings: settings),
        .testTarget(name: "SSGmailTests", dependencies: ["SSGmail"], swiftSettings: settings),
        .testTarget(name: "SSGraphTests", dependencies: ["SSGraph"], swiftSettings: settings),
        .testTarget(name: "SSDesignTests", dependencies: ["SSDesign"], swiftSettings: settings),
        // Recorded CLI runs and API error bodies live in Fixtures/ as files (redacted; see Fixtures/README.md), read
        // through Bundle.module: SSE and JSONL fixtures must keep their exact bytes, which string constants would not.
        .testTarget(name: "SSAITests", dependencies: ["SSAI", "SSCore"], resources: [.copy("Fixtures")], swiftSettings: settings),
        // The app's own views (the message list): behaviour always, timings with SS_PERF=1, state renders with
        // SS_UI_TESTS=1. SwiftPM lets a test target import an executable target.
        .testTarget(name: "SuperSparrowAppTests", dependencies: [
            "SuperSparrowApp", "SSCore", "SSDesign", .product(name: "Sentry", package: "sentry-cocoa"),
        ], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5]
)
