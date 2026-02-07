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

        let resolvedVersionName = versionName ?? getCurrentBundle().getVersionName()
        let info = createInfoObject()

        let event = StatsEvent(
            platform: info.platform,
            device_id: info.device_id,
            app_id: info.app_id,
            custom_id: info.custom_id,
            version_build: info.version_build,
            version_code: info.version_code,
            version_os: info.version_os,
            version_name: resolvedVersionName,
            old_version_name: oldVersionName ?? "",
            plugin_version: info.plugin_version,
            is_emulator: info.is_emulator,
            is_prod: info.is_prod,
            action: action,
            channel: info.channel,
            defaultChannel: info.defaultChannel,
            key_id: info.key_id,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        statsQueueLock.lock()
        statsQueue.append(event)
        statsQueueLock.unlock()

        ensureStatsTimerStarted()
    }
}
