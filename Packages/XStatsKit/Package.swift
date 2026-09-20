// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XStatsKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Localization", targets: ["Localization"]),
        .library(name: "SMC", targets: ["SMC"]),
        .library(name: "Metrics", targets: ["Metrics"]),
        .library(name: "HelperShared", targets: ["HelperShared"]),
        .library(name: "Cleaner", targets: ["Cleaner"]),
        .library(name: "Updates", targets: ["Updates"]),
        .library(name: "WebDAVSync", targets: ["WebDAVSync"]),
        .library(name: "XStatsUI", targets: ["XStatsUI"]),
    ],
    targets: [
        .target(name: "Localization"),
        .target(name: "SMC", dependencies: ["Localization"]),
        .target(name: "Metrics", dependencies: ["SMC", "Localization"], linkerSettings: [.linkedLibrary("IOReport")]),
        .target(name: "HelperShared", dependencies: ["Localization"]),
        .target(name: "Cleaner", dependencies: ["Localization"]),
        .target(name: "Updates", dependencies: ["Localization"]),
        .target(name: "WebDAVSync", dependencies: ["Localization"]),
        .target(name: "XStatsUI", dependencies: ["Localization", "Metrics", "SMC", "HelperShared", "Cleaner", "Updates", "WebDAVSync"],
                resources: [.copy("Resources/Flags"), .copy("Resources/Logos")]),
        .testTarget(name: "MetricsTests", dependencies: ["Metrics", "SMC"]),
        .testTarget(name: "CleanerTests", dependencies: ["Cleaner"]),
        .testTarget(name: "HelperSharedTests", dependencies: ["HelperShared"]),
        .testTarget(name: "UpdatesTests", dependencies: ["Updates"]),
        .testTarget(name: "WebDAVSyncTests", dependencies: ["WebDAVSync"]),
        .testTarget(name: "XStatsUITests", dependencies: ["XStatsUI", "Metrics", "WebDAVSync"]),
        .testTarget(name: "LocalizationTests", dependencies: ["Localization"]),
    ],
    swiftLanguageModes: [.v6]
)
