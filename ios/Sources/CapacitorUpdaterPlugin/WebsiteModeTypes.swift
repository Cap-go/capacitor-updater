/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

extension WebsiteModeUpdater {
    enum WebsiteModeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Parsed body of `GET website_live?app_id=`. Unknown fields are ignored.
    struct LiveResponse: Equatable {
        let allowed: Bool
        let mode: String
        let websiteUrl: String
        let downloadBaseUrl: String
        let checkIntervalSeconds: Int
        let reason: String

        var isCapgoMode: Bool {
            mode == WebsiteModeUpdater.modeCapgo
        }

        /// True only when the website may be downloaded and its URL is usable.
        var isWebsiteUpdateAllowed: Bool {
            allowed && mode == WebsiteModeUpdater.modeWebsite && WebsiteModeUpdater.parseHttpsUrl(websiteUrl) != nil
        }

        static func parse(_ data: Data?) -> LiveResponse? {
            guard let data, !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else {
                return nil
            }
            let interval: Int
            if let number = json["check_interval_seconds"] as? NSNumber {
                interval = min(max(0, number.intValue), WebsiteModeUpdater.maxCheckIntervalSeconds)
            } else {
                interval = 0
            }
            return LiveResponse(
                allowed: (json["allowed"] as? Bool) ?? false,
                mode: (json["mode"] as? String) ?? "",
                websiteUrl: (json["website_url"] as? String) ?? "",
                downloadBaseUrl: (json["download_base_url"] as? String) ?? "",
                checkIntervalSeconds: interval,
                reason: (json["reason"] as? String) ?? ""
            )
        }
    }

    struct FetchResponse {
        let statusCode: Int
        let data: Data
        let contentType: String

        var isSuccess: Bool {
            (200..<300).contains(statusCode)
        }
    }

    struct Asset: Equatable {
        let url: URL
        let required: Bool
    }
}
