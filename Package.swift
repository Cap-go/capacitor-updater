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
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.10.2")),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
        .package(url: "https://github.com/mrackwitz/Version.git", exact: "0.8.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0")
    ],
    targets: [
        .target(
            name: "CapacitorUpdaterPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "Version", package: "Version"),
                .product(name: "BigInt", package: "BigInt")
            ],
            path: "ios/Sources/CapacitorUpdaterPlugin"),
        .testTarget(
            name: "CapacitorUpdaterPluginTests",
            dependencies: ["CapacitorUpdaterPlugin"],
            path: "ios/Tests/CapacitorUpdaterPluginTests")
    ],
    swiftLanguageVersions: [.v5]
)
