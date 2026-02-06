/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

// MARK: - Bundle Management Methods
extension CapacitorUpdaterPlugin {
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
        DispatchQueue.global(qos: .background).async {
            do {
                let next: BundleInfo
                if let manifestArray = manifestArray {
                    // Convert JSArray to [ManifestEntry]
                    var manifestEntries: [ManifestEntry] = []
                    for item in manifestArray {
                        if let manifestDict = item as? [String: Any] {
                            let entry = ManifestEntry(
                                file_name: manifestDict["file_name"] as? String,
                                file_hash: manifestDict["file_hash"] as? String,
                                download_url: manifestDict["download_url"] as? String
                            )
                            manifestEntries.append(entry)
                        }
                    }
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
                self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
                call.resolve(next.toJSON())
            } catch {
                self.logger.error("Failed to download from: \(String(describing: url)) \(error.localizedDescription)")
                self.notifyListeners("downloadFailed", data: ["version": version])
                self.implementation.sendStats(action: "download_fail")
                call.reject("Failed to download from: \(url!) - \(error.localizedDescription)")
            }
        }
    }

    // Backward-compatible alias used by ShakeMenu and older internal call sites.
    func _reload() -> Bool {
        return performReload()
    }

    public func performReload() -> Bool {
        guard let bridge = self.bridge else { return false }
        self.semaphoreUp()
        let id = self.implementation.getCurrentBundleId()
        let dest: URL
        if BundleInfo.ID_BUILTIN == id {
            dest = Bundle.main.resourceURL!.appendingPathComponent("public")
        } else {
            dest = self.implementation.getBundleDirectory(id: id)
        }
        logger.info("Reloading \(id)")

        let performReload: () -> Bool = {
            guard let viewController = bridge.viewController as? CAPBridgeViewController else {
                self.logger.error("Cannot get viewController")
                return false
            }
            guard let capBridge = viewController.bridge else {
                self.logger.error("Cannot get capBridge")
                return false
            }
            if self.keepUrlPathAfterReload {
                if let currentURL = viewController.webView?.url {
                    capBridge.setServerBasePath(dest.path)
                    var urlComponents = URLComponents(url: capBridge.config.serverURL, resolvingAgainstBaseURL: false)!
                    urlComponents.path = currentURL.path
                    urlComponents.query = currentURL.query
                    urlComponents.fragment = currentURL.fragment
                    if let finalUrl = urlComponents.url {
                        _ = viewController.webView?.load(URLRequest(url: finalUrl))
                    } else {
                        self.logger.error("Unable to build final URL when keeping path after reload; falling back to base path")
                        viewController.setServerBasePath(path: dest.path)
                    }
                } else {
                    self.logger.error("vc.webView?.url is null? Falling back to base path reload.")
                    viewController.setServerBasePath(path: dest.path)
                }
            } else {
                viewController.setServerBasePath(path: dest.path)
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
        if self.performReload() {
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
        } else {
            self.reload(call)
        }
    }

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
        if self.checkAutoUpdateEnabled() {
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

    @objc func current(_ call: CAPPluginCall) {
        let bundle: BundleInfo = self.implementation.getCurrentBundle()
        call.resolve([
            "bundle": bundle.toJSON(),
            "native": self.currentVersionNative.description
        ])
    }

    @objc func getNextBundle(_ call: CAPPluginCall) {
        let bundle = self.implementation.getNextBundle()
        if bundle == nil || bundle?.isUnknown() == true {
            call.resolve()
            return
        }

        call.resolve(bundle!.toJSON())
    }

    @objc func getFailedUpdate(_ call: CAPPluginCall) {
        let bundle = self.readLastFailedBundle()
        if bundle == nil || bundle?.isUnknown() == true {
            call.resolve()
            return
        }

        self.persistLastFailedBundle(nil)
        call.resolve([
            "bundle": bundle!.toJSON()
        ])
    }

    @objc func performReset(toLastSuccessful: Bool) -> Bool {
        guard let bridge = self.bridge else { return false }

        if (bridge.viewController as? CAPBridgeViewController) != nil {
            let fallback: BundleInfo = self.implementation.getFallbackBundle()

            // If developer wants to reset to the last successful bundle, and that bundle is not
            // the built-in bundle, set it as the bundle to use and reload.
            if toLastSuccessful && !fallback.isBuiltin() {
                logger.info("Resetting to: \(fallback.toString())")
                return self.implementation.set(bundle: fallback) && self.performReload()
            }

            logger.info("Resetting to builtin version")

            // Otherwise, reset back to the built-in bundle and reload.
            self.implementation.reset()
            return self.performReload()
        }

        return false
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toLastSuccessful = call.getBool("toLastSuccessful") ?? false
        if self.performReset(toLastSuccessful: toLastSuccessful) {
            call.resolve()
        } else {
            logger.error("Reset failed")
            call.reject("Reset failed")
        }
    }
}
