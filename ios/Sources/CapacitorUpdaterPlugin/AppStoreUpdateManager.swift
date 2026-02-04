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

    private enum ErrorCode: Int {
        case invalidUrl = -1
        case openFailed = -2
        case lookupFailed = -3
    }

    init(logger: Logger, appIdProvider: @escaping () -> String) {
        self.logger = logger
        self.appId = appIdProvider
    }

    // MARK: - Helper Methods

    private func createError(code: ErrorCode, message: String) -> NSError {
        return NSError(
            domain: "AppStoreUpdateManager",
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func buildLookupUrl(bundleId: String, country: String) -> URL? {
        guard let encodedBundleId = bundleId.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ),
              let encodedCountry = country.addingPercentEncoding(
                  withAllowedCharacters: .urlQueryAllowed
              ) else {
            return nil
        }
        let urlString = "https://itunes.apple.com/lookup?bundleId=\(encodedBundleId)&country=\(encodedCountry)"
        return URL(string: urlString)
    }

    private func compareVersions(current: String, available: String) -> AppUpdateAvailability {
        do {
            let currentVer = try Version(current)
            let availableVer = try Version(available)
            return availableVer > currentVer ? .updateAvailable : .updateNotAvailable
        } catch {
            // If version parsing fails, do string comparison
            return available != current ? .updateAvailable : .updateNotAvailable
        }
    }

    private func parseAppStoreResponse(
        data: Data,
        bundleId: String
    ) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultCount = json["resultCount"] as? Int else {
            throw createError(code: .lookupFailed, message: "Invalid response from App Store")
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
            populateResultWithAppInfo(
                result: &result,
                appInfo: appInfo,
                currentVersionName: currentVersionName
            )
        } else {
            // App not found in App Store (maybe not published yet)
            result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
            logger.info("App not found in App Store for bundleId: \(bundleId)")
        }

        return result
    }

    private func populateResultWithAppInfo(
        result: inout [String: Any],
        appInfo: [String: Any],
        currentVersionName: String
    ) {
        let availableVersion = appInfo["version"] as? String
        let releaseDate = appInfo["currentVersionReleaseDate"] as? String
        let minimumOsVersion = appInfo["minimumOsVersion"] as? String

        result["availableVersionName"] = availableVersion
        result["availableVersionCode"] = availableVersion
        result["availableVersionReleaseDate"] = releaseDate
        result["minimumOsVersion"] = minimumOsVersion

        if let availableVersion = availableVersion {
            let availability = compareVersions(current: currentVersionName, available: availableVersion)
            result["updateAvailability"] = availability.rawValue
        } else {
            result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
        }

        // iOS doesn't support in-app updates like Android
        result["immediateUpdateAllowed"] = false
        result["flexibleUpdateAllowed"] = false
    }
}

// MARK: - Public API
extension AppStoreUpdateManager {
    /// Get App Store update information
    func getAppUpdateInfo(country: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let bundleId = appId()
        logger.info("Getting App Store update info for \(bundleId) in country \(country)")

        DispatchQueue.global(qos: .background).async {
            guard let url = self.buildLookupUrl(bundleId: bundleId, country: country) else {
                let error = self.createError(code: .invalidUrl, message: "Failed to encode URL parameters")
                completion(.failure(error))
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    let error = self.createError(code: .lookupFailed, message: "No data received")
                    completion(.failure(error))
                    return
                }

                do {
                    let result = try self.parseAppStoreResponse(data: data, bundleId: bundleId)
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
            openAppStoreWithId(appId: appId, completion: completion)
        } else {
            openAppStoreWithLookup(completion: completion)
        }
    }
}

// MARK: - App Store Opening
extension AppStoreUpdateManager {
    private func openAppStoreWithId(appId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let urlString = "https://apps.apple.com/app/id\(appId)"
        guard let url = URL(string: urlString) else {
            let error = createError(code: .invalidUrl, message: "Invalid App Store URL")
            completion(.failure(error))
            return
        }
        openUrl(url, completion: completion)
    }

    private func openAppStoreWithLookup(completion: @escaping (Result<Void, Error>) -> Void) {
        let bundleId = self.appId()
        guard let encodedBundleId = bundleId.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else {
            let error = createError(code: .invalidUrl, message: "Failed to encode bundle ID")
            completion(.failure(error))
            return
        }

        let lookupUrlString = "https://itunes.apple.com/lookup?bundleId=\(encodedBundleId)"
        guard let lookupUrl = URL(string: lookupUrlString) else {
            let error = createError(code: .invalidUrl, message: "Invalid lookup URL")
            completion(.failure(error))
            return
        }

        DispatchQueue.global(qos: .background).async {
            self.performLookupAndOpen(lookupUrl: lookupUrl, bundleId: bundleId, completion: completion)
        }
    }

    private func performLookupAndOpen(
        lookupUrl: URL,
        bundleId: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let task = URLSession.shared.dataTask(with: lookupUrl) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let appInfo = results.first,
                  let trackId = appInfo["trackId"] as? Int else {
                // If lookup fails, try opening with bundle ID
                self.openFallbackUrl(bundleId: bundleId, completion: completion)
                return
            }

            let appStoreUrl = "https://apps.apple.com/app/id\(trackId)"
            guard let url = URL(string: appStoreUrl) else {
                let error = self.createError(code: .invalidUrl, message: "Invalid App Store URL")
                completion(.failure(error))
                return
            }

            self.openUrl(url, completion: completion)
        }
        task.resume()
    }

    private func openFallbackUrl(bundleId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let encodedBundleIdPath = bundleId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else {
            let error = createError(code: .lookupFailed, message: "Failed to encode bundle ID for fallback")
            completion(.failure(error))
            return
        }

        let fallbackUrlString = "https://apps.apple.com/app/\(encodedBundleIdPath)"
        guard let fallbackUrl = URL(string: fallbackUrlString) else {
            let error = createError(code: .lookupFailed, message: "Failed to create fallback URL")
            completion(.failure(error))
            return
        }

        openUrl(fallbackUrl, completion: completion)
    }

    private func openUrl(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url) { success in
                if success {
                    completion(.success(()))
                } else {
                    let error = self.createError(code: .openFailed, message: "Failed to open App Store")
                    completion(.failure(error))
                }
            }
        }
    }
}
