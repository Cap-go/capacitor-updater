/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Alamofire

/// Manages statistics sending and rate limiting for the CapacitorUpdater plugin.
class StatsManager {
    private let logger: Logger
    private let operationQueue = OperationQueue()

    // Configuration
    var statsUrl: String = ""
    var timeout: Double = 20

    // Rate limiting - static to persist across instances until app restart
    // Thread-safe access via lock
    private static let rateLimitLock = NSLock()
    private static var _rateLimitExceeded = false
    private static var _rateLimitStatisticSent = false

    private static var rateLimitExceeded: Bool {
        get {
            rateLimitLock.lock()
            defer { rateLimitLock.unlock() }
            return _rateLimitExceeded
        }
        set {
            rateLimitLock.lock()
            defer { rateLimitLock.unlock() }
            _rateLimitExceeded = newValue
        }
    }

    private static var rateLimitStatisticSent: Bool {
        get {
            rateLimitLock.lock()
            defer { rateLimitLock.unlock() }
            return _rateLimitStatisticSent
        }
        set {
            rateLimitLock.lock()
            defer { rateLimitLock.unlock() }
            _rateLimitStatisticSent = newValue
        }
    }

    // Dependency injection for creating info objects
    private let createInfoObject: () -> InfoObject
    private let getCurrentVersionName: () -> String
    private let alamofireSession: Session

    init(logger: Logger,
         alamofireSession: Session,
         createInfoObject: @escaping () -> InfoObject,
         getCurrentVersionName: @escaping () -> String) {
        self.logger = logger
        self.alamofireSession = alamofireSession
        self.createInfoObject = createInfoObject
        self.getCurrentVersionName = getCurrentVersionName
        self.operationQueue.maxConcurrentOperationCount = 1
    }

    /// Check if rate limit has been exceeded
    static var isRateLimited: Bool {
        return rateLimitExceeded
    }

    /// Check and handle rate limit response. Returns true if rate limited.
    func checkAndHandleRateLimitResponse(statusCode: Int?) -> Bool {
        if statusCode == 429 {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if !StatsManager.rateLimitExceeded && !StatsManager.rateLimitStatisticSent {
                StatsManager.rateLimitStatisticSent = true

                // Dispatch to background queue to avoid blocking the main thread
                DispatchQueue.global(qos: .utility).async {
                    self.sendRateLimitStatistic()
                }
            }
            StatsManager.rateLimitExceeded = true
            logger.warn("Rate limit exceeded (429). Stopping all stats and channel requests until app restart.")
            return true
        }
        return false
    }

    /// Send statistics asynchronously
    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        // Check if rate limit was exceeded
        if StatsManager.rateLimitExceeded {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.")
            return
        }

        guard !statsUrl.isEmpty else {
            return
        }

        let effectiveVersionName = versionName ?? getCurrentVersionName()

        var parameters = createInfoObject()
        parameters.action = action
        parameters.version_name = effectiveVersionName
        parameters.old_version_name = oldVersionName ?? ""

        let operation = BlockOperation { [weak self] in
            guard let self = self else { return }
            let semaphore = DispatchSemaphore(value: 0)
            self.alamofireSession.request(
                self.statsUrl,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                requestModifier: { $0.timeoutInterval = self.timeout }
            ).responseData { response in
                // Check for 429 rate limit
                if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                    semaphore.signal()
                    return
                }

                switch response.result {
                case .success:
                    self.logger.info("Stats sent successfully")
                    self.logger.debug("Action: \(action), Version: \(effectiveVersionName)")
                case let .failure(error):
                    self.logger.error("Error sending stats")
                    self.logger.debug("Response: \(response.value?.debugDescription ?? "nil"), Error: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        operationQueue.addOperation(operation)
    }

    /// Send a synchronous statistic about rate limiting
    /// Note: This method uses a semaphore to block until the request completes.
    /// It MUST be called from a background queue to avoid blocking the main thread.
    private func sendRateLimitStatistic() {
        guard !statsUrl.isEmpty else {
            return
        }

        var parameters = createInfoObject()
        parameters.action = "rate_limit_reached"
        parameters.version_name = getCurrentVersionName()
        parameters.old_version_name = ""

        // Send synchronously using semaphore (safe because we're on a background queue)
        let semaphore = DispatchSemaphore(value: 0)
        alamofireSession.request(
            statsUrl,
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
