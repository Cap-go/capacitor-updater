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
    @objc func delete(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            logger.error("Delete called without version")
            call.reject("Delete called without id")
            return
        }
        let res = implementation.delete(id: id)
        if res {
            call.resolve()
        } else {
            logger.error("Delete failed, id \(id) doesn't exist or it cannot be deleted (perhaps it is the 'next' bundle)")
            call.reject("Delete failed, id \(id) does not exist or it cannot be deleted (perhaps it is the 'next' bundle)")
        }
    }

    @objc func setBundleError(_ call: CAPPluginCall) {
        if !allowManualBundleError {
            logger.error("setBundleError called without allowManualBundleError")
            call.reject("setBundleError not allowed. Set allowManualBundleError to true in your config to enable it.")
            return
        }
        guard let id = call.getString("id") else {
            logger.error("setBundleError called without id")
            call.reject("setBundleError called without id")
            return
        }
        let bundle = implementation.getBundleInfo(id: id)
        if bundle.isUnknown() {
            logger.error("setBundleError called with unknown bundle \(id)")
            call.reject("Bundle \(id) does not exist")
            return
        }
        if bundle.isBuiltin() {
            logger.error("setBundleError called on builtin bundle")
            call.reject("Cannot set builtin bundle to error state")
            return
        }
        if self.isAutoUpdateEnabledInternal() {
            logger.warn("setBundleError used while autoUpdate is enabled; this method is intended for manual mode")
        }
        implementation.setError(bundle: bundle)
        let updated = implementation.getBundleInfo(id: id)
        call.resolve(["bundle": updated.toJSON()])
    }

    @objc func list(_ call: CAPPluginCall) {
        let raw = call.getBool("raw", false)
        let res = implementation.list(raw: raw)
        var resArr: [[String: String]] = []
        for bundle in res {
            resArr.append(bundle.toJSON())
        }
        call.resolve([
            "bundles": resArr
        ])
    }

    @objc func getLatest(_ call: CAPPluginCall) {
        let channel = call.getString("channel")
        let includeBundleSize = call.getBool("includeBundleSize", false)
        let appId = self.normalizedPreviewAppId(call.getString("appId"))
        if appId != nil && !self.allowPreview {
            logger.error("getLatest preview override called without allowPreview")
            call.reject("getLatest preview override not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        self.saveCallForAsyncHandling(call)
        runGetLatestWork {
            guard let updateURL = URL(string: self.updateUrl) else {
                self.logger.error("getLatest called with invalid updateUrl")
                self.rejectCall(call, message: "Invalid updateUrl")
                return
            }
            let res = self.implementation.getLatest(
                url: updateURL,
                channel: channel,
                appIdOverride: appId
            )
            if includeBundleSize {
                self.attachBundleSize(to: res)
            }
            if let error = res.error, !error.isEmpty {
                let responseKind = self.updateResponseKind(kind: res.kind)
                res.kind = responseKind
                self.notifyBreakingEventsIfNeeded(response: res, version: res.version)
                if responseKind == "failed" {
                    self.rejectCall(call, message: error)
                } else {
                    if res.version.isEmpty {
                        res.version = self.implementation.getCurrentBundle().getVersionName()
                    }
                    self.resolveCall(call, data: res.toDict())
                }
            } else if let kind = res.kind, !kind.isEmpty {
                let responseKind = self.updateResponseKind(kind: kind)
                res.kind = responseKind
                self.notifyBreakingEventsIfNeeded(response: res, version: res.version)
                if responseKind != "failed" {
                    if res.version.isEmpty {
                        res.version = self.implementation.getCurrentBundle().getVersionName()
                    }
                    self.resolveCall(call, data: res.toDict())
                } else {
                    self.rejectCall(call, message: res.message ?? "server did not provide a message")
                }
            } else if let message = res.message, !message.isEmpty {
                self.notifyBreakingEventsIfNeeded(response: res, version: res.version)
                self.rejectCall(call, message: message)
            } else {
                self.resolveCall(call, data: res.toDict())
            }
        }
    }

    func attachBundleSize(to res: AppVersion) {
        guard let manifest = res.manifest, !manifest.isEmpty, let updateUrl = URL(string: self.updateUrl) else {
            return
        }
        let missing = self.implementation.getMissingBundleFiles(manifest: manifest, sessionKey: res.sessionKey ?? "")
        res.missing = [
            "missing": missing.map { $0.toDict() },
            "total": manifest.count,
            "missingCount": missing.count,
            "reusableCount": manifest.count - missing.count
        ]
        res.downloadSize = self.implementation.getBundleDownloadSize(updateUrl: updateUrl, version: res.version, manifest: missing)
    }

    @objc func getMissingBundleFiles(_ call: CAPPluginCall) {
        guard let manifest = manifestEntries(from: call.getArray("manifest")) else {
            call.reject("getMissingBundleFiles called without manifest")
            return
        }
        let sessionKey = call.getString("sessionKey", "")
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let res = self.implementation.missingBundleFilesResult(manifest: manifest, sessionKey: sessionKey)
            self.resolveCall(call, data: res)
        }
    }

    @objc func getBundleDownloadSize(_ call: CAPPluginCall) {
        guard let manifest = manifestEntries(from: call.getArray("manifest")) else {
            call.reject("getBundleDownloadSize called without manifest")
            return
        }
        guard let updateUrl = URL(string: self.updateUrl) else {
            call.reject("getBundleDownloadSize called without valid updateUrl")
            return
        }
        let version = call.getString("version")
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let res = self.implementation.getBundleDownloadSize(updateUrl: updateUrl, version: version, manifest: manifest)
            self.resolveCall(call, data: res)
        }
    }

    public func triggerBackgroundUpdateCheck() -> String {
        guard !self.updateUrl.isEmpty, URL(string: self.updateUrl) != nil else {
            logger.error("Error no url or wrong format")
            return "unavailable"
        }
        if self.isDownloadStuckOrTimedOut() {
            logger.info("Download already in progress, skipping duplicate download request")
            return "already_running"
        }
        self.backgroundDownload()
        return "queued"
    }

    @objc func triggerUpdateCheck(_ call: CAPPluginCall) {
        let status = self.triggerBackgroundUpdateCheck()
        call.resolve([
            "status": status,
            "queued": status == "queued"
        ])
    }

    @objc func unsetChannel(_ call: CAPPluginCall) {
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate", false)
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
            let res = self.implementation.unsetChannel(defaultChannelKey: self.defaultChannelDefaultsKey, configDefaultChannel: configDefaultChannel)
            if res.error != "" {
                self.rejectCall(call, message: res.error, code: "UNSETCHANNEL_FAILED", data: [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                if self.isAutoUpdateEnabledInternal() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    // Check if download is already in progress (with timeout protection)
                    if !self.isDownloadStuckOrTimedOut() {
                        self.backgroundDownload()
                    } else {
                        self.logger.info("Download already in progress, skipping duplicate download request")
                    }
                }
                self.resolveCall(call, data: res.toDict())
            }
        }
    }

    @objc func setChannel(_ call: CAPPluginCall) {
        guard let channel = call.getString("channel") else {
            logger.error("setChannel called without channel")
            call.reject("setChannel called without channel", "SETCHANNEL_INVALID_PARAMS", nil, [
                "message": "setChannel called without channel",
                "error": "missing_parameter"
            ])
            return
        }
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate") ?? false
        let configDefaultChannel = self.getConfig().getString("defaultChannel", "") ?? ""
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let res = self.implementation.setChannel(
                channel: channel,
                defaultChannelKey: self.defaultChannelDefaultsKey,
                allowSetDefaultChannel: self.allowSetDefaultChannel,
                configDefaultChannel: configDefaultChannel
            )
            if res.error != "" {
                // Fire channelPrivate event if channel doesn't allow self-assignment
                if res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed") {
                    self.notifyListenersOnMain("channelPrivate", data: [
                        "channel": channel,
                        "message": res.error
                    ])
                }
                self.rejectCall(call, message: res.error, code: "SETCHANNEL_FAILED", data: [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : (res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed")) ? "channel_private" : "request_failed"
                ])
            } else {
                if self.isAutoUpdateEnabledInternal() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    // Check if download is already in progress (with timeout protection)
                    if !self.isDownloadStuckOrTimedOut() {
                        self.backgroundDownload()
                    } else {
                        self.logger.info("Download already in progress, skipping duplicate download request")
                    }
                }
                self.resolveCall(call, data: res.toDict())
            }
        }
    }

    @objc func getChannel(_ call: CAPPluginCall) {
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let res = self.implementation.getChannel()
            if res.error != "" {
                self.rejectCall(call, message: res.error, code: "GETCHANNEL_FAILED", data: [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                self.resolveCall(call, data: res.toDict())
            }
        }
    }

    @objc func listChannels(_ call: CAPPluginCall) {
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let res = self.implementation.listChannels()
            if res.error != "" {
                self.rejectCall(call, message: res.error, code: "LISTCHANNELS_FAILED", data: [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                var payload: JSObject = [:]
                payload["channels"] = res.channels
                self.resolveCall(call, data: payload)
            }
        }
    }

    @objc func setCustomId(_ call: CAPPluginCall) {
        guard let customId = call.getString("customId") else {
            logger.error("setCustomId called without customId")
            call.reject("setCustomId called without customId")
            return
        }
        self.implementation.customId = customId
        if persistCustomId {
            if customId.isEmpty {
                UserDefaults.standard.removeObject(forKey: customIdDefaultsKey)
            } else {
                UserDefaults.standard.set(customId, forKey: customIdDefaultsKey)
            }
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    @objc func resetToTarget(toLastSuccessful: Bool, usePendingBundle: Bool) -> Bool {
        self.performReset(toLastSuccessful: toLastSuccessful, usePendingBundle: usePendingBundle, isInternal: false)
    }

    func performReset(toLastSuccessful: Bool, usePendingBundle: Bool, isInternal: Bool) -> Bool {
        guard self.canPerformResetTransition() else { return false }

        let fallback: BundleInfo = self.implementation.getFallbackBundle()
        let pending: BundleInfo? = self.implementation.getNextBundle()
        let previousState = self.implementation.captureResetState()
        let previousBundleName = self.implementation.getCurrentBundle().getVersionName()

        if usePendingBundle {
            guard let pending = pending, !pending.isErrorStatus() else {
                logger.error("No pending bundle available to reset to")
                return false
            }
            guard self.implementation.canSet(bundle: pending) else {
                logger.error("Pending bundle is not installable")
                return false
            }
            self.implementation.prepareResetStateForTransition()
            logger.info("Resetting to pending bundle: \(pending.toString())")
            let didApplyPendingBundle: Bool
            if pending.isBuiltin() {
                didApplyPendingBundle = true
            } else {
                didApplyPendingBundle = self.implementation.set(bundle: pending)
            }
            if didApplyPendingBundle && self.reloadCurrentBundle() {
                self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: isInternal)
                self.notifyBundleSet(pending)
                _ = self.implementation.setNextBundle(next: Optional<String>.none)
                return true
            }
            self.implementation.restoreResetState(previousState)
            self.restoreLiveBundleStateAfterFailedReload()
            return false
        }

        // If developer wants to reset to the last successful bundle, and that bundle is not
        // the built-in bundle, set it as the bundle to use and reload.
        if toLastSuccessful && !fallback.isBuiltin() {
            if self.implementation.canSet(bundle: fallback) {
                self.implementation.prepareResetStateForTransition()
                logger.info("Resetting to: \(fallback.toString())")
                if self.implementation.set(bundle: fallback) && self.reloadCurrentBundle() {
                    self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: isInternal)
                    self.notifyBundleSet(fallback)
                    return true
                }
                if !isInternal {
                    self.implementation.restoreResetState(previousState)
                    self.restoreLiveBundleStateAfterFailedReload()
                    return false
                }
                logger.warn("Fallback reload failed during internal reset, resetting to builtin instead")
            } else {
                logger.warn("Fallback bundle is not installable, resetting to builtin instead")
            }
        }

        self.implementation.prepareResetStateForTransition()
        logger.info("Resetting to builtin version")
        if self.reloadCurrentBundle() {
            self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: isInternal)
            return true
        }
        if !isInternal {
            self.implementation.restoreResetState(previousState)
            self.restoreLiveBundleStateAfterFailedReload()
        }
        return false
    }

    func canPerformResetTransitionImpl() -> Bool {
        guard let bridge = self.bridge else { return false }
        return (bridge.viewController as? CAPBridgeViewController) != nil
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toLastSuccessful = call.getBool("toLastSuccessful") ?? false
        let usePendingBundle = call.getBool("usePendingBundle") ?? false
        if self.resetToTarget(toLastSuccessful: toLastSuccessful, usePendingBundle: usePendingBundle) {
            call.resolve()
        } else {
            logger.error("Reset failed")
            call.reject("Reset failed")
        }
    }

    @objc func current(_ call: CAPPluginCall) {
        let bundle: BundleInfo = self.implementation.getCurrentBundle()
        call.resolve([
            "bundle": bundle.toJSON(),
            "native": self.currentVersionNative.description
        ])
    }

    @objc func notifyAppReady(_ call: CAPPluginCall) {
        self.semaphoreDown()
        let bundle = self.implementation.getCurrentBundle()
        self.implementation.setSuccess(bundle: bundle, autoDeletePrevious: self.autoDeletePrevious)
        logger.info("Current bundle loaded successfully. [notifyAppReady was called] \(bundle.toString())")

        call.resolve(["bundle": bundle.toJSON()])
    }

    @objc func setMultiDelay(_ call: CAPPluginCall) {
        guard let delayConditionList = call.getValue("delayConditions") else {
            logger.error("setMultiDelay called without delayCondition")
            call.reject("setMultiDelay called without delayCondition")
            return
        }

        // Handle background conditions with empty value (set to "0")
        if var modifiableList = delayConditionList as? [[String: Any]] {
            for index in 0..<modifiableList.count {
                if let kind = modifiableList[index]["kind"] as? String,
                   kind == "background",
                   let value = modifiableList[index]["value"] as? String,
                   value.isEmpty {
                    modifiableList[index]["value"] = "0"
                }
            }
            let delayConditions: String = toJson(object: modifiableList)
            if delayUpdateUtils.setMultiDelay(delayConditions: delayConditions) {
                call.resolve()
            } else {
                call.reject("Failed to delay update")
            }
        } else {
            let delayConditions: String = toJson(object: delayConditionList)
            if delayUpdateUtils.setMultiDelay(delayConditions: delayConditions) {
                call.resolve()
            } else {
                call.reject("Failed to delay update")
            }
        }
    }

    // Note: _setMultiDelay and _cancelDelay methods have been moved to DelayUpdateUtils class

    @objc func cancelDelay(_ call: CAPPluginCall) {
        if delayUpdateUtils.cancelDelay(source: "JS") {
            call.resolve()
        } else {
            call.reject("Failed to cancel delay")
        }
    }

    // Note: _checkCancelDelay method has been moved to DelayUpdateUtils class

    func isAutoUpdateEnabledInternal() -> Bool {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        if instanceDescriptor?.serverURL != nil {
            logger.warn("AutoUpdate is automatic disabled when serverUrl is set.")
        }
        return self.autoUpdate && self.updateUrl != "" && instanceDescriptor?.serverURL == nil
    }

    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.isAutoUpdateEnabledInternal()
        ])
    }

    @objc func isAutoUpdateAvailable(_ call: CAPPluginCall) {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        let isAvailable = instanceDescriptor?.serverURL == nil
        call.resolve([
            "available": isAvailable
        ])
    }

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

        if BundleStatus.SUCCESS.storedValue != current.getStatus() {
            logger.error("notifyAppReady was not called, roll back current bundle: \(current.toString())")
            logger.error("Did you forget to call 'notifyAppReady()' in your Capacitor App code?")
            self.notifyListeners("updateFailed", data: [
                "bundle": current.toJSON()
            ])
            self.persistLastFailedBundle(current)
            self.implementation.sendStats(action: "update_fail", versionName: current.getVersionName())
            self.implementation.setError(bundle: current)
            _ = self.performReset(toLastSuccessful: true, usePendingBundle: false, isInternal: true)
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

    func endBackGroundTaskImpl() {
        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    }
}
