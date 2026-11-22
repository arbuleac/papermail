// swift-tools-version: 6.0
import PackageDescription

// Release builds treat warnings as errors in every target, the app and its tests included.
let settings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .release)),
]

let package = Package(
    name: "Paper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Paper", targets: ["PaperApp"]),
        .library(name: "PaperCore", targets: ["PaperCore"]),
        .library(name: "PaperGmail", targets: ["PaperGmail"]),
        .library(name: "PaperGraph", targets: ["PaperGraph"]),
        .library(name: "PaperDesign", targets: ["PaperDesign"]),
        .library(name: "PaperAI", targets: ["PaperAI"]),
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
            name: "PaperCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            swiftSettings: settings
        ),
        .target(name: "PaperGmail", dependencies: ["PaperCore"], swiftSettings: settings),
        .target(name: "PaperGraph", dependencies: ["PaperCore"], swiftSettings: settings),
        // Help Me Write's adapters (docs/ARCHITECTURE.md, "AI"): the Anthropic and OpenAI APIs over URLSession, and
        // the user's Claude Code and Codex CLIs as processes. Foundation only, like the mail adapters.
        .target(name: "PaperAI", dependencies: ["PaperCore"], swiftSettings: settings),
        // The Quire design runtime. Kept out of the executable so it can be unit-tested, and free of
        // PaperCore, GRDB and WebKit so tokens never pull the mail stack into a test or a preview.
        .target(
            name: "PaperDesign",
            swiftSettings: settings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "PaperApp",
            dependencies: [
                "PaperCore", "PaperGmail", "PaperGraph", "PaperDesign", "PaperAI",
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
        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"], swiftSettings: settings),
        .testTarget(name: "PaperGmailTests", dependencies: ["PaperGmail"], swiftSettings: settings),
        .testTarget(name: "PaperGraphTests", dependencies: ["PaperGraph"], swiftSettings: settings),
        .testTarget(name: "PaperDesignTests", dependencies: ["PaperDesign"], swiftSettings: settings),
        // Recorded CLI runs and API error bodies live in Fixtures/ as files (redacted; see Fixtures/README.md), read
        // through Bundle.module: SSE and JSONL fixtures must keep their exact bytes, which string constants would not.
        .testTarget(name: "PaperAITests", dependencies: ["PaperAI", "PaperCore"], resources: [.copy("Fixtures")], swiftSettings: settings),
        // The app's own views (the message list): behaviour always, timings with PAPER_PERF=1, state renders with
        // PAPER_UI_TESTS=1. SwiftPM lets a test target import an executable target.
        .testTarget(name: "PaperAppTests", dependencies: [
            "PaperApp", "PaperCore", "PaperDesign", .product(name: "Sentry", package: "sentry-cocoa"),
        ], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5]
)
