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

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin, CAPBridgedPlugin {
    let logger = Logger(withTag: "✨  CapgoUpdater")

    public let identifier = "CapacitorUpdaterPlugin"
    public let jsName = "CapacitorUpdater"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "download", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setUpdateUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setStatsUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setChannelUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "set", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "list", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "delete", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBundleError", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reset", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "current", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notifyAppReady", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDelay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMultiDelay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelDelay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLatest", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setChannel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unsetChannel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getChannel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listChannels", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setCustomId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDeviceId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "next", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAutoUpdateEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBuiltinVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAutoUpdateAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getNextBundle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFailedUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setShakeMenu", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isShakeMenuEnabled", returnType: CAPPluginReturnPromise),
        // App Store update methods
        CAPPluginMethod(name: "getAppUpdateInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openAppStore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "performImmediateUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startFlexibleUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "completeFlexibleUpdate", returnType: CAPPluginReturnPromise)
    ]
    public var implementation = CapgoUpdater()
    private let pluginVersion: String = "8.4.2"
    static let updateUrlDefault = "https://plugin.capgo.app/updates"
    static let statsUrlDefault = "https://plugin.capgo.app/stats"
    static let channelUrlDefault = "https://plugin.capgo.app/channel_self"
    private let keepUrlPathFlagKey = "__capgo_keep_url_path_after_reload"
    private let customIdDefaultsKey = "CapacitorUpdater.customId"
    private let updateUrlDefaultsKey = "CapacitorUpdater.updateUrl"
    private let statsUrlDefaultsKey = "CapacitorUpdater.statsUrl"
    private let channelUrlDefaultsKey = "CapacitorUpdater.channelUrl"
    private let defaultChannelDefaultsKey = "CapacitorUpdater.defaultChannel"
    private let lastFailedBundleDefaultsKey = "CapacitorUpdater.lastFailedBundle"
    // Note: DELAY_CONDITION_PREFERENCES is now defined in DelayUpdateUtils.DELAY_CONDITION_PREFERENCES
    private var updateUrl = ""
    private var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var currentVersionNative: Version = "0.0.0"
    private var currentBuildVersion: String = "0"
    private var autoUpdate = false
    private var appReadyTimeout = 10000
    private var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    private var directUpdate = false
    private var directUpdateMode: String = "false"
    private var wasRecentlyInstalledOrUpdated = false
    private var onLaunchDirectUpdateUsed = false
    private var autoSplashscreen = false
    private var autoSplashscreenLoader = false
    private var autoSplashscreenTimeout = 10000
    private var autoSplashscreenTimeoutWorkItem: DispatchWorkItem?
    private var splashscreenLoaderView: UIActivityIndicatorView?
    private var splashscreenLoaderContainer: UIView?
    private var autoSplashscreenTimedOut = false
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    private var allowSetDefaultChannel = true
    private var keepUrlPathAfterReload = false
    private var backgroundWork: DispatchWorkItem?
    private var taskRunning = false
    private var periodCheckDelay = 0

    // Lock to ensure cleanup completes before downloads start
    private let cleanupLock = NSLock()
    private var cleanupComplete = false
    private var cleanupThread: Thread?
    private var persistCustomId = false
    private var persistModifyUrl = false
    private var allowManualBundleError = false
    private var keepUrlPathFlagLastValue: Bool?
    public var shakeMenuEnabled = false
    let semaphoreReady = DispatchSemaphore(value: 0)

    private var delayUpdateUtils: DelayUpdateUtils!

    override public func load() {
        let disableJSLogging = getConfig().getBoolean("disableJSLogging", false)
        // Set webView for logging to JavaScript console
        if let webView = self.bridge?.webView, !disableJSLogging {
            logger.setWebView(webView: webView)
            logger.info("WebView set successfully for logging")
        } else {
            logger.error("Failed to get webView for logging")
        }
        #if targetEnvironment(simulator)
        logger.info("::::: SIMULATOR :::::")
        logger.info("Application directory: \(NSHomeDirectory())")
        #endif

        self.semaphoreUp()
        // Use DeviceIdHelper to get or create device ID that persists across reinstalls
        self.implementation.deviceID = DeviceIdHelper.getOrCreateDeviceId()
        persistCustomId = getConfig().getBoolean("persistCustomId", false)
        allowSetDefaultChannel = getConfig().getBoolean("allowSetDefaultChannel", true)
        if persistCustomId {
            let storedCustomId = UserDefaults.standard.string(forKey: customIdDefaultsKey) ?? ""
            if !storedCustomId.isEmpty {
                implementation.customId = storedCustomId
                logger.info("Loaded persisted customId")
            }
        }
        persistModifyUrl = getConfig().getBoolean("persistModifyUrl", false)
        allowManualBundleError = getConfig().getBoolean("allowManualBundleError", false)
        logger.info("init for device \(self.implementation.deviceID)")
        guard let versionName = getConfig().getString("version", Bundle.main.versionName) else {
            logger.error("Cannot get version name")
            // crash the app on purpose
            fatalError("Cannot get version name")
        }
        do {
            currentVersionNative = try Version(versionName)
        } catch {
            logger.error("Cannot parse versionName \(versionName)")
        }
        currentBuildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        logger.info("version native \(self.currentVersionNative.description)")
        implementation.versionBuild = getConfig().getString("version", Bundle.main.versionName)!
        autoDeleteFailed = getConfig().getBoolean("autoDeleteFailed", true)
        autoDeletePrevious = getConfig().getBoolean("autoDeletePrevious", true)
        keepUrlPathAfterReload = getConfig().getBoolean("keepUrlPathAfterReload", false)
        syncKeepUrlPathFlag(enabled: keepUrlPathAfterReload)

        // Handle directUpdate configuration - support string values and backward compatibility
        if let directUpdateString = getConfig().getString("directUpdate") {
            // Handle backward compatibility for boolean true
            if directUpdateString == "true" {
                directUpdateMode = "always"
                directUpdate = true
            } else {
                directUpdateMode = directUpdateString
                directUpdate = directUpdateString == "always" || directUpdateString == "atInstall" || directUpdateString == "onLaunch"
                // Validate directUpdate value
                if directUpdateString != "false" && directUpdateString != "always" && directUpdateString != "atInstall" && directUpdateString != "onLaunch" {
                    logger.error("Invalid directUpdate value: \"\(directUpdateString)\". Supported values are: \"false\", \"true\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\".")
                    directUpdateMode = "false"
                    directUpdate = false
                }
            }
        } else {
            let directUpdateBool = getConfig().getBoolean("directUpdate", false)
            if directUpdateBool {
                directUpdateMode = "always" // backward compatibility: true = always
                directUpdate = true
            } else {
                directUpdateMode = "false"
                directUpdate = false
            }
        }

        autoSplashscreen = getConfig().getBoolean("autoSplashscreen", false)
        autoSplashscreenLoader = getConfig().getBoolean("autoSplashscreenLoader", false)
        let splashscreenTimeoutValue = getConfig().getInt("autoSplashscreenTimeout", 10000)
        autoSplashscreenTimeout = max(0, splashscreenTimeoutValue)
        updateUrl = getConfig().getString("updateUrl", CapacitorUpdaterPlugin.updateUrlDefault)!
        if persistModifyUrl, let storedUpdateUrl = UserDefaults.standard.object(forKey: updateUrlDefaultsKey) as? String {
            updateUrl = storedUpdateUrl
            logger.info("Loaded persisted updateUrl")
        }
        autoUpdate = getConfig().getBoolean("autoUpdate", true)
        appReadyTimeout = max(1000, getConfig().getInt("appReadyTimeout", 10000))  // Minimum 1 second
        implementation.timeout = Double(getConfig().getInt("responseTimeout", 20))
        resetWhenUpdate = getConfig().getBoolean("resetWhenUpdate", true)
        shakeMenuEnabled = getConfig().getBoolean("shakeMenu", false)
        let periodCheckDelayValue = getConfig().getInt("periodCheckDelay", 0)
        if periodCheckDelayValue >= 0 && periodCheckDelayValue > 600 {
            periodCheckDelay = 600
        } else {
            periodCheckDelay = periodCheckDelayValue
        }

        implementation.setPublicKey(getConfig().getString("publicKey") ?? "")
        implementation.notifyDownloadRaw = notifyDownload
        implementation.pluginVersion = self.pluginVersion

        // Set logger for shared classes
        implementation.setLogger(logger)
        CryptoCipher.setLogger(logger)

        // Log public key prefix if encryption is enabled
        if let keyId = implementation.getKeyId(), !keyId.isEmpty {
            logger.info("Public key prefix: \(keyId)")
        }

        // Initialize DelayUpdateUtils
        self.delayUpdateUtils = DelayUpdateUtils(currentVersionNative: currentVersionNative, logger: logger)
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        implementation.appId = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        implementation.appId = config?["appId"] as? String ?? implementation.appId
        implementation.appId = getConfig().getString("appId", implementation.appId)!
        if implementation.appId == "" {
            // crash the app on purpose it should not happen
            fatalError("appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config")
        }
        logger.info("appId \(implementation.appId)")
        implementation.statsUrl = getConfig().getString("statsUrl", CapacitorUpdaterPlugin.statsUrlDefault)!
        implementation.channelUrl = getConfig().getString("channelUrl", CapacitorUpdaterPlugin.channelUrlDefault)!
        if persistModifyUrl {
            if let storedStatsUrl = UserDefaults.standard.object(forKey: statsUrlDefaultsKey) as? String {
                implementation.statsUrl = storedStatsUrl
                logger.info("Loaded persisted statsUrl")
            }
            if let storedChannelUrl = UserDefaults.standard.object(forKey: channelUrlDefaultsKey) as? String {
                implementation.channelUrl = storedChannelUrl
                logger.info("Loaded persisted channelUrl")
            }
        }

        // Load defaultChannel: first try from persistent storage (set via setChannel), then fall back to config
        if let storedDefaultChannel = UserDefaults.standard.object(forKey: defaultChannelDefaultsKey) as? String {
            implementation.defaultChannel = storedDefaultChannel
            logger.info("Loaded persisted defaultChannel from setChannel()")
        } else {
            implementation.defaultChannel = getConfig().getString("defaultChannel", "")!
        }
        self.implementation.autoReset()

        // Check if app was recently installed/updated BEFORE cleanupObsoleteVersions updates LatestVersionNative
        self.wasRecentlyInstalledOrUpdated = self.checkIfRecentlyInstalledOrUpdated()

        if resetWhenUpdate {
            self.cleanupObsoleteVersions()
        }

        // Load the server
        // This is very much swift specific, android does not do that
        // In android we depend on the serverBasePath capacitor property
        // In IOS we do not. Instead during the plugin initialization we try to call setServerBasePath
        // The idea is to prevent having to store the bundle in 2 locations for hot reload and persistent storage
        // According to martin it is not possible to use serverBasePath on ios in a way that allows us to store the bundle once

        if !self.initialLoad() {
            logger.error("unable to force reload, the plugin might fallback to the builtin version")
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        // Check for 'kill' delay condition on app launch
        // This handles cases where the app was killed (willTerminateNotification is not reliable for system kills)
        self.delayUpdateUtils.checkCancelDelay(source: .killed)

        self.appMovedToForeground()
        self.checkForUpdateAfterDelay()
    }

    private func syncKeepUrlPathFlag(enabled: Bool) {
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

    private func persistLastFailedBundle(_ bundle: BundleInfo?) {
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

    private func readLastFailedBundle() -> BundleInfo? {
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

    private func initialLoad() -> Bool {
        guard let bridge = self.bridge else { return false }
        if keepUrlPathAfterReload {
            syncKeepUrlPathFlag(enabled: true)
        }

        let id = self.implementation.getCurrentBundleId()
        var dest: URL
        if BundleInfo.ID_BUILTIN == id {
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

    private func semaphoreWait(waitTime: Int) {
        // print("\\(CapgoUpdater.TAG) semaphoreWait \\(waitTime)")
        let result = semaphoreReady.wait(timeout: .now() + .milliseconds(waitTime))
        if result == .timedOut {
            logger.error("Semaphore wait timed out after \(waitTime)ms")
        }
    }

    private func semaphoreUp() {
        DispatchQueue.global().async {
            self.semaphoreWait(waitTime: 0)
        }
    }

    private func semaphoreDown() {
        semaphoreReady.signal()
    }

    private func cleanupObsoleteVersions() {
        cleanupThread = Thread {
            self.cleanupLock.lock()
            defer {
                self.cleanupComplete = true
                self.cleanupLock.unlock()
                self.logger.info("Cleanup complete")
            }

            let previous = UserDefaults.standard.string(forKey: "LatestNativeBuildVersion") ?? UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0"
            if previous != "0" && self.currentBuildVersion != previous {
                _ = self._reset(toLastSuccessful: false)
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
            if let thread = self.cleanupThread, !thread.isFinished && !self.cleanupComplete {
                self.logger.warn("Cleanup timeout exceeded (\(timeout)s), cancelling cleanup thread")
                thread.cancel()
            }
        }
    }

    private func waitForCleanupIfNeeded() {
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

    public func _reload() -> Bool {
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
        if self._reload() {
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
        if self._isAutoUpdateEnabled() {
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
        for v in res {
            resArr.append(v.toJSON())
        }
        call.resolve([
            "bundles": resArr
        ])
    }

    @objc func getLatest(_ call: CAPPluginCall) {
        let channel = call.getString("channel")
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.getLatest(url: URL(string: self.updateUrl)!, channel: channel)
            if res.error != nil {
                call.reject( res.error!)
            } else if res.message != nil {
                call.reject( res.message!)
            } else {
                call.resolve(res.toDict())
            }
        }
    }

    @objc func unsetChannel(_ call: CAPPluginCall) {
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate", false)
        DispatchQueue.global(qos: .background).async {
            let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
            let res = self.implementation.unsetChannel(defaultChannelKey: self.defaultChannelDefaultsKey, configDefaultChannel: configDefaultChannel)
            if res.error != "" {
                call.reject(res.error, "UNSETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    self.backgroundDownload()
                }
                call.resolve(res.toDict())
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
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.setChannel(channel: channel, defaultChannelKey: self.defaultChannelDefaultsKey, allowSetDefaultChannel: self.allowSetDefaultChannel)
            if res.error != "" {
                // Fire channelPrivate event if channel doesn't allow self-assignment
                if res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed") {
                    self.notifyListeners("channelPrivate", data: [
                        "channel": channel,
                        "message": res.error
                    ])
                }
                call.reject(res.error, "SETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : (res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed")) ? "channel_private" : "request_failed"
                ])
            } else {
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    self.backgroundDownload()
                }
                call.resolve(res.toDict())
            }
        }
    }

    @objc func getChannel(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.getChannel()
            if res.error != "" {
                call.reject(res.error, "GETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                call.resolve(res.toDict())
            }
        }
    }

    @objc func listChannels(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.listChannels()
            if res.error != "" {
                call.reject(res.error, "LISTCHANNELS_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                call.resolve(res.toDict())
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

    @objc func _reset(toLastSuccessful: Bool) -> Bool {
        guard let bridge = self.bridge else { return false }

        if (bridge.viewController as? CAPBridgeViewController) != nil {
            let fallback: BundleInfo = self.implementation.getFallbackBundle()

            // If developer wants to reset to the last successful bundle, and that bundle is not
            // the built-in bundle, set it as the bundle to use and reload.
            if toLastSuccessful && !fallback.isBuiltin() {
                logger.info("Resetting to: \(fallback.toString())")
                return self.implementation.set(bundle: fallback) && self._reload()
            }

            logger.info("Resetting to builtin version")

            // Otherwise, reset back to the built-in bundle and reload.
            self.implementation.reset()
            return self._reload()
        }

        return false
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toLastSuccessful = call.getBool("toLastSuccessful") ?? false
        if self._reset(toLastSuccessful: toLastSuccessful) {
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
            for i in 0..<modifiableList.count {
                if let kind = modifiableList[i]["kind"] as? String,
                   kind == "background",
                   let value = modifiableList[i]["value"] as? String,
                   value.isEmpty {
                    modifiableList[i]["value"] = "0"
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

    private func _isAutoUpdateEnabled() -> Bool {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        if instanceDescriptor?.serverURL != nil {
            logger.warn("AutoUpdate is automatic disabled when serverUrl is set.")
        }
        return self.autoUpdate && self.updateUrl != "" && instanceDescriptor?.serverURL == nil
    }

    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self._isAutoUpdateEnabled()
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
            self.DeferredNotifyAppReadyCheck()
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
            _ = self._reset(toLastSuccessful: true)
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

    func DeferredNotifyAppReadyCheck() {
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
            if self.autoSplashscreen {
                self.hideSplashscreen()
            }
        }
    }

    private func hideSplashscreen() {
        if Thread.isMainThread {
            self.performHideSplashscreen()
        } else {
            DispatchQueue.main.async {
                self.performHideSplashscreen()
            }
        }
    }

    private func performHideSplashscreen() {
        self.cancelSplashscreenTimeout()
        self.removeSplashscreenLoader()

        guard let bridge = self.bridge else {
            self.logger.warn("Bridge not available for hiding splashscreen with autoSplashscreen")
            return
        }

        // Create a plugin call for the hide method
        let call = CAPPluginCall(callbackId: "autoHideSplashscreen", options: [:], success: { (_, _) in
            self.logger.info("Splashscreen hidden automatically")
        }, error: { (_) in
            self.logger.error("Failed to auto-hide splashscreen")
        })

        // Try to call the SplashScreen hide method directly through the bridge
        if let splashScreenPlugin = bridge.plugin(withName: "SplashScreen") {
            // Use runtime method invocation to call hide method
            let selector = NSSelectorFromString("hide:")
            if splashScreenPlugin.responds(to: selector) {
                _ = splashScreenPlugin.perform(selector, with: call)
                self.logger.info("Called SplashScreen hide method")
            } else {
                self.logger.warn("autoSplashscreen: SplashScreen plugin does not respond to hide: method. Make sure @capacitor/splash-screen plugin is properly installed.")
            }
        } else {
            self.logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.")
        }
    }

    private func showSplashscreen() {
        if Thread.isMainThread {
            self.performShowSplashscreen()
        } else {
            DispatchQueue.main.async {
                self.performShowSplashscreen()
            }
        }
    }

    private func performShowSplashscreen() {
        self.cancelSplashscreenTimeout()
        self.autoSplashscreenTimedOut = false

        guard let bridge = self.bridge else {
            self.logger.warn("Bridge not available for showing splashscreen with autoSplashscreen")
            return
        }

        // Create a plugin call for the show method
        let call = CAPPluginCall(callbackId: "autoShowSplashscreen", options: [:], success: { (_, _) in
            self.logger.info("Splashscreen shown automatically")
        }, error: { (_) in
            self.logger.error("Failed to auto-show splashscreen")
        })

        // Try to call the SplashScreen show method directly through the bridge
        if let splashScreenPlugin = bridge.plugin(withName: "SplashScreen") {
            // Use runtime method invocation to call show method
            let selector = NSSelectorFromString("show:")
            if splashScreenPlugin.responds(to: selector) {
                _ = splashScreenPlugin.perform(selector, with: call)
                self.logger.info("Called SplashScreen show method")
            } else {
                self.logger.warn("autoSplashscreen: SplashScreen plugin does not respond to show: method. Make sure @capacitor/splash-screen plugin is properly installed.")
            }
        } else {
            self.logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.")
        }

        self.addSplashscreenLoaderIfNeeded()
        self.scheduleSplashscreenTimeout()
    }

    private func addSplashscreenLoaderIfNeeded() {
        guard self.autoSplashscreenLoader else {
            return
        }

        let addLoader = {
            guard self.splashscreenLoaderContainer == nil else {
                return
            }
            guard let rootView = self.bridge?.viewController?.view else {
                self.logger.warn("autoSplashscreen: Unable to access root view for loader overlay")
                return
            }

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = UIColor.clear
            container.isUserInteractionEnabled = false

            let indicatorStyle: UIActivityIndicatorView.Style
            if #available(iOS 13.0, *) {
                indicatorStyle = .large
            } else {
                indicatorStyle = .whiteLarge
            }

            let indicator = UIActivityIndicatorView(style: indicatorStyle)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.hidesWhenStopped = false
            if #available(iOS 13.0, *) {
                indicator.color = UIColor.label
            }
            indicator.startAnimating()

            container.addSubview(indicator)
            rootView.addSubview(container)

            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                container.topAnchor.constraint(equalTo: rootView.topAnchor),
                container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])

            self.splashscreenLoaderContainer = container
            self.splashscreenLoaderView = indicator
        }

        if Thread.isMainThread {
            addLoader()
        } else {
            DispatchQueue.main.async {
                addLoader()
            }
        }
    }

    private func removeSplashscreenLoader() {
        let removeLoader = {
            self.splashscreenLoaderView?.stopAnimating()
            self.splashscreenLoaderContainer?.removeFromSuperview()
            self.splashscreenLoaderView = nil
            self.splashscreenLoaderContainer = nil
        }

        if Thread.isMainThread {
            removeLoader()
        } else {
            DispatchQueue.main.async {
                removeLoader()
            }
        }
    }

    private func scheduleSplashscreenTimeout() {
        guard self.autoSplashscreenTimeout > 0 else {
            return
        }

        let scheduleTimeout = {
            self.autoSplashscreenTimeoutWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.autoSplashscreenTimedOut = true
                self.logger.info("autoSplashscreen timeout reached, hiding splashscreen")
                self.hideSplashscreen()
            }
            self.autoSplashscreenTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.autoSplashscreenTimeout), execute: workItem)
        }

        if Thread.isMainThread {
            scheduleTimeout()
        } else {
            DispatchQueue.main.async {
                scheduleTimeout()
            }
        }
    }

    private func cancelSplashscreenTimeout() {
        let cancelTimeout = {
            self.autoSplashscreenTimeoutWorkItem?.cancel()
            self.autoSplashscreenTimeoutWorkItem = nil
        }

        if Thread.isMainThread {
            cancelTimeout()
        } else {
            DispatchQueue.main.async {
                cancelTimeout()
            }
        }
    }

    private func checkIfRecentlyInstalledOrUpdated() -> Bool {
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

    private func shouldUseDirectUpdate() -> Bool {
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
            if !self.onLaunchDirectUpdateUsed {
                return true
            }
            return false
        default:
            logger.error("Invalid directUpdateMode: \"\(self.directUpdateMode)\". Supported values are: \"false\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\" behavior.")
            return false
        }
    }

    private func notifyBreakingEvents(version: String) {
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
        let plannedDirectUpdate = self.shouldUseDirectUpdate()
        let messageUpdate = plannedDirectUpdate ? "Update will occur now." : "Update will occur next time app moves to background."
        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            return
        }
        DispatchQueue.global(qos: .background).async {
            // Wait for cleanup to complete before starting download
            self.waitForCleanupIfNeeded()
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Download Tasks") {
                // End the task if time expires.
                self.endBackGroundTask()
            }
            self.logger.info("Check for update via \(self.updateUrl)")
            let res = self.implementation.getLatest(url: url, channel: nil)
            let current = self.implementation.getCurrentBundle()

            // Handle network errors and other failures first
            if let backendError = res.error, !backendError.isEmpty {
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
                return
            }
            if res.version == "builtin" {
                self.logger.info("Latest version is builtin")
                let directUpdateAllowed = plannedDirectUpdate && !self.autoSplashscreenTimedOut
                if directUpdateAllowed {
                    self.logger.info("Direct update to builtin version")
                    if self.directUpdateMode == "onLaunch" {
                        self.onLaunchDirectUpdateUsed = true
                        self.directUpdate = false
                    }
                    _ = self._reset(toLastSuccessful: false)
                    self.endBackGroundTaskWithNotif(msg: "Updated to builtin version", latestVersionName: res.version, current: self.implementation.getCurrentBundle(), error: false)
                } else {
                    if plannedDirectUpdate && !directUpdateAllowed {
                        self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will apply later.")
                    }
                    self.logger.info("Setting next bundle to builtin")
                    _ = self.implementation.setNextBundle(next: BundleInfo.ID_BUILTIN)
                    self.endBackGroundTaskWithNotif(msg: "Next update will be to builtin version", latestVersionName: res.version, current: current, error: false)
                }
                return
            }
            let sessionKey = res.sessionKey ?? ""
            guard let downloadUrl = URL(string: res.url) else {
                self.logger.error("Error no url or wrong format")
                self.endBackGroundTaskWithNotif(msg: "Error no url or wrong format", latestVersionName: res.version, current: current)
                return
            }
            let latestVersionName = res.version
            if latestVersionName != "" && current.getVersionName() != latestVersionName {
                do {
                    self.logger.info("New bundle: \(latestVersionName) found. Current is: \(current.getVersionName()). \(messageUpdate)")
                    var nextImpl = self.implementation.getBundleInfoByVersionName(version: latestVersionName)
                    if nextImpl == nil || nextImpl?.isDeleted() == true {
                        if nextImpl?.isDeleted() == true {
                            self.logger.info("Latest bundle already exists and will be deleted, download will overwrite it.")
                            let res = self.implementation.delete(id: nextImpl!.getId(), removeInfo: true)
                            if res {
                                self.logger.info("Failed bundle deleted: \(nextImpl!.toString())")
                            } else {
                                self.logger.error("Failed to delete failed bundle: \(nextImpl!.toString())")
                            }
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
                        return
                    }
                    if next.isErrorStatus() {
                        self.logger.error("Latest bundle already exists and is in error state. Aborting update.")
                        self.endBackGroundTaskWithNotif(msg: "Latest version is in error state. Aborting update.", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    res.checksum = try CryptoCipher.decryptChecksum(checksum: res.checksum, publicKey: self.implementation.publicKey)
                    CryptoCipher.logChecksumInfo(label: "Bundle checksum", hexChecksum: next.getChecksum())
                    CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: res.checksum)
                    if res.checksum != "" && next.getChecksum() != res.checksum && res.manifest == nil {
                        self.logger.error("Error checksum \(next.getChecksum()) \(res.checksum)")
                        self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
                        let id = next.getId()
                        let resDel = self.implementation.delete(id: id)
                        if !resDel {
                            self.logger.error("Delete failed, id \(id) doesn't exist")
                        }
                        self.endBackGroundTaskWithNotif(msg: "Error checksum", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    let directUpdateAllowed = plannedDirectUpdate && !self.autoSplashscreenTimedOut
                    if directUpdateAllowed {
                        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
                        let delayConditionList: [DelayCondition] = self.fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
                            let kind: String = obj.value(forKey: "kind") as! String
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
                        _ = self._reload()
                        self.endBackGroundTaskWithNotif(msg: "update installed", latestVersionName: latestVersionName, current: next, error: false)
                    } else {
                        if plannedDirectUpdate && !directUpdateAllowed {
                            self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will install on next app background.")
                        }
                        self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
                        _ = self.implementation.setNextBundle(next: next.getId())
                        self.endBackGroundTaskWithNotif(msg: "update downloaded, will install next background", latestVersionName: latestVersionName, current: current, error: false)
                    }
                    return
                } catch {
                    self.logger.error("Error downloading file \(error.localizedDescription)")
                    let current: BundleInfo = self.implementation.getCurrentBundle()
                    self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
                    return
                }
            } else {
                self.logger.info("No need to update, \(current.getId()) is the latest bundle.")
                self.endBackGroundTaskWithNotif(msg: "No need to update, \(current.getId()) is the latest bundle.", latestVersionName: latestVersionName, current: current, error: false)
                return
            }
        }
    }

    private func installNext() {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
            let kind: String = obj.value(forKey: "kind") as! String
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
            if self.implementation.set(bundle: next!) && self._reload() {
                logger.info("Updated to bundle: \(next!.toString())")
                _ = self.implementation.setNextBundle(next: Optional<String>.none)
            } else {
                logger.error("Update to bundle: \(next!.toString()) Failed!")
            }
        }
    }

    @objc private func toJson(object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return ""
        }
        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }

    @objc private func fromJsonArr(json: String) -> [NSObject] {
        guard let jsonData = json.data(using: .utf8) else {
            return []
        }
        let object = try? JSONSerialization.jsonObject(
            with: jsonData,
            options: .mutableContainers
        ) as? [NSObject]
        return object ?? []
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
        if self._isAutoUpdateEnabled() {
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

    private var periodicUpdateTimer: Timer?

    @objc func checkForUpdateAfterDelay() {
        if periodCheckDelay == 0 || !self._isAutoUpdateEnabled() {
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
        if self.autoSplashscreen {
            var canShowSplashscreen = true

            if !self._isAutoUpdateEnabled() {
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
                self.showSplashscreen()
            }
        }

        // Set background timestamp
        let backgroundTimestamp = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
        self.delayUpdateUtils.setBackgroundTimestamp(backgroundTimestamp)
        self.delayUpdateUtils.checkCancelDelay(source: .background)
        self.installNext()
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

    @objc func setShakeMenu(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            logger.error("setShakeMenu called without enabled parameter")
            call.reject("setShakeMenu called without enabled parameter")
            return
        }

        self.shakeMenuEnabled = enabled
        logger.info("Shake menu \(enabled ? "enabled" : "disabled")")
        call.resolve()
    }

    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeMenuEnabled
        ])
    }

    @objc func getAppId(_ call: CAPPluginCall) {
        call.resolve([
            "appId": implementation.appId
        ])
    }

    @objc func setAppId(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyAppId", false) {
            logger.error("setAppId called without allowModifyAppId")
            call.reject("setAppId called without allowModifyAppId set allowModifyAppId in your config to true to allow it")
            return
        }
        guard let appId = call.getString("appId") else {
            logger.error("setAppId called without appId")
            call.reject("setAppId called without appId")
            return
        }
        implementation.appId = appId
        call.resolve()
    }

    // MARK: - App Store Update Methods

    /// AppUpdateAvailability enum values matching TypeScript definitions
    private enum AppUpdateAvailability: Int {
        case unknown = 0
        case updateNotAvailable = 1
        case updateAvailable = 2
        case updateInProgress = 3
    }

    @objc func getAppUpdateInfo(_ call: CAPPluginCall) {
        let country = call.getString("country", "US")
        let bundleId = implementation.appId

        logger.info("Getting App Store update info for \(bundleId) in country \(country)")

        DispatchQueue.global(qos: .background).async {
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)"
            guard let url = URL(string: urlString) else {
                call.reject("Invalid URL for App Store lookup")
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    call.reject("App Store lookup failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    call.reject("No data received from App Store")
                    return
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let resultCount = json["resultCount"] as? Int else {
                        call.reject("Invalid response from App Store")
                        return
                    }

                    let currentVersionName = Bundle.main.versionName ?? "0.0.0"
                    let currentVersionCode = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

                    var result: [String: Any] = [
                        "currentVersionName": currentVersionName,
                        "currentVersionCode": currentVersionCode,
                        "updateAvailability": AppUpdateAvailability.unknown.rawValue
                    ]

                    if resultCount > 0,
                       let results = json["results"] as? [[String: Any]],
                       let appInfo = results.first {

                        let availableVersion = appInfo["version"] as? String
                        let releaseDate = appInfo["currentVersionReleaseDate"] as? String
                        let minimumOsVersion = appInfo["minimumOsVersion"] as? String

                        result["availableVersionName"] = availableVersion
                        result["availableVersionCode"] = availableVersion // iOS doesn't have separate version code
                        result["availableVersionReleaseDate"] = releaseDate
                        result["minimumOsVersion"] = minimumOsVersion

                        // Determine update availability by comparing versions
                        if let availableVersion = availableVersion {
                            do {
                                let currentVer = try Version(currentVersionName)
                                let availableVer = try Version(availableVersion)
                                if availableVer > currentVer {
                                    result["updateAvailability"] = AppUpdateAvailability.updateAvailable.rawValue
                                } else {
                                    result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                                }
                            } catch {
                                // If version parsing fails, do string comparison
                                if availableVersion != currentVersionName {
                                    result["updateAvailability"] = AppUpdateAvailability.updateAvailable.rawValue
                                } else {
                                    result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                                }
                            }
                        } else {
                            result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                        }

                        // iOS doesn't support in-app updates like Android
                        result["immediateUpdateAllowed"] = false
                        result["flexibleUpdateAllowed"] = false
                    } else {
                        // App not found in App Store (maybe not published yet)
                        result["updateAvailability"] = AppUpdateAvailability.updateNotAvailable.rawValue
                        self.logger.info("App not found in App Store for bundleId: \(bundleId)")
                    }

                    call.resolve(result)
                } catch {
                    self.logger.error("Failed to parse App Store response: \(error.localizedDescription)")
                    call.reject("Failed to parse App Store response: \(error.localizedDescription)")
                }
            }
            task.resume()
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")

        if let appId = appId {
            // Open App Store with provided app ID
            let urlString = "https://apps.apple.com/app/id\(appId)"
            guard let url = URL(string: urlString) else {
                call.reject("Invalid App Store URL")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        call.resolve()
                    } else {
                        call.reject("Failed to open App Store")
                    }
                }
            }
        } else {
            // Look up app ID using bundle identifier
            let bundleId = implementation.appId
            let lookupUrl = "https://itunes.apple.com/lookup?bundleId=\(bundleId)"

            DispatchQueue.global(qos: .background).async {
                guard let url = URL(string: lookupUrl) else {
                    call.reject("Invalid lookup URL")
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { data, _, error in
                    if let error = error {
                        call.reject("Failed to lookup app: \(error.localizedDescription)")
                        return
                    }

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]],
                          let appInfo = results.first,
                          let trackId = appInfo["trackId"] as? Int else {
                        // If lookup fails, try opening the generic App Store app page using bundle ID
                        let fallbackUrlString = "https://apps.apple.com/app/\(bundleId)"
                        guard let fallbackUrl = URL(string: fallbackUrlString) else {
                            call.reject("Failed to find app in App Store and fallback URL is invalid")
                            return
                        }
                        DispatchQueue.main.async {
                            UIApplication.shared.open(fallbackUrl) { success in
                                if success {
                                    call.resolve()
                                } else {
                                    call.reject("Failed to open App Store")
                                }
                            }
                        }
                        return
                    }

                    let appStoreUrl = "https://apps.apple.com/app/id\(trackId)"
                    guard let url = URL(string: appStoreUrl) else {
                        call.reject("Invalid App Store URL")
                        return
                    }

                    DispatchQueue.main.async {
                        UIApplication.shared.open(url) { success in
                            if success {
                                call.resolve()
                            } else {
                                call.reject("Failed to open App Store")
                            }
                        }
                    }
                }
                task.resume()
            }
        }
    }

    @objc func performImmediateUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support in-app updates like Android's Play Store
        // Redirect users to the App Store instead
        logger.warn("performImmediateUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("In-app updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func startFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("startFlexibleUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("Flexible updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func completeFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("completeFlexibleUpdate is not supported on iOS.")
        call.reject("Flexible updates are not supported on iOS.", "NOT_SUPPORTED")
    }
}
