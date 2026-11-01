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
        .executableTarget(
            name: "SuperSparrowApp",
            dependencies: ["SSCore", "SSGmail", "SSGraph"],
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
    ],
    swiftLanguageModes: [.v5]
)
