/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit
import WebKit
import Version

extension CapacitorUpdaterPlugin {
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
        if !self.autoUpdate || self.autoUpdateMode == Self.autoUpdateModeOnlyDownload {
            return false
        }
        if self.autoSplashscreenTimedOut {
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
            if !self.getOnLaunchDirectUpdateUsed() {
                return true
            }
            return false
        default:
            logger.error("Invalid directUpdateMode: \"\(self.directUpdateMode)\". Supported values are: \"false\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\" behavior.")
            return false
        }
    }

    func canUseDirectUpdateWithoutConsumingState() -> Bool {
        if !self.autoUpdate || self.autoUpdateMode == Self.autoUpdateModeOnlyDownload {
            return false
        }
        if self.autoSplashscreenTimedOut {
            return false
        }
        switch directUpdateMode {
        case "false":
            return false
        case "always":
            return true
        case "atInstall":
            return self.wasRecentlyInstalledOrUpdated
        case "onLaunch":
            return !self.getOnLaunchDirectUpdateUsed()
        default:
            logger.error("Invalid directUpdateMode: \"\(self.directUpdateMode)\". Supported values are: \"false\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\" behavior.")
            return false
        }
    }

    func configureAutoUpdateModeFromConfig() {
        if let configuredMode = getConfig().getString("autoUpdate"),
           configuredMode != "",
           configuredMode != "true",
           configuredMode != "false" {
            autoUpdateMode = Self.normalizedAutoUpdateMode(configuredMode)
            if autoUpdateMode != configuredMode {
                logger.error(
                    "Invalid autoUpdate value: \"\(configuredMode)\". Supported values are: true, false, " +
                        "\"off\", \"atBackground\", \"atInstall\", \"onLaunch\", \"always\", \"onlyDownload\". Defaulting to \"atBackground\"."
                )
            }
        } else {
            let configuredMode = getConfig().getString("autoUpdate")
            let enabled = configuredMode != nil ? configuredMode == "true" : getConfig().getBoolean("autoUpdate", true)
            autoUpdateMode = enabled
                ? Self.autoUpdateModeForLegacyDirectUpdateMode(resolveLegacyDirectUpdateModeFromConfig())
                : Self.autoUpdateModeOff
        }

        autoUpdate = Self.isAutoUpdateModeEnabled(autoUpdateMode)
        directUpdateMode = Self.directUpdateModeForAutoUpdateMode(autoUpdateMode)
        directUpdate = Self.isDirectUpdateMode(directUpdateMode)
    }

    func resolveLegacyDirectUpdateModeFromConfig() -> String {
        if let directUpdateString = getConfig().getString("directUpdate") {
            if directUpdateString == "true" {
                return Self.autoUpdateModeAlways
            }
            if directUpdateString == "false" || Self.isDirectUpdateMode(directUpdateString) {
                return directUpdateString
            }
            logger.error(
                "Invalid directUpdate value: \"\(directUpdateString)\". Supported values are: false, true, " +
                    "\"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\"."
            )
            return "false"
        }

        return getConfig().getBoolean("directUpdate", false) ? Self.autoUpdateModeAlways : "false"
    }

    static func normalizedAutoUpdateMode(_ value: String?) -> String {
        guard let value else {
            return autoUpdateModeBackground
        }
        switch value {
        case "false", autoUpdateModeOff:
            return autoUpdateModeOff
        case "true", autoUpdateModeBackground:
            return autoUpdateModeBackground
        case autoUpdateModeInstall, autoUpdateModeLaunch, autoUpdateModeAlways, autoUpdateModeOnlyDownload:
            return value
        default:
            return autoUpdateModeBackground
        }
    }

    static func autoUpdateModeForLegacyDirectUpdateMode(_ directUpdateMode: String) -> String {
        switch directUpdateMode {
        case autoUpdateModeInstall, autoUpdateModeLaunch, autoUpdateModeAlways:
            return directUpdateMode
        default:
            return autoUpdateModeBackground
        }
    }

    static func directUpdateModeForAutoUpdateMode(_ autoUpdateMode: String) -> String {
        switch autoUpdateMode {
        case autoUpdateModeInstall, autoUpdateModeLaunch, autoUpdateModeAlways:
            return autoUpdateMode
        default:
            return "false"
        }
    }

    static func isAutoUpdateModeEnabled(_ autoUpdateMode: String) -> Bool {
        autoUpdateMode != autoUpdateModeOff
    }

    static func shouldAutoUpdateModeSetNextBundle(_ autoUpdateMode: String) -> Bool {
        isAutoUpdateModeEnabled(autoUpdateMode) && autoUpdateMode != autoUpdateModeOnlyDownload
    }

    static func isDirectUpdateMode(_ directUpdateMode: String) -> Bool {
        directUpdateMode == autoUpdateModeInstall || directUpdateMode == autoUpdateModeLaunch || directUpdateMode == autoUpdateModeAlways
    }

    func shouldAutoSetNextBundle() -> Bool {
        Self.shouldAutoUpdateModeSetNextBundle(autoUpdateMode)
    }

    static func shouldConsumeOnLaunchDirectUpdate(directUpdateMode: String, plannedDirectUpdate: Bool) -> Bool {
        plannedDirectUpdate && directUpdateMode == "onLaunch"
    }

    static func normalizedPeriodCheckDelaySeconds(_ value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return max(600, value)
    }

    func getOnLaunchDirectUpdateUsed() -> Bool {
        self.onLaunchDirectUpdateStateLock.lock()
        defer { self.onLaunchDirectUpdateStateLock.unlock() }
        return self.onLaunchDirectUpdateUsed
    }

    func setOnLaunchDirectUpdateUsed(_ used: Bool) {
        self.onLaunchDirectUpdateStateLock.lock()
        self.onLaunchDirectUpdateUsed = used
        self.onLaunchDirectUpdateStateLock.unlock()
    }

    func consumeOnLaunchDirectUpdateAttempt(plannedDirectUpdate: Bool) {
        guard Self.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: self.directUpdateMode, plannedDirectUpdate: plannedDirectUpdate) else {
            return
        }

        self.setOnLaunchDirectUpdateUsed(true)
    }

    func configureDirectUpdateModeForTesting(_ directUpdateMode: String, onLaunchDirectUpdateUsed: Bool = false) {
        self.directUpdateMode = directUpdateMode
        self.autoUpdateMode = Self.autoUpdateModeForLegacyDirectUpdateMode(directUpdateMode)
        self.autoUpdate = Self.isAutoUpdateModeEnabled(self.autoUpdateMode)
        self.directUpdate = Self.isDirectUpdateMode(self.directUpdateMode)
        self.setOnLaunchDirectUpdateUsed(onLaunchDirectUpdateUsed)
    }

    func setUpdateUrlForTesting(_ updateUrl: String) {
        self.updateUrl = updateUrl
    }

    func setAutoUpdateModeForTesting(_ autoUpdateMode: String) {
        self.autoUpdateMode = Self.normalizedAutoUpdateMode(autoUpdateMode)
        self.autoUpdate = Self.isAutoUpdateModeEnabled(self.autoUpdateMode)
        self.directUpdateMode = Self.directUpdateModeForAutoUpdateMode(self.autoUpdateMode)
        self.directUpdate = Self.isDirectUpdateMode(self.directUpdateMode)
    }

    func setCurrentBuildVersionForTesting(_ currentBuildVersion: String) {
        self.currentBuildVersion = currentBuildVersion
    }

    func shouldUseDirectUpdateForTesting() -> Bool {
        self.shouldUseDirectUpdate()
    }

    var hasConsumedOnLaunchDirectUpdateForTesting: Bool {
        self.getOnLaunchDirectUpdateUsed()
    }

    func notifyBreakingEvents(version: String) {
        guard !version.isEmpty else {
            return
        }
        let payload: [String: Any] = ["version": version]
        self.notifyListeners("breakingAvailable", data: payload)
        self.notifyListeners("majorAvailable", data: payload)
    }

    func shouldNotifyBreakingEvents(response: AppVersion) -> Bool {
        if response.breaking == true {
            return true
        }

        return response.error == "disable_auto_update_to_major" || response.message == "store_update_required"
    }

    func notifyBreakingEventsIfNeeded(response: AppVersion, version: String) {
        if self.shouldNotifyBreakingEvents(response: response) {
            let eventVersion = version.isEmpty ? self.implementation.getCurrentBundle().getVersionName() : version
            self.notifyBreakingEvents(version: eventVersion)
        }
    }

    static func normalizedUpdateResponseKind(kind: String?) -> String {
        if let kind, ["up_to_date", "blocked", "failed"].contains(kind) {
            return kind
        }
        return "failed"
    }

    func updateResponseKind(kind: String?) -> String {
        Self.normalizedUpdateResponseKind(kind: kind)
    }

    func endBackgroundDownloadAfterLatestError(
        backendError: String,
        res: AppVersion,
        current: BundleInfo,
        plannedDirectUpdate: Bool
    ) {
        let statusCode = res.statusCode
        let responseKind = self.updateResponseKind(kind: res.kind)
        let responseMessage = res.message?.isEmpty == false ? res.message : nil
        let message = responseMessage ?? (backendError.isEmpty ? "server did not provide a message" : backendError)
        let latestVersionName = res.version.isEmpty ? current.getVersionName() : res.version
        self.notifyListeners("updateCheckResult", data: [
            "kind": responseKind,
            "error": backendError,
            "message": message,
            "statusCode": statusCode,
            "version": latestVersionName,
            "bundle": current.toJSON()
        ])
        self.notifyBreakingEventsIfNeeded(response: res, version: res.version)

        if responseKind == "up_to_date" {
            self.logger.info("No new version available")
        } else if responseKind == "blocked" {
            self.logger.info("Update check blocked with error: \(backendError)")
        } else {
            self.logger.error("getLatest failed with error: \(backendError)")
        }

        let isFailure = responseKind == "failed"
        self.endBackGroundTaskWithNotif(
            msg: message,
            latestVersionName: latestVersionName,
            current: current,
            error: isFailure,
            plannedDirectUpdate: plannedDirectUpdate,
            sendStats: isFailure
        )
    }

    func endBackGroundTaskWithNotif(
        msg: String,
        latestVersionName: String,
        current: BundleInfo,
        error: Bool = true,
        plannedDirectUpdate: Bool = false,
        failureAction: String = "download_fail",
        failureEvent: String = "downloadFailed",
        sendStats: Bool = true,
        notifyNoNeedUpdate: Bool = true
    ) {
        // Clear download in progress flag - this is called at the end of every download attempt
        // whether it succeeds, fails, or is skipped (e.g., already up to date)
        downloadLock.lock()
        defer { downloadLock.unlock() }
        downloadInProgress = false
        downloadStartTime = nil

        self.consumeOnLaunchDirectUpdateAttempt(plannedDirectUpdate: plannedDirectUpdate)

        if error {
            if sendStats {
                self.implementation.sendStats(action: failureAction, versionName: current.getVersionName())
            }
            self.notifyListeners(failureEvent, data: ["version": latestVersionName])
        }
        if notifyNoNeedUpdate {
            self.notifyListeners("noNeedUpdate", data: ["bundle": current.toJSON()])
        }
        self.sendReadyToJs(current: current, msg: msg)
        logger.info("endBackGroundTaskWithNotif \(msg) current: \(current.getVersionName()) latestVersionName: \(latestVersionName)")
        self.endBackGroundTask()
    }

    func isDownloadStuckOrTimedOut() -> Bool {
        downloadLock.lock()
        defer { downloadLock.unlock() }

        guard downloadInProgress else {
            return false
        }

        // Check if download has timed out
        if let startTime = downloadStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > downloadTimeout {
                self.logger.warn("Download has been in progress for \(elapsed) seconds, exceeding timeout of \(downloadTimeout) seconds. Clearing stuck state.")
                downloadInProgress = false
                downloadStartTime = nil
                return false // Now it's not stuck anymore, caller can proceed
            }
        }

        return true
    }

    func runBackgroundDownloadWorkImpl(_ work: @escaping () -> Void) {
        // Live update checks/downloads are user-visible work. Using `.background`
        // lets the scheduler starve them for minutes while the app is active.
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    func beginDownloadBackgroundTask() {
        let registerTask = {
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Download Tasks") {
                self.endBackGroundTask()
            }
        }

        if Thread.isMainThread {
            registerTask()
        } else {
            DispatchQueue.main.sync(execute: registerTask)
        }
    }

    func runGetLatestWorkImpl(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .background).async(execute: work)
    }
}
