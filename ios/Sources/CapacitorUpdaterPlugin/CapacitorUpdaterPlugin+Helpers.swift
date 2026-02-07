/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit

// MARK: - Helper Methods
extension CapacitorUpdaterPlugin {
    func persistLastFailedBundle(_ bundle: BundleInfo?) {
        if let bundle = bundle {
            do {
                try UserDefaults.standard.setObj(bundle, forKey: lastFailedBundleDefaultsKey)
            } catch {
                logger.error("Failed to persist failed bundle info \(error.localizedDescription)")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: lastFailedBundleDefaultsKey)
        }
        UserDefaults.standard.synchronize()
    }

    func readLastFailedBundle() -> BundleInfo? {
        do {
            let bundle: BundleInfo = try UserDefaults.standard.getObj(forKey: lastFailedBundleDefaultsKey, castTo: BundleInfo.self)
            return bundle
        } catch ObjectSavableError.noValue {
            return nil
        } catch {
            logger.error("Failed to read failed bundle info \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: lastFailedBundleDefaultsKey)
            UserDefaults.standard.synchronize()
            return nil
        }
    }

    func semaphoreWait(waitTime: Int) {
        let result = semaphoreReady.wait(timeout: .now() + .milliseconds(waitTime))
        if result == .timedOut {
            logger.error("Semaphore wait timed out after \(waitTime)ms")
        }
    }

    func semaphoreUp() {
        DispatchQueue.global().async {
            self.semaphoreWait(waitTime: 0)
        }
    }

    func semaphoreDown() {
        semaphoreReady.signal()
    }

    func waitForCleanupIfNeeded() {
        if cleanupComplete {
            return  // Already done, no need to wait
        }

        logger.info("Waiting for cleanup to complete before starting download...")

        // Wait for cleanup to complete - blocks until lock is released
        cleanupLock.lock()
        cleanupLock.unlock()

        logger.info("Cleanup finished, proceeding with download")
    }

    @objc func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false, bundle: BundleInfo? = nil) {
        let bundleInfo = bundle ?? self.implementation.getBundleInfo(id: id)
        self.notifyListeners("download", data: ["percent": percent, "bundle": bundleInfo.toJSON()])
        if percent == 100 {
            self.notifyListeners("downloadComplete", data: ["bundle": bundleInfo.toJSON()])
            self.implementation.sendStats(action: "download_complete", versionName: bundleInfo.getVersionName())
        } else if percent.isMultiple(of: 10) || ignoreMultipleOfTen {
            self.implementation.sendStats(action: "download_\(percent)", versionName: bundleInfo.getVersionName())
        }
    }

    func checkIfRecentlyInstalledOrUpdated() -> Bool {
        let userDefaults = UserDefaults.standard
        let currentVersion = self.currentBuildVersion
        let lastKnownVersion = userDefaults.string(forKey: "LatestNativeBuildVersion") ?? "0"

        if lastKnownVersion == "0" {
            // First time running, consider it as recently installed
            return true
        } else if lastKnownVersion != currentVersion {
            // Version changed, consider it as recently updated
            return true
        }

        return false
    }

    func shouldUseDirectUpdate() -> Bool {
        if self.splashscreenManager.hasTimedOut {
            return false
        }
        switch directUpdateMode {
        case "false":
            return false
        case "always":
            return true
        case "atInstall":
            if self.wasRecentlyInstalledOrUpdated {
                // Reset the flag after first use to prevent subsequent foreground events from using direct update
                self.wasRecentlyInstalledOrUpdated = false
                return true
            }
            return false
        case "onLaunch":
            if !self.onLaunchDirectUpdateUsed {
                return true
            }
            return false
        default:
            logger.error("Invalid directUpdateMode: \"\(self.directUpdateMode)\". Supported values are: \"false\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\" behavior.")
            return false
        }
    }
}
