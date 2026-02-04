/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Alamofire

// MARK: - Stats Operations
extension CapgoUpdater {
    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.")
            return
        }

        guard !statsUrl.isEmpty else {
            return
        }
        operationQueue.maxConcurrentOperationCount = 1

        let versionName = versionName ?? getCurrentBundle().getVersionName()

        var parameters = createInfoObject()
        parameters.action = action
        parameters.version_name = versionName
        parameters.old_version_name = oldVersionName ?? ""

        let operation = BlockOperation {
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
                    self.logger.debug("Action: \(action), Version: \(versionName)")
                case let .failure(error):
                    self.logger.error("Error sending stats")
                    let responseDebug = response.value?.debugDescription ?? "nil"
                    self.logger.debug("Response: \(responseDebug), Error: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        operationQueue.addOperation(operation)
    }
}
