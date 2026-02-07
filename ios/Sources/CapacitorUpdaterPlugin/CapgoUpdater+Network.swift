/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Alamofire

// MARK: - Network Operations
extension CapgoUpdater {
    func createInfoObject() -> InfoObject {
        return InfoObject(
            platform: "ios",
            device_id: self.deviceID,
            app_id: self.appId,
            custom_id: self.customId,
            version_build: self.versionBuild,
            version_code: self.versionCode,
            version_os: self.versionOs,
            version_name: self.getCurrentBundle().getVersionName(),
            plugin_version: self.pluginVersion,
            is_emulator: self.isEmulator(),
            is_prod: self.isProd(),
            action: nil,
            channel: nil,
            defaultChannel: self.defaultChannel,
            key_id: self.cachedKeyId
        )
    }

    public func getLatest(url: URL, channel: String?) -> AppVersion {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let latest: AppVersion = AppVersion()
        var parameters: InfoObject = self.createInfoObject()
        if let channel = channel {
            parameters.defaultChannel = channel
        }
        logger.info("Auto-update parameters: \(parameters)")
        let request = alamofireSession.request(
            url,
            method: .post,
            parameters: parameters,
            encoder: JSONParameterEncoder.default,
            requestModifier: { $0.timeoutInterval = self.timeout }
        )

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
            case .success:
                latest.statusCode = response.response?.statusCode ?? 0
                if let urlValue = response.value?.url {
                    latest.url = urlValue
                }
                if let checksum = response.value?.checksum {
                    latest.checksum = checksum
                }
                if let version = response.value?.version {
                    latest.version = version
                }
                if let major = response.value?.major {
                    latest.major = major
                }
                if let breaking = response.value?.breaking {
                    latest.breaking = breaking
                }
                if let error = response.value?.error {
                    latest.error = error
                }
                if let message = response.value?.message {
                    latest.message = message
                }
                if let sessionKey = response.value?.session_key {
                    latest.sessionKey = sessionKey
                }
                if let data = response.value?.data {
                    latest.data = data
                }
                if let manifest = response.value?.manifest {
                    latest.manifest = manifest
                }
                if let linkValue = response.value?.link {
                    latest.link = linkValue
                }
                if let comment = response.value?.comment {
                    latest.comment = comment
                }
            case let .failure(error):
                self.logger.error("Error getting latest version")
                self.logger.debug("Response: \(response.value.debugDescription), Error: \(error)")
                latest.message = "Error getting Latest"
                latest.error = "response_error"
                latest.statusCode = response.response?.statusCode ?? 0
            }
            semaphore.signal()
        }
        semaphore.wait()
        return latest
    }

    /**
     * Check if a 429 (Too Many Requests) response was received and set the flag
     */
    func checkAndHandleRateLimitResponse(statusCode: Int?) -> Bool {
        if statusCode == 429 {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if !CapgoUpdater.rateLimitExceeded && !CapgoUpdater.rateLimitStatisticSent {
                CapgoUpdater.rateLimitStatisticSent = true

                // Dispatch to background queue to avoid blocking the main thread
                DispatchQueue.global(qos: .utility).async {
                    self.sendRateLimitStatistic()
                }
            }
            CapgoUpdater.rateLimitExceeded = true
            logger.warn("Rate limit exceeded (429). Stopping all stats and channel requests until app restart.")
            return true
        }
        return false
    }

    /**
     * Send a synchronous statistic about rate limiting
     * Note: This method uses a semaphore to block until the request completes.
     * It MUST be called from a background queue to avoid blocking the main thread.
     */
    func sendRateLimitStatistic() {
        guard !statsUrl.isEmpty else {
            return
        }

        let current = getCurrentBundle()
        var parameters = createInfoObject()
        parameters.action = "rate_limit_reached"
        parameters.version_name = current.getVersionName()
        parameters.old_version_name = ""

        // Send synchronously using semaphore (safe because we're on a background queue)
        let semaphore = DispatchSemaphore(value: 0)
        self.alamofireSession.request(
            self.statsUrl,
            method: .post,
            parameters: parameters,
            encoder: JSONParameterEncoder.default,
            requestModifier: { $0.timeoutInterval = self.timeout }
        ).responseData { response in
            switch response.result {
            case .success:
                self.logger.info("Rate limit statistic sent")
            case let .failure(error):
                self.logger.error("Error sending rate limit statistic")
                self.logger.debug("Error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
