// swift-tools-version: 5.9
import PackageDescription

// DO NOT MODIFY THIS FILE - managed by Capacitor CLI commands
let package = Package(
    name: "CapApp-SPM",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapApp-SPM",
            targets: ["CapApp-SPM"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.0.0"),
        .package(name: "CapacitorApp", path: "../../../node_modules/.bun/@capacitor+app@8.0.1+15e98482558ccfe6/node_modules/@capacitor/app"),
        .package(name: "CapacitorSplashScreen", path: "../../../node_modules/.bun/@capacitor+splash-screen@8.0.1+15e98482558ccfe6/node_modules/@capacitor/splash-screen"),
        .package(name: "CapgoCapacitorUpdater", path: "../../../node_modules/.bun/@capgo+capacitor-updater@file+../node_modules/@capgo/capacitor-updater")
    ],
    targets: [
        .target(
            name: "CapApp-SPM",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "CapacitorApp", package: "CapacitorApp"),
                .product(name: "CapacitorSplashScreen", package: "CapacitorSplashScreen"),
                .product(name: "CapgoCapacitorUpdater", package: "CapgoCapacitorUpdater")
            ]
        )
    ]
)
