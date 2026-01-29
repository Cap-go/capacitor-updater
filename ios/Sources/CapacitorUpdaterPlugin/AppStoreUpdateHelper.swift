import Foundation
import UIKit
import Version

/// AppUpdateAvailability enum values matching TypeScript definitions
public enum AppUpdateAvailability: Int {
    case unknown = 0
    case updateNotAvailable = 1
    case updateAvailable = 2
    case updateInProgress = 3
}

/// Helper class for App Store update functionality
/// Handles checking for updates and opening the App Store
public class AppStoreUpdateHelper {
    private let logger: Logger
    private let appId: String

    public init(logger: Logger, appId: String) {
        self.logger = logger
        self.appId = appId
    }

    /// Get update info from the App Store
    /// - Parameters:
    ///   - country: Country code for the App Store lookup
    ///   - completion: Callback with the result dictionary or error
    public func getAppUpdateInfo(country: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        logger.info("Getting App Store update info for \(appId) in country \(country)")

        let urlString = "https://itunes.apple.com/lookup?bundleId=\(appId)&country=\(country)"
        guard let url = URL(string: urlString) else {
            completion(.failure(AppStoreError.invalidURL))
            return
        }

        DispatchQueue.global(qos: .background).async {
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let self = self else { return }

                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(AppStoreError.noData))
                    return
                }

                do {
                    let result = try self.parseAppStoreResponse(data: data)
                    completion(.success(result))
                } catch {
                    self.logger.error("Failed to parse App Store response: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
            task.resume()
        }
    }

    /// Parse the App Store response and build the result dictionary
    private func parseAppStoreResponse(data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultCount = json["resultCount"] as? Int else {
            throw AppStoreError.invalidResponse
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
                result["updateAvailability"] = compareVersions(
                    current: currentVersionName,
                    available: availableVersion
                )
            } else {
                result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
            }

            // iOS doesn't support in-app updates like Android
            result["immediateUpdateAllowed"] = false
            result["flexibleUpdateAllowed"] = false
        } else {
            // App not found in App Store (maybe not published yet)
            result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
            logger.info("App not found in App Store for bundleId: \(appId)")
        }

        return result
    }

    /// Compare two version strings
    private func compareVersions(current: String, available: String) -> Int {
        do {
            let currentVer = try Version(current)
            let availableVer = try Version(available)
            if availableVer > currentVer {
                return AppUpdateAvailability.updateAvailable.rawValue
            } else {
                return AppUpdateAvailability.updateNotAvailable.rawValue
            }
        } catch {
            // If version parsing fails, do string comparison
            if available != current {
                return AppUpdateAvailability.updateAvailable.rawValue
            } else {
                return AppUpdateAvailability.updateNotAvailable.rawValue
            }
        }
    }

    /// Open the App Store page for this app or a specific app ID
    /// - Parameters:
    ///   - specificAppId: Optional app ID to open. If nil, looks up using bundle ID.
    ///   - completion: Callback with success/failure
    public func openAppStore(specificAppId: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        if let appId = specificAppId {
            openAppStoreWithId(appId, completion: completion)
        } else {
            lookupAndOpenAppStore(completion: completion)
        }
    }

    /// Open App Store with a specific app ID
    private func openAppStoreWithId(_ appId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let urlString = "https://apps.apple.com/app/id\(appId)"
        guard let url = URL(string: urlString) else {
            completion(.failure(AppStoreError.invalidURL))
            return
        }

        DispatchQueue.main.async {
            UIApplication.shared.open(url) { success in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(AppStoreError.failedToOpen))
                }
            }
        }
    }

    /// Look up app ID using bundle identifier and open App Store
    private func lookupAndOpenAppStore(completion: @escaping (Result<Void, Error>) -> Void) {
        let lookupUrl = "https://itunes.apple.com/lookup?bundleId=\(appId)"

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            guard let url = URL(string: lookupUrl) else {
                completion(.failure(AppStoreError.invalidURL))
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
                    self.openFallbackAppStore(completion: completion)
                    return
                }

                self.openAppStoreWithId(String(trackId), completion: completion)
            }
            task.resume()
        }
    }

    /// Fallback: open App Store using bundle ID
    private func openFallbackAppStore(completion: @escaping (Result<Void, Error>) -> Void) {
        let fallbackUrlString = "https://apps.apple.com/app/\(appId)"
        guard let fallbackUrl = URL(string: fallbackUrlString) else {
            completion(.failure(AppStoreError.invalidURL))
            return
        }

        DispatchQueue.main.async {
            UIApplication.shared.open(fallbackUrl) { success in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(AppStoreError.failedToOpen))
                }
            }
        }
    }
}

/// Errors for App Store operations
public enum AppStoreError: Error, LocalizedError {
    case invalidURL
    case noData
    case invalidResponse
    case failedToOpen

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for App Store lookup"
        case .noData:
            return "No data received from App Store"
        case .invalidResponse:
            return "Invalid response from App Store"
        case .failedToOpen:
            return "Failed to open App Store"
        }
    }
}
