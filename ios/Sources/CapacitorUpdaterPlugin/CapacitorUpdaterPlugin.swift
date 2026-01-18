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
public class CapacitorUpdaterPlugin: CAPPlugin, CAPBridgedPlugin, SplashscreenManagerDelegate {
    lazy var logger: Logger = {
        // Default to true for OS logging. In test environments without a bridge,
        // this will default to true. In production, it reads from config.
        let osLogging: Bool
        if self.bridge != nil {
            osLogging = getConfig().getBoolean("osLogging", true)
        } else {
            osLogging = true
        }
        let options = Logger.Options(useSyslog: osLogging)
        return Logger(withTag: "✨  CapgoUpdater", options: options)
    }()

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
        CAPPluginMethod(name: "setMiniApp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "writeAppState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readAppState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAppState", returnType: CAPPluginReturnPromise),
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
    private let pluginVersion: String = "8.42.10"
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
    private var splashscreenManager: SplashscreenManager?
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

    // Mini-apps support
    private var miniAppsEnabled = false
    private lazy var miniAppsManager = MiniAppsManager(logger: logger)

    // App Store update helper
    private var appStoreUpdateHelper: AppStoreUpdateHelper!

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
        if autoSplashscreen {
            let loaderEnabled = getConfig().getBoolean("autoSplashscreenLoader", false)
            let timeout = max(0, getConfig().getInt("autoSplashscreenTimeout", 10000))
            splashscreenManager = SplashscreenManager(
                logger: logger,
                timeout: timeout,
                loaderEnabled: loaderEnabled,
                delegate: self
            )
        }
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
        miniAppsEnabled = getConfig().getBoolean("miniAppsEnabled", false)
        if miniAppsEnabled {
            logger.info("Mini-apps support enabled")
        }
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
        self.appStoreUpdateHelper = AppStoreUpdateHelper(logger: logger, appId: implementation.appId)
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
                var allowedIds = Set(storedBundles.compactMap { info -> String? in
                    let id = info.getId()
                    return id.isEmpty ? nil : id
                })

                // Add protected mini-app bundle IDs if mini-apps are enabled
                if self.miniAppsEnabled {
                    allowedIds.formUnion(self.miniAppsManager.getProtectedBundleIds())
                }

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
        var bundleId: String?

        // Check if miniApp parameter is provided
        if let miniAppName = call.getString("miniApp") {
            guard miniAppsEnabled else {
                logger.error("set called with miniApp but miniAppsEnabled is false")
                call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
                return
            }

            let registry = miniAppsManager.getRegistry()
            guard let entry = registry[miniAppName], let id = entry["id"] as? String else {
                logger.error("set called with unknown miniApp: \(miniAppName)")
                call.reject("Mini-app '\(miniAppName)' not found", "MINIAPP_NOT_FOUND")
                return
            }
            bundleId = id
            logger.info("Set via miniApp name: \(miniAppName) -> bundle \(id)")
        } else if let id = call.getString("id") {
            bundleId = id
        } else {
            logger.error("Set called without id or miniApp")
            call.reject("Set called without id or miniApp")
            return
        }

        guard let id = bundleId else {
            logger.error("Set called without valid bundle id")
            call.reject("Set called without valid bundle id")
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
        var bundleId: String?
        var miniAppName: String?

        // Check if miniApp parameter is provided
        if let name = call.getString("miniApp") {
            guard miniAppsEnabled else {
                logger.error("delete called with miniApp but miniAppsEnabled is false")
                call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
                return
            }

            miniAppName = name
            let registry = miniAppsManager.getRegistry()
            guard let entry = registry[name], let id = entry["id"] as? String else {
                logger.error("delete called with unknown miniApp: \(name)")
                call.reject("Mini-app '\(name)' not found", "MINIAPP_NOT_FOUND")
                return
            }
            bundleId = id
            logger.info("Delete via miniApp name: \(name) -> bundle \(id)")
        } else if let id = call.getString("id") {
            bundleId = id
        } else {
            logger.error("Delete called without id or miniApp")
            call.reject("Delete called without id or miniApp")
            return
        }

        guard let id = bundleId else {
            logger.error("Delete called without valid bundle id")
            call.reject("Delete called without valid bundle id")
            return
        }

        let res = implementation.delete(id: id)
        if res {
            // If deleting via miniApp, also remove from registry
            if let name = miniAppName {
                var registry = miniAppsManager.getRegistry()
                registry.removeValue(forKey: name)
                miniAppsManager.saveRegistry(registry)
                logger.info("Removed mini-app '\(name)' from registry")
            }
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

        var result: [String: Any] = [
            "bundles": resArr
        ]

        // Add mini-apps list if enabled
        if miniAppsEnabled {
            let registry = miniAppsManager.getRegistry()
            var miniAppsArr: [[String: Any]] = []

            for (name, entry) in registry {
                if let bundleId = entry["id"] as? String {
                    let isMain = entry["isMain"] as? Bool ?? false
                    let bundleInfo = implementation.getBundleInfo(id: bundleId)
                    miniAppsArr.append([
                        "name": name,
                        "bundle": bundleInfo.toJSON(),
                        "isMain": isMain
                    ])
                }
            }

            result["miniApps"] = miniAppsArr
        }

        call.resolve(result)
    }

    @objc func getLatest(_ call: CAPPluginCall) {
        let channel = call.getString("channel")
        let updateMiniApp = call.getString("updateMiniApp")

        // Handle updateMiniApp flow
        if let miniAppName = updateMiniApp {
            guard miniAppsEnabled else {
                logger.error("getLatest called with updateMiniApp but miniAppsEnabled is false")
                call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
                return
            }

            // Check if this mini-app is current
            let currentBundleId = implementation.getCurrentBundleId()
            let registry = miniAppsManager.getRegistry()

            if let entry = registry[miniAppName], let bundleId = entry["id"] as? String {
                if bundleId == currentBundleId {
                    logger.error("Cannot update mini-app '\(miniAppName)' because it is currently active")
                    call.reject("Cannot update mini-app that is currently in use", "MINIAPP_IS_CURRENT")
                    return
                }
            }

            // Use mini-app name as channel
            DispatchQueue.global(qos: .background).async {
                self.performMiniAppUpdate(miniAppName: miniAppName, call: call)
            }
            return
        }

        // Regular getLatest flow
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

    private func performMiniAppUpdate(miniAppName: String, call: CAPPluginCall) {
        // Check for updates on this channel (channel name = mini-app name)
        let res = self.implementation.getLatest(url: URL(string: self.updateUrl)!, channel: miniAppName)

        if res.error != nil || res.message != nil {
            // No update available or error - return with miniAppUpdated: false
            var result = res.toDict()
            result["miniAppUpdated"] = false
            call.resolve(result)
            return
        }

        // Get current mini-app version (if exists)
        let registry = miniAppsManager.getRegistry()
        var currentVersion = ""
        var oldBundleId: String?

        if let entry = registry[miniAppName], let bundleId = entry["id"] as? String {
            oldBundleId = bundleId
            let bundle = self.implementation.getBundleInfo(id: bundleId)
            currentVersion = bundle.getVersionName()
        }

        // Check if update needed
        if res.version == currentVersion {
            var result = res.toDict()
            result["miniAppUpdated"] = false
            call.resolve(result)
            return
        }

        logger.info("Mini-app '\(miniAppName)' has update: \(currentVersion) -> \(res.version)")

        // Download new version
        do {
            let sessionKey = res.sessionKey ?? ""
            guard let downloadUrl = URL(string: res.url ?? "") else {
                call.reject("Invalid download URL", "INVALID_URL")
                return
            }

            var newBundle: BundleInfo

            if let manifest = res.manifest, !manifest.isEmpty {
                newBundle = try self.implementation.downloadManifest(
                    manifest: manifest,
                    version: res.version,
                    sessionKey: sessionKey,
                    link: res.link,
                    comment: res.comment
                )
            } else {
                newBundle = try self.implementation.download(
                    url: downloadUrl,
                    version: res.version,
                    sessionKey: sessionKey,
                    link: res.link,
                    comment: res.comment
                )
            }

            // Verify checksum if provided
            if !res.checksum.isEmpty {
                let decryptedChecksum = try CryptoCipher.decryptChecksum(
                    checksum: res.checksum,
                    publicKey: self.implementation.publicKey
                )
                if !decryptedChecksum.isEmpty && newBundle.getChecksum() != decryptedChecksum {
                    _ = self.implementation.delete(id: newBundle.getId())
                    call.reject("Checksum mismatch", "CHECKSUM_MISMATCH")
                    return
                }
            }

            // Atomically update registry with new bundle ID
            guard self.miniAppsManager.updateBundleId(name: miniAppName, newBundleId: newBundle.getId()) else {
                call.reject("Failed to update mini-app registry", "REGISTRY_UPDATE_FAILED")
                return
            }

            // Auto-switch: set the new bundle active
            let setSuccess = self.implementation.set(id: newBundle.getId())
            guard setSuccess else {
                call.reject("Failed to set new bundle", "SET_FAILED")
                return
            }

            logger.info("Mini-app '\(miniAppName)' updated and switched to bundle \(newBundle.getId())")

            // Reload the app
            DispatchQueue.main.async {
                _ = self._reload()
            }

            // Delete old bundle AFTER successful activation (non-fatal if fails)
            if let oldId = oldBundleId {
                let oldBundle = self.implementation.getBundleInfo(id: oldId)
                if !oldBundle.isBuiltin() && !oldBundle.isUnknown() {
                    let deleted = self.implementation.delete(id: oldId)
                    if deleted {
                        logger.info("Deleted old bundle \(oldId) for mini-app '\(miniAppName)'")
                    } else {
                        logger.warn("Failed to delete old bundle \(oldId) - non-fatal, new bundle is active")
                    }
                }
            }

            var result = res.toDict()
            result["miniAppUpdated"] = true
            call.resolve(result)

        } catch {
            logger.error("Failed to download mini-app update: \(error.localizedDescription)")
            call.reject("Failed to download update: \(error.localizedDescription)", "DOWNLOAD_FAILED")
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

    // MARK: - Mini-Apps Methods

    @objc func setMiniApp(_ call: CAPPluginCall) {
        guard miniAppsEnabled else {
            logger.error("setMiniApp called but miniAppsEnabled is false")
            call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
            return
        }

        guard let name = call.getString("name") else {
            logger.error("setMiniApp called without name")
            call.reject("setMiniApp called without name", "INVALID_PARAMS")
            return
        }

        // Get bundle ID - use provided ID or current bundle
        let bundleId = call.getString("id") ?? implementation.getCurrentBundleId()
        let isMain = call.getBool("isMain") ?? false

        // Verify the bundle exists
        let bundleInfo = implementation.getBundleInfo(id: bundleId)
        if bundleInfo.isUnknown() && !bundleInfo.isBuiltin() {
            logger.error("setMiniApp: bundle \(bundleId) not found")
            call.reject("Bundle '\(bundleId)' not found", "BUNDLE_NOT_FOUND")
            return
        }

        miniAppsManager.register(name: name, bundleId: bundleId, isMain: isMain)
        call.resolve()
    }

    @objc func writeAppState(_ call: CAPPluginCall) {
        guard miniAppsEnabled else {
            logger.error("writeAppState called but miniAppsEnabled is false")
            call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
            return
        }

        guard let miniApp = call.getString("miniApp") else {
            logger.error("writeAppState called without miniApp")
            call.reject("writeAppState called without miniApp", "INVALID_PARAMS")
            return
        }

        // Get state - can be null to clear
        let stateValue = call.getObject("state")
        miniAppsManager.writeState(miniApp: miniApp, state: stateValue)
        call.resolve()
    }

    @objc func readAppState(_ call: CAPPluginCall) {
        guard miniAppsEnabled else {
            logger.error("readAppState called but miniAppsEnabled is false")
            call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
            return
        }

        guard let miniApp = call.getString("miniApp") else {
            logger.error("readAppState called without miniApp")
            call.reject("readAppState called without miniApp", "INVALID_PARAMS")
            return
        }

        let state = miniAppsManager.readState(miniApp: miniApp)
        if let state = state {
            call.resolve(["state": state])
        } else {
            call.resolve(["state": NSNull()])
        }
    }

    @objc func clearAppState(_ call: CAPPluginCall) {
        guard miniAppsEnabled else {
            logger.error("clearAppState called but miniAppsEnabled is false")
            call.reject("Mini-apps support is disabled. Set miniAppsEnabled: true in your Capacitor config.", "MINIAPPS_DISABLED")
            return
        }

        guard let miniApp = call.getString("miniApp") else {
            logger.error("clearAppState called without miniApp")
            call.reject("clearAppState called without miniApp", "INVALID_PARAMS")
            return
        }

        miniAppsManager.clearState(miniApp: miniApp)
        call.resolve()
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
        var result: [String: Any] = [
            "bundle": bundle.toJSON(),
            "native": self.currentVersionNative.description
        ]

        // Add mini-app info if enabled and current bundle is a registered mini-app
        if miniAppsEnabled {
            if let miniAppEntry = miniAppsManager.getMiniAppForBundleId(bundle.getId()) {
                result["miniApp"] = miniAppEntry.toDict()
            }
        }

        call.resolve(result)
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
                self.splashscreenManager?.hide()
            }
        }
    }

    // MARK: - SplashscreenManagerDelegate

    public func getSplashscreenBridge() -> CAPBridgeProtocol? {
        return self.bridge
    }

    public func onSplashscreenTimeout() {
        // Disable direct update when splashscreen times out
        self.directUpdate = false
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
        if self.splashscreenManager?.hasTimedOut == true {
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
                let directUpdateAllowed = plannedDirectUpdate && !(self.splashscreenManager?.hasTimedOut == true)
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
                    let directUpdateAllowed = plannedDirectUpdate && !(self.splashscreenManager?.hasTimedOut == true)
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
                self.splashscreenManager?.show()
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

    @objc func getAppUpdateInfo(_ call: CAPPluginCall) {
        let country = call.getString("country", "US")

        appStoreUpdateHelper.getAppUpdateInfo(country: country) { result in
            switch result {
            case .success(let info):
                call.resolve(info)
            case .failure(let error):
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")

        appStoreUpdateHelper.openAppStore(specificAppId: appId) { result in
            switch result {
            case .success:
                call.resolve()
            case .failure(let error):
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func performImmediateUpdate(_ call: CAPPluginCall) {
        logger.warn("performImmediateUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("In-app updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func startFlexibleUpdate(_ call: CAPPluginCall) {
        logger.warn("startFlexibleUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("Flexible updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func completeFlexibleUpdate(_ call: CAPPluginCall) {
        logger.warn("completeFlexibleUpdate is not supported on iOS.")
        call.reject("Flexible updates are not supported on iOS.", "NOT_SUPPORTED")
    }
}
