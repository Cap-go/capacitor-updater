/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit
import WebKit
import Version

extension CapacitorUpdaterPlugin {
    @objc func appMovedToForeground() {
        appHealthTracker?.markForeground(true)
        let current: BundleInfo = self.implementation.getCurrentBundle()
        self.implementation.sendStats(action: "app_moved_to_foreground", versionName: current.getVersionName())
        self.delayUpdateUtils.checkCancelDelay(source: .foreground)
        self.delayUpdateUtils.unsetBackgroundTimestamp()
        if backgroundWork != nil && taskRunning {
            backgroundWork!.cancel()
            logger.info("Background Timer Task canceled, Activity resumed before timer completes")
        }
        if self.isAutoUpdateEnabledInternal() {
            // Check if download is already in progress (with timeout protection)
            if !isDownloadStuckOrTimedOut() {
                self.backgroundDownload()
            } else {
                logger.info("Download already in progress, skipping duplicate download request")
            }
        } else {
            let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
            if instanceDescriptor?.serverURL != nil {
                self.implementation.sendStats(action: "blocked_by_server_url", versionName: current.getVersionName())
            }
            logger.info("Auto update is disabled")
            self.sendReadyToJs(current: current, msg: "disabled")
        }
        self.checkAppReady()
    }

    @objc func checkForUpdateAfterDelay() {
        if periodCheckDelay == 0 || !self.isAutoUpdateEnabledInternal() {
            return
        }
        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            return
        }

        // Clean up any existing timer
        periodicUpdateTimer?.invalidate()

        periodicUpdateTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(periodCheckDelay), repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let res = self.implementation.getLatest(url: url, channel: nil)
                let current = self.implementation.getCurrentBundle()

