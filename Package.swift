// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapgoCapacitorUpdater",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "CapgoCapacitorUpdater",
            targets: ["CapacitorUpdaterPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.10.2")),
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", .upToNextMajor(from: "2.6.0")),
        .package(url: "https://github.com/mxcl/Version.git", .upToNextMajor(from: "2.1.0"))
    ],
    targets: [
        .target(
            name: "CapacitorUpdaterPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "ZipArchive", package: "ZipArchive"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "Version", package: "Version")
            ],
            path: "ios/Plugin"),
        .testTarget(
            name: "CapacitorUpdaterPluginTests",
            dependencies: ["CapacitorUpdaterPlugin"],
            path: "ios/PluginTests")
    ],
    swiftLanguageVersions: [.v5]
)
