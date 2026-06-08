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
        CAPPluginMethod(name: "startPreviewSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listPreviews", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deletePreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPreviewUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updatePreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "list", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "delete", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBundleError", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reset", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "current", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notifyAppReady", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMultiDelay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelDelay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLatest", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMissingBundleFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBundleDownloadSize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "triggerUpdateCheck", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setChannel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unsetChannel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportWebViewError", returnType: CAPPluginReturnPromise),
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
        CAPPluginMethod(name: "setShakeChannelSelector", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isShakeChannelSelectorEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAppId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAppId", returnType: CAPPluginReturnPromise),
        // App Store update methods
        CAPPluginMethod(name: "getAppUpdateInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openAppStore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "performImmediateUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startFlexibleUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "completeFlexibleUpdate", returnType: CAPPluginReturnPromise)
    ]
    public var implementation = CapgoUpdater()
    private let pluginVersion: String = "8.49.0"
    static let updateUrlDefault = "https://plugin.capgo.app/updates"
    static let statsUrlDefault = "https://plugin.capgo.app/stats"
    static let channelUrlDefault = "https://plugin.capgo.app/channel_self"
    static let autoUpdateModeOff = "off"
    static let autoUpdateModeBackground = "atBackground"
    static let autoUpdateModeInstall = "atInstall"
    static let autoUpdateModeLaunch = "onLaunch"
    static let autoUpdateModeAlways = "always"
    static let autoUpdateModeOnlyDownload = "onlyDownload"
    static let shakeMenuGestureShake = "shake"
    static let shakeMenuGestureThreeFingerPinch = "threeFingerPinch"
    private static let previewLoaderTimeoutMs = 60000
    private let keepUrlPathFlagKey = "__capgo_keep_url_path_after_reload"
    private let customIdDefaultsKey = "CapacitorUpdater.customId"
    private let updateUrlDefaultsKey = "CapacitorUpdater.updateUrl"
    private let statsUrlDefaultsKey = "CapacitorUpdater.statsUrl"
    private let channelUrlDefaultsKey = "CapacitorUpdater.channelUrl"
    private let defaultChannelDefaultsKey = "CapacitorUpdater.defaultChannel"
    private let lastFailedBundleDefaultsKey = "CapacitorUpdater.lastFailedBundle"
    private let previewSessionDefaultsKey = "CapacitorUpdater.previewSession"
    private let previewPreviousShakeMenuDefaultsKey = "CapacitorUpdater.previewPreviousShakeMenu"
    private let previewPreviousShakeChannelSelectorDefaultsKey = "CapacitorUpdater.previewPreviousShakeChannelSelector"
    private let previewPreviousNextBundleDefaultsKey = "CapacitorUpdater.previewPreviousNextBundle"
    private let previewPreviousAppIdDefaultsKey = "CapacitorUpdater.previewPreviousAppId"
    private let previewPreviousDefaultChannelDefaultsKey = "CapacitorUpdater.previewPreviousDefaultChannel"
    private let previewPreviousDefaultChannelWasSetDefaultsKey = "CapacitorUpdater.previewPreviousDefaultChannelWasSet"
    private let previewAppIdDefaultsKey = "CapacitorUpdater.previewAppId"
    private let previewPayloadUrlDefaultsKey = "CapacitorUpdater.previewPayloadUrl"
    private let previewNameDefaultsKey = "CapacitorUpdater.previewName"
    private let previewSourceDefaultsKey = "CapacitorUpdater.previewSource"
    private let previewSessionsDefaultsKey = "CapacitorUpdater.previewSessions"
    private let previewSessionAlertPendingDefaultsKey = "CapacitorUpdater.previewSessionAlertPending"
    private let previewDeepLinkScheme = "capgo"
    private let previewDeepLinkRootComponent = "preview"
    private let previewDeepLinkChannelComponent = "channel"
    private let previewDeepLinkBundleComponent = "bundle"
    private let previewPathSeparator = Character(UnicodeScalar(UInt8(47)))
    // Note: DELAY_CONDITION_PREFERENCES is now defined in DelayUpdateUtils.DELAY_CONDITION_PREFERENCES
    private var updateUrl = ""
    private var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var currentVersionNative: Version = "0.0.0"
    private var currentBuildVersion: String = "0"
    private var autoUpdate = false
    private var autoUpdateMode = CapacitorUpdaterPlugin.autoUpdateModeOff
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
    private var previewTransitionLoaderView: UIActivityIndicatorView?
    private var previewTransitionLoaderContainer: UIView?
    private var previewTransitionLoaderTimeoutWorkItem: DispatchWorkItem?
    private var previewTransitionLoaderRequested = false
    private let splashscreenPluginName = "SplashScreen"
    private let splashscreenRetryDelayMilliseconds = 100
    private let splashscreenMaxRetries = 20
    private var autoSplashscreenTimedOut = false
    private var splashscreenInvocationToken = 0
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    var allowSetDefaultChannel = true
    private var keepUrlPathAfterReload = false
    private var backgroundWork: DispatchWorkItem?
    private var taskRunning = false
    private var periodCheckDelay = 0
    private let downloadLock = NSLock()
    private let onLaunchDirectUpdateStateLock = NSLock()
    private var downloadInProgress = false
    private var downloadStartTime: Date?
    private let downloadTimeout: TimeInterval = 3600 // 1 hour timeout

    // Lock to ensure cleanup completes before downloads start
    private let cleanupLock = NSLock()
    private var cleanupComplete = false
    private var cleanupThread: Thread?
    private var persistCustomId = false
    private var persistModifyUrl = false
    private var allowManualBundleError = false
    private var allowPreview = false
    private var keepUrlPathFlagLastValue: Bool?
    private var appHealthTracker: AppHealthTracker?
    private var webViewStatsReporter: WebViewStatsReporter?
    public var shakeMenuEnabled = false
    public var shakeChannelSelectorEnabled = false
    public var shakeMenuGesture = CapacitorUpdaterPlugin.shakeMenuGestureShake
    var shakeMenuPinchGestureRecognizer: ThreeFingerPinchGestureRecognizer?
    var shakeMenuPinchGestureTriggered = false
    public var previewSessionEnabled = false
    private var previewSessionAlertPending = false
    private var isLeavingPreviewForIncomingLink = false
    private var previewTransitionClearWorkItem: DispatchWorkItem?
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
        let webViewStatsReporter = WebViewStatsReporter(implementation: implementation)
        self.webViewStatsReporter = webViewStatsReporter
        webViewStatsReporter.install(on: self.bridge?.webView)
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
        allowPreview = getConfig().getBoolean("allowPreview", false)
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

        autoSplashscreen = getConfig().getBoolean("autoSplashscreen", false)
        autoSplashscreenLoader = getConfig().getBoolean("autoSplashscreenLoader", false)
        let splashscreenTimeoutValue = getConfig().getInt("autoSplashscreenTimeout", 10000)
        autoSplashscreenTimeout = max(0, splashscreenTimeoutValue)
        updateUrl = getConfig().getString("updateUrl", CapacitorUpdaterPlugin.updateUrlDefault)!
        if persistModifyUrl, let storedUpdateUrl = UserDefaults.standard.object(forKey: updateUrlDefaultsKey) as? String {
            updateUrl = storedUpdateUrl
            logger.info("Loaded persisted updateUrl")
        }
        configureAutoUpdateModeFromConfig()
        appReadyTimeout = max(1000, getConfig().getInt("appReadyTimeout", 10000))  // Minimum 1 second
        implementation.timeout = Double(getConfig().getInt("responseTimeout", 20))
        resetWhenUpdate = getConfig().getBoolean("resetWhenUpdate", true)
        shakeMenuEnabled = getConfig().getBoolean("shakeMenu", false)
        shakeChannelSelectorEnabled = getConfig().getBoolean("allowShakeChannelSelector", false)
        shakeMenuGesture = Self.normalizedShakeMenuGesture(getConfig().getString("shakeMenuGesture", Self.shakeMenuGestureShake))
        let storedPreviewSessionEnabled = UserDefaults.standard.bool(forKey: previewSessionDefaultsKey)
        let shouldClearPreviewSessionBecauseDisabled = !allowPreview && storedPreviewSessionEnabled
        previewSessionEnabled = allowPreview && storedPreviewSessionEnabled
        implementation.previewSession = previewSessionEnabled
        if previewSessionEnabled {
            previewSessionAlertPending = UserDefaults.standard.object(forKey: previewSessionAlertPendingDefaultsKey) as? Bool ?? true
            shakeMenuEnabled = true
            shakeChannelSelectorEnabled = UserDefaults.standard.object(forKey: previewPreviousShakeChannelSelectorDefaultsKey) as? Bool
                ?? shakeChannelSelectorEnabled
        }
        syncShakeMenuGestureRecognizer()
        periodCheckDelay = Self.normalizedPeriodCheckDelaySeconds(getConfig().getInt("periodCheckDelay", 0))

        implementation.setPublicKey(getConfig().getString("publicKey") ?? "")
        implementation.notifyDownloadRaw = notifyDownload
        implementation.notifyListeners = { [weak self] eventName, data in
            let emit = {
                self?.notifyListeners(eventName, data: data)
            }
            if Thread.isMainThread {
                emit()
            } else {
                DispatchQueue.main.async {
                    emit()
                }
            }
        }
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
        if shouldClearPreviewSessionBecauseDisabled {
            clearPreviewSessionBecauseDisabled()
        }
        if previewSessionEnabled,
           let previewAppId = UserDefaults.standard.string(forKey: previewAppIdDefaultsKey),
           !previewAppId.isEmpty {
            implementation.appId = previewAppId
            logger.info("Using preview appId \(previewAppId)")
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
        let appHealthTracker = AppHealthTracker(implementation: self.implementation)
        self.appHealthTracker = appHealthTracker
        appHealthTracker.reportPreviousUncleanForegroundExit()
        appHealthTracker.startSession()

        // Check if app was recently installed/updated BEFORE cleanup updates the stored native build version.
        self.wasRecentlyInstalledOrUpdated = self.checkIfRecentlyInstalledOrUpdated()
        let nativeBuildVersionChanged = self.hasNativeBuildVersionChanged()
        if nativeBuildVersionChanged {
            self.clearPreviewSessionForNativeBuildChange()
        }
        self.leavePreviewSessionForLaunchURLIfNeeded()

        if resetWhenUpdate {
            let didResetCurrentBundle = self.resetCurrentBundleForNativeBuildChangeIfNeeded()
            self.cleanupObsoleteVersions(didResetCurrentBundle: didResetCurrentBundle)
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

        self.registerNotificationObservers()

        // Check for 'kill' delay condition on app launch
        // This handles cases where the app was killed (willTerminateNotification is not reliable for system kills)
        self.delayUpdateUtils.checkCancelDelay(source: .killed)

        self.appMovedToForeground()
        self.checkForUpdateAfterDelay()
        self.showPreviewSessionNoticeIfNeeded()
    }

    private func registerNotificationObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(appMovedToBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(appMovedToForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleOpenURLForPreviewSession(notification:)),
            name: Notification.Name.capacitorOpenURL,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleOpenURLForPreviewSession(notification:)),
            name: Notification.Name.capacitorOpenUniversalLink,
            object: nil
        )
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

    @objc private func appWillTerminate() {
        appHealthTracker?.markForeground(false)
    }

    @objc private func appDidReceiveMemoryWarning() {
        appHealthTracker?.reportMemoryWarning()
    }

    @objc func reportWebViewError(_ call: CAPPluginCall) {
        guard let webViewStatsReporter = webViewStatsReporter else {
            call.resolve()
            return
        }
        webViewStatsReporter.reportError(call)
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

    private func cleanupObsoleteVersions(didResetCurrentBundle: Bool = false) {
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

    private func resolveCall(_ call: CAPPluginCall, data: PluginCallResultData? = nil) {
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

    private func rejectCall(_ call: CAPPluginCall, message: String, code: String? = nil, error: Error? = nil, data: PluginCallResultData? = nil) {
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

    private func saveCallForAsyncHandling(_ call: CAPPluginCall) {
        bridge?.saveCall(call)
    }

    private func notifyListenersOnMain(_ eventName: String, data: JSObject) {
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

    private func bundlePayload(_ bundleInfo: BundleInfo) -> JSObject {
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

    private func manifestEntries(from manifestArray: [Any]?) -> [ManifestEntry]? {
        guard let manifestArray = manifestArray else {
            return nil
        }
        var manifestEntries: [ManifestEntry] = []
        for item in manifestArray {
            if let manifestDict = item as? [String: Any] {
                manifestEntries.append(ManifestEntry(
                    file_name: manifestDict["file_name"] as? String,
                    file_hash: manifestDict["file_hash"] as? String,
                    download_url: manifestDict["download_url"] as? String
                ))
            }
        }
        return manifestEntries
    }

    private struct PreviewPayload: Decodable {
        let version: String?
        let url: String?
        let checksum: String?
        let sessionKey: String?
        let manifest: [ManifestEntry]?
        let message: String?
        let error: String?
    }

    private func normalizedPreviewMetadataValue(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let lowercased = value.lowercased()
        guard lowercased != "undefined", lowercased != "null" else {
            return nil
        }

        return value
    }

    private func previewSessions() -> [String: [String: Any]] {
        guard let rawSessions = UserDefaults.standard.dictionary(forKey: self.previewSessionsDefaultsKey) else {
            return [:]
        }

        var sessions: [String: [String: Any]] = [:]
        for (id, rawValue) in rawSessions {
            if let session = rawValue as? [String: Any] {
                sessions[id] = session
            }
        }
        return sessions
    }

    private func savePreviewSessions(_ sessions: [String: [String: Any]]) {
        UserDefaults.standard.set(sessions, forKey: self.previewSessionsDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private func metadataString(_ metadata: [String: Any], _ key: String) -> String? {
        self.normalizedPreviewMetadataValue(metadata[key] as? String)
    }

    private func currentPreviewMetadataValue(forKey key: String) -> String? {
        self.normalizedPreviewMetadataValue(UserDefaults.standard.string(forKey: key))
    }

    private func previewInfo(
        id: String,
        metadata: [String: Any],
        availableBundleIds: Set<String>,
        currentBundleId: String
    ) -> [String: Any]? {
        let bundle = self.implementation.getBundleInfo(id: id)
        if !bundle.isBuiltin() && !availableBundleIds.contains(id) {
            return nil
        }
        if bundle.isDeleted() || bundle.isErrorStatus() {
            return nil
        }

        var info: [String: Any] = [
            "id": id,
            "bundle": bundle.toJSON(),
            "createdAt": self.metadataString(metadata, "createdAt") ?? Date().iso8601withFractionalSeconds,
            "updatedAt": self.metadataString(metadata, "updatedAt") ?? Date().iso8601withFractionalSeconds,
            "lastUsedAt": self.metadataString(metadata, "lastUsedAt") ?? Date().iso8601withFractionalSeconds,
            "isActive": self.previewSessionEnabled && currentBundleId == id
        ]

        for key in ["name", "source", "appId", "payloadUrl"] {
            if let value = self.metadataString(metadata, key) {
                info[key] = value
            }
        }

        return info
    }

    private func listPreviewInfos(cleanup: Bool = true) -> [[String: Any]] {
        let availableBundleIds = Set(self.implementation.list().map { $0.getId() })
        let currentBundleId = self.implementation.getCurrentBundleId()
        var sessions = self.previewSessions()
        var previews: [[String: Any]] = []
        var staleIds: [String] = []

        for (id, metadata) in sessions {
            if let info = self.previewInfo(
                id: id,
                metadata: metadata,
                availableBundleIds: availableBundleIds,
                currentBundleId: currentBundleId
            ) {
                previews.append(info)
            } else {
                staleIds.append(id)
            }
        }

        if cleanup && !staleIds.isEmpty {
            for id in staleIds {
                sessions.removeValue(forKey: id)
            }
            self.savePreviewSessions(sessions)
        }

        return previews.sorted { first, second in
            let firstUsed = first["lastUsedAt"] as? String ?? ""
            let secondUsed = second["lastUsedAt"] as? String ?? ""
            return firstUsed > secondUsed
        }
    }

    private func storedPreviewInfo(id: String) -> [String: Any]? {
        let sessions = self.previewSessions()
        guard let metadata = sessions[id] else {
            return nil
        }
        let availableBundleIds = Set(self.implementation.list().map { $0.getId() })
        return self.previewInfo(
            id: id,
            metadata: metadata,
            availableBundleIds: availableBundleIds,
            currentBundleId: self.implementation.getCurrentBundleId()
        )
    }

    @discardableResult
    private func recordPreviewBundle(_ bundle: BundleInfo, replacing oldId: String? = nil) -> [String: Any] {
        let now = Date().iso8601withFractionalSeconds
        var sessions = self.previewSessions()
        let id = bundle.getId()
        let replacingPreview = oldId.map { $0 != id } ?? false
        var metadata = sessions[id] ?? (replacingPreview ? sessions[oldId ?? ""] ?? [:] : [:])

        if metadata["createdAt"] == nil {
            metadata["createdAt"] = now
        }
        metadata["updatedAt"] = now
        if metadata["lastUsedAt"] == nil || self.implementation.getCurrentBundleId() == id {
            metadata["lastUsedAt"] = now
        }
        metadata["version"] = bundle.getVersionName()

        if !replacingPreview {
            if let appId = self.currentPreviewMetadataValue(forKey: self.previewAppIdDefaultsKey) {
                metadata["appId"] = appId
            } else {
                metadata.removeValue(forKey: "appId")
            }

            if let payloadUrl = self.currentPreviewMetadataValue(forKey: self.previewPayloadUrlDefaultsKey) {
                metadata["payloadUrl"] = payloadUrl
            } else {
                metadata.removeValue(forKey: "payloadUrl")
            }
        }

        if !replacingPreview {
            if let name = self.currentPreviewMetadataValue(forKey: self.previewNameDefaultsKey) {
                metadata["name"] = name
            } else {
                metadata.removeValue(forKey: "name")
            }
        }
        if self.metadataString(metadata, "name") == nil {
            metadata["name"] = bundle.getVersionName()
        }

        if !replacingPreview {
            if let source = self.currentPreviewMetadataValue(forKey: self.previewSourceDefaultsKey) {
                metadata["source"] = source
            } else {
                metadata.removeValue(forKey: "source")
            }
        }

        if let oldId, oldId != id {
            sessions.removeValue(forKey: oldId)
        }
        sessions[id] = metadata
        self.savePreviewSessions(sessions)

        return self.storedPreviewInfo(id: id) ?? [
            "id": id,
            "bundle": bundle.toJSON(),
            "createdAt": now,
            "updatedAt": now,
            "lastUsedAt": now,
            "isActive": self.previewSessionEnabled && self.implementation.getCurrentBundleId() == id
        ]
    }

    private func updateCurrentPreviewSessionMetadata(from preview: [String: Any]) {
        if let appId = self.metadataString(preview, "appId") {
            self.implementation.appId = appId
            UserDefaults.standard.set(appId, forKey: self.previewAppIdDefaultsKey)
        } else {
            self.restorePreviewPreviousAppId()
            UserDefaults.standard.removeObject(forKey: self.previewAppIdDefaultsKey)
        }

        if let payloadUrl = self.metadataString(preview, "payloadUrl") {
            UserDefaults.standard.set(payloadUrl, forKey: self.previewPayloadUrlDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewPayloadUrlDefaultsKey)
        }

        if let name = self.metadataString(preview, "name") {
            UserDefaults.standard.set(name, forKey: self.previewNameDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewNameDefaultsKey)
        }

        if let source = self.metadataString(preview, "source") {
            UserDefaults.standard.set(source, forKey: self.previewSourceDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewSourceDefaultsKey)
        }
        UserDefaults.standard.synchronize()
    }

    private func makePreviewError(_ message: String) -> NSError {
        NSError(domain: "CapacitorUpdaterPreview", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func downloadBundle(urlString: String, version: String, sessionKey: String, checksum rawChecksum: String, manifestEntries: [ManifestEntry]?) throws -> BundleInfo {
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
        let checksum = call.getString("checksum", "")
        let manifestArray = call.getArray("manifest")
        logger.info("Downloading \(urlString)")
        self.saveCallForAsyncHandling(call)
        self.runBackgroundDownloadWork {
            do {
                let next = try self.downloadBundle(
                    urlString: urlString,
                    version: version,
                    sessionKey: sessionKey,
                    checksum: checksum,
                    manifestEntries: self.manifestEntries(from: manifestArray)
                )
                var updateAvailablePayload: JSObject = [:]
                updateAvailablePayload["bundle"] = self.bundlePayload(next)
                self.notifyListenersOnMain("updateAvailable", data: updateAvailablePayload)
                self.resolveCall(call, data: next.toJSON())
            } catch {
                self.logger.error("Failed to download from: \(urlString) \(error.localizedDescription)")
                var downloadFailedPayload: JSObject = [:]
                downloadFailedPayload["version"] = version
                self.notifyListenersOnMain("downloadFailed", data: downloadFailedPayload)
                self.implementation.sendStats(action: "download_fail")
                self.rejectCall(call, message: "Failed to download from: \(urlString) - \(error.localizedDescription)")
            }
        }
    }

    private func currentReloadDestination() -> URL {
        let id = self.implementation.getCurrentBundleId()
        if BundleInfo.ID_BUILTIN == id {
            return Bundle.main.resourceURL!.appendingPathComponent("public")
        } else {
            return self.implementation.getBundleDirectory(id: id)
        }
    }

    private func applyCurrentBundleToBridge(_ bridge: CAPBridgeProtocol) -> Bool {
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

    func restoreLiveBundleStateAfterFailedReload() {
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

    public func _reload() -> Bool {
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

    func reloadWithoutWaitingForAppReady() -> Bool {
        guard let bridge = self.bridge else { return false }

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

        if !self.isPreviewSessionStateActive(),
           let next = next,
           !next.isErrorStatus(),
           next.getId() != current.getId() {
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
            if didApplyPendingBundle && self._reload() {
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

        if self._reload() {
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        } else {
            logger.error("Reload failed")
            call.reject("Reload failed")
        }
    }

    private func applyDownloadedBundleForDirectUpdate(_ next: BundleInfo) -> Bool {
        let previousState = self.implementation.captureResetState()
        let previousBundleName = self.implementation.getCurrentBundle().getVersionName()

        guard self.implementation.stagePendingReload(bundle: next) else {
            self.implementation.restoreResetState(previousState)
            logger.error("Direct update failed to stage downloaded bundle: \(next.toString())")
            return false
        }

        if self._reload() {
            self.implementation.finalizePendingReload(bundle: next, previousBundleName: previousBundleName)
            _ = self.implementation.setNextBundle(next: Optional<String>.none)
            return true
        }

        self.implementation.restoreResetState(previousState)
        self.restoreLiveBundleStateAfterFailedReload()
        logger.error("Direct update reload failed after staging bundle: \(next.toString())")
        return false
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
        } else if self.previewSessionEnabled {
            let bundle = self.implementation.getBundleInfo(id: id)
            _ = self.recordPreviewBundle(bundle)
            if !self.reloadWithoutWaitingForAppReady() {
                call.reject("Reload failed after setting preview bundle \(id)")
                return
            }
            self.notifyBundleSet(bundle)
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        } else if !self._reload() {
            call.reject("Reload failed after setting bundle \(id)")
        } else {
            self.notifyBundleSet(self.implementation.getBundleInfo(id: id))
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        }
    }

    private func isPreviewSessionStateActive() -> Bool {
        self.previewSessionEnabled || self.isLeavingPreviewForIncomingLink || self.implementation.previewSession
    }

    private func shouldBlockAutoUpdateForPreviewSession() -> Bool {
        guard self.isPreviewSessionStateActive() else {
            return false
        }

        logger.info("Preview session is active. Skipping normal auto-update work.")
        return true
    }

    private func clearIncomingPreviewTransition() {
        self.previewTransitionClearWorkItem?.cancel()
        self.previewTransitionClearWorkItem = nil
        self.isLeavingPreviewForIncomingLink = false
        if !self.previewSessionEnabled {
            self.implementation.previewSession = false
        }
    }

    private func scheduleIncomingPreviewTransitionFallbackClear() {
        self.previewTransitionClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearIncomingPreviewTransition()
        }
        self.previewTransitionClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.appReadyTimeout), execute: workItem)
    }

    private func preparePreviewFallbackIfNeeded() -> Bool {
        if self.previewSessionEnabled {
            return true
        }

        let current = self.implementation.getCurrentBundle()
        guard self.implementation.setPreviewFallbackBundle(fallback: current.getId()) else {
            logger.error("Could not save current bundle as preview fallback")
            return false
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
        return true
    }

    private func activatePreviewSessionState() {
        self.clearIncomingPreviewTransition()
        self.hidePreviewTransitionLoader(reason: "preview-session-started")
        self.previewSessionEnabled = true
        self.previewSessionAlertPending = true
        self.implementation.previewSession = true
        self.shakeMenuEnabled = true
        self.syncShakeMenuGestureRecognizer()
        UserDefaults.standard.set(true, forKey: self.previewSessionDefaultsKey)
        UserDefaults.standard.set(true, forKey: self.previewSessionAlertPendingDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    @objc func startPreviewSession(_ call: CAPPluginCall) {
        guard self.allowPreview else {
            self.hidePreviewTransitionLoader(reason: "preview-session-not-allowed")
            logger.error("startPreviewSession called without allowPreview")
            call.reject("startPreviewSession not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        let previewAppId = self.normalizedPreviewAppId(call.getString("appId"))
        let rawPayloadUrl = call.getString("payloadUrl")
        let previewPayloadUrl = self.normalizedPreviewPayloadUrl(rawPayloadUrl)
        if let rawPayloadUrl = rawPayloadUrl, !rawPayloadUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, previewPayloadUrl == nil {
            self.hidePreviewTransitionLoader(reason: "preview-session-invalid-payload")
            logger.error("startPreviewSession called with invalid payloadUrl")
            call.reject("Invalid preview payloadUrl")
            return
        }

        guard self.preparePreviewFallbackIfNeeded() else {
            self.hidePreviewTransitionLoader(reason: "preview-session-fallback-failed")
            call.reject("Could not save current bundle as preview fallback")
            return
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

        if let previewName = self.normalizedPreviewMetadataValue(call.getString("name")) {
            UserDefaults.standard.set(previewName, forKey: self.previewNameDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewNameDefaultsKey)
        }

        if let previewSource = self.normalizedPreviewMetadataValue(call.getString("source")) {
            UserDefaults.standard.set(previewSource, forKey: self.previewSourceDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.previewSourceDefaultsKey)
        }

        self.activatePreviewSessionState()
        call.resolve()
    }

    @objc func listPreviews(_ call: CAPPluginCall) {
        guard self.allowPreview else {
            call.reject("listPreviews not allowed. Set allowPreview to true in your config to enable it.")
            return
        }

        let previews = self.listPreviewInfos()
        var result: [String: Any] = [
            "previews": previews,
            "currentBundle": self.implementation.getCurrentBundle().toJSON()
        ]
        if let currentPreview = previews.first(where: { ($0["isActive"] as? Bool) == true }) {
            result["current"] = currentPreview
        }
        if let liveBundle = self.implementation.getPreviewFallbackBundle() {
            result["liveBundle"] = liveBundle.toJSON()
        }
        call.resolve(result)
    }

    @objc func setPreview(_ call: CAPPluginCall) {
        guard self.allowPreview else {
            call.reject("setPreview not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("setPreview called without id")
            return
        }
        guard let preview = self.storedPreviewInfo(id: id) else {
            call.reject("Preview \(id) is not available locally")
            return
        }

        self.showPreviewTransitionLoader(reason: "set-preview")
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.preparePreviewFallbackIfNeeded() else {
                self.hidePreviewTransitionLoader(reason: "set-preview-fallback-failed")
                call.reject("Could not save current bundle as preview fallback")
                return
            }

            guard self.implementation.set(id: id) else {
                self.hidePreviewTransitionLoader(reason: "set-preview-failed")
                call.reject("Preview \(id) cannot be applied")
                return
            }

            let bundle = self.implementation.getBundleInfo(id: id)
            self.updateCurrentPreviewSessionMetadata(from: preview)
            self.activatePreviewSessionState()
            _ = self.recordPreviewBundle(bundle)
            guard self.reloadWithoutWaitingForAppReady() else {
                self.hidePreviewTransitionLoader(reason: "set-preview-reload-failed")
                call.reject("Reload failed after setting preview \(id)")
                return
            }

            self.notifyBundleSet(bundle)
            self.showPreviewSessionNoticeIfNeeded()
            call.resolve()
        }
    }

    func previewMenuPreviews() -> [[String: Any]] {
        self.listPreviewInfos()
    }

    func setPreviewFromShakeMenu(id: String) -> Bool {
        guard self.allowPreview, let preview = self.storedPreviewInfo(id: id) else {
            return false
        }

        self.showPreviewTransitionLoader(reason: "set-preview-menu")
        guard self.preparePreviewFallbackIfNeeded() else {
            self.hidePreviewTransitionLoader(reason: "set-preview-menu-fallback-failed")
            return false
        }

        guard self.implementation.set(id: id) else {
            self.hidePreviewTransitionLoader(reason: "set-preview-menu-failed")
            return false
        }

        let bundle = self.implementation.getBundleInfo(id: id)
        self.updateCurrentPreviewSessionMetadata(from: preview)
        self.activatePreviewSessionState()
        _ = self.recordPreviewBundle(bundle)
        guard self.reloadWithoutWaitingForAppReady() else {
            self.hidePreviewTransitionLoader(reason: "set-preview-menu-reload-failed")
            return false
        }

        self.notifyBundleSet(bundle)
        self.showPreviewSessionNoticeIfNeeded()
        return true
    }

    @objc func resetPreview(_ call: CAPPluginCall) {
        guard self.previewSessionEnabled else {
            call.resolve()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if self.leavePreviewSessionFromShakeMenu() {
                call.resolve()
            } else {
                call.reject("Could not leave preview session")
            }
        }
    }

    @objc func deletePreview(_ call: CAPPluginCall) {
        guard self.allowPreview else {
            call.reject("deletePreview not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("deletePreview called without id")
            return
        }
        if self.previewSessionEnabled && self.implementation.getCurrentBundleId() == id {
            call.reject("Cannot delete the active preview")
            return
        }

        var sessions = self.previewSessions()
        let removed = sessions.removeValue(forKey: id) != nil
        self.savePreviewSessions(sessions)

        var deleted = false
        let fallbackId = self.implementation.getPreviewFallbackBundle()?.getId()
        let nextId = self.implementation.getNextBundle()?.getId()
        if removed, id != fallbackId, id != nextId, id != BundleInfo.ID_BUILTIN {
            deleted = self.implementation.delete(id: id, removeInfo: false)
        }

        call.resolve(["removed": removed, "deleted": deleted])
    }

    @objc func checkPreviewUpdate(_ call: CAPPluginCall) {
        self.handlePreviewUpdate(call, shouldDownload: false)
    }

    @objc func updatePreview(_ call: CAPPluginCall) {
        self.handlePreviewUpdate(call, shouldDownload: true)
    }

    private func handlePreviewUpdate(_ call: CAPPluginCall, shouldDownload: Bool) {
        guard self.allowPreview else {
            call.reject("Preview updates not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("Preview update called without id")
            return
        }
        guard let preview = self.storedPreviewInfo(id: id),
              let payloadUrlString = preview["payloadUrl"] as? String,
              let payloadUrl = self.normalizedPreviewPayloadUrl(payloadUrlString) else {
            call.reject("Preview \(id) has no payloadUrl to update from")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try self.fetchPreviewPayload(payloadUrl)
                guard let version = payload.version, !version.isEmpty else {
                    throw self.makePreviewError("Preview payload is missing a version")
                }

                let currentPreviewBundle = self.implementation.getBundleInfo(id: id)
                let upToDate = currentPreviewBundle.getVersionName() == version
                if upToDate || !shouldDownload {
                    call.resolve([
                        "preview": preview,
                        "latestVersion": version,
                        "upToDate": upToDate,
                        "updated": false,
                        "bundle": currentPreviewBundle.toJSON()
                    ])
                    return
                }

                guard payload.url != nil || payload.manifest?.isEmpty == false else {
                    throw self.makePreviewError("Preview payload is missing download information")
                }

                let next = try self.downloadBundle(
                    // Fallback URL is only provided when payload.url is missing; when manifestEntries is present,
                    // downloadBundle routes through downloadManifest and ignores urlString.
                    urlString: payload.url ?? "https://404.capgo.app/no.zip",
                    version: version,
                    sessionKey: payload.sessionKey ?? "",
                    checksum: payload.checksum ?? "",
                    manifestEntries: payload.manifest
                )

                let wasActive = self.previewSessionEnabled && self.implementation.getCurrentBundleId() == id
                if wasActive {
                    guard self.implementation.set(id: next.getId()) else {
                        throw self.makePreviewError("Downloaded preview bundle cannot be applied")
                    }
                }

                let savedPreview = self.recordPreviewBundle(next, replacing: id)
                if wasActive {
                    guard self.reloadWithoutWaitingForAppReady() else {
                        throw self.makePreviewError("Reload failed after updating preview")
                    }
                    self.notifyBundleSet(next)
                    self.showPreviewSessionNoticeIfNeeded()
                }

                call.resolve([
                    "preview": savedPreview,
                    "latestVersion": version,
                    "upToDate": false,
                    "updated": true,
                    "bundle": next.toJSON()
                ])
            } catch {
                self.logger.error("Could not update preview: \(error.localizedDescription)")
                call.reject("Could not update preview: \(error.localizedDescription)")
            }
        }
    }

    func leavePreviewSessionFromShakeMenu() -> Bool {
        self.showPreviewTransitionLoader(reason: "leave-preview-session")
        let didReset = self.resetToPreviewFallbackBundle()
        guard didReset else {
            self.hidePreviewTransitionLoader(reason: "leave-preview-session-failed")
            return false
        }

        self.endPreviewSession(keepPreviewGuard: true)
        return true
    }

    private func leavePreviewSessionForLaunchURLIfNeeded() {
        guard self.previewSessionEnabled,
              !self.isLeavingPreviewForIncomingLink,
              let launchUrl = ApplicationDelegateProxy.shared.lastURL,
              self.isPreviewDeepLink(launchUrl) else {
            return
        }

        self.isLeavingPreviewForIncomingLink = true
        self.showPreviewTransitionLoader(reason: "preview-launch-deeplink")
        logger.info("Preview deeplink launch detected while preview session is active; restoring fallback before initial load")
        if !self.leavePreviewSessionWithoutReload() {
            logger.error("Could not leave preview session before initial preview deeplink routing")
            self.isLeavingPreviewForIncomingLink = false
            self.hidePreviewTransitionLoader(reason: "preview-launch-deeplink-failed")
        }
    }

    private func leavePreviewSessionWithoutReload(keepPreviewGuard: Bool = false) -> Bool {
        guard let previewFallbackBundle = self.resolvePreviewFallbackBundle(reason: "preview deeplink launch") else {
            return false
        }
        guard self.implementation.stagePreviewFallbackReload(bundle: previewFallbackBundle) else {
            logger.error("Could not stage preview fallback bundle")
            return false
        }

        self.endPreviewSession(keepPreviewGuard: keepPreviewGuard)
        return true
    }

    private func leavePreviewSessionForIncomingPreviewLink() -> Bool {
        self.showPreviewTransitionLoader(reason: "incoming-preview-deeplink")
        guard let previewFallbackBundle = self.resolvePreviewFallbackBundle(reason: "incoming preview deeplink") else {
            self.clearIncomingPreviewTransition()
            self.hidePreviewTransitionLoader(reason: "incoming-preview-deeplink-failed")
            return false
        }

        let previousState = self.implementation.captureResetState()
        guard self.implementation.stagePreviewFallbackReload(bundle: previewFallbackBundle) else {
            logger.error("Could not stage preview fallback bundle")
            self.clearIncomingPreviewTransition()
            self.hidePreviewTransitionLoader(reason: "incoming-preview-deeplink-failed")
            return false
        }

        let didReload = self.reloadWithoutWaitingForAppReady()
        if didReload {
            self.endPreviewSession(keepPreviewGuard: true)
            self.scheduleIncomingPreviewTransitionFallbackClear()
        } else {
            self.implementation.restoreResetState(previousState)
            self.restoreLiveBundleStateAfterFailedReload()
            self.clearIncomingPreviewTransition()
            self.hidePreviewTransitionLoader(reason: "incoming-preview-deeplink-reload-failed")
        }
        return didReload
    }

    func reloadPreviewSessionFromShakeMenu() -> Bool {
        self.showPreviewTransitionLoader(reason: "reload-preview-session")
        let didReload: Bool
        if let payloadUrl = self.storedPreviewPayloadUrl() {
            didReload = self.refreshPreviewSessionFromPayloadUrl(payloadUrl)
        } else {
            didReload = self.reloadWithoutWaitingForAppReady()
        }

        if !didReload {
            self.hidePreviewTransitionLoader(reason: "reload-preview-session-failed")
        }
        return didReload
    }

    func hasActivePreviewSession() -> Bool {
        self.previewSessionEnabled
    }

    func resetToPreviewFallbackBundle() -> Bool {
        guard self.canPerformResetTransition() else { return false }
        guard let fallback = self.resolvePreviewFallbackBundle(reason: "leave preview") else {
            return false
        }

        let previousState = self.implementation.captureResetState()
        let previousBundleName = self.implementation.getCurrentBundle().getVersionName()
        logger.info("Resetting to preview fallback bundle: \(fallback.toString())")
        if self.implementation.stagePreviewFallbackReload(bundle: fallback) && self.reloadWithoutWaitingForAppReady() {
            self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: false)
            self.notifyBundleSet(fallback)
            return true
        }
        self.implementation.restoreResetState(previousState)
        self.restoreLiveBundleStateAfterFailedReload()
        return false
    }

    private func resolvePreviewFallbackBundle(reason: String) -> BundleInfo? {
        let fallback = self.implementation.getPreviewFallbackBundle()
        if let fallback, !fallback.isErrorStatus(), self.implementation.canSet(bundle: fallback) {
            return fallback
        }

        if let fallback {
            if fallback.isErrorStatus() {
                logger.warn("Preview fallback bundle is in error state for \(reason). Falling back to builtin bundle.")
            } else {
                logger.warn("Preview fallback bundle is not installable for \(reason). Falling back to builtin bundle.")
            }
        } else {
            logger.warn("No preview fallback bundle available for \(reason). Falling back to builtin bundle.")
        }

        let builtin = self.implementation.getBundleInfo(id: BundleInfo.ID_BUILTIN)
        if !builtin.isErrorStatus(), self.implementation.canSet(bundle: builtin) {
            return builtin
        }

        logger.error("Builtin bundle is not available to leave preview for \(reason)")
        return nil
    }

    private func endPreviewSession(keepPreviewGuard: Bool = false) {
        let previousShakeMenuEnabled = UserDefaults.standard.object(forKey: self.previewPreviousShakeMenuDefaultsKey) as? Bool
            ?? self.getBooleanConfig("shakeMenu", defaultValue: false)
        let previousShakeChannelSelectorEnabled = UserDefaults.standard.object(forKey: self.previewPreviousShakeChannelSelectorDefaultsKey) as? Bool
            ?? self.getBooleanConfig("allowShakeChannelSelector", defaultValue: false)
        self.restorePreviewPreviousNextBundle()
        self.restorePreviewPreviousAppId()
        self.restorePreviewPreviousDefaultChannel()

        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        if keepPreviewGuard {
            self.implementation.previewSession = true
        } else {
            self.clearIncomingPreviewTransition()
        }
        self.shakeMenuEnabled = previousShakeMenuEnabled
        self.shakeChannelSelectorEnabled = previousShakeChannelSelectorEnabled
        self.syncShakeMenuGestureRecognizer()
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        self.clearPreviewSessionPreferences()
        logger.info("Preview session ended")
    }

    private func clearPreviewSessionBecauseDisabled() {
        logger.info("Preview session disabled by config; restoring preview fallback")
        if let bundleToRestore = self.resolvePreviewFallbackBundle(reason: "preview disabled") {
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
        self.hidePreviewTransitionLoader(reason: "preview-session-disabled")
        self.shakeMenuEnabled = self.getBooleanConfig("shakeMenu", defaultValue: false)
        self.shakeChannelSelectorEnabled = self.getBooleanConfig("allowShakeChannelSelector", defaultValue: false)
        self.shakeMenuGesture = Self.normalizedShakeMenuGesture(self.getStringConfig("shakeMenuGesture", defaultValue: Self.shakeMenuGestureShake))
        self.syncShakeMenuGestureRecognizer()
        self.clearPreviewSessionPreferences()
    }

    private func getBooleanConfig(_ key: String, defaultValue: Bool) -> Bool {
        guard self.bridge != nil else {
            return defaultValue
        }
        return getConfig().getBoolean(key, defaultValue)
    }

    private func getStringConfig(_ key: String, defaultValue: String) -> String {
        guard self.bridge != nil else {
            return defaultValue
        }
        return getConfig().getString(key, defaultValue) ?? defaultValue
    }

    private func clearPreviewSessionPreferences() {
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
        UserDefaults.standard.removeObject(forKey: self.previewNameDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewSourceDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.previewSessionAlertPendingDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private func restorePreviewPreviousAppId() {
        guard let previousAppId = UserDefaults.standard.string(forKey: self.previewPreviousAppIdDefaultsKey),
              !previousAppId.isEmpty else {
            return
        }
        self.implementation.appId = previousAppId
        logger.info("Restored appId after preview: \(previousAppId)")
    }

    private func restorePreviewPreviousDefaultChannel() {
        let configDefaultChannel = self.getStringConfig("defaultChannel", defaultValue: "")
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

    private func normalizedPreviewAppId(_ rawAppId: String?) -> String? {
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

    private func normalizedPreviewPayloadUrl(_ rawPayloadUrl: String?) -> URL? {
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

    private func storedPreviewPayloadUrl() -> URL? {
        normalizedPreviewPayloadUrl(UserDefaults.standard.string(forKey: self.previewPayloadUrlDefaultsKey))
    }

    private func previewPath(from url: URL) -> String {
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

    private func normalizedPreviewPath(_ components: [String]) -> String {
        let separator = String(self.previewPathSeparator)
        return separator + components.filter { !$0.isEmpty }.joined(separator: separator)
    }

    private func previewDeepLinkPath(_ leafComponent: String) -> String {
        self.normalizedPreviewPath([self.previewDeepLinkRootComponent, leafComponent])
    }

    private func isPreviewDeepLink(_ url: URL) -> Bool {
        let path = self.previewPath(from: url)
        return path == self.previewDeepLinkPath(self.previewDeepLinkChannelComponent) ||
            path == self.previewDeepLinkPath(self.previewDeepLinkBundleComponent)
    }

    @objc private func handleOpenURLForPreviewSession(notification: NSNotification) {
        let rawUrl = (notification.object as? [String: Any])?["url"]
        let url = rawUrl as? URL ?? (rawUrl as? NSURL).map { $0 as URL }
        guard self.previewSessionEnabled,
              !self.isLeavingPreviewForIncomingLink,
              let url,
              self.isPreviewDeepLink(url) else {
            return
        }

        self.isLeavingPreviewForIncomingLink = true
        self.showPreviewTransitionLoader(reason: "incoming-preview-deeplink")
        logger.info("Preview deeplink received while preview session is active; restoring fallback before routing")
        DispatchQueue.global(qos: .userInitiated).async {
            let didLeave = self.leavePreviewSessionForIncomingPreviewLink()
            if !didLeave {
                self.logger.error("Could not leave preview session before routing incoming preview deeplink")
                self.isLeavingPreviewForIncomingLink = false
                self.hidePreviewTransitionLoader(reason: "incoming-preview-deeplink-failed")
            }
        }
    }

    private func fetchPreviewPayload(_ payloadUrl: URL) throws -> PreviewPayload {
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

    private func refreshPreviewSessionFromPayloadUrl(_ payloadUrl: URL) -> Bool {
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
                return self.reloadWithoutWaitingForAppReady()
            }

            let next = try self.downloadBundle(
                // Fallback URL is only provided when payload.url is missing; when manifestEntries is present,
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

            _ = self.recordPreviewBundle(next, replacing: current.getId())
            self.notifyBundleSet(next)
            return self.reloadWithoutWaitingForAppReady()
        } catch {
            self.logger.error("Could not refresh preview session: \(error.localizedDescription)")
            return false
        }
    }

    private func clearPreviewSessionForNativeBuildChange() {
        guard self.previewSessionEnabled || self.implementation.getPreviewFallbackBundle() != nil || !self.previewSessions().isEmpty else {
            return
        }
        logger.info("Native build changed; clearing preview session state")
        self.previewSessionEnabled = false
        self.previewSessionAlertPending = false
        self.isLeavingPreviewForIncomingLink = false
        self.implementation.previewSession = false
        self.shakeMenuEnabled = self.getBooleanConfig("shakeMenu", defaultValue: false)
        self.shakeChannelSelectorEnabled = self.getBooleanConfig("allowShakeChannelSelector", defaultValue: false)
        self.shakeMenuGesture = Self.normalizedShakeMenuGesture(self.getStringConfig("shakeMenuGesture", defaultValue: Self.shakeMenuGestureShake))
        self.syncShakeMenuGestureRecognizer()
        self.restorePreviewPreviousAppId()
        self.restorePreviewPreviousDefaultChannel()
        _ = self.implementation.setPreviewFallbackBundle(fallback: nil)
        _ = self.implementation.setNextBundle(next: Optional<String>.none)
        self.clearPreviewSessionPreferences()
        UserDefaults.standard.removeObject(forKey: self.previewSessionsDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private func restorePreviewPreviousNextBundle() {
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

    private func showPreviewSessionNoticeIfNeeded() {
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
        let includeBundleSize = call.getBool("includeBundleSize", false)
        let appId = self.normalizedPreviewAppId(call.getString("appId"))
        if appId != nil && !self.allowPreview {
            logger.error("getLatest preview override called without allowPreview")
            call.reject("getLatest preview override not allowed. Set allowPreview to true in your config to enable it.")
            return
        }
        self.saveCallForAsyncHandling(call)
        runGetLatestWork {
            let res = self.implementation.getLatest(
                url: URL(string: self.updateUrl)!,
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

    private func attachBundleSize(to res: AppVersion) {
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
        if self.shouldBlockAutoUpdateForPreviewSession() {
            return "preview_session"
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
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
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
        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .utility).async {
            let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
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
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
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
            let res = self.implementation.getChannel(defaultChannelKey: self.defaultChannelDefaultsKey)
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

    @objc func _reset(toLastSuccessful: Bool, usePendingBundle: Bool) -> Bool {
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
            if didApplyPendingBundle && self._reload() {
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
                if self.implementation.set(bundle: fallback) && self._reload() {
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
        if self._reload() {
            self.implementation.finalizeResetTransition(previousBundleName: previousBundleName, isInternal: isInternal)
            return true
        }
        if !isInternal {
            self.implementation.restoreResetState(previousState)
            self.restoreLiveBundleStateAfterFailedReload()
        }
        return false
    }

    func canPerformResetTransition() -> Bool {
        guard let bridge = self.bridge else { return false }
        return (bridge.viewController as? CAPBridgeViewController) != nil
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toLastSuccessful = call.getBool("toLastSuccessful") ?? false
        let usePendingBundle = call.getBool("usePendingBundle") ?? false
        if self._reset(toLastSuccessful: toLastSuccessful, usePendingBundle: usePendingBundle) {
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
        self.clearIncomingPreviewTransition()
        self.hidePreviewTransitionLoader(reason: "notify-app-ready")

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
        if self.isPreviewSessionStateActive() {
            return false
        }
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
        if self.isPreviewSessionStateActive() {
            logger.info("Preview session is active. We skip the check for notifyAppReady.")
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

    func DeferredNotifyAppReadyCheck() {
        self.checkRevert()
        self.appReadyCheck = nil
    }

    func endBackGroundTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    }

    private func notifyBundleSet(_ bundle: BundleInfo) {
        self.notifyListeners("set", data: ["bundle": bundle.toJSON()], retainUntilConsumed: true)
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
            self.hidePreviewTransitionLoader(reason: "app-ready")
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
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenMethod(
            methodName: "hide",
            callbackId: "autoHideSplashscreen",
            options: self.splashscreenOptions(methodName: "hide"),
            retriesRemaining: self.splashscreenMaxRetries,
            requestToken: self.splashscreenInvocationToken
        )
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
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenMethod(
            methodName: "show",
            callbackId: "autoShowSplashscreen",
            options: self.splashscreenOptions(methodName: "show"),
            retriesRemaining: self.splashscreenMaxRetries,
            requestToken: self.splashscreenInvocationToken
        )

        self.addSplashscreenLoaderIfNeeded()
        self.scheduleSplashscreenTimeout()
    }

    private func splashscreenOptions(methodName: String) -> [String: Any] {
        methodName == "show" ? ["autoHide": false] : [:]
    }

    private func splashscreenCompletedMessage(methodName: String) -> String {
        methodName == "show" ? "Splashscreen shown automatically" : "Splashscreen hidden automatically"
    }

    func splashscreenOptionsForTesting(methodName: String) -> [String: Any] {
        self.splashscreenOptions(methodName: methodName)
    }

    func isCurrentSplashscreenInvocationTokenForTesting(_ requestToken: Int) -> Bool {
        requestToken == self.splashscreenInvocationToken
    }

    func advanceSplashscreenInvocationTokenForTesting() {
        self.splashscreenInvocationToken += 1
    }

    private func makeSplashscreenCall(callbackId: String, options: [String: Any], methodName: String) -> CAPPluginCall {
        CAPPluginCall(callbackId: callbackId, options: options, success: { [weak self] (_, _) in
            guard let self = self else { return }
            self.logger.info(self.splashscreenCompletedMessage(methodName: methodName))
        }, error: { [weak self] (_) in
            guard let self = self else { return }
            self.logger.error("Failed to auto-\(methodName) splashscreen")
        })
    }

    private func invokeSplashscreenMethod(
        methodName: String,
        callbackId: String,
        options: [String: Any],
        retriesRemaining: Int,
        requestToken: Int
    ) {
        guard requestToken == self.splashscreenInvocationToken else {
            return
        }

        guard let bridge = self.bridge else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "Bridge not available for \(methodName == "show" ? "showing" : "hiding") splashscreen with autoSplashscreen"
            )
            return
        }

        guard let splashScreenPlugin = bridge.plugin(withName: self.splashscreenPluginName) else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin."
            )
            return
        }

        let selector = NSSelectorFromString("\(methodName):")
        guard splashScreenPlugin.responds(to: selector) else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin does not respond to \(methodName): method. Make sure @capacitor/splash-screen plugin is properly installed."
            )
            return
        }

        let call = self.makeSplashscreenCall(callbackId: callbackId, options: options, methodName: methodName)
        _ = splashScreenPlugin.perform(selector, with: call)
        self.logger.info("Called SplashScreen \(methodName) method")
    }

    private func retrySplashscreenMethod(
        methodName: String,
        callbackId: String,
        options: [String: Any],
        retriesRemaining: Int,
        requestToken: Int,
        message: String
    ) {
        guard retriesRemaining > 0 else {
            if methodName == "show" {
                self.logger.warn(message)
            } else {
                self.logger.error(message)
            }
            return
        }

        self.logger.info("\(message). Retrying.")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.splashscreenRetryDelayMilliseconds)) { [weak self] in
            guard let self = self, requestToken == self.splashscreenInvocationToken else {
                return
            }
            self.invokeSplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining - 1,
                requestToken: requestToken
            )
        }
    }

    private func createLoaderOverlay(
        backgroundColor: UIColor,
        isUserInteractionEnabled: Bool,
        indicatorColor: UIColor?
    ) -> (container: UIView, indicator: UIActivityIndicatorView) {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = backgroundColor
        container.isUserInteractionEnabled = isUserInteractionEnabled

        let indicatorStyle: UIActivityIndicatorView.Style
        if #available(iOS 13.0, *) {
            indicatorStyle = .large
        } else {
            indicatorStyle = .whiteLarge
        }

        let indicator = UIActivityIndicatorView(style: indicatorStyle)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = false
        if let indicatorColor = indicatorColor {
            indicator.color = indicatorColor
        }
        indicator.startAnimating()

        return (container, indicator)
    }

    private func attachLoaderOverlay(
        _ overlay: (container: UIView, indicator: UIActivityIndicatorView),
        to rootView: UIView
    ) {
        overlay.container.addSubview(overlay.indicator)
        rootView.addSubview(overlay.container)

        NSLayoutConstraint.activate([
            overlay.container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            overlay.container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            overlay.container.topAnchor.constraint(equalTo: rootView.topAnchor),
            overlay.container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            overlay.indicator.centerXAnchor.constraint(equalTo: overlay.container.centerXAnchor),
            overlay.indicator.centerYAnchor.constraint(equalTo: overlay.container.centerYAnchor)
        ])
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

            let indicatorColor: UIColor?
            if #available(iOS 13.0, *) {
                indicatorColor = UIColor.label
            } else {
                indicatorColor = nil
            }
            let overlay = self.createLoaderOverlay(
                backgroundColor: UIColor.clear,
                isUserInteractionEnabled: false,
                indicatorColor: indicatorColor
            )
            self.attachLoaderOverlay(overlay, to: rootView)
            self.splashscreenLoaderContainer = overlay.container
            self.splashscreenLoaderView = overlay.indicator
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

    private func showPreviewTransitionLoader(reason: String) {
        self.previewTransitionLoaderRequested = true
        let showLoader = {
            guard self.previewTransitionLoaderRequested else {
                return
            }

            if let container = self.previewTransitionLoaderContainer {
                self.previewTransitionLoaderTimeoutWorkItem?.cancel()
                self.schedulePreviewTransitionLoaderTimeout()
                container.superview?.bringSubviewToFront(container)
                return
            }

            guard let rootView = self.bridge?.viewController?.view else {
                self.logger.warn("Preview transition loader unavailable: root view missing for \(reason)")
                self.previewTransitionLoaderRequested = false
                return
            }

            self.previewTransitionLoaderTimeoutWorkItem?.cancel()
            self.schedulePreviewTransitionLoaderTimeout()

            let indicatorColor: UIColor?
            if #available(iOS 13.0, *) {
                indicatorColor = UIColor.white
            } else {
                indicatorColor = nil
            }
            let overlay = self.createLoaderOverlay(
                backgroundColor: UIColor.black.withAlphaComponent(0.18),
                isUserInteractionEnabled: true,
                indicatorColor: indicatorColor
            )
            self.attachLoaderOverlay(overlay, to: rootView)
            self.previewTransitionLoaderContainer = overlay.container
            self.previewTransitionLoaderView = overlay.indicator
            self.logger.info("Preview transition loader shown: \(reason)")
        }

        if Thread.isMainThread {
            showLoader()
        } else {
            DispatchQueue.main.async {
                showLoader()
            }
        }
    }

    private func hidePreviewTransitionLoader(reason: String) {
        if !self.previewTransitionLoaderRequested &&
            self.previewTransitionLoaderContainer == nil &&
            self.previewTransitionLoaderTimeoutWorkItem == nil {
            return
        }

        let hideLoader = {
            self.previewTransitionLoaderRequested = false
            self.previewTransitionLoaderTimeoutWorkItem?.cancel()
            self.previewTransitionLoaderTimeoutWorkItem = nil
            guard self.previewTransitionLoaderContainer != nil else {
                return
            }
            self.previewTransitionLoaderView?.stopAnimating()
            self.previewTransitionLoaderContainer?.removeFromSuperview()
            self.previewTransitionLoaderView = nil
            self.previewTransitionLoaderContainer = nil
            self.logger.info("Preview transition loader hidden: \(reason)")
        }

        if Thread.isMainThread {
            hideLoader()
        } else {
            DispatchQueue.main.async {
                hideLoader()
            }
        }
    }

    private func schedulePreviewTransitionLoaderTimeout() {
        self.previewTransitionLoaderTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hidePreviewTransitionLoader(reason: "preview-transition-timeout")
        }
        self.previewTransitionLoaderTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.previewLoaderTimeoutMs),
            execute: workItem
        )
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

    private func configureAutoUpdateModeFromConfig() {
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

    private func resolveLegacyDirectUpdateModeFromConfig() -> String {
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

    static func normalizedShakeMenuGesture(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return shakeMenuGestureShake
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == shakeMenuGestureThreeFingerPinch {
            return shakeMenuGestureThreeFingerPinch
        }
        return shakeMenuGestureShake
    }

    static func isSupportedShakeMenuGesture(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return false
        }
        return normalized == shakeMenuGestureShake || normalized == shakeMenuGestureThreeFingerPinch
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

    private func shouldAutoSetNextBundle() -> Bool {
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

    private func getOnLaunchDirectUpdateUsed() -> Bool {
        self.onLaunchDirectUpdateStateLock.lock()
        defer { self.onLaunchDirectUpdateStateLock.unlock() }
        return self.onLaunchDirectUpdateUsed
    }

    private func setOnLaunchDirectUpdateUsed(_ used: Bool) {
        self.onLaunchDirectUpdateStateLock.lock()
        self.onLaunchDirectUpdateUsed = used
        self.onLaunchDirectUpdateStateLock.unlock()
    }

    private func consumeOnLaunchDirectUpdateAttempt(plannedDirectUpdate: Bool) {
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

    private func notifyBreakingEvents(version: String) {
        guard !version.isEmpty else {
            return
        }
        let payload: [String: Any] = ["version": version]
        self.notifyListeners("breakingAvailable", data: payload)
        self.notifyListeners("majorAvailable", data: payload)
    }

    private func shouldNotifyBreakingEvents(response: AppVersion) -> Bool {
        if response.breaking == true {
            return true
        }

        return response.error == "disable_auto_update_to_major" || response.message == "store_update_required"
    }

    private func notifyBreakingEventsIfNeeded(response: AppVersion, version: String) {
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

    private func updateResponseKind(kind: String?) -> String {
        Self.normalizedUpdateResponseKind(kind: kind)
    }

    private func endBackgroundDownloadAfterLatestError(
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

    private func isDownloadStuckOrTimedOut() -> Bool {
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

    private func clearDownloadInProgressState() {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        downloadInProgress = false
        downloadStartTime = nil
    }

    func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
        // Live update checks/downloads are user-visible work. Using `.background`
        // lets the scheduler starve them for minutes while the app is active.
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func beginDownloadBackgroundTask() {
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

    func runGetLatestWork(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .background).async(execute: work)
    }

    func backgroundDownload() {
        if self.shouldBlockAutoUpdateForPreviewSession() {
            return
        }
        // Set download in progress flag (thread-safe)
        downloadLock.lock()
        downloadInProgress = true
        downloadStartTime = Date()
        downloadLock.unlock()

        let plannedDirectUpdate = self.shouldUseDirectUpdate()
        let messageUpdate: String
        if plannedDirectUpdate {
            messageUpdate = "Update will occur now."
        } else if self.shouldAutoSetNextBundle() {
            messageUpdate = "Update will occur next time app moves to background."
        } else {
            messageUpdate = "Update will be downloaded and made available."
        }
        guard let url = URL(string: self.updateUrl) else {
            logger.error("Error no url or wrong format")
            // Clear the flag if we return early
            downloadLock.lock()
            defer { downloadLock.unlock() }
            downloadInProgress = false
            downloadStartTime = nil
            return
        }

        self.runBackgroundDownloadWork {
            // Wait for cleanup to complete before starting download
            self.waitForCleanupIfNeeded()
            if self.shouldBlockAutoUpdateForPreviewSession() {
                self.clearDownloadInProgressState()
                return
            }
            self.beginDownloadBackgroundTask()
            self.logger.info("Check for update via \(self.updateUrl)")
            let res = self.implementation.getLatest(url: url, channel: nil)
            let current = self.implementation.getCurrentBundle()
            if self.shouldBlockAutoUpdateForPreviewSession() {
                self.clearDownloadInProgressState()
                self.endBackGroundTask()
                return
            }

            // Handle network errors and other failures first
            let backendError = res.error ?? ""
            let backendKind = res.kind ?? ""
            if !backendError.isEmpty || !backendKind.isEmpty {
                self.endBackgroundDownloadAfterLatestError(
                    backendError: backendError,
                    res: res,
                    current: current,
                    plannedDirectUpdate: plannedDirectUpdate
                )
                return
            }
            if res.version == "builtin" {
                self.logger.info("Latest version is builtin")
                let directUpdateAllowed = plannedDirectUpdate && !self.autoSplashscreenTimedOut
                if directUpdateAllowed {
                    self.logger.info("Direct update to builtin version")
                    _ = self._reset(toLastSuccessful: false, usePendingBundle: false)
                    self.endBackGroundTaskWithNotif(
                        msg: "Updated to builtin version",
                        latestVersionName: res.version,
                        current: self.implementation.getCurrentBundle(),
                        error: false,
                        plannedDirectUpdate: plannedDirectUpdate
                    )
                } else if self.shouldAutoSetNextBundle() {
                    if plannedDirectUpdate && !directUpdateAllowed {
                        self.logger.info("Direct update skipped because splashscreen timeout occurred. Update will apply later.")
                    }
                    self.logger.info("Setting next bundle to builtin")
                    _ = self.implementation.setNextBundle(next: BundleInfo.ID_BUILTIN)
                    self.endBackGroundTaskWithNotif(
                        msg: "Next update will be to builtin version",
                        latestVersionName: res.version,
                        current: current,
                        error: false,
                        plannedDirectUpdate: plannedDirectUpdate
                    )
                } else {
                    self.logger.info("autoUpdate is set to onlyDownload, builtin version will not be set as next bundle")
                    let builtinUpdateAvailable = !current.isBuiltin()
                    if builtinUpdateAvailable {
                        let builtinBundle = self.implementation.getBundleInfo(id: BundleInfo.ID_BUILTIN)
                        self.notifyListeners("updateAvailable", data: ["bundle": builtinBundle.toJSON()], retainUntilConsumed: true)
                    }
                    self.endBackGroundTaskWithNotif(
                        msg: "Latest version is builtin, autoUpdate onlyDownload",
                        latestVersionName: res.version,
                        current: current,
                        error: false,
                        plannedDirectUpdate: plannedDirectUpdate,
                        notifyNoNeedUpdate: !builtinUpdateAvailable
                    )
                }
                return
            }
            let sessionKey = res.sessionKey ?? ""
            let latestVersionName = res.version
            guard let downloadUrl = URL(string: res.url) else {
                self.notifyBreakingEventsIfNeeded(response: res, version: latestVersionName)
                self.logger.error("Error no url or wrong format")
                self.endBackGroundTaskWithNotif(
                    msg: "Error no url or wrong format",
                    latestVersionName: latestVersionName,
                    current: current,
                    plannedDirectUpdate: plannedDirectUpdate
                )
                return
            }
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
                        self.consumeOnLaunchDirectUpdateAttempt(plannedDirectUpdate: plannedDirectUpdate)
                        if res.manifest != nil {
                            nextImpl = try self.implementation.downloadManifest(manifest: res.manifest!, version: latestVersionName, sessionKey: sessionKey, link: res.link, comment: res.comment)
                        } else {
                            nextImpl = try self.implementation.download(url: downloadUrl, version: latestVersionName, sessionKey: sessionKey, link: res.link, comment: res.comment)
                        }
                    }
                    guard let next = nextImpl else {
                        self.logger.error("Error downloading file")
                        self.endBackGroundTaskWithNotif(
                            msg: "Error downloading file",
                            latestVersionName: latestVersionName,
                            current: current,
                            plannedDirectUpdate: plannedDirectUpdate
                        )
                        return
                    }
                    if next.isErrorStatus() {
                        self.logger.error("Latest bundle already exists and is in error state. Aborting update.")
                        self.endBackGroundTaskWithNotif(
                            msg: "Latest version is in error state. Aborting update.",
                            latestVersionName: latestVersionName,
                            current: current,
                            plannedDirectUpdate: plannedDirectUpdate
                        )
                        return
                    }
                    if self.shouldBlockAutoUpdateForPreviewSession() {
                        self.clearDownloadInProgressState()
                        self.endBackGroundTask()
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
                        self.endBackGroundTaskWithNotif(
                            msg: "Error checksum",
                            latestVersionName: latestVersionName,
                            current: current,
                            plannedDirectUpdate: plannedDirectUpdate
                        )
                        return
                    }
                    if self.shouldBlockAutoUpdateForPreviewSession() {
                        self.clearDownloadInProgressState()
                        self.endBackGroundTask()
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
                            self.endBackGroundTaskWithNotif(
                                msg: "Update delayed until delay conditions met",
                                latestVersionName: latestVersionName,
                                current: next,
                                error: false,
                                plannedDirectUpdate: plannedDirectUpdate
                            )
                            return
                        }
                        if self.applyDownloadedBundleForDirectUpdate(next) {
                            self.notifyBundleSet(next)
                            self.endBackGroundTaskWithNotif(
                                msg: "update installed",
                                latestVersionName: latestVersionName,
                                current: next,
                                error: false,
                                plannedDirectUpdate: plannedDirectUpdate
                            )
                        } else {
                            _ = self.implementation.setNextBundle(next: next.getId())
                            self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
                            self.endBackGroundTaskWithNotif(
                                msg: "Direct update reload failed, update will install next background",
                                latestVersionName: latestVersionName,
                                current: self.implementation.getCurrentBundle(),
                                error: false,
                                plannedDirectUpdate: plannedDirectUpdate
                            )
                        }
                    } else if self.shouldAutoSetNextBundle() {
                        if plannedDirectUpdate && !directUpdateAllowed {
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
                    return
                } catch {
                    self.logger.error("Error downloading file \(error.localizedDescription)")
                    let current: BundleInfo = self.implementation.getCurrentBundle()
                    self.endBackGroundTaskWithNotif(
                        msg: "Error downloading file",
                        latestVersionName: latestVersionName,
                        current: current,
                        plannedDirectUpdate: plannedDirectUpdate
                    )
                    return
                }
            } else {
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
        }
    }

    private func installNext() {
        if self.shouldBlockAutoUpdateForPreviewSession() {
            return
        }
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
                self.notifyBundleSet(next!)
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
        appHealthTracker?.markForeground(true)
        let current: BundleInfo = self.implementation.getCurrentBundle()
        self.implementation.sendStats(action: "app_moved_to_foreground", versionName: current.getVersionName())
        self.delayUpdateUtils.checkCancelDelay(source: .foreground)
        self.delayUpdateUtils.unsetBackgroundTimestamp()
        if backgroundWork != nil && taskRunning {
            backgroundWork!.cancel()
            logger.info("Background Timer Task canceled, Activity resumed before timer completes")
        }
        if self._isAutoUpdateEnabled() {
            // Check if download is already in progress (with timeout protection)
            if !isDownloadStuckOrTimedOut() {
                self.backgroundDownload()
            } else {
                logger.info("Download already in progress, skipping duplicate download request")
            }
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
            DispatchQueue.global(qos: .utility).async {
                if self.shouldBlockAutoUpdateForPreviewSession() {
                    return
                }
                let res = self.implementation.getLatest(url: url, channel: nil)
                let current = self.implementation.getCurrentBundle()
                if self.shouldBlockAutoUpdateForPreviewSession() {
                    return
                }

                if res.version != current.getVersionName() {
                    self.logger.info("New version found: \(res.version)")
                    // Check if download is already in progress (with timeout protection)
                    if !self.isDownloadStuckOrTimedOut() {
                        self.backgroundDownload()
                    } else {
                        self.logger.info("Download already in progress, skipping duplicate download request")
                    }
                }
            }
        }
        RunLoop.current.add(periodicUpdateTimer!, forMode: .default)
    }

    @objc func appMovedToBackground() {
        // Reset timeout flag at start of each background cycle
        self.autoSplashscreenTimedOut = false
        appHealthTracker?.markForeground(false)

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
        self.syncShakeMenuGestureRecognizer()
        logger.info("Shake menu \(enabled ? "enabled" : "disabled") with \(self.shakeMenuGesture) gesture")
        call.resolve()
    }

    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeMenuEnabled,
            "gesture": self.shakeMenuGesture
        ])
    }

    @objc func setShakeChannelSelector(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            logger.error("setShakeChannelSelector called without enabled parameter")
            call.reject("setShakeChannelSelector called without enabled parameter")
            return
        }

        self.shakeChannelSelectorEnabled = enabled
        self.syncShakeMenuGestureRecognizer()
        logger.info("Shake channel selector \(enabled ? "enabled" : "disabled")")
        call.resolve()
    }

    @objc func isShakeChannelSelectorEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeChannelSelectorEnabled
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

        self.saveCallForAsyncHandling(call)
        DispatchQueue.global(qos: .background).async {
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(country)"
            guard let url = URL(string: urlString) else {
                self.rejectCall(call, message: "Invalid URL for App Store lookup")
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                    self.rejectCall(call, message: "App Store lookup failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    self.rejectCall(call, message: "No data received from App Store")
                    return
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let resultCount = json["resultCount"] as? Int else {
                        self.rejectCall(call, message: "Invalid response from App Store")
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

                    self.resolveCall(call, data: result)
                } catch {
                    self.logger.error("Failed to parse App Store response: \(error.localizedDescription)")
                    self.rejectCall(call, message: "Failed to parse App Store response: \(error.localizedDescription)")
                }
            }
            task.resume()
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")
        let bundleId = implementation.appId
        self.saveCallForAsyncHandling(call)

        func openAppStorePage(urlString: String, invalidMessage: String = "Invalid App Store URL", failureMessage: String = "Failed to open App Store") {
            guard let url = URL(string: urlString) else {
                self.rejectCall(call, message: invalidMessage)
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        self.resolveCall(call)
                    } else {
                        self.rejectCall(call, message: failureMessage)
                    }
                }
            }
        }

        func openFallbackAppStorePage() {
            guard let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                self.rejectCall(call, message: "Failed to build App Store fallback URL")
                return
            }
            openAppStorePage(urlString: "https://apps.apple.com/app/\(encodedBundleId)")
        }

        if let appId = appId {
            openAppStorePage(urlString: "https://apps.apple.com/app/id\(appId)")
        } else {
            let lookupUrl = "https://itunes.apple.com/lookup?bundleId=\(bundleId)"

            DispatchQueue.global(qos: .background).async {
                guard let url = URL(string: lookupUrl) else {
                    openFallbackAppStorePage()
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { data, _, error in
                    if let error = error {
                        self.logger.error("App Store lookup failed: \(error.localizedDescription)")
                        openFallbackAppStorePage()
                        return
                    }

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]],
                          let appInfo = results.first,
                          let trackId = appInfo["trackId"] as? Int else {
                        openFallbackAppStorePage()
                        return
                    }

                    openAppStorePage(urlString: "https://apps.apple.com/app/id\(trackId)")
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
