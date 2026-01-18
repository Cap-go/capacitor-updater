/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import UIKit
import Version

/// AppUpdateAvailability enum values matching TypeScript definitions
enum AppUpdateAvailability: Int {
    case unknown = 0
    case updateNotAvailable = 1
    case updateAvailable = 2
    case updateInProgress = 3
}

/// Manages App Store update checks and opening the App Store.
class AppStoreUpdateManager {
    private let logger: Logger
    private let appId: () -> String

    init(logger: Logger, appIdProvider: @escaping () -> String) {
        self.logger = logger
        self.appId = appIdProvider
    }

    /// Get App Store update information
    func getAppUpdateInfo(country: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let bundleId = appId()

        logger.info("Getting App Store update info for \(bundleId) in country \(country)")

        DispatchQueue.global(qos: .background).async {
            guard let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let encodedCountry = country.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode URL parameters"])))
                return
            }
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(encodedBundleId)&country=\(encodedCountry)"
            guard let url = URL(string: urlString) else {
                completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for App Store lookup"])))
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data received from App Store"])))
                    return
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let resultCount = json["resultCount"] as? Int else {
                        completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid response from App Store"])))
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

                    completion(.success(result))
                } catch {
                    self.logger.error("Failed to parse App Store response: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
            task.resume()
        }
    }

    /// Open the App Store page for the app
    func openAppStore(appId: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        if let appId = appId {
            // Open App Store with provided app ID
            let urlString = "https://apps.apple.com/app/id\(appId)"
            guard let url = URL(string: urlString) else {
                completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid App Store URL"])))
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to open App Store"])))
                    }
                }
            }
        } else {
            // Look up app ID using bundle identifier
            let bundleId = self.appId()
            guard let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode bundle ID"])))
                return
            }
            let lookupUrl = "https://itunes.apple.com/lookup?bundleId=\(encodedBundleId)"

            DispatchQueue.global(qos: .background).async {
                guard let url = URL(string: lookupUrl) else {
                    completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid lookup URL"])))
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { data, _, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]],
                          let appInfo = results.first,
                          let trackId = appInfo["trackId"] as? Int else {
                        // If lookup fails, try opening the generic App Store app page using bundle ID
                        guard let encodedBundleIdPath = bundleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                            completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode bundle ID for fallback URL"])))
                            return
                        }
                        let fallbackUrlString = "https://apps.apple.com/app/\(encodedBundleIdPath)"
                        guard let fallbackUrl = URL(string: fallbackUrlString) else {
                            completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to find app in App Store and fallback URL is invalid"])))
                            return
                        }
                        DispatchQueue.main.async {
                            UIApplication.shared.open(fallbackUrl) { success in
                                if success {
                                    completion(.success(()))
                                } else {
                                    completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to open App Store"])))
                                }
                            }
                        }
                        return
                    }

                    let appStoreUrl = "https://apps.apple.com/app/id\(trackId)"
                    guard let url = URL(string: appStoreUrl) else {
                        completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid App Store URL"])))
                        return
                    }

                    DispatchQueue.main.async {
                        UIApplication.shared.open(url) { success in
                            if success {
                                completion(.success(()))
                            } else {
                                completion(.failure(NSError(domain: "AppStoreUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to open App Store"])))
                            }
                        }
                    }
                }
                task.resume()
            }
        }
    }
}
