// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapgoCapacitorUpdater",
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "CapacitorUpdaterPlugin",
            targets: ["CapacitorUpdaterPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", branch: "6.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.9.1")),
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", .upToNextMajor(from: "2.5.1")),
        .package(url: "https://github.com/mxcl/Version.git", .upToNextMajor(from: "2.0.0"))
    ],
    targets: [
        .target(
            name: "CapacitorUpdaterPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "SSZipArchive", package: "ZipArchive"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "Version", package: "Version")
            ],
            path: "ios/Sources/CapacitorUpdaterPlugin"),
        .testTarget(
            name: "CapacitorUpdaterPluginTests",
            dependencies: ["CapacitorUpdaterPlugin"],
            path: "ios/Tests/CapacitorUpdaterPluginTests")
    ]
)
