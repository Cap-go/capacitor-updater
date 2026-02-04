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
    let pluginVersion: String = "8.41.12"
    static let updateUrlDefault = "https://plugin.capgo.app/updates"
    static let statsUrlDefault = "https://plugin.capgo.app/stats"
    static let channelUrlDefault = "https://plugin.capgo.app/channel_self"
    private let keepUrlPathFlagKey = "__capgo_keep_url_path_after_reload"
    let customIdDefaultsKey = "CapacitorUpdater.customId"
    let updateUrlDefaultsKey = "CapacitorUpdater.updateUrl"
    let statsUrlDefaultsKey = "CapacitorUpdater.statsUrl"
    let channelUrlDefaultsKey = "CapacitorUpdater.channelUrl"
    let defaultChannelDefaultsKey = "CapacitorUpdater.defaultChannel"
    let lastFailedBundleDefaultsKey = "CapacitorUpdater.lastFailedBundle"
    // Note: DELAY_CONDITION_PREFERENCES is now defined in DelayUpdateUtils.DELAY_CONDITION_PREFERENCES
    var updateUrl = ""
    var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    var currentVersionNative: Version = "0.0.0"
    var currentBuildVersion: String = "0"
    var autoUpdate = false
    var appReadyTimeout = 10000
    var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    var directUpdate = false
    var directUpdateMode: String = "false"
    var wasRecentlyInstalledOrUpdated = false
    var onLaunchDirectUpdateUsed = false
    var splashscreenManager: SplashscreenManager!
    var appStoreUpdateManager: AppStoreUpdateManager!
    var autoDeleteFailed = false
    var autoDeletePrevious = false
    var allowSetDefaultChannel = true
    var keepUrlPathAfterReload = false
    var backgroundWork: DispatchWorkItem?
    var taskRunning = false
    var periodCheckDelay = 0

    // Lock to ensure cleanup completes before downloads start
    let cleanupLock = NSLock()
    var cleanupComplete = false
    private var cleanupThread: Thread?
    var persistCustomId = false
    var persistModifyUrl = false
    var allowManualBundleError = false
    private var keepUrlPathFlagLastValue: Bool?
    public var shakeMenuEnabled = false
    let semaphoreReady = DispatchSemaphore(value: 0)

    var delayUpdateUtils: DelayUpdateUtils!
    var periodicUpdateTimer: Timer?

    // swiftlint:disable:next function_body_length
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

        // Initialize SplashscreenManager
        let autoSplashscreen = getConfig().getBoolean("autoSplashscreen", false)
        let autoSplashscreenLoader = getConfig().getBoolean("autoSplashscreenLoader", false)
        let splashscreenTimeoutValue = getConfig().getInt("autoSplashscreenTimeout", 10000)
        self.splashscreenManager = SplashscreenManager(bridge: self.bridge, logger: logger)
        self.splashscreenManager.configure(enabled: autoSplashscreen, loaderEnabled: autoSplashscreenLoader, timeout: max(0, splashscreenTimeoutValue))

        // Initialize AppStoreUpdateManager (appId will be set later)
        self.appStoreUpdateManager = AppStoreUpdateManager(logger: logger) { [weak self] in
            return self?.implementation.appId ?? ""
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
        if !self.initialLoad() {
            logger.error("unable to force reload, the plugin might fallback to the builtin version")
        }

        let notifCenter = NotificationCenter.default
        notifCenter.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        notifCenter.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        // Check for 'kill' delay condition on app launch
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
        bridge.setServerBasePath(dest.path)
        return true
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
                _ = self.performReset(toLastSuccessful: false)
                let res = self.implementation.list()
                for bundleVersion in res {
                    // Check if thread was cancelled
                    if Thread.current.isCancelled {
                        self.logger.warn("Cleanup was cancelled, stopping")
                        return
                    }
                    self.logger.info("Deleting obsolete bundle: \(bundleVersion.getId())")
                    let delResult = self.implementation.delete(id: bundleVersion.getId())
                    if !delResult {
                        self.logger.error("Delete failed, id \(bundleVersion.getId()) doesn't exist")
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
}
