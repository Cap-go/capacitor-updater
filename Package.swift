// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapgoCapacitorUpdater",
    platforms: [.iOS("15.0")],
    products: [
        .library(
            name: "CapgoCapacitorUpdater",
            targets: ["CapacitorUpdaterPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        // Shared Rust updater core (core/), built by scripts/build-core.sh ios.
        .binaryTarget(
            name: "CapgoUpdaterCore",
            path: "ios/Frameworks/CapgoUpdaterCore.xcframework"),
        .target(
            name: "CapacitorUpdaterPlugin",
            dependencies: [
                "CapgoUpdaterCore",
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/CapacitorUpdaterPlugin"),
        .testTarget(
            name: "CapacitorUpdaterPluginTests",
            dependencies: [
                "CapacitorUpdaterPlugin"
            ],
            path: "ios/Tests/CapacitorUpdaterPluginTests")
    ],
    swiftLanguageVersions: [.v5]
)