                if res.version != current.getVersionName() {
                    self.logger.info("New version found: \(res.version)")
                    // Check if download is already in progress (with timeout protection)
                    if !self.isDownloadStuckOrTimedOut() {
                        self.backgroundDownload()
                    } else {
                        self.logger.info("Download already in progress, skipping duplicate download request")
                    }
                }
            }
        }
        RunLoop.current.add(periodicUpdateTimer!, forMode: .default)
    }

    @objc func appMovedToBackground() {
        // Reset timeout flag at start of each background cycle
        self.autoSplashscreenTimedOut = false
        appHealthTracker?.markForeground(false)

        let current: BundleInfo = self.implementation.getCurrentBundle()
        self.implementation.sendStats(action: "app_moved_to_background", versionName: current.getVersionName())
        logger.info("Check for pending update")

        // Show splashscreen only if autoSplashscreen is enabled AND autoUpdate is enabled AND directUpdate would be used
        if self.autoSplashscreen {
            var canShowSplashscreen = true

            if !self.isAutoUpdateEnabledInternal() {
                logger.warn("autoSplashscreen is enabled but autoUpdate is disabled. Splashscreen will not be shown. Enable autoUpdate or disable autoSplashscreen.")
                canShowSplashscreen = false
            }

            if !self.shouldUseDirectUpdate() {
                if self.directUpdateMode == "false" {
                    logger.warn("autoSplashscreen is enabled but directUpdate is not configured for immediate updates. Set directUpdate to 'always' or disable autoSplashscreen.")
                } else if self.directUpdateMode == "atInstall" || self.directUpdateMode == "onLaunch" {
                    logger.info("autoSplashscreen is enabled but directUpdate is set to \"\(self.directUpdateMode)\". This is normal. Skipping autoSplashscreen logic.")
                }
                canShowSplashscreen = false
            }

            if canShowSplashscreen {
                self.showSplashscreen()
            }
        }

        // Set background timestamp
        let backgroundTimestamp = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
        self.delayUpdateUtils.setBackgroundTimestamp(backgroundTimestamp)
        self.delayUpdateUtils.checkCancelDelay(source: .background)
        self.installNext()
    }

    @objc func getNextBundle(_ call: CAPPluginCall) {
        let bundle = self.implementation.getNextBundle()
        if bundle == nil || bundle?.isUnknown() == true {
            call.resolve()
            return
        }

        call.resolve(bundle!.toJSON())
    }

    @objc func getFailedUpdate(_ call: CAPPluginCall) {
        let bundle = self.readLastFailedBundle()
        if bundle == nil || bundle?.isUnknown() == true {
            call.resolve()
            return
        }

        self.persistLastFailedBundle(nil)
        call.resolve([
            "bundle": bundle!.toJSON()
        ])
    }

    @objc func setShakeMenu(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            logger.error("setShakeMenu called without enabled parameter")
            call.reject("setShakeMenu called without enabled parameter")
            return
        }

        self.shakeMenuEnabled = enabled
        logger.info("Shake menu \(enabled ? "enabled" : "disabled")")
        call.resolve()
    }

    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeMenuEnabled
        ])
    }

    @objc func setShakeChannelSelector(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            logger.error("setShakeChannelSelector called without enabled parameter")
            call.reject("setShakeChannelSelector called without enabled parameter")
            return
        }

        self.shakeChannelSelectorEnabled = enabled
        logger.info("Shake channel selector \(enabled ? "enabled" : "disabled")")
        call.resolve()
    }

    @objc func isShakeChannelSelectorEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeChannelSelectorEnabled
        ])
    }

    @objc func getAppId(_ call: CAPPluginCall) {
        call.resolve([
            "appId": implementation.appId
        ])
    }

    @objc func setAppId(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyAppId", false) {
            logger.error("setAppId called without allowModifyAppId")
            call.reject("setAppId called without allowModifyAppId set allowModifyAppId in your config to true to allow it")
            return
        }
        guard let appId = call.getString("appId") else {
            logger.error("setAppId called without appId")
            call.reject("setAppId called without appId")
            return
        }
        implementation.appId = appId
        call.resolve()
    }

    // MARK: - App Store Update Methods

    /// AppUpdateAvailability enum values matching TypeScript definitions
    enum AppUpdateAvailability: Int {
        case unknown = 0
        case updateNotAvailable = 1
        case updateAvailable = 2
        case updateInProgress = 3
    }

    @objc func getAppUpdateInfo(_ call: CAPPluginCall) {
        let country = call.getString("country", "US")
        let bundleId = implementation.appId

        logger.info("Getting App Store update info for \(bundleId) in country \(country)")

        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .background).async {
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)"
            guard let url = URL(string: urlString) else {
                self.rejectCall(call, message: "Invalid URL for App Store lookup")
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    self.rejectCall(call, message: "App Store lookup failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    self.rejectCall(call, message: "No data received from App Store")
                    return
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let resultCount = json["resultCount"] as? Int else {
                        self.rejectCall(call, message: "Invalid response from App Store")
                        return
                    }

                    let currentVersionName = Bundle.main.versionName ?? "0.0.0"
                    let currentVersionCode = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

                    var result: [String: Any] = [
                        "currentVersionName": currentVersionName,
                        "currentVersionCode": currentVersionCode,
                        "updateAvailability": AppUpdateAvailability.unknown.rawValue
                    ]

                    if resultCount > 0,
                       let results = json["results"] as? [[String: Any]],
                       let appInfo = results.first {

                        let availableVersion = appInfo["version"] as? String
                        let releaseDate = appInfo["currentVersionReleaseDate"] as? String
                        let minimumOsVersion = appInfo["minimumOsVersion"] as? String

                        result["availableVersionName"] = availableVersion
                        result["availableVersionCode"] = availableVersion // iOS doesn't have separate version code
                        result["availableVersionReleaseDate"] = releaseDate
                        result["minimumOsVersion"] = minimumOsVersion

                        // Determine update availability by comparing versions
                        if let availableVersion = availableVersion {
                            do {
                                let currentVer = try Version(currentVersionName)
                                let availableVer = try Version(availableVersion)
                                if availableVer > currentVer {
                                    result["updateAvailability"] = AppUpdateAvailability.updateAvailable.rawValue
                                } else {
                                    result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                                }
                            } catch {
                                // If version parsing fails, do string comparison
                                if availableVersion != currentVersionName {
                                    result["updateAvailability"] = AppUpdateAvailability.updateAvailable.rawValue
                                } else {
                                    result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                                }
                            }
                        } else {
                            result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                        }

                        // iOS doesn't support in-app updates like Android
                        result["immediateUpdateAllowed"] = false
                        result["flexibleUpdateAllowed"] = false
                    } else {
                        // App not found in App Store (maybe not published yet)
                        result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                        self.logger.info("App not found in App Store for bundleId: \(bundleId)")
                    }

                    self.resolveCall(call, data: result)
                } catch {
                    self.logger.error("Failed to parse App Store response: \(error.localizedDescription)")
                    self.rejectCall(call, message: "Failed to parse App Store response: \(error.localizedDescription)")
                }
            }
            task.resume()
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")
        let bundleId = implementation.appId
        self.saveCallForAsyncHandling(call)

        func openAppStorePage(urlString: String, invalidMessage: String = "Invalid App Store URL", failureMessage: String = "Failed to open App Store") {
            guard let url = URL(string: urlString) else {
                self.rejectCall(call, message: invalidMessage)
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        self.resolveCall(call)
                    } else {
                        self.rejectCall(call, message: failureMessage)
                    }
                }
            }
        }

        func openFallbackAppStorePage() {
            guard let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                self.rejectCall(call, message: "Failed to build App Store fallback URL")
                return
            }
            openAppStorePage(urlString: "https://apps.apple.com/app/\(encodedBundleId)")
        }

        if let appId = appId {
            openAppStorePage(urlString: "https://apps.apple.com/app/id\(appId)")
        } else {
            let lookupUrl = "https://itunes.apple.com/lookup?bundleId=\(bundleId)"

            DispatchQueue.global(qos: .background).async {
                guard let url = URL(string: lookupUrl) else {
                    openFallbackAppStorePage()
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { data, _, error in
                    if let error = error {
                        self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                        openFallbackAppStorePage()
                        return
                    }

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]],
                          let appInfo = results.first,
                          let trackId = appInfo["trackId"] as? Int else {
                        openFallbackAppStorePage()
                        return
                    }

                    openAppStorePage(urlString: "https://apps.apple.com/app/id\(trackId)")
                }
                task.resume()
            }
        }
    }

    @objc func performImmediateUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support in-app updates like Android's Play Store
        // Redirect users to the App Store instead
        logger.warn("performImmediateUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("In-app updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func startFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("startFlexibleUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("Flexible updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func completeFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("completeFlexibleUpdate is not supported on iOS.")
        call.reject("Flexible updates are not supported on iOS.", "NOT_SUPPORTED")
    }
}
