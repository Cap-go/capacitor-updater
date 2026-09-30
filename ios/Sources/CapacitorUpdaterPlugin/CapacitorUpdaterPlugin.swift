/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit
import WebKit

/// Capacitor glue for the Capgo updater. Every updater decision runs in the
/// Rust engine (`core/src/engine/plugin`); this class registers the methods,
/// forwards calls, lifecycle notifications and events, and implements the
/// engine hooks that need the WebView or UIKit (bundle reload, splash screen,
/// loaders, preview notice, shake menu).
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin, CAPBridgedPlugin {
    lazy var logger: Logger = {
        // Tests run without a bridge: log to the OS by default.
        let osLogging = self.bridge != nil ? getConfig().getBoolean("osLogging", true) : true
        return Logger(withTag: "✨  CapgoUpdater", options: Logger.Options(useSyslog: osLogging))
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

    deinit {
        implementation.shutdown()
    }

    private let pluginVersion: String = "8.52.0"
    static let shakeMenuGestureShake = "shake"
    static let shakeMenuGestureThreeFingerPinch = "threeFingerPinch"
    /// Events kept for listeners registered after they fired.
    private static let retainedEvents: Set<String> = ["set", "appReady", "updateAvailable"]
    static let previewLoaderTimeoutMs = 60000
    let keepUrlPathFlagKey = "__capgo_keep_url_path_after_reload"
    var keepUrlPathAfterReload = false
    var keepUrlPathFlagLastValue: Bool?
    var autoSplashscreenLoader = false
    var splashscreenLoaderView: UIActivityIndicatorView?
    var splashscreenLoaderContainer: UIView?
    var previewTransitionLoaderView: UIActivityIndicatorView?
    var previewTransitionLoaderContainer: UIView?
    var previewTransitionLoaderTimeoutWorkItem: DispatchWorkItem?
    var previewTransitionLoaderRequested = false
    let splashscreenPluginName = "SplashScreen"
    let splashscreenRetryDelayMilliseconds = 100
    let splashscreenMaxRetries = 20
    var splashscreenInvocationToken = 0
    private var webViewStatsReporter: WebViewStatsReporter?
    // Mirrors of the engine's shake menu state, pushed through the `shakeMenu` hook.
    public var shakeMenuEnabled = false
    public var shakeChannelSelectorEnabled = false
    public var shakeMenuGesture = CapacitorUpdaterPlugin.shakeMenuGestureShake
    var shakeMenuPinchGestureRecognizer: ThreeFingerPinchGestureRecognizer?
    var shakeMenuPinchGestureTriggered = false

    override public func load() {
        let disableJSLogging = getConfig().getBoolean("disableJSLogging", false)
        if let webView = self.bridge?.webView, !disableJSLogging {
            logger.setWebView(webView: webView)
            logger.info("WebView set successfully for logging")
        } else {
            logger.error("Failed to get webView for logging")
        }
        let webViewStatsReporter = WebViewStatsReporter()
        self.webViewStatsReporter = webViewStatsReporter
        webViewStatsReporter.install(on: self.bridge?.webView)
        #if targetEnvironment(simulator)
        logger.info("::::: SIMULATOR :::::")
        logger.info("Application directory: \(NSHomeDirectory())")
        #endif

        autoSplashscreenLoader = getConfig().getBoolean("autoSplashscreenLoader", false)
        guard let versionName = getConfig().getString("version", Bundle.main.versionName) else {
            logger.error("Cannot get version name")
            // crash the app on purpose
            fatalError("Cannot get version name")
        }
        let descriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        var appId = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        appId = descriptor?.legacyConfig["appId"] as? String ?? appId
        implementation.appId = getConfig().getString("appId", appId) ?? appId
        implementation.deviceID = DeviceIdHelper.getOrCreateDeviceId()
        implementation.pluginVersion = pluginVersion
        implementation.versionBuild = versionName
        implementation.setLogger(logger)
        implementation.onEvent = { [weak self] event, payload in
            self?.notifyListenersOnMain(event, data: payload, retainUntilConsumed: Self.retainedEvents.contains(event))
        }
        implementation.onHook = { [weak self] name, payload in
            self?.handleEngineHook(name, payload)
        }

        var native: [String: Any] = [
            "versionName": Bundle.main.versionName ?? "",
            "versionCode": Bundle.main.versionCode ?? "0",
            "serverUrlConfigured": descriptor?.serverURL != nil,
            "noBackupDir": FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "",
            "trackUncleanExits": true
        ]
        if let launchUrl = ApplicationDelegateProxy.shared.lastURL?.absoluteString {
            native["launchUrl"] = launchUrl
        }
        let loaded: [String: Any]
        do {
            guard let engine = implementation.engine() else {
                fatalError("Capgo updater engine could not be created")
            }
            loaded = try engine.call("pluginLoad", ["config": pluginConfigJSON(), "native": native])
        } catch {
            // Missing appId or an invalid public key: the updater must not run unprotected.
            logger.error("Capgo updater failed to load: \(error)")
            fatalError("Capgo updater failed to load: \(error)")
        }
        logger.info("appId \(loaded["appId"] as? String ?? "")")

        // iOS sets the server base path during plugin init (Android uses the
        // serverBasePath preference) so a bundle is stored only once.
        if !self.initialLoad(loaded) {
            logger.error("unable to force reload, the plugin might fallback to the builtin version")
        }
        self.registerNotificationObservers()
        // The launch counts as the first foreground: runs the update check.
        self.engineOp("appForeground")
    }

    private func pluginConfigJSON() -> [String: Any] {
        let config = getConfig().getConfigJSON().mapValues { $0 as Any }
        return JSONSerialization.isValidJSONObject(config) ? config : [:]
    }

    private func registerNotificationObservers() {
        let observers: [(Selector, Notification.Name)] = [
            (#selector(appMovedToBackground), UIApplication.didEnterBackgroundNotification),
            (#selector(appMovedToForeground), UIApplication.willEnterForegroundNotification),
            (#selector(appWillTerminate), UIApplication.willTerminateNotification),
            (#selector(appDidReceiveMemoryWarning), UIApplication.didReceiveMemoryWarningNotification),
            (#selector(handleOpenURL(notification:)), Notification.Name.capacitorOpenURL),
            (#selector(handleOpenURL(notification:)), Notification.Name.capacitorOpenUniversalLink)
        ]
        for (selector, name) in observers {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
        }
    }

    @objc func appMovedToForeground() {
        engineOp("appForeground")
    }

    @objc func appMovedToBackground() {
        engineOp("appBackground")
    }

    @objc private func appWillTerminate() {
        engineOp("appTerminate")
    }

    @objc private func appDidReceiveMemoryWarning() {
        engineOp("reportMemoryWarning")
    }

    @objc private func handleOpenURL(notification: NSNotification) {
        let rawUrl = (notification.object as? [String: Any])?["url"]
        guard let url = rawUrl as? URL ?? (rawUrl as? NSURL).map({ $0 as URL }) else {
            return
        }
        engineOp("openUrl", ["url": url.absoluteString])
    }

    // MARK: - Engine calls

    /// Runs an engine operation that cannot trigger a reload (safe on any thread).
    @discardableResult
    func engineOp(_ operation: String, _ input: [String: Any?] = [:]) -> Any? {
        guard let engine = implementation.engine() else {
            return nil
        }
        do {
            return try engine.callValue(operation, input)
        } catch {
            logger.error("Engine \(operation) failed: \(error)")
            return nil
        }
    }

    enum MethodOutcome {
        case resolved(Any?)
        case rejected(message: String, code: String?, data: [String: Any]?)
    }

    /// Runs a JavaScript plugin method in the engine. Blocking, and it can reload
    /// the WebView through the `applyBundle` hook: never call it on the main thread.
    func runEngineMethod(_ name: String, _ args: [String: Any]) -> MethodOutcome {
        guard let engine = implementation.engine() else {
            return .rejected(message: "Updater engine unavailable", code: nil, data: nil)
        }
        let safeArgs = JSONSerialization.isValidJSONObject(args) ? args : [:]
        do {
            let outcome = try engine.call("pluginMethod", ["name": name, "args": safeArgs])
            if let rejection = outcome["reject"] as? [String: Any] {
                return .rejected(
                    message: rejection["message"] as? String ?? "\(name) failed",
                    code: rejection["code"] as? String,
                    data: rejection["data"] as? [String: Any]
                )
            }
            let value = outcome["resolve"]
            return .resolved(value is NSNull ? nil : value)
        } catch {
            return .rejected(message: "\(name) failed: \(error)", code: nil, data: nil)
        }
    }

    /// CAPPlugin's listener storage is not thread-safe (ionic-team/capacitor#8157), so every
    /// event this plugin emits goes through the main thread. Calls already on main stay synchronous.
    private func notifyListenersOnMain(_ eventName: String, data: [String: Any]?, retainUntilConsumed: Bool = false) {
        let notify = {
            self.notifyListeners(eventName, data: data, retainUntilConsumed: retainUntilConsumed)
        }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async(execute: notify)
        }
    }

    // MARK: - Engine hooks

    private func handleEngineHook(_ name: String, _ payload: [String: Any]) -> [String: Any]? {
        switch name {
        case "applyBundle":
            return onMainSync { self.applyBundle(payload) }
        case "previewNotice":
            return onMainSync { ["shown": self.showPreviewNotice(gesture: payload["gesture"] as? String ?? "")] }
        case "splash":
            onMainAsync {
                if payload["action"] as? String == "show" {
                    self.performShowSplashscreen()
                } else {
                    self.performHideSplashscreen()
                }
            }
        case "previewLoader":
            let reason = payload["reason"] as? String ?? ""
            if payload["action"] as? String == "show" {
                showPreviewTransitionLoader(reason: reason)
            } else {
                hidePreviewTransitionLoader(reason: reason)
            }
        case "shakeMenu":
            onMainAsync {
                self.shakeMenuEnabled = payload["enabled"] as? Bool ?? false
                self.shakeChannelSelectorEnabled = payload["channelSelector"] as? Bool ?? false
                self.shakeMenuGesture = payload["gesture"] as? String ?? Self.shakeMenuGestureShake
                self.syncShakeMenuGestureRecognizer()
            }
        case "keepUrlPath":
            let enabled = payload["enabled"] as? Bool ?? false
            onMainAsync {
                self.keepUrlPathAfterReload = enabled
            }
            syncKeepUrlPathFlag(enabled: enabled)
        default:
            break
        }
        return nil
    }

    private func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    func onMainAsync(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
