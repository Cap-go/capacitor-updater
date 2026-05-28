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
    @objc func setUpdateUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setUpdateUrl called without allowModifyUrl")
            call.reject("setUpdateUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setUpdateUrl called without url")
            call.reject("setUpdateUrl called without url")
            return
        }
        self.updateUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: updateUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    func getUpdateUrl() -> String {
        return updateUrl
    }

    @objc func setStatsUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setStatsUrl called without allowModifyUrl")
            call.reject("setStatsUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setStatsUrl called without url")
            call.reject("setStatsUrl called without url")
            return
        }
        self.implementation.statsUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: statsUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    @objc func setChannelUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setChannelUrl called without allowModifyUrl")
            call.reject("setChannelUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setChannelUrl called without url")
            call.reject("setChannelUrl called without url")
            return
        }
        self.implementation.channelUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: channelUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    @objc func getBuiltinVersion(_ call: CAPPluginCall) {
        call.resolve(["version": implementation.versionBuild])
    }

    @objc func getDeviceId(_ call: CAPPluginCall) {
        call.resolve(["deviceId": implementation.deviceID])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }

    func manifestEntries(from manifestArray: [Any]?) -> [ManifestEntry]? {
        guard let manifestArray = manifestArray else {
            return nil
        }
        var manifestEntries: [ManifestEntry] = []
        for item in manifestArray {
            if let manifestDict = item as? [String: Any] {
                manifestEntries.append(ManifestEntry(
                    fileName: manifestDict["file_name"] as? String,
                    fileHash: manifestDict["file_hash"] as? String,
                    downloadUrl: manifestDict["download_url"] as? String
                ))
            }
        }
        return manifestEntries
    }

    @objc func download(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url") else {
            logger.error("Download called without url")
            call.reject("Download called without url")
            return
        }
        guard let version = call.getString("version") else {
            logger.error("Download called without version")
            call.reject("Download called without version")
            return
        }

        let sessionKey = call.getString("sessionKey", "")
        var checksum = call.getString("checksum", "")
        let manifestArray = call.getArray("manifest")
        let url = URL(string: urlString)
        logger.info("Downloading \(String(describing: url))")
        self.saveCallForAsyncHandling(call)
        self.runBackgroundDownloadWork {
            do {
                let next: BundleInfo
                if let manifestEntries = self.manifestEntries(from: manifestArray) {
                    next = try self.implementation.downloadManifest(manifest: manifestEntries, version: version, sessionKey: sessionKey)
                } else {
                    next = try self.implementation.download(url: url!, version: version, sessionKey: sessionKey)
                }
                // If public key is present but no checksum provided, refuse installation
                if self.implementation.publicKey != "" && checksum == "" {
                    self.logger.error("Public key present but no checksum provided")
                    self.implementation.sendStats(action: "checksum_required", versionName: next.getVersionName())
                    let id = next.getId()
                    let resDel = self.implementation.delete(id: id)
                    if !resDel {
                        self.logger.error("Delete failed, id \(id) doesn't exist")
                    }
                    throw ObjectSavableError.checksum
                }

                checksum = try CryptoCipher.decryptChecksum(checksum: checksum, publicKey: self.implementation.publicKey)
                CryptoCipher.logChecksumInfo(label: "Bundle checksum", hexChecksum: next.getChecksum())
                CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: checksum)
                if (checksum != "" || self.implementation.publicKey != "") && next.getChecksum() != checksum {
                    self.logger.error("Error checksum \(next.getChecksum()) \(checksum)")
                    self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
                    let id = next.getId()
                    let resDel = self.implementation.delete(id: id)
                    if !resDel {
                        self.logger.error("Delete failed, id \(id) doesn't exist")
                    }
                    throw ObjectSavableError.checksum
                } else {
                    self.logger.info("Good checksum \(next.getChecksum()) \(checksum)")
                }
                var updateAvailablePayload: JSObject = [:]
                updateAvailablePayload["bundle"] = self.bundlePayload(next)
                self.notifyListenersOnMain("updateAvailable", data: updateAvailablePayload)
                self.resolveCall(call, data: next.toJSON())
            } catch {
                self.logger.error("Failed to download from: \(String(describing: url)) \(error.localizedDescription)")
                var downloadFailedPayload: JSObject = [:]
                downloadFailedPayload["version"] = version
                self.notifyListenersOnMain("downloadFailed", data: downloadFailedPayload)
                self.implementation.sendStats(action: "download_fail")
                self.rejectCall(call, message: "Failed to download from: \(url!) - \(error.localizedDescription)")
            }
        }
    }

    func currentReloadDestination() -> URL {
        let id = self.implementation.getCurrentBundleId()
        if BundleInfo.idBuiltin == id {
            return Bundle.main.resourceURL!.appendingPathComponent("public")
        } else {
            return self.implementation.getBundleDirectory(id: id)
        }
    }

    func applyCurrentBundleToBridge(_ bridge: CAPBridgeProtocol) -> Bool {
        let id = self.implementation.getCurrentBundleId()
        let dest = self.currentReloadDestination()
        logger.info("Reloading \(id)")

        guard let vc = bridge.viewController as? CAPBridgeViewController else {
            self.logger.error("Cannot get viewController")
            return false
        }
        guard let capBridge = vc.bridge else {
            self.logger.error("Cannot get capBridge")
            return false
        }
        if self.keepUrlPathAfterReload {
            if let currentURL = vc.webView?.url {
                capBridge.setServerBasePath(dest.path)
                var urlComponents = URLComponents(url: capBridge.config.serverURL, resolvingAgainstBaseURL: false)!
                urlComponents.path = currentURL.path
                urlComponents.query = currentURL.query
                urlComponents.fragment = currentURL.fragment
                if let finalUrl = urlComponents.url {
                    _ = vc.webView?.load(URLRequest(url: finalUrl))
                } else {
                    self.logger.error("Unable to build final URL when keeping path after reload; falling back to base path")
                    vc.setServerBasePath(path: dest.path)
                }
            } else {
                self.logger.error("vc.webView?.url is null? Falling back to base path reload.")
                vc.setServerBasePath(path: dest.path)
            }
        } else {
            vc.setServerBasePath(path: dest.path)
        }
        return true
    }

    func restoreLiveBundleStateAfterFailedReloadImpl() {
        guard let bridge = self.bridge else {
            return
        }

        let restoreLiveState = {
            _ = self.applyCurrentBundleToBridge(bridge)
        }

        if Thread.isMainThread {
            restoreLiveState()
        } else {
            DispatchQueue.main.sync {
                restoreLiveState()
            }
        }
    }

    func reloadCurrentBundleImpl() -> Bool {
        guard let bridge = self.bridge else { return false }
        self.semaphoreUp()

        let performReload: () -> Bool = {
            guard self.applyCurrentBundleToBridge(bridge) else {
                return false
            }
            self.checkAppReady()
            self.notifyListeners("appReloaded", data: [:])
            return true
        }

        if Thread.isMainThread {
            return performReload()
        } else {
            var result = false
            DispatchQueue.main.sync {
                result = performReload()
            }
            return result
        }
    }

    @objc func reload(_ call: CAPPluginCall) {
        let current: BundleInfo = self.implementation.getCurrentBundle()
        let next: BundleInfo? = self.implementation.getNextBundle()

        if let next = next, !next.isErrorStatus(), next.getId() != current.getId() {
            let previousState = self.implementation.captureResetState()
            let previousBundleName = self.implementation.getCurrentBundle().getVersionName()
            logger.info("Applying pending bundle before reload: \(next.toString())")
            let didApplyPendingBundle: Bool
            if next.isBuiltin() {
                self.implementation.prepareResetStateForTransition()
                didApplyPendingBundle = true
            } else {
                didApplyPendingBundle = self.implementation.stagePendingReload(bundle: next)
            }
            if didApplyPendingBundle && self.reloadCurrentBundle() {
                if next.isBuiltin() {
                    self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: false)
                } else {
                    self.implementation.finalizePendingReload(bundle: next, previousBundleName: previousBundleName)
                }
                self.notifyBundleSet(next)
                _ = self.implementation.setNextBundle(next: Optional<String>.none)
                self.showPreviewSessionNoticeIfNeeded()
                call.resolve()
                return
            }
            self.implementation.restoreResetState(previousState)
            self.restoreLiveBundleStateAfterFailedReload()
            logger.error("Reload failed after applying pending bundle: \(next.toString())")
            call.reject("Reload failed after applying pending bundle")
            return
        }

        if self.reloadCurrentBundle() {
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        } else {
            logger.error("Reload failed")
            call.reject("Reload failed")
        }
    }

    @objc func next(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            logger.error("Next called without id")
            call.reject("Next called without id")
            return
        }
        logger.info("Setting next active id \(id)")
        if !self.implementation.setNextBundle(next: id) {
            logger.error("Set next version failed. id \(id) does not exist.")
            call.reject("Set next version failed. id \(id) does not exist.")
        } else {
            call.resolve(self.implementation.getBundleInfo(id: id).toJSON())
        }
    }

    @objc func set(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            logger.error("Set called without id")
            call.reject("Set called without id")
            return
        }
        let res = implementation.set(id: id)
        logger.info("Set active bundle: \(id)")
        if !res {
            logger.info("Bundle successfully set to: \(id) ")
            call.reject("Update failed, id \(id) doesn't exist")
        } else if !self.reloadCurrentBundle() {
            call.reject("Reload failed after setting bundle \(id)")
        } else {
            self.notifyBundleSet(self.implementation.getBundleInfo(id: id))
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        }
    }

    @objc func startPreviewSession(_ call: CAPPluginCall) {
        guard self.allowPreview else {
            logger.error("startPreviewSession called without allowPreview")
            call.reject("startPreviewSession not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        let previewAppId = self.normalizedPreviewAppId(call.getString("appId"))

        if !self.previewSessionEnabled {
            let current = self.implementation.getCurrentBundle()
            guard self.implementation.setPreviewFallbackBundle(fallback: current.getId()) else {
                logger.error("Could not save current bundle as preview fallback")
                call.reject("Could not save current bundle as preview fallback")
                return
            }

            if let previousNext = self.implementation.getNextBundle(),
               !previousNext.isDeleted(),
               !previousNext.isErrorStatus() {
                UserDefaults.standard.set(previousNext.getId(), forKey: self.previewPreviousNextBundleDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: self.previewPreviousNextBundleDefaultsKey)
            }

            UserDefaults.standard.set(self.implementation.appId, forKey: self.previewPreviousAppIdDefaultsKey)
            UserDefaults.standard.set(self.shakeMenuEnabled, forKey: self.previewPreviousShakeMenuDefaultsKey)
            UserDefaults.standard.set(self.shakeChannelSelectorEnabled, forKey: self.previewPreviousShakeChannelSelectorDefaultsKey)
            logger.info("Preview session started with fallback bundle: \(current.toString())")
        }

        if let previewAppId = previewAppId, !previewAppId.isEmpty {
            self.implementation.appId = previewAppId
            UserDefaults.standard.set(previewAppId, forKey: self.previewAppIdDefaultsKey)
            logger.info("Preview session using appId: \(previewAppId)")
        }

        self.previewSessionEnabled = true
        self.previewSessionAlertPending = true
        self.implementation.previewSession = true
        self.shakeMenuEnabled = true
        self.shakeChannelSelectorEnabled = false
        UserDefaults.standard.set(true, forKey: self.previewSessionDefaultsKey)
        UserDefaults.standard.synchronize()
        call.resolve()
    }

    func leavePreviewSessionFromShakeMenu() -> Bool {
        let previewBundle = self.implementation.getCurrentBundle()
        let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!

        let didReset = self.resetToPreviewFallbackBundle()
        guard didReset else {
            return false
        }

        _ = self.implementation.unsetChannel(defaultChannelKey: self.defaultChannelDefaultsKey, configDefaultChannel: configDefaultChannel)
        let previewFallbackBundle = self.implementation.getPreviewFallbackBundle()
        self.endPreviewSession()
        let restoredNextBundle = self.implementation.getNextBundle()
        if !previewBundle.isBuiltin() &&
            previewFallbackBundle?.getId() != previewBundle.getId() &&
            restoredNextBundle?.getId() != previewBundle.getId() {
            _ = self.implementation.delete(id: previewBundle.getId(), removeInfo: false)
        }
        return true
    }

    func reloadPreviewSessionFromShakeMenu() -> Bool {
        self.reloadCurrentBundle()
    }

    func hasActivePreviewSession() -> Bool {
        self.previewSessionEnabled
    }

    func resetToPreviewFallbackBundle() -> Bool {
        guard self.canPerformResetTransition() else { return false }
        guard let fallback = self.implementation.getPreviewFallbackBundle(), !fallback.isErrorStatus() else {
            logger.error("No preview fallback bundle available")
            return false
        }
        guard self.implementation.canSet(bundle: fallback) else {
            logger.error("Preview fallback bundle is not installable")
            return false
        }

        let previousState = self.implementation.captureResetState()
        let previousBundleName = self.implementation.getCurrentBundle().getVersionName()
        logger.info("Resetting to preview fallback bundle: \(fallback.toString())")
        if self.implementation.stagePreviewFallbackReload(bundle: fallback) && self.reloadCurrentBundle() {
            self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: false)
            self.notifyBundleSet(fallback)
            return true
        }
        self.implementation.restoreResetState(previousState)
        self.restoreLiveBundleStateAfterFailedReload()
        return false
    }

    func endPreviewSession() {
        let previousShakeMenuEnabled = UserDefaults.standard.object(forKey: self.previewPreviousShakeMenuDefaultsKey) as? Bool
            ?? getConfig().getBoolean("shakeMenu", false)
        let previousShakeChannelSelectorEnabled = UserDefaults.standard.object(forKey: self.previewPreviousShakeChannelSelectorDefaultsKey) as? Bool
            ?? getConfig().getBoolean("allowShakeChannelSelector", false)
        self.restorePreviewPreviousNextBundle()
        self.restorePreviewPreviousAppId()

        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.implementation.previewSession = false
        self.shakeMenuEnabled = previousShakeMenuEnabled
        self.shakeChannelSelectorEnabled = previousShakeChannelSelectorEnabled
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        self.clearPreviewSessionPreferences()
        logger.info("Preview session ended")
    }

    func clearPreviewSessionBecauseDisabled() {
        logger.info("Preview session disabled by config; restoring preview fallback")
        let fallback = self.implementation.getPreviewFallbackBundle()
        let bundleToRestore: BundleInfo
        if let fallback, !fallback.isErrorStatus() {
            bundleToRestore = fallback
        } else {
            bundleToRestore = self.implementation.getBundleInfo(id: BundleInfo.idBuiltin)
        }

        if self.implementation.canSet(bundle: bundleToRestore) {
            _ = self.implementation.stagePreviewFallbackReload(bundle: bundleToRestore)
        } else {
            logger.warn("Could not restore preview fallback while disabling preview")
        }

        self.restorePreviewPreviousNextBundle()
        self.restorePreviewPreviousAppId()
        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.implementation.previewSession = false
        self.shakeMenuEnabled = getConfig().getBoolean("shakeMenu", false)
        self.shakeChannelSelectorEnabled = getConfig().getBoolean("allowShakeChannelSelector", false)
        self.clearPreviewSessionPreferences()
    }

    func clearPreviewSessionPreferences() {
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        UserDefaults.standard.removeObject(forKey: self.previewSessionDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPreviousShakeMenuDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPreviousShakeChannelSelectorDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPreviousNextBundleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPreviousAppIdDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewAppIdDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    func restorePreviewPreviousAppId() {
        guard let previousAppId = UserDefaults.standard.string(forKey: self.previewPreviousAppIdDefaultsKey),
              !previousAppId.isEmpty else {
            return
        }
        self.implementation.appId = previousAppId
        logger.info("Restored appId after preview: \(previousAppId)")
    }

    func normalizedPreviewAppId(_ rawAppId: String?) -> String? {
        guard let rawAppId else {
            return nil
        }

        let appId = rawAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appId.isEmpty else {
            return nil
        }

        let lowercasedAppId = appId.lowercased()
        if lowercasedAppId == "undefined" || lowercasedAppId == "null" {
            return nil
        }

        return appId
    }

    func clearPreviewSessionForNativeBuildChange() {
        guard self.previewSessionEnabled || self.implementation.getPreviewFallbackBundle() != nil else {
            return
        }
        logger.info("Native build changed; clearing preview session state")
        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.implementation.previewSession = false
        self.shakeMenuEnabled = getConfig().getBoolean("shakeMenu", false)
        self.shakeChannelSelectorEnabled = getConfig().getBoolean("allowShakeChannelSelector", false)
        self.restorePreviewPreviousAppId()
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        _ = self.implementation.setNextBundle(next: Optional<String>.none)
        let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
        _ = self.implementation.unsetChannel(defaultChannelKey: self.defaultChannelDefaultsKey, configDefaultChannel: configDefaultChannel)
        self.clearPreviewSessionPreferences()
    }

    func restorePreviewPreviousNextBundle() {
        guard let previousNextBundleId = UserDefaults.standard.string(forKey: self.previewPreviousNextBundleDefaultsKey),
              !previousNextBundleId.isEmpty else {
            _ = self.implementation.setNextBundle(next: Optional<String>.none)
            return
        }
        if !self.implementation.setNextBundle(next: previousNextBundleId) {
            logger.warn("Could not restore pre-preview next bundle: \(previousNextBundleId)")
            _ = self.implementation.setNextBundle(next: Optional<String>.none)
        }
    }

    func showPreviewSessionNoticeIfNeeded() {
        guard self.previewSessionEnabled && self.previewSessionAlertPending else {
            return
        }
        self.previewSessionAlertPending = false

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            guard self.previewSessionEnabled else {
                return
            }
            if let topVC = UIApplication.topViewController(),
               topVC.isKind(of: UIAlertController.self) {
                self.previewSessionAlertPending = true
                return
            }

            let alert = UIAlertController(
                title: "Preview started",
                message: "Shake your device anytime to reload or leave the test app.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Got it", style: .default))
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }
}
