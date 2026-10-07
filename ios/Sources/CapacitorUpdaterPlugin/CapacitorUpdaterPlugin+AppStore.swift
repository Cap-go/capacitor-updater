/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit

/// App Store methods stay native: iOS has no in-app update API.
extension CapacitorUpdaterPlugin {
    /// AppUpdateAvailability enum values matching TypeScript definitions
    private enum AppUpdateAvailability: Int {
        case unknown = 0
        case updateNotAvailable = 1
        case updateAvailable = 2
        case updateInProgress = 3
    }

    /// The active app id (config, `setAppId` or preview override), read from the engine.
    func activeAppId() -> String {
        if case .resolved(let value) = runEngineMethod("getAppId", [:]),
           let appId = (value as? [String: Any])?["appId"] as? String {
            return appId
        }
        return implementation.appId
    }

    @objc func getAppUpdateInfo(_ call: CAPPluginCall) {
        let country = call.getString("country", "US")
        DispatchQueue.global(qos: .background).async {
            let bundleId = self.activeAppId()
            self.logger.info("Getting App Store update info for \(bundleId) in country \(country)")
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)"
            guard let url = URL(string: urlString) else {
                call.reject("Invalid URL for App Store lookup")
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    call.reject("App Store lookup failed: \(error.localizedDescription)")
                    return
                }
                guard let data = data else {
                    call.reject("No data received from App Store")
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resultCount = json["resultCount"] as? Int else {
                    self.logger.error("Failed to parse App Store response")
                    call.reject("Invalid response from App Store")
                    return
                }

                let currentVersionName = Bundle.main.versionName ?? "0.0.0"
                let currentVersionCode = Bundle.main.versionCode ?? "0"
                var result: [String: Any] = [
                    "currentVersionName": currentVersionName,
                    "currentVersionCode": currentVersionCode,
                    "updateAvailability": AppUpdateAvailability.unknown.rawValue
                ]

                if resultCount > 0, let results = json["results"] as? [[String: Any]], let appInfo = results.first {
                    let availableVersion = appInfo["version"] as? String
                    result["availableVersionName"] = availableVersion
                    result["availableVersionCode"] = availableVersion // iOS doesn't have separate version code
                    result["availableVersionReleaseDate"] = appInfo["currentVersionReleaseDate"] as? String
                    result["minimumOsVersion"] = appInfo["minimumOsVersion"] as? String

                    var updateAvailable = false
                    if let availableVersion = availableVersion {
                        if let currentVer = try? CapgoSemanticVersion(currentVersionName),
                           let availableVer = try? CapgoSemanticVersion(availableVersion) {
                            updateAvailable = availableVer > currentVer
                        } else {
                            // If version parsing fails, do string comparison
                            updateAvailable = availableVersion != currentVersionName
                        }
                    }
                    result["updateAvailability"] = updateAvailable
                        ? AppUpdateAvailability.updateAvailable.rawValue
                        : AppUpdateAvailability.updateNotAvailable.rawValue
                    // iOS doesn't support in-app updates like Android
                    result["immediateUpdateAllowed"] = false
                    result["flexibleUpdateAllowed"] = false
                } else {
                    // App not found in App Store (maybe not published yet)
                    result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                    self.logger.info("App not found in App Store for bundleId: \(bundleId)")
                }
                call.resolve(result)
            }
            task.resume()
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")

        func openAppStorePage(urlString: String, invalidMessage: String = "Invalid App Store URL", failureMessage: String = "Failed to open App Store") {
            guard let url = URL(string: urlString) else {
                call.reject(invalidMessage)
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        call.resolve()
                    } else {
                        call.reject(failureMessage)
                    }
                }
            }
        }

        if let appId = appId {
            openAppStorePage(urlString: "https://apps.apple.com/app/id\(appId)")
            return
        }
        DispatchQueue.global(qos: .background).async {
            let bundleId = self.activeAppId()
            func openFallbackAppStorePage() {
                guard let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                    call.reject("Failed to build App Store fallback URL")
                    return
                }
                openAppStorePage(urlString: "https://apps.apple.com/app/\(encodedBundleId)")
            }
            guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)") else {
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

    @objc func performImmediateUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support in-app updates like Android's Play Store
        logger.warn("performImmediateUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("In-app updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func startFlexibleUpdate(_ call: CAPPluginCall) {
        logger.warn("startFlexibleUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("Flexible updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func completeFlexibleUpdate(_ call: CAPPluginCall) {
        logger.warn("completeFlexibleUpdate is not supported on iOS.")
        call.reject("Flexible updates are not supported on iOS.", "NOT_SUPPORTED")
    }
}
