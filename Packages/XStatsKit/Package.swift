// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XStatsKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Localization", targets: ["Localization"]),
        .library(name: "AIUsage", targets: ["AIUsage"]),
        .library(name: "SMC", targets: ["SMC"]),
        .library(name: "Metrics", targets: ["Metrics"]),
        .library(name: "HelperShared", targets: ["HelperShared"]),
        .library(name: "Cleaner", targets: ["Cleaner"]),
        .library(name: "Updates", targets: ["Updates"]),
        .library(name: "WebDAVSync", targets: ["WebDAVSync"]),
        .library(name: "WidgetData", targets: ["WidgetData"]),
        .library(name: "XStatsUI", targets: ["XStatsUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/6tail/tyme4swift.git", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "Localization", resources: [.process("Resources")]),
        .target(name: "AIUsage"),
        .target(name: "SMC", dependencies: ["Localization"]),
        .target(name: "Metrics", dependencies: ["SMC", "Localization"], linkerSettings: [.linkedLibrary("IOReport")]),
        .target(name: "HelperShared", dependencies: ["Localization"]),
        .target(name: "Cleaner", dependencies: ["Localization"]),
        .target(name: "Updates", dependencies: ["Localization"]),
        .target(name: "WebDAVSync", dependencies: ["Localization"]),
        .target(name: "WidgetData"),
        .target(name: "XStatsUI", dependencies: ["AIUsage", "Localization", "Metrics", "SMC", "HelperShared", "Cleaner", "Updates", "WebDAVSync", "WidgetData",
                                                   .product(name: "Tyme4Swift", package: "tyme4swift")],
                resources: [.copy("Resources/Flags"), .copy("Resources/Logos"), .copy("Resources/Legal")]),
        .testTarget(name: "MetricsTests", dependencies: ["Metrics", "SMC"]),
        .testTarget(name: "CleanerTests", dependencies: ["Cleaner"]),
        .testTarget(name: "HelperSharedTests", dependencies: ["HelperShared"]),
        .testTarget(name: "UpdatesTests", dependencies: ["Updates"]),
        .testTarget(name: "WebDAVSyncTests", dependencies: ["WebDAVSync"]),
        .testTarget(name: "XStatsUITests", dependencies: ["XStatsUI", "Metrics", "WebDAVSync", "Localization", "Updates"]),
        .testTarget(name: "LocalizationTests", dependencies: ["Localization"]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage"]),
        .testTarget(name: "WidgetDataTests", dependencies: ["WidgetData"]),
    ],
    swiftLanguageModes: [.v6]
)
