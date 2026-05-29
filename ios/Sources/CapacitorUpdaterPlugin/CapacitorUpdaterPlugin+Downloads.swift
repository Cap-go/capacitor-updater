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

    struct PreviewPayload: Decodable {
        let version: String?
        let url: String?
        let checksum: String?
        let sessionKey: String?
        let manifest: [ManifestEntry]?
        let message: String?
        let error: String?
    }

    func makePreviewError(_ message: String) -> NSError {
        NSError(domain: "CapacitorUpdaterPreview", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func downloadBundle(
        urlString: String,
        version: String,
        sessionKey: String,
        checksum rawChecksum: String,
        manifestEntries: [ManifestEntry]?
    ) throws -> BundleInfo {
        guard let url = URL(string: urlString) else {
            throw makePreviewError("Invalid download URL")
        }

        var checksum = rawChecksum
        let next: BundleInfo
        if let manifestEntries = manifestEntries {
            next = try self.implementation.downloadManifest(manifest: manifestEntries, version: version, sessionKey: sessionKey)
        } else {
            next = try self.implementation.download(url: url, version: version, sessionKey: sessionKey)
        }

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
        }

        self.logger.info("Good checksum \(next.getChecksum()) \(checksum)")
        return next
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
        let rawPayloadUrl = call.getString("payloadUrl")
        let previewPayloadUrl = self.normalizedPreviewPayloadUrl(rawPayloadUrl)
        if let rawPayloadUrl = rawPayloadUrl,
           !rawPayloadUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           previewPayloadUrl == nil {
            logger.error("startPreviewSession called with invalid payloadUrl")
            call.reject("Invalid preview payloadUrl")
            return
        }

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
            if let previousDefaultChannel = UserDefaults.standard.object(forKey: self.defaultChannelDefaultsKey) as? String {
                UserDefaults.standard.set(previousDefaultChannel, forKey: self.previewPreviousDefaultChannelDefaultsKey)
                UserDefaults.standard.set(true, forKey: self.previewPreviousDefaultChannelWasSetDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: self.previewPreviousDefaultChannelDefaultsKey)
                UserDefaults.standard.set(false, forKey: self.previewPreviousDefaultChannelWasSetDefaultsKey)
            }
            UserDefaults.standard.set(self.shakeMenuEnabled, forKey: self.previewPreviousShakeMenuDefaultsKey)
            UserDefaults.standard.set(self.shakeChannelSelectorEnabled, forKey: self.previewPreviousShakeChannelSelectorDefaultsKey)
            logger.info("Preview session started with fallback bundle: \(current.toString())")
        }

        if let previewAppId = previewAppId, !previewAppId.isEmpty {
            self.implementation.appId = previewAppId
            UserDefaults.standard.set(previewAppId, forKey: self.previewAppIdDefaultsKey)
            logger.info("Preview session using appId: \(previewAppId)")
        }

        if let previewPayloadUrl = previewPayloadUrl {
            UserDefaults.standard.set(previewPayloadUrl.absoluteString, forKey: self.previewPayloadUrlDefaultsKey)
            logger.info("Preview session using payload URL")
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewPayloadUrlDefaultsKey)
        }

        self.previewSessionEnabled = true
        self.previewSessionAlertPending = true
        self.implementation.previewSession = true
        self.shakeMenuEnabled = true
        self.shakeChannelSelectorEnabled = false
        UserDefaults.standard.set(true, forKey: self.previewSessionDefaultsKey)
        UserDefaults.standard.set(true, forKey: self.previewSessionAlertPendingDefaultsKey)
        UserDefaults.standard.synchronize()
        call.resolve()
    }

    func leavePreviewSessionFromShakeMenu() -> Bool {
        let previewBundle = self.implementation.getCurrentBundle()

        let didReset = self.resetToPreviewFallbackBundle()
        guard didReset else {
            return false
        }

        let previewFallbackBundle = self.implementation.getPreviewFallbackBundle()
        self.endPreviewSession()
        let restoredNextBundle = self.implementation.getNextBundle()
        self.deletePreviewBundleIfUnused(previewBundle, previewFallbackBundle: previewFallbackBundle, restoredNextBundle: restoredNextBundle)
        return true
    }

    func leavePreviewSessionForLaunchURLIfNeeded() {
        guard self.previewSessionEnabled,
              !self.isLeavingPreviewForIncomingLink,
              let launchUrl = ApplicationDelegateProxy.shared.lastURL,
              self.isPreviewDeepLink(launchUrl) else {
            return
        }

        self.isLeavingPreviewForIncomingLink = true
        logger.info("Preview deeplink launch detected while preview session is active; restoring fallback before initial load")
        if !self.leavePreviewSessionWithoutReload() {
            logger.error("Could not leave preview session before initial preview deeplink routing")
            self.isLeavingPreviewForIncomingLink = false
        }
    }

    func leavePreviewSessionWithoutReload() -> Bool {
        let previewBundle = self.implementation.getCurrentBundle()
        guard let previewFallbackBundle = self.implementation.getPreviewFallbackBundle(), !previewFallbackBundle.isErrorStatus() else {
            logger.error("No preview fallback bundle available")
            return false
        }
        guard self.implementation.canSet(bundle: previewFallbackBundle) else {
            logger.error("Preview fallback bundle is not installable")
            return false
        }
        guard self.implementation.stagePreviewFallbackReload(bundle: previewFallbackBundle) else {
            logger.error("Could not stage preview fallback bundle")
            return false
        }

        self.endPreviewSession()
        let restoredNextBundle = self.implementation.getNextBundle()
        self.deletePreviewBundleIfUnused(previewBundle, previewFallbackBundle: previewFallbackBundle, restoredNextBundle: restoredNextBundle)
        return true
    }

    func deletePreviewBundleIfUnused(
        _ previewBundle: BundleInfo,
        previewFallbackBundle: BundleInfo?,
        restoredNextBundle: BundleInfo?
    ) {
        if !previewBundle.isBuiltin() &&
            previewFallbackBundle?.getId() != previewBundle.getId() &&
            restoredNextBundle?.getId() != previewBundle.getId() {
            _ = self.implementation.delete(id: previewBundle.getId(), removeInfo: false)
        }
    }

    func reloadPreviewSessionFromShakeMenu() -> Bool {
        if let payloadUrl = self.storedPreviewPayloadUrl() {
            return self.refreshPreviewSessionFromPayloadUrl(payloadUrl)
        }

        return self.reloadCurrentBundle()
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
        self.restorePreviewPreviousDefaultChannel()

        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.isLeavingPreviewForIncomingLink = false
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
        self.restorePreviewPreviousDefaultChannel()
        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.isLeavingPreviewForIncomingLink = false
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
        UserDefaults.standard.removeObject(forKey: self.previewPreviousDefaultChannelDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPreviousDefaultChannelWasSetDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewAppIdDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewPayloadUrlDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewSessionAlertPendingDefaultsKey)
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

    func restorePreviewPreviousDefaultChannel() {
        let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
        let hadPreviousDefaultChannel = UserDefaults.standard.object(forKey: self.previewPreviousDefaultChannelWasSetDefaultsKey) as? Bool ?? false

        guard hadPreviousDefaultChannel,
              let previousDefaultChannel = UserDefaults.standard.string(forKey: self.previewPreviousDefaultChannelDefaultsKey) else {
            UserDefaults.standard.removeObject(forKey: self.defaultChannelDefaultsKey)
            self.implementation.defaultChannel = configDefaultChannel
            logger.info("Restored defaultChannel after preview to config value")
            return
        }

        UserDefaults.standard.set(previousDefaultChannel, forKey: self.defaultChannelDefaultsKey)
        self.implementation.defaultChannel = previousDefaultChannel
        logger.info("Restored defaultChannel after preview")
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

    func normalizedPreviewPayloadUrl(_ rawPayloadUrl: String?) -> URL? {
        guard let rawPayloadUrl else {
            return nil
        }

        let payloadUrl = rawPayloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payloadUrl.isEmpty,
              let url = URL(string: payloadUrl),
              url.scheme == "https" || url.scheme == "http" else {
            return nil
        }

        return url
    }

    func storedPreviewPayloadUrl() -> URL? {
        normalizedPreviewPayloadUrl(UserDefaults.standard.string(forKey: self.previewPayloadUrlDefaultsKey))
    }

    func previewPath(from url: URL) -> String {
        if url.scheme == self.previewDeepLinkScheme {
            var components: [String] = []
            if let host = url.host, !host.isEmpty {
                components.append(host)
            }
            components.append(contentsOf: url.path.split(separator: self.previewPathSeparator).map(String.init))
            return self.normalizedPreviewPath(components)
        }

        return url.path
    }

    func normalizedPreviewPath(_ components: [String]) -> String {
        let separator = String(self.previewPathSeparator)
        return separator + components.filter { !$0.isEmpty }.joined(separator: separator)
    }

    func previewDeepLinkPath(_ leafComponent: String) -> String {
        self.normalizedPreviewPath([self.previewDeepLinkRootComponent, leafComponent])
    }

    func isPreviewDeepLink(_ url: URL) -> Bool {
        let path = self.previewPath(from: url)
        return path == self.previewDeepLinkPath(self.previewDeepLinkChannelComponent) ||
            path == self.previewDeepLinkPath(self.previewDeepLinkBundleComponent)
    }

    @objc func handleOpenURLForPreviewSession(notification: NSNotification) {
        let rawUrl = (notification.object as? [String: Any])?["url"]
        let url = rawUrl as? URL ?? (rawUrl as? NSURL).map { $0 as URL }
        guard self.previewSessionEnabled,
              !self.isLeavingPreviewForIncomingLink,
              let url,
              self.isPreviewDeepLink(url) else {
            return
        }

        self.isLeavingPreviewForIncomingLink = true
        logger.info("Preview deeplink received while preview session is active; restoring fallback before routing")
        DispatchQueue.global(qos: .userInitiated).async {
            let didLeave = self.leavePreviewSessionFromShakeMenu()
            if !didLeave {
                self.logger.error("Could not leave preview session before routing incoming preview deeplink")
                self.isLeavingPreviewForIncomingLink = false
            }
        }
    }

    func fetchPreviewPayload(_ payloadUrl: URL) throws -> PreviewPayload {
        var request = URLRequest(url: payloadUrl)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            responseError = error
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            throw makePreviewError("Preview payload request timed out")
        }

        if let responseError = responseError {
            throw responseError
        }

        let data = responseData ?? Data()
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if let payload = try? JSONDecoder().decode(PreviewPayload.self, from: data) {
                throw makePreviewError(payload.message ?? payload.error ?? "Preview payload request failed with HTTP \(httpResponse.statusCode)")
            }
            let message = String(data: data, encoding: .utf8) ?? "Preview payload request failed with HTTP \(httpResponse.statusCode)"
            throw makePreviewError(message)
        }

        return try JSONDecoder().decode(PreviewPayload.self, from: data)
    }

    func refreshPreviewSessionFromPayloadUrl(_ payloadUrl: URL) -> Bool {
        do {
            let payload = try self.fetchPreviewPayload(payloadUrl)
            guard let version = payload.version, !version.isEmpty else {
                throw makePreviewError("Preview payload is missing a version")
            }
            guard payload.url != nil || payload.manifest?.isEmpty == false else {
                throw makePreviewError("Preview payload is missing download information")
            }

            let current = self.implementation.getCurrentBundle()
            if current.getVersionName() == version {
                self.logger.info("Preview payload unchanged, reloading current bundle")
                return self.reloadCurrentBundle()
            }

            let next = try self.downloadBundle(
                // Fallback URL is only provided when payload.url is missing; when manifest entries exist,
                // downloadBundle routes through downloadManifest and ignores urlString.
                urlString: payload.url ?? "https://404.capgo.app/no.zip",
                version: version,
                sessionKey: payload.sessionKey ?? "",
                checksum: payload.checksum ?? "",
                manifestEntries: payload.manifest
            )

            guard self.implementation.set(id: next.getId()) else {
                throw makePreviewError("Downloaded preview bundle cannot be applied")
            }

            self.notifyBundleSet(next)
            return self.reloadCurrentBundle()
        } catch {
            self.logger.error("Could not refresh preview session: \(error.localizedDescription)")
            return false
        }
    }

    func clearPreviewSessionForNativeBuildChange() {
        guard self.previewSessionEnabled || self.implementation.getPreviewFallbackBundle() != nil else {
            return
        }
        logger.info("Native build changed; clearing preview session state")
        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.isLeavingPreviewForIncomingLink = false
        self.implementation.previewSession = false
        self.shakeMenuEnabled = getConfig().getBoolean("shakeMenu", false)
        self.shakeChannelSelectorEnabled = getConfig().getBoolean("allowShakeChannelSelector", false)
        self.restorePreviewPreviousAppId()
        self.restorePreviewPreviousDefaultChannel()
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        _ = self.implementation.setNextBundle(next: Optional<String>.none)
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
        UserDefaults.standard.set(false, forKey: self.previewSessionAlertPendingDefaultsKey)
        UserDefaults.standard.synchronize()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            guard self.previewSessionEnabled else {
                return
            }
            if let topVC = UIApplication.topViewController(),
               topVC.isKind(of: UIAlertController.self) {
                self.previewSessionAlertPending = true
                UserDefaults.standard.set(true, forKey: self.previewSessionAlertPendingDefaultsKey)
                UserDefaults.standard.synchronize()
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
            } else {
                self.previewSessionAlertPending = true
                UserDefaults.standard.set(true, forKey: self.previewSessionAlertPendingDefaultsKey)
                UserDefaults.standard.synchronize()
            }
        }
    }
}
