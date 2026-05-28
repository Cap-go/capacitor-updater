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
    let pluginVersion: String = "8.47.4"
    static let updateUrlDefault = "https://plugin.capgo.app/updates"
    static let statsUrlDefault = "https://plugin.capgo.app/stats"
    static let channelUrlDefault = "https://plugin.capgo.app/channel_self"
    static let autoUpdateModeOff = "off"
    static let autoUpdateModeBackground = "atBackground"
    static let autoUpdateModeInstall = "atInstall"
    static let autoUpdateModeLaunch = "onLaunch"
    static let autoUpdateModeAlways = "always"
    static let autoUpdateModeOnlyDownload = "onlyDownload"
    let keepUrlPathFlagKey = "__capgo_keep_url_path_after_reload"
    let customIdDefaultsKey = "CapacitorUpdater.customId"
    let updateUrlDefaultsKey = "CapacitorUpdater.updateUrl"
    let statsUrlDefaultsKey = "CapacitorUpdater.statsUrl"
    let channelUrlDefaultsKey = "CapacitorUpdater.channelUrl"
    let defaultChannelDefaultsKey = "CapacitorUpdater.defaultChannel"
    let lastFailedBundleDefaultsKey = "CapacitorUpdater.lastFailedBundle"
    let previewSessionDefaultsKey = "CapacitorUpdater.previewSession"
    let previewPreviousShakeMenuDefaultsKey = "CapacitorUpdater.previewPreviousShakeMenu"
    let previewPreviousShakeChannelSelectorDefaultsKey = "CapacitorUpdater.previewPreviousShakeChannelSelector"
    let previewPreviousNextBundleDefaultsKey = "CapacitorUpdater.previewPreviousNextBundle"
    let previewPreviousAppIdDefaultsKey = "CapacitorUpdater.previewPreviousAppId"
    let previewPreviousDefaultChannelDefaultsKey = "CapacitorUpdater.previewPreviousDefaultChannel"
    let previewPreviousDefaultChannelWasSetDefaultsKey = "CapacitorUpdater.previewPreviousDefaultChannelWasSet"
    let previewAppIdDefaultsKey = "CapacitorUpdater.previewAppId"
    let previewPayloadUrlDefaultsKey = "CapacitorUpdater.previewPayloadUrl"
    // Delay preference keys live in DelayUpdateUtils.
    var updateUrl = ""
    var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    var currentVersionNative: Version = "0.0.0"
    var currentBuildVersion: String = "0"
    var autoUpdate = false
    var autoUpdateMode = CapacitorUpdaterPlugin.autoUpdateModeOff
    var appReadyTimeout = 10000
    var appReadyCheck: DispatchWorkItem?
    var resetWhenUpdate = true
    var directUpdate = false
    var directUpdateMode: String = "false"
    var wasRecentlyInstalledOrUpdated = false
    var onLaunchDirectUpdateUsed = false
    var autoSplashscreen = false
    var autoSplashscreenLoader = false
    var autoSplashscreenTimeout = 10000
    var autoSplashscreenTimeoutWorkItem: DispatchWorkItem?
    var splashscreenLoaderView: UIActivityIndicatorView?
    var splashscreenLoaderContainer: UIView?
    let splashscreenPluginName = "SplashScreen"
    let splashscreenRetryDelayMilliseconds = 100
    let splashscreenMaxRetries = 20
    var autoSplashscreenTimedOut = false
    var splashscreenInvocationToken = 0
    var autoDeleteFailed = false
    var autoDeletePrevious = false
    var allowSetDefaultChannel = true
    var keepUrlPathAfterReload = false
    var backgroundWork: DispatchWorkItem?
    var taskRunning = false
    var periodCheckDelay = 0
    let downloadLock = NSLock()
    let onLaunchDirectUpdateStateLock = NSLock()
    var downloadInProgress = false
    var downloadStartTime: Date?
    let downloadTimeout: TimeInterval = 3600 // 1 hour timeout

    // Lock to ensure cleanup completes before downloads start
    let cleanupLock = NSLock()
    var cleanupComplete = false
    var cleanupThread: Thread?
    var persistCustomId = false
    var persistModifyUrl = false
    var allowManualBundleError = false
    var allowPreview = false
    var keepUrlPathFlagLastValue: Bool?
    var appHealthTracker: AppHealthTracker?
    var webViewStatsReporter: WebViewStatsReporter?
    public var shakeMenuEnabled = false
    public var shakeChannelSelectorEnabled = false
    public var previewSessionEnabled = false
    var previewSessionAlertPending = false
    let semaphoreReady = DispatchSemaphore(value: 0)

    var delayUpdateUtils: DelayUpdateUtils!
    var periodicUpdateTimer: Timer?

    func endBackGroundTask() {
        endBackGroundTaskImpl()
    }

    func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
        runBackgroundDownloadWorkImpl(work)
    }

    func runGetLatestWork(_ work: @escaping () -> Void) {
        runGetLatestWorkImpl(work)
    }

    func sendReadyToJs(current: BundleInfo, msg: String) {
        sendReadyToJsImpl(current: current, msg: msg)
    }

    func canPerformResetTransition() -> Bool {
        canPerformResetTransitionImpl()
    }

    public func reloadCurrentBundle() -> Bool {
        reloadCurrentBundleImpl()
    }

    @objc(_reload)
    @available(*, deprecated, message: "Use reloadCurrentBundle().")
    public func reloadLegacyEntrypoint() -> Bool {
        reloadCurrentBundle()
    }

    func restoreLiveBundleStateAfterFailedReload() {
        restoreLiveBundleStateAfterFailedReloadImpl()
    }

    override public func load() {
        configureWebViewLogging()
        self.semaphoreUp()
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
        let storedPreviewSessionEnabled = UserDefaults.standard.bool(forKey: previewSessionDefaultsKey)
        let shouldClearPreviewSessionBecauseDisabled = !allowPreview && storedPreviewSessionEnabled
        previewSessionEnabled = allowPreview && storedPreviewSessionEnabled
        implementation.previewSession = previewSessionEnabled
        if previewSessionEnabled {
            shakeMenuEnabled = true
            shakeChannelSelectorEnabled = false
        }
        periodCheckDelay = Self.normalizedPeriodCheckDelaySeconds(getConfig().getInt("periodCheckDelay", 0))

        configureImplementationCallbacks()
        configureIdentityAndEndpoints(shouldClearPreviewSessionBecauseDisabled: shouldClearPreviewSessionBecauseDisabled)
        startPluginRuntime()
    }
}

