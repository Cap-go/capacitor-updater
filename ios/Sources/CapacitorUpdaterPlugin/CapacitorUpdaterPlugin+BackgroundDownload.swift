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
    func backgroundDownload() {
        markDownloadStarted()
        let plannedDirectUpdate = self.shouldUseDirectUpdate()
        let messageUpdate = backgroundUpdateMessage(plannedDirectUpdate: plannedDirectUpdate)

        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            clearDownloadInProgress()
            return
        }

        self.runBackgroundDownloadWork {
            self.performBackgroundDownload(
                updateUrl: url,
                plannedDirectUpdate: plannedDirectUpdate,
                messageUpdate: messageUpdate
            )
        }
    }

    func markDownloadStarted() {
        downloadLock.lock()
        downloadInProgress = true
        downloadStartTime = Date()
        downloadLock.unlock()
    }

    func clearDownloadInProgress() {
        downloadLock.lock()
        downloadInProgress = false
        downloadStartTime = nil
        downloadLock.unlock()
    }

    func backgroundUpdateMessage(plannedDirectUpdate: Bool) -> String {
        if plannedDirectUpdate {
            return "Update will occur now."
        }
        if self.shouldAutoSetNextBundle() {
            return "Update will occur next time app moves to background."
        }
        return "Update will be downloaded and made available."
    }

    func performBackgroundDownload(updateUrl: URL, plannedDirectUpdate: Bool, messageUpdate: String) {
        self.waitForCleanupIfNeeded()
        self.beginDownloadBackgroundTask()
        self.logger.info("Check for update via \(self.updateUrl)")

        let response = self.implementation.getLatest(url: updateUrl, channel: nil)
        let current = self.implementation.getCurrentBundle()
        let backendError = response.error ?? ""
        let backendKind = response.kind ?? ""
        if !backendError.isEmpty || !backendKind.isEmpty {
            self.endBackgroundDownloadAfterLatestError(
                backendError: backendError,
                res: response,
                current: current,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        if response.version == "builtin" {
            handleBuiltinLatest(response: response, current: current, plannedDirectUpdate: plannedDirectUpdate)
            return
        }

        let latestVersionName = response.version
        guard let downloadUrl = URL(string: response.url) else {
            self.notifyBreakingEventsIfNeeded(response: response, version: latestVersionName)
            self.logger.error("Error no url or wrong format")
            self.endBackGroundTaskWithNotif(
                msg: "Error no url or wrong format",
                latestVersionName: latestVersionName,
                current: current,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        guard !latestVersionName.isEmpty, current.getVersionName() != latestVersionName else {
            self.logger.info("No need to update, \(current.getId()) is the latest bundle.")
            self.endBackGroundTaskWithNotif(
                msg: "No need to update, \(current.getId()) is the latest bundle.",
                latestVersionName: latestVersionName,
                current: current,
                error: false,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        downloadAndApplyLatest(
            response: response,
            downloadUrl: downloadUrl,
            current: current,
            plannedDirectUpdate: plannedDirectUpdate,
            messageUpdate: messageUpdate
        )
    }

    func handleBuiltinLatest(response: AppVersion, current: BundleInfo, plannedDirectUpdate: Bool) {
        self.logger.info("Latest version is builtin")
        let directUpdateAllowed = plannedDirectUpdate && !self.autoSplashscreenTimedOut
        if directUpdateAllowed {
            self.logger.info("Direct update to builtin version")
            _ = self.resetToTarget(toLastSuccessful: false, usePendingBundle: false)
            self.endBackGroundTaskWithNotif(
                msg: "Updated to builtin version",
                latestVersionName: response.version,
                current: self.implementation.getCurrentBundle(),
                error: false,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        if self.shouldAutoSetNextBundle() {
            if plannedDirectUpdate {
                self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will apply later.")
            }
            self.logger.info("Setting next bundle to builtin")
            _ = self.implementation.setNextBundle(next: BundleInfo.idBuiltin)
            self.endBackGroundTaskWithNotif(
                msg: "Next update will be to builtin version",
                latestVersionName: response.version,
                current: current,
                error: false,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        self.logger.info("autoUpdate is set to onlyDownload, builtin version will not be set as next bundle")
        let builtinUpdateAvailable = !current.isBuiltin()
        if builtinUpdateAvailable {
            let builtinBundle = self.implementation.getBundleInfo(id: BundleInfo.idBuiltin)
            self.notifyListeners("updateAvailable", data: ["bundle": builtinBundle.toJSON()], retainUntilConsumed: true)
        }
        self.endBackGroundTaskWithNotif(
            msg: "Latest version is builtin, autoUpdate onlyDownload",
            latestVersionName: response.version,
            current: current,
            error: false,
            plannedDirectUpdate: plannedDirectUpdate,
            notifyNoNeedUpdate: !builtinUpdateAvailable
        )
    }

    func downloadAndApplyLatest(
        response: AppVersion,
        downloadUrl: URL,
        current: BundleInfo,
        plannedDirectUpdate: Bool,
        messageUpdate: String
    ) {
        let latestVersionName = response.version
        do {
            self.logger.info("New bundle: \(latestVersionName) found. Current is: \(current.getVersionName()). \(messageUpdate)")
            guard let next = try nextBundle(response: response, downloadUrl: downloadUrl, plannedDirectUpdate: plannedDirectUpdate) else {
                self.logger.error("Error downloading file")
                self.endBackGroundTaskWithNotif(
                    msg: "Error downloading file",
                    latestVersionName: latestVersionName,
                    current: current,
                    plannedDirectUpdate: plannedDirectUpdate
                )
                return
            }
            guard !next.isErrorStatus() else {
                self.logger.error("Latest bundle already exists and is in error state. Aborting update.")
                self.endBackGroundTaskWithNotif(
                    msg: "Latest version is in error state. Aborting update.",
                    latestVersionName: latestVersionName,
                    current: current,
                    plannedDirectUpdate: plannedDirectUpdate
                )
                return
            }

            guard validateChecksum(response: response, next: next, current: current, plannedDirectUpdate: plannedDirectUpdate) else {
                return
            }
            finishDownloadedUpdate(next: next, latestVersionName: latestVersionName, current: current, plannedDirectUpdate: plannedDirectUpdate)
        } catch {
            self.logger.error("Error downloading file \(error.localizedDescription)")
            self.endBackGroundTaskWithNotif(
                msg: "Error downloading file",
                latestVersionName: latestVersionName,
                current: self.implementation.getCurrentBundle(),
                plannedDirectUpdate: plannedDirectUpdate
            )
        }
    }

    func nextBundle(response: AppVersion, downloadUrl: URL, plannedDirectUpdate: Bool) throws -> BundleInfo? {
        let latestVersionName = response.version
        var nextImpl = self.implementation.getBundleInfoByVersionName(version: latestVersionName)
        if nextImpl == nil || nextImpl?.isDeleted() == true {
            if let deletedBundle = nextImpl, deletedBundle.isDeleted() {
                self.logger.info("Latest bundle already exists and will be deleted, download will overwrite it.")
                let deleted = self.implementation.delete(id: deletedBundle.getId(), removeInfo: true)
                if deleted {
                    self.logger.info("Failed bundle deleted: \(deletedBundle.toString())")
                } else {
                    self.logger.error("Failed to delete failed bundle: \(deletedBundle.toString())")
                }
            }
            self.consumeOnLaunchDirectUpdateAttempt(plannedDirectUpdate: plannedDirectUpdate)
            if let manifest = response.manifest {
                nextImpl = try self.implementation.downloadManifest(
                    manifest: manifest,
                    version: latestVersionName,
                    sessionKey: response.sessionKey ?? "",
                    link: response.link,
                    comment: response.comment
                )
            } else {
                nextImpl = try self.implementation.download(
                    url: downloadUrl,
                    version: latestVersionName,
                    sessionKey: response.sessionKey ?? "",
                    link: response.link,
                    comment: response.comment
                )
            }
        }
        return nextImpl
    }

    func validateChecksum(response: AppVersion, next: BundleInfo, current: BundleInfo, plannedDirectUpdate: Bool) -> Bool {
        do {
            response.checksum = try CryptoCipher.decryptChecksum(checksum: response.checksum, publicKey: self.implementation.publicKey)
        } catch {
            self.logger.error("Error decrypting checksum \(error.localizedDescription)")
            return false
        }

        CryptoCipher.logChecksumInfo(label: "Bundle checksum", hexChecksum: next.getChecksum())
        CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: response.checksum)
        guard response.checksum != "", next.getChecksum() != response.checksum, response.manifest == nil else {
            return true
        }

        self.logger.error("Error checksum \(next.getChecksum()) \(response.checksum)")
        self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
        let id = next.getId()
        if !self.implementation.delete(id: id) {
            self.logger.error("Delete failed, id \(id) doesn't exist")
        }
        self.endBackGroundTaskWithNotif(
            msg: "Error checksum",
            latestVersionName: response.version,
            current: current,
            plannedDirectUpdate: plannedDirectUpdate
        )
        return false
    }

    func finishDownloadedUpdate(
        next: BundleInfo,
        latestVersionName: String,
        current: BundleInfo,
        plannedDirectUpdate: Bool
    ) {
        let directUpdateAllowed = plannedDirectUpdate && !self.autoSplashscreenTimedOut
        if directUpdateAllowed {
            installDownloadedBundleNow(next: next, latestVersionName: latestVersionName, plannedDirectUpdate: plannedDirectUpdate)
        } else if self.shouldAutoSetNextBundle() {
            queueDownloadedBundle(next: next, latestVersionName: latestVersionName, current: current, plannedDirectUpdate: plannedDirectUpdate)
        } else {
            self.logger.info("autoUpdate is set to onlyDownload, downloaded update will not be set as next bundle")
            self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()], retainUntilConsumed: true)
            self.endBackGroundTaskWithNotif(
                msg: "update downloaded, autoUpdate onlyDownload",
                latestVersionName: latestVersionName,
                current: current,
                error: false,
                plannedDirectUpdate: plannedDirectUpdate,
                notifyNoNeedUpdate: false
            )
        }
    }

    func installDownloadedBundleNow(next: BundleInfo, latestVersionName: String, plannedDirectUpdate: Bool) {
        if hasDelayConditions() {
            self.logger.info("Update delayed until delay conditions met")
            self.endBackGroundTaskWithNotif(
                msg: "Update delayed until delay conditions met",
                latestVersionName: latestVersionName,
                current: next,
                error: false,
                plannedDirectUpdate: plannedDirectUpdate
            )
            return
        }

        if self.implementation.set(bundle: next) && self.reloadCurrentBundle() {
            self.notifyBundleSet(next)
            self.endBackGroundTaskWithNotif(
                msg: "update installed",
                latestVersionName: latestVersionName,
                current: next,
                error: false,
                plannedDirectUpdate: plannedDirectUpdate
            )
        } else {
            self.endBackGroundTaskWithNotif(
                msg: "Update install failed",
                latestVersionName: latestVersionName,
                current: next,
                plannedDirectUpdate: plannedDirectUpdate
            )
        }
    }

    func queueDownloadedBundle(next: BundleInfo, latestVersionName: String, current: BundleInfo, plannedDirectUpdate: Bool) {
        if plannedDirectUpdate {
            self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will install on next app background.")
        }
        self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
        _ = self.implementation.setNextBundle(next: next.getId())
        self.endBackGroundTaskWithNotif(
            msg: "update downloaded, will install next background",
            latestVersionName: latestVersionName,
            current: current,
            error: false,
            plannedDirectUpdate: plannedDirectUpdate
        )
    }

    func hasDelayConditions() -> Bool {
        return !delayConditions().isEmpty
    }

    func delayConditions() -> [DelayCondition] {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.delayConditionPreferences) ?? "[]"
        return fromJsonArr(json: delayUpdatePreferences).compactMap { obj -> DelayCondition? in
            guard let kind = obj.value(forKey: "kind") as? String else {
                return nil
            }
            let value = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
    }

    func installNext() {
        if hasDelayConditions() {
            logger.info("Update delayed until delay conditions met")
            return
        }
        let current: BundleInfo = self.implementation.getCurrentBundle()
        guard let next = self.implementation.getNextBundle(),
              !next.isErrorStatus(),
              next.getVersionName() != current.getVersionName() else {
            return
        }

        logger.info("Next bundle is: \(next.toString())")
        if self.implementation.set(bundle: next) && self.reloadCurrentBundle() {
            logger.info("Updated to bundle: \(next.toString())")
            self.notifyBundleSet(next)
            _ = self.implementation.setNextBundle(next: Optional<String>.none)
        } else {
            logger.error("Update to bundle: \(next.toString()) Failed!")
        }
    }

    @objc func toJson(object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return ""
        }
        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }

    @objc func fromJsonArr(json: String) -> [NSObject] {
        guard let jsonData = json.data(using: .utf8) else {
            return []
        }
        let object = try? JSONSerialization.jsonObject(
            with: jsonData,
            options: .mutableContainers
        ) as? [NSObject]
        return object ?? []
    }
}
