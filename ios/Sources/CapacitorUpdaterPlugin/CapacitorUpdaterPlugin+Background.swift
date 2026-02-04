/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit

// MARK: - Background and Lifecycle Methods
extension CapacitorUpdaterPlugin {
    func checkAppReady() {
        self.appReadyCheck?.cancel()
        self.appReadyCheck = DispatchWorkItem(block: {
            self.deferredNotifyAppReadyCheck()
        })
        logger.info("Wait for \(self.appReadyTimeout) ms, then check for notifyAppReady")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.appReadyTimeout), execute: self.appReadyCheck!)
    }

    func checkRevert() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        let current: BundleInfo = self.implementation.getCurrentBundle()
        if current.isBuiltin() {
            logger.info("Built-in bundle is active. We skip the check for notifyAppReady.")
            return
        }

        logger.info("Current bundle is: \(current.toString())")

        if BundleStatus.SUCCESS.localizedString != current.getStatus() {
            logger.error("notifyAppReady was not called, roll back current bundle: \(current.toString())")
            logger.error("Did you forget to call 'notifyAppReady()' in your Capacitor App code?")
            self.notifyListeners("updateFailed", data: [
                "bundle": current.toJSON()
            ])
            self.persistLastFailedBundle(current)
            self.implementation.sendStats(action: "update_fail", versionName: current.getVersionName())
            self.implementation.setError(bundle: current)
            _ = self.performReset(toLastSuccessful: true)
            if self.autoDeleteFailed && !current.isBuiltin() {
                logger.info("Deleting failing bundle: \(current.toString())")
                let res = self.implementation.delete(id: current.getId(), removeInfo: false)
                if !res {
                    logger.info("Delete version deleted: \(current.toString())")
                } else {
                    logger.error("Failed to delete failed bundle: \(current.toString())")
                }
            }
        } else {
            logger.info("notifyAppReady was called. This is fine: \(current.toString())")
        }
    }

    func deferredNotifyAppReadyCheck() {
        self.checkRevert()
        self.appReadyCheck = nil
    }

    func endBackGroundTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    }

    func sendReadyToJs(current: BundleInfo, msg: String) {
        logger.info("sendReadyToJs")
        DispatchQueue.global().async {
            self.semaphoreWait(waitTime: self.appReadyTimeout)
            self.notifyListeners("appReady", data: ["bundle": current.toJSON(), "status": msg], retainUntilConsumed: true)

            // Auto hide splashscreen if enabled
            // We show it on background when conditions are met, so we should hide it on foreground regardless of update outcome
            if self.splashscreenManager.isEnabled {
                self.splashscreenManager.hide()
            }
        }
    }

    func notifyBreakingEvents(version: String) {
        guard !version.isEmpty else {
            return
        }
        let payload: [String: Any] = ["version": version]
        self.notifyListeners("breakingAvailable", data: payload)
        self.notifyListeners("majorAvailable", data: payload)
    }

    func endBackGroundTaskWithNotif(
        msg: String,
        latestVersionName: String,
        current: BundleInfo,
        error: Bool = true,
        failureAction: String = "download_fail",
        failureEvent: String = "downloadFailed",
        sendStats: Bool = true
    ) {
        downloadLock.lock()
        downloadInProgress = false
        downloadStartTime = nil
        downloadLock.unlock()

        if error {
            if sendStats {
                self.implementation.sendStats(action: failureAction, versionName: current.getVersionName())
            }
            self.notifyListeners(failureEvent, data: ["version": latestVersionName])
        }
        self.notifyListeners("noNeedUpdate", data: ["bundle": current.toJSON()])
        self.sendReadyToJs(current: current, msg: msg)
        logger.info("endBackGroundTaskWithNotif \(msg) current: \(current.getVersionName()) latestVersionName: \(latestVersionName)")
        self.endBackGroundTask()
    }

    func backgroundDownload() {
        downloadLock.lock()
        downloadInProgress = true
        downloadStartTime = Date()
        downloadLock.unlock()

        let plannedDirectUpdate = self.shouldUseDirectUpdate()
        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            downloadLock.lock()
            downloadInProgress = false
            downloadStartTime = nil
            downloadLock.unlock()
            return
        }
        DispatchQueue.global(qos: .background).async {
            self.waitForCleanupIfNeeded()
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Download Tasks") {
                self.endBackGroundTask()
            }
            self.logger.info("Check for update via \(self.updateUrl)")
            let res = self.implementation.getLatest(url: url, channel: nil)
            let current = self.implementation.getCurrentBundle()

            if self.handleBackendError(res: res, current: current) {
                return
            }
            if res.version == "builtin" {
                self.handleBuiltinUpdate(res: res, current: current, plannedDirectUpdate: plannedDirectUpdate)
                return
            }
            self.handleNewVersionDownload(res: res, current: current, plannedDirectUpdate: plannedDirectUpdate)
        }
    }

    private func handleBackendError(res: LatestRelease, current: BundleInfo) -> Bool {
        guard let backendError = res.error, !backendError.isEmpty else {
            return false
        }
        self.logger.error("getLatest failed with error: \(backendError)")
        let statusCode = res.statusCode
        let responseIsOk = statusCode >= 200 && statusCode < 300
        self.endBackGroundTaskWithNotif(
            msg: res.message ?? backendError,
            latestVersionName: res.version,
            current: current,
            error: true,
            sendStats: !responseIsOk
        )
        return true
    }

    private func handleBuiltinUpdate(res: LatestRelease, current: BundleInfo, plannedDirectUpdate: Bool) {
        self.logger.info("Latest version is builtin")
        let directUpdateAllowed = plannedDirectUpdate && !self.splashscreenManager.hasTimedOut
        if directUpdateAllowed {
            self.logger.info("Direct update to builtin version")
            if self.directUpdateMode == "onLaunch" {
                self.onLaunchDirectUpdateUsed = true
                self.directUpdate = false
            }
            _ = self.performReset(toLastSuccessful: false)
            self.endBackGroundTaskWithNotif(msg: "Updated to builtin version", latestVersionName: res.version, current: self.implementation.getCurrentBundle(), error: false)
        } else {
            if plannedDirectUpdate {
                self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will apply later.")
            }
            self.logger.info("Setting next bundle to builtin")
            _ = self.implementation.setNextBundle(next: BundleInfo.ID_BUILTIN)
            self.endBackGroundTaskWithNotif(msg: "Next update will be to builtin version", latestVersionName: res.version, current: current, error: false)
        }
    }

    private func handleNewVersionDownload(res: LatestRelease, current: BundleInfo, plannedDirectUpdate: Bool) {
        let messageUpdate = plannedDirectUpdate ? "Update will occur now." : "Update will occur next time app moves to background."
        let sessionKey = res.sessionKey ?? ""
        guard let downloadUrl = URL(string: res.url) else {
            self.logger.error("Error no url or wrong format")
            self.endBackGroundTaskWithNotif(msg: "Error no url or wrong format", latestVersionName: res.version, current: current)
            return
        }
        let latestVersionName = res.version
        guard latestVersionName != "" && current.getVersionName() != latestVersionName else {
            self.logger.info("No need to update, \(current.getId()) is the latest bundle.")
            self.endBackGroundTaskWithNotif(msg: "No need to update", latestVersionName: latestVersionName, current: current, error: false)
            return
        }
        do {
            self.logger.info("New bundle: \(latestVersionName) found. Current is: \(current.getVersionName()). \(messageUpdate)")
            let next = try self.downloadOrReuseBundle(res: res, downloadUrl: downloadUrl, latestVersionName: latestVersionName, sessionKey: sessionKey, current: current)
            guard let next = next else { return }
            try self.processDownloadedBundle(next: next, res: res, current: current, latestVersionName: latestVersionName, plannedDirectUpdate: plannedDirectUpdate)
        } catch {
            self.logger.error("Error downloading file \(error.localizedDescription)")
            self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: self.implementation.getCurrentBundle())
        }
    }

    private func downloadOrReuseBundle(res: LatestRelease, downloadUrl: URL, latestVersionName: String, sessionKey: String, current: BundleInfo) throws -> BundleInfo? {
        var nextImpl = self.implementation.getBundleInfoByVersionName(version: latestVersionName)
        if nextImpl == nil || nextImpl?.isDeleted() == true {
            if let existing = nextImpl, existing.isDeleted() {
                self.logger.info("Latest bundle already exists and will be deleted, download will overwrite it.")
                let resDel = self.implementation.delete(id: existing.getId(), removeInfo: true)
                self.logger.info(resDel ? "Failed bundle deleted: \(existing.toString())" : "Failed to delete failed bundle: \(existing.toString())")
            }
            if res.manifest != nil {
                nextImpl = try self.implementation.downloadManifest(manifest: res.manifest!, version: latestVersionName, sessionKey: sessionKey, link: res.link, comment: res.comment)
            } else {
                nextImpl = try self.implementation.download(url: downloadUrl, version: latestVersionName, sessionKey: sessionKey, link: res.link, comment: res.comment)
            }
        }
        guard let next = nextImpl else {
            self.logger.error("Error downloading file")
            self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
            return nil
        }
        if next.isErrorStatus() {
            self.logger.error("Latest bundle already exists and is in error state. Aborting update.")
            self.endBackGroundTaskWithNotif(msg: "Latest version is in error state", latestVersionName: latestVersionName, current: current)
            return nil
        }
        return next
    }

    private func processDownloadedBundle(next: BundleInfo, res: LatestRelease, current: BundleInfo, latestVersionName: String, plannedDirectUpdate: Bool) throws {
        let decryptedChecksum = try CryptoCipher.decryptChecksum(checksum: res.checksum, publicKey: self.implementation.publicKey)
        CryptoCipher.logChecksumInfo(label: "Bundle checksum", hexChecksum: next.getChecksum())
        CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: decryptedChecksum)
        if decryptedChecksum != "" && next.getChecksum() != decryptedChecksum && res.manifest == nil {
            self.logger.error("Error checksum \(next.getChecksum()) \(decryptedChecksum)")
            self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
            _ = self.implementation.delete(id: next.getId())
            self.endBackGroundTaskWithNotif(msg: "Error checksum", latestVersionName: latestVersionName, current: current)
            return
        }
        let directUpdateAllowed = plannedDirectUpdate && !self.splashscreenManager.hasTimedOut
        if directUpdateAllowed {
            self.applyDirectUpdate(next: next, latestVersionName: latestVersionName, current: current, plannedDirectUpdate: plannedDirectUpdate)
        } else {
            if plannedDirectUpdate {
                self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will install on next app background.")
            }
            self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
            _ = self.implementation.setNextBundle(next: next.getId())
            self.endBackGroundTaskWithNotif(msg: "update downloaded, will install next background", latestVersionName: latestVersionName, current: current, error: false)
        }
    }

    private func applyDirectUpdate(next: BundleInfo, latestVersionName: String, current: BundleInfo, plannedDirectUpdate: Bool) {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = self.fromJsonArr(json: delayUpdatePreferences).compactMap { obj -> DelayCondition? in
            guard let kind = obj.value(forKey: "kind") as? String else { return nil }
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
        if !delayConditionList.isEmpty {
            self.logger.info("Update delayed until delay conditions met")
            self.endBackGroundTaskWithNotif(msg: "Update delayed until delay conditions met", latestVersionName: latestVersionName, current: next, error: false)
            return
        }
        if self.directUpdateMode == "onLaunch" {
            self.onLaunchDirectUpdateUsed = true
            self.directUpdate = false
        }
        _ = self.implementation.set(bundle: next)
        _ = self.performReload()
        self.endBackGroundTaskWithNotif(msg: "update installed", latestVersionName: latestVersionName, current: next, error: false)
    }

    func installNext() {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).compactMap { obj -> DelayCondition? in
            guard let kind = obj.value(forKey: "kind") as? String else { return nil }
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
        if !delayConditionList.isEmpty {
            logger.info("Update delayed until delay conditions met")
            return
        }
        let current: BundleInfo = self.implementation.getCurrentBundle()
        let next: BundleInfo? = self.implementation.getNextBundle()

        if next != nil && !next!.isErrorStatus() && next!.getVersionName() != current.getVersionName() {
            logger.info("Next bundle is: \(next!.toString())")
            if self.implementation.set(bundle: next!) && self.performReload() {
                logger.info("Updated to bundle: \(next!.toString())")
                _ = self.implementation.setNextBundle(next: Optional<String>.none)
            } else {
                logger.error("Update to bundle: \(next!.toString()) Failed!")
            }
        }
    }

    @objc func appMovedToForeground() {
        let current: BundleInfo = self.implementation.getCurrentBundle()
        self.implementation.sendStats(action: "app_moved_to_foreground", versionName: current.getVersionName())
        self.delayUpdateUtils.checkCancelDelay(source: .foreground)
        self.delayUpdateUtils.unsetBackgroundTimestamp()
        if backgroundWork != nil && taskRunning {
            backgroundWork!.cancel()
            logger.info("Background Timer Task canceled, Activity resumed before timer completes")
        }
        if self.checkAutoUpdateEnabled() {
            self.backgroundDownload()
        } else {
            let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
            if instanceDescriptor?.serverURL != nil {
                self.implementation.sendStats(action: "blocked_by_server_url", versionName: current.getVersionName())
            }
            logger.info("Auto update is disabled")
            self.sendReadyToJs(current: current, msg: "disabled")
        }
        self.checkAppReady()
    }

    @objc func checkForUpdateAfterDelay() {
        if periodCheckDelay == 0 || !self.checkAutoUpdateEnabled() {
            return
        }
        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            return
        }

        // Clean up any existing timer
        periodicUpdateTimer?.invalidate()

        periodicUpdateTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(periodCheckDelay), repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            DispatchQueue.global(qos: .background).async {
                let res = self.implementation.getLatest(url: url, channel: nil)
                let current = self.implementation.getCurrentBundle()

                if res.version != current.getVersionName() {
                    self.logger.info("New version found: \(res.version)")
                    self.backgroundDownload()
                }
            }
        }
        RunLoop.current.add(periodicUpdateTimer!, forMode: .default)
    }

    @objc func appMovedToBackground() {
        let current: BundleInfo = self.implementation.getCurrentBundle()
        self.implementation.sendStats(action: "app_moved_to_background", versionName: current.getVersionName())
        logger.info("Check for pending update")

        // Show splashscreen only if autoSplashscreen is enabled AND autoUpdate is enabled AND directUpdate would be used
        if self.splashscreenManager.isEnabled {
            // Reset timeout state when entering background (allows showing splashscreen again)
            self.splashscreenManager.resetTimeoutState()

            var canShowSplashscreen = true

            if !self.checkAutoUpdateEnabled() {
                logger.warn("autoSplashscreen is enabled but autoUpdate is disabled. Splashscreen will not be shown. Enable autoUpdate or disable autoSplashscreen.")
                canShowSplashscreen = false
            }

            if !self.shouldUseDirectUpdate() {
                if self.directUpdateMode == "false" {
                    logger.warn("autoSplashscreen is enabled but directUpdate is not configured for immediate updates. Set directUpdate to 'always' or disable autoSplashscreen.")
                } else if self.directUpdateMode == "atInstall" || self.directUpdateMode == "onLaunch" {
                    logger.info("autoSplashscreen is enabled but directUpdate is set to \"\(self.directUpdateMode)\". This is normal. Skipping autoSplashscreen logic.")
                }
                canShowSplashscreen = false
            }

            if canShowSplashscreen {
                self.splashscreenManager.show()
            }
        }

        // Set background timestamp
        let backgroundTimestamp = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
        self.delayUpdateUtils.setBackgroundTimestamp(backgroundTimestamp)
        self.delayUpdateUtils.checkCancelDelay(source: .background)
        self.installNext()
    }
}
