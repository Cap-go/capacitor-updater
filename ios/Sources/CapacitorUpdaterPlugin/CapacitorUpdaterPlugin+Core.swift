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
    func syncKeepUrlPathFlag(enabled: Bool) {
        let script: String
        if enabled {
            script = "(function(){ try { localStorage.setItem('\(keepUrlPathFlagKey)', '1'); } catch (err) {} window.__capgoKeepUrlPathAfterReload = true; var evt; try { evt = new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', { detail: { enabled: true } }); } catch (e) { evt = document.createEvent('CustomEvent'); evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', false, false, { enabled: true }); } window.dispatchEvent(evt); })();"
        } else {
            script = "(function(){ try { localStorage.removeItem('\(keepUrlPathFlagKey)'); } catch (err) {} delete window.__capgoKeepUrlPathAfterReload; var evt; try { evt = new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', { detail: { enabled: false } }); } catch (e) { evt = document.createEvent('CustomEvent'); evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', false, false, { enabled: false }); } window.dispatchEvent(evt); })();"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.bridge?.webView else {
                return
            }
            if self.keepUrlPathFlagLastValue != enabled {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                webView.configuration.userContentController.addUserScript(userScript)
                self.keepUrlPathFlagLastValue = enabled
            }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

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

    @objc func appWillTerminate() {
        appHealthTracker?.markForeground(false)
    }

    @objc func appDidReceiveMemoryWarning() {
        appHealthTracker?.reportMemoryWarning()
    }

    @objc func reportWebViewError(_ call: CAPPluginCall) {
        guard let webViewStatsReporter = webViewStatsReporter else {
            call.resolve()
            return
        }
        webViewStatsReporter.reportError(call)
    }

    func initialLoad() -> Bool {
        guard let bridge = self.bridge else { return false }
        if keepUrlPathAfterReload {
            syncKeepUrlPathFlag(enabled: true)
        }

        let id = self.implementation.getCurrentBundleId()
        var dest: URL
        if BundleInfo.idBuiltin == id {
            dest = Bundle.main.resourceURL!.appendingPathComponent("public")
        } else {
            dest = self.implementation.getBundleDirectory(id: id)
        }

        if !FileManager.default.fileExists(atPath: dest.path) {
            logger.error("Initial load fail - file at path \(dest.path) doesn't exist. Defaulting to buildin!! \(id)")
            dest = Bundle.main.resourceURL!.appendingPathComponent("public")
        }

        logger.info("Initial load \(id)")
        // We don't use the viewcontroller here as it does not work during the initial load state
        bridge.setServerBasePath(dest.path)
        return true
    }

    func semaphoreWait(waitTime: Int) {
        // print("\\(CapgoUpdater.TAG) semaphoreWait \\(waitTime)")
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

    func storedNativeBuildVersion() -> String {
        UserDefaults.standard.string(forKey: "LatestNativeBuildVersion") ?? UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0"
    }

    func hasNativeBuildVersionChanged() -> Bool {
        let previous = self.storedNativeBuildVersion()
        return previous != "0" && self.currentBuildVersion != previous
    }

    @discardableResult
    func resetCurrentBundleForNativeBuildChangeIfNeeded() -> Bool {
        let previous = self.storedNativeBuildVersion()
        guard previous != "0" && self.currentBuildVersion != previous else {
            return false
        }

        // Reset startup state synchronously so initialLoad() boots from the builtin bundle.
        self.logger.info("Native build version changed from \(previous) to \(self.currentBuildVersion). Resetting startup bundle to builtin.")
        self.implementation.reset(isInternal: true)
        return true
    }

    func cleanupObsoleteVersions(didResetCurrentBundle: Bool = false) {
        cleanupCondition.lock()
        cleanupComplete = false
        cleanupInProgress = true
        cleanupCondition.unlock()

        cleanupThread = Thread {
            defer {
                self.cleanupCondition.lock()
                self.cleanupComplete = true
                self.cleanupInProgress = false
                self.cleanupCondition.broadcast()
                self.cleanupCondition.unlock()
                self.logger.info("Cleanup complete")
            }

            // Michael (WcaleNieWolny) at 04.01.2026
            // The following line of code contains a bug. After having evaluated it, I have decided not to fix it.
            // The initial report: https://discord.com/channels/912707985829163099/1456985639345061969
            // The bug happens in a very specific scenario. Here is the reproduction steps, followed by the lackof busniess impact
            // Reproduction steps:
            // 1. Install iOS app via app store. Version: 10.13.0. Version v10 of the app uses Capacitor 6 (6.3.13) - a version where the key was still "LatestVersionNative"
            // 2. The plugin writes "10.13.0" to the key "LatestVersionNative"
            // 3. Update the app to version 10.17.0 via Capgo.
            // 4. Update the app via testflight to version 11.0.0. This version uses Capacitor 8 (8.41.3) - a version where the key was changed to "LatestNativeBuildVersion"
            // 5. During the initial load of then new native version, the plugin will read "LatestNativeBuildVersion", not find it, read "LatestVersionNative", find it and revert to builtin version sucessfully.
            // 6. The plugin writes "11.0.0" to the key "LatestNativeBuildVersion"
            // 7. The app is now in a state where it is using the builtin version, but the key "LatestNativeBuildVersion" is still set to "11.0.0" and "LatestVersionNative" is still set to "10.13.0".
            // 8. The user downgrades using app store back to version 10.13.0.
            // 9. The old plugin reads "LatestVersionNative", finds "10.13.0," so it doesn't revert to builtin version. // <--- THIS IS THE FIRST PART OF THE BUG
            // 10. "LatestVersionNative" is written to "10.13.0" but "LatestNativeBuildVersion" is not touched, and stays at "11.0.0"
            // 11. A capgo update happesn to version 10.17.0.
            // 12. The user updates again to version 11.0.0 via Testflight.
            // 13. The plugin reads "LatestNativeBuildVersion", finds "11.0.0", so it doesn't revert to builtin version. It is unaware of the native update that happended.
            // 14. Capgo loads the 10.13.0 version, while it should have loaded the builtin 11.0.0 version. // <--- THIS IS THE SECOND PART OF THE BUG
            // The business impact:
            // None - no one will ever be affected by this bug as reverting via app store should in practice never happen. You are not SUPPOSE to go from Capacitor v8 to v6.
            // Downgrading isn't supported.
            // Possible fixes:
            // 1. Write "LatestVersionNative" - this fixes the part 1 of this bug
            // 2. Compare both keys. If any is not equal to "currentBuildVersion", then revert to builtin version. This fixes the part 2 of this bug

            let previous = self.storedNativeBuildVersion()
            if previous != "0" && self.currentBuildVersion != previous {
                if !didResetCurrentBundle {
                    self.logger.info("Native build version changed from \(previous) to \(self.currentBuildVersion). Resetting current bundle to builtin.")
                    self.implementation.reset(isInternal: true)
                }
                let res = self.implementation.list()
                for version in res {
                    // Check if thread was cancelled
                    if Thread.current.isCancelled {
                        self.logger.warn("Cleanup was cancelled, stopping")
                        return
                    }
                    self.logger.info("Deleting obsolete bundle: \(version.getId())")
                    let res = self.implementation.delete(id: version.getId())
                    if !res {
                        self.logger.error("Delete failed, id \(version.getId()) doesn't exist")
                    }
                }

                let storedBundles = self.implementation.list(raw: true)
                let allowedIds = Set(storedBundles.compactMap { info -> String? in
                    let id = info.getId()
                    return id.isEmpty ? nil : id
                })
                self.implementation.cleanupDownloadDirectories(allowedIds: allowedIds, threadToCheck: Thread.current)
                self.implementation.cleanupOrphanedTempFolders(threadToCheck: Thread.current)

                // Check again before the expensive delta cache cleanup
                if Thread.current.isCancelled {
                    self.logger.warn("Cleanup was cancelled before delta cache cleanup")
                    return
                }
                self.implementation.cleanupDeltaCache(threadToCheck: Thread.current)
            }
            UserDefaults.standard.set(self.currentBuildVersion, forKey: "LatestNativeBuildVersion")
            UserDefaults.standard.synchronize()
        }
        cleanupThread?.start()

        // Start a timeout watchdog thread to cancel cleanup if it takes too long
        let timeout = Double(self.appReadyTimeout / 2) / 1000.0
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: timeout)
            self.cleanupCondition.lock()
            let shouldCancelCleanup = self.cleanupInProgress && !self.cleanupComplete
            self.cleanupCondition.unlock()
            if let thread = self.cleanupThread, !thread.isFinished && shouldCancelCleanup {
                self.logger.warn("Cleanup timeout exceeded (\(timeout)s), cancelling cleanup thread")
                thread.cancel()
            }
        }
    }

    func waitForCleanupIfNeeded() {
        cleanupCondition.lock()
        if !cleanupInProgress || cleanupComplete {
            cleanupCondition.unlock()
            return  // Already done, no need to wait
        }

        logger.info("Waiting for cleanup to complete before starting download...")

        while cleanupInProgress && !cleanupComplete {
            cleanupCondition.wait()
        }
        cleanupCondition.unlock()

        logger.info("Cleanup finished, proceeding with download")
    }

    func resolveCall(_ call: CAPPluginCall, data: PluginCallResultData? = nil) {
        let resolve = {
            let savedCall = self.bridge?.savedCall(withID: call.callbackId)
            let targetCall = savedCall ?? call

            if let data {
                targetCall.resolve(data)
            } else {
                targetCall.resolve()
            }

            if savedCall != nil {
                self.bridge?.releaseCall(withID: call.callbackId)
            }
        }

        if Thread.isMainThread {
            resolve()
        } else {
            DispatchQueue.main.async {
                resolve()
            }
        }
    }

    func rejectCall(_ call: CAPPluginCall, message: String, code: String? = nil, error: Error? = nil, data: PluginCallResultData? = nil) {
        let reject = {
            let savedCall = self.bridge?.savedCall(withID: call.callbackId)
            let targetCall = savedCall ?? call

            targetCall.reject(message, code, error, data)

            if savedCall != nil {
                self.bridge?.releaseCall(withID: call.callbackId)
            }
        }

        if Thread.isMainThread {
            reject()
        } else {
            DispatchQueue.main.async {
                reject()
            }
        }
    }

    func saveCallForAsyncHandling(_ call: CAPPluginCall) {
        bridge?.saveCall(call)
    }

    func notifyListenersOnMain(_ eventName: String, data: JSObject) {
        let notify = {
            self.notifyListeners(eventName, data: data)
        }

        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async {
                notify()
            }
        }
    }

    func bundlePayload(_ bundleInfo: BundleInfo) -> JSObject {
        var payload: JSObject = [:]
        for (key, value) in bundleInfo.toJSON() {
            payload[key] = value
        }
        return payload
    }

    @objc func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false, bundle: BundleInfo? = nil) {
        let bundleInfo = bundle ?? self.implementation.getBundleInfo(id: id)
        var downloadPayload: JSObject = [:]
        downloadPayload["percent"] = percent
        downloadPayload["bundle"] = bundlePayload(bundleInfo)
        self.notifyListenersOnMain("download", data: downloadPayload)
        if percent == 100 {
            var downloadCompletePayload: JSObject = [:]
            downloadCompletePayload["bundle"] = bundlePayload(bundleInfo)
            self.notifyListenersOnMain("downloadComplete", data: downloadCompletePayload)
            self.implementation.sendStats(action: "download_complete", versionName: bundleInfo.getVersionName())
        } else if percent.isMultiple(of: 10) || ignoreMultipleOfTen {
            self.implementation.sendStats(action: "download_\(percent)", versionName: bundleInfo.getVersionName())
        }
    }
}