extension CapacitorUpdaterPlugin {
    func configureWebViewLogging() {
        let disableJSLogging = getConfig().getBoolean("disableJSLogging", false)
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
    }

    func configureImplementationCallbacks() {
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
        implementation.setLogger(logger)
        CryptoCipher.setLogger(logger)

        if let keyId = implementation.getKeyId(), !keyId.isEmpty {
            logger.info("Public key prefix: \(keyId)")
        }
    }

    func configureIdentityAndEndpoints(shouldClearPreviewSessionBecauseDisabled: Bool) {
        self.delayUpdateUtils = DelayUpdateUtils(currentVersionNative: currentVersionNative, logger: logger)
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        implementation.appId = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        implementation.appId = config?["appId"] as? String ?? implementation.appId
        implementation.appId = getConfig().getString("appId", implementation.appId)!
        if implementation.appId == "" {
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
        restorePersistedEndpointsIfNeeded()
        if let storedDefaultChannel = UserDefaults.standard.object(forKey: defaultChannelDefaultsKey) as? String {
            implementation.defaultChannel = storedDefaultChannel
            logger.info("Loaded persisted defaultChannel from setChannel()")
        } else {
            implementation.defaultChannel = getConfig().getString("defaultChannel", "")!
        }
    }

    func restorePersistedEndpointsIfNeeded() {
        guard persistModifyUrl else {
            return
        }
        if let storedStatsUrl = UserDefaults.standard.object(forKey: statsUrlDefaultsKey) as? String {
            implementation.statsUrl = storedStatsUrl
            logger.info("Loaded persisted statsUrl")
        }
        if let storedChannelUrl = UserDefaults.standard.object(forKey: channelUrlDefaultsKey) as? String {
            implementation.channelUrl = storedChannelUrl
            logger.info("Loaded persisted channelUrl")
        }
    }

    func startPluginRuntime() {
        self.implementation.autoReset()
        let appHealthTracker = AppHealthTracker(implementation: self.implementation)
        self.appHealthTracker = appHealthTracker
        appHealthTracker.reportPreviousUncleanForegroundExit()
        appHealthTracker.startSession()
        self.wasRecentlyInstalledOrUpdated = self.checkIfRecentlyInstalledOrUpdated()
        if self.hasNativeBuildVersionChanged() {
            self.clearPreviewSessionForNativeBuildChange()
        }
        if resetWhenUpdate {
            let didResetCurrentBundle = self.resetCurrentBundleForNativeBuildChangeIfNeeded()
            self.cleanupObsoleteVersions(didResetCurrentBundle: didResetCurrentBundle)
        }
        if !self.initialLoad() {
            logger.error("unable to force reload, the plugin might fallback to the builtin version")
        }
        registerLifecycleObservers()
        self.delayUpdateUtils.checkCancelDelay(source: .killed)
        self.appMovedToForeground()
        self.checkForUpdateAfterDelay()
    }

    func registerLifecycleObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appDidReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
}
