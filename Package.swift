// swift-tools-version: 6.0
import PackageDescription

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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
    ],
    targets: [
        .target(
            name: "SSCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(name: "SSGmail", dependencies: ["SSCore"]),
        .target(name: "SSGraph", dependencies: ["SSCore"]),
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
            dependencies: ["SSCore", "SSGmail", "SSGraph", "SSDesign"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "SSCoreTests", dependencies: ["SSCore"]),
        .testTarget(name: "SSGmailTests", dependencies: ["SSGmail"]),
        .testTarget(name: "SSGraphTests", dependencies: ["SSGraph"]),
        .testTarget(name: "SSDesignTests", dependencies: ["SSDesign"]),
    ],
    swiftLanguageModes: [.v5]
)
