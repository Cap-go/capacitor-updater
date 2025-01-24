/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import Version

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin, CAPBridgedPlugin {
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
        CAPPluginMethod(name: "setCustomId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDeviceId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "next", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAutoUpdateEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBuiltinVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAutoUpdateAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getNextBundle", returnType: CAPPluginReturnPromise)
    ]
    public var implementation = CapacitorUpdater()
    private let PLUGIN_VERSION: String = "6.14.7"
    static let updateUrlDefault = "https://plugin.capgo.app/updates"
    static let statsUrlDefault = "https://plugin.capgo.app/stats"
    static let channelUrlDefault = "https://plugin.capgo.app/channel_self"
    let DELAY_CONDITION_PREFERENCES = ""
    private var updateUrl = ""
    private var statsUrl = ""
    private var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var currentVersionNative: Version = "0.0.0"
    private var autoUpdate = false
    private var appReadyTimeout = 10000
    private var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    private var directUpdate = false
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    private var keepUrlPathAfterReload = false
    private var backgroundWork: DispatchWorkItem?
    private var taskRunning = false
    private var periodCheckDelay = 0
    let semaphoreReady = DispatchSemaphore(value: 0)

    override public func load() {
        #if targetEnvironment(simulator)
        print("\(CapacitorUpdater.TAG) ::::: SIMULATOR :::::")
        print("\(CapacitorUpdater.TAG) Application directory: \(NSHomeDirectory())")
        #endif

        self.semaphoreUp()
        self.implementation.deviceID = (UserDefaults.standard.string(forKey: "appUUID") ?? UUID().uuidString).lowercased()
        UserDefaults.standard.set( self.implementation.deviceID, forKey: "appUUID")
        UserDefaults.standard.synchronize()
        print("\(CapacitorUpdater.TAG) init for device \(self.implementation.deviceID)")
        guard let versionName = getConfig().getString("version", Bundle.main.versionName) else {
            print("\(CapacitorUpdater.TAG) Cannot get version name")
            // crash the app
            fatalError("Cannot get version name")
        }
        do {
            currentVersionNative = try Version(versionName)
        } catch {
            print("\(CapacitorUpdater.TAG) Cannot parse versionName \(versionName)")
        }
        print("\(CapacitorUpdater.TAG) version native \(self.currentVersionNative.description)")
        implementation.versionBuild = getConfig().getString("version", Bundle.main.versionName)!
        autoDeleteFailed = getConfig().getBoolean("autoDeleteFailed", true)
        autoDeletePrevious = getConfig().getBoolean("autoDeletePrevious", true)
        keepUrlPathAfterReload = getConfig().getBoolean("keepUrlPathAfterReload", false)
        directUpdate = getConfig().getBoolean("directUpdate", false)
        updateUrl = getConfig().getString("updateUrl", CapacitorUpdaterPlugin.updateUrlDefault)!
        autoUpdate = getConfig().getBoolean("autoUpdate", true)
        appReadyTimeout = getConfig().getInt("appReadyTimeout", 10000)
        implementation.timeout = Double(getConfig().getInt("responseTimeout", 20))
        resetWhenUpdate = getConfig().getBoolean("resetWhenUpdate", true)
        let periodCheckDelayValue = getConfig().getInt("periodCheckDelay", 0)
        if periodCheckDelayValue >= 0 && periodCheckDelayValue > 600 {
            periodCheckDelay = 600
        } else {
            periodCheckDelay = periodCheckDelayValue
        }

        implementation.publicKey = getConfig().getString("publicKey", "")!
        implementation.notifyDownloadRaw = notifyDownload
        implementation.PLUGIN_VERSION = self.PLUGIN_VERSION
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        implementation.appId = config?["appId"] as? String ?? implementation.appId
        implementation.appId = getConfig().getString("appId", implementation.appId)!
        if implementation.appId == "" {
            fatalError("appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config")
        }
        print("\(CapacitorUpdater.TAG) appId \(implementation.appId)")
        implementation.statsUrl = getConfig().getString("statsUrl", CapacitorUpdaterPlugin.statsUrlDefault)!
        implementation.channelUrl = getConfig().getString("channelUrl", CapacitorUpdaterPlugin.channelUrlDefault)!
        implementation.defaultChannel = getConfig().getString("defaultChannel", "")!
        self.implementation.autoReset()

        if resetWhenUpdate {
            self.cleanupObsoleteVersions()
        }

        // Load the server
        // This is very much swift specific, android does not do that
        // In android we depend on the serverBasePath capacitor property
        // In IOS we do not. Instead during the plugin initialization we try to call setServerBasePath
        // The idea is to prevent having to store the bundle in 2 locations for hot reload and persisten storage
        // According to martin it is not possible to use serverBasePath on ios in a way that allows us to store the bundle once

        if !self.initialLoad() {
            print("\(CapacitorUpdater.TAG) unable to force reload, the plugin might fallback to the builtin version")
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appKilled), name: UIApplication.willTerminateNotification, object: nil)
        self.appMovedToForeground()
        self.checkForUpdateAfterDelay()
    }

    private func initialLoad() -> Bool {
        guard let bridge = self.bridge else { return false }

        let id = self.implementation.getCurrentBundleId()
        var dest: URL
        if BundleInfo.ID_BUILTIN == id {
            dest = Bundle.main.resourceURL!.appendingPathComponent("public")
        } else {
            dest = self.implementation.getBundleDirectory(id: id)
        }

        if !FileManager.default.fileExists(atPath: dest.path) {
            print("\(CapacitorUpdater.TAG) Initial load fail - file at path \(dest.path) doesn't exist. Defaulting to buildin!! \(id)")
            dest = Bundle.main.resourceURL!.appendingPathComponent("public")
        }

        print("\(CapacitorUpdater.TAG) Initial load \(id)")
        // We don't use the viewcontroller here as it does not work during the initial load state
        bridge.setServerBasePath(dest.path)
        return true
    }

    private func semaphoreWait(waitTime: Int) {
        print("\(CapacitorUpdater.TAG) semaphoreWait \(waitTime)")
        _ = semaphoreReady.wait(timeout: .now() + .milliseconds(waitTime))
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
        var LatestVersionNative: Version = "0.0.0"
        do {
            LatestVersionNative = try Version(UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0.0.0")
        } catch {
            print("\(CapacitorUpdater.TAG) Cannot get version native \(currentVersionNative)")
        }
        if LatestVersionNative != "0.0.0" && self.currentVersionNative.description != LatestVersionNative.description {
            _ = self._reset(toLastSuccessful: false)
            let res = implementation.list()
            res.forEach { version in
                print("\(CapacitorUpdater.TAG) Deleting obsolete bundle: \(version.getId())")
                let res = implementation.delete(id: version.getId())
                if !res {
                    print("\(CapacitorUpdater.TAG) Delete failed, id \(version.getId()) doesn't exist")
                }
            }
        }
        UserDefaults.standard.set( self.currentVersionNative.description, forKey: "LatestVersionNative")
        UserDefaults.standard.synchronize()
    }

    @objc func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false) {
        let bundle = self.implementation.getBundleInfo(id: id)
        self.notifyListeners("download", data: ["percent": percent, "bundle": bundle.toJSON()])
        if percent == 100 {
            self.notifyListeners("downloadComplete", data: ["bundle": bundle.toJSON()])
            self.implementation.sendStats(action: "download_complete", versionName: bundle.getVersionName())
        } else if percent.isMultiple(of: 10) || ignoreMultipleOfTen {
            self.implementation.sendStats(action: "download_\(percent)", versionName: bundle.getVersionName())
        }
    }

    @objc func setUpdateUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            print("\(CapacitorUpdater.TAG) setUpdateUrl called without allowModifyUrl")
            call.reject("setUpdateUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            print("\(CapacitorUpdater.TAG) setUpdateUrl called without url")
            call.reject("setUpdateUrl called without url")
            return
        }
        self.updateUrl = url
        call.resolve()
    }

    @objc func setStatsUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            print("\(CapacitorUpdater.TAG) setStatsUrl called without allowModifyUrl")
            call.reject("setStatsUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            print("\(CapacitorUpdater.TAG) setStatsUrl called without url")
            call.reject("setStatsUrl called without url")
            return
        }
        self.statsUrl = url
        call.resolve()
    }

    @objc func setChannelUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            print("\(CapacitorUpdater.TAG) setChannelUrl called without allowModifyUrl")
            call.reject("setChannelUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            print("\(CapacitorUpdater.TAG) setChannelUrl called without url")
            call.reject("setChannelUrl called without url")
            return
        }
        self.implementation.channelUrl = url
        call.resolve()
    }

    @objc func getBuiltinVersion(_ call: CAPPluginCall) {
        call.resolve(["version": implementation.versionBuild])
    }

    @objc func getDeviceId(_ call: CAPPluginCall) {
        call.resolve(["deviceId": implementation.deviceID])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.PLUGIN_VERSION])
    }

    @objc func download(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url") else {
            print("\(CapacitorUpdater.TAG) Download called without url")
            call.reject("Download called without url")
            return
        }
        guard let version = call.getString("version") else {
            print("\(CapacitorUpdater.TAG) Download called without version")
            call.reject("Download called without version")
            return
        }

        let sessionKey = call.getString("sessionKey", "")
        var checksum = call.getString("checksum", "")
        let url = URL(string: urlString)
        print("\(CapacitorUpdater.TAG) Downloading \(String(describing: url))")
        DispatchQueue.global(qos: .background).async {
            do {
                let next = try self.implementation.download(url: url!, version: version, sessionKey: sessionKey)
                do {
                    checksum = try CryptoCipher.decryptChecksum(checksum: checksum, publicKey: self.implementation.publicKey, version: version)
                } catch {
                    self.implementation.sendStats(action: "decrypt_fail", versionName: version)
                    throw error
                }
                if (checksum != "" || self.implementation.publicKey != "") && next.getChecksum() != checksum {
                    print("\(CapacitorUpdater.TAG) Error checksum", next.getChecksum(), checksum)
                    self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
                    let id = next.getId()
                    let resDel = self.implementation.delete(id: id)
                    if !resDel {
                        print("\(CapacitorUpdater.TAG) Delete failed, id \(id) doesn't exist")
                    }
                    throw ObjectSavableError.checksum
                } else {
                    print("\(CapacitorUpdater.TAG) Good checksum", next.getChecksum(), checksum)
                }
                self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
                call.resolve(next.toJSON())
            } catch {
                print("\(CapacitorUpdater.TAG) Failed to download from: \(String(describing: url)) \(error.localizedDescription)")
                self.notifyListeners("downloadFailed", data: ["version": version])
                self.implementation.sendStats(action: "download_fail")
                call.reject("Failed to download from: \(url!)", error.localizedDescription)
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
        print("\(CapacitorUpdater.TAG) Reloading \(id)")
        if let vc = bridge.viewController as? CAPBridgeViewController {
            guard let capBridge = vc.bridge else {
                print("\(CapacitorUpdater.TAG) Cannot get capBridge")
                return false
            }
            if keepUrlPathAfterReload {
                DispatchQueue.main.async {
                    guard let url = vc.webView?.url else {
                        print("\(CapacitorUpdater.TAG) vc.webView?.url is null?")
                        return
                    }
                    capBridge.setServerBasePath(dest.path)
                    var urlComponents = URLComponents(url: capBridge.config.serverURL, resolvingAgainstBaseURL: false)!
                    urlComponents.path = url.path
                    if let finalUrl = urlComponents.url {
                        _ = vc.webView?.load(URLRequest(url: finalUrl))
                        vc.webView?.backForwardList.perform(Selector(("_removeAllItems")))
                    }
                }
            } else {
                vc.setServerBasePath(path: dest.path)

            }

            self.checkAppReady()
            self.notifyListeners("appReloaded", data: [:])
            return true
        }
        return false
    }

    @objc func reload(_ call: CAPPluginCall) {
        if self._reload() {
            call.resolve()
        } else {
            print("\(CapacitorUpdater.TAG) Reload failed")
            call.reject("Reload failed")
        }
    }

    @objc func next(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(CapacitorUpdater.TAG) Next called without id")
            call.reject("Next called without id")
            return
        }
        print("\(CapacitorUpdater.TAG) Setting next active id \(id)")
        if !self.implementation.setNextBundle(next: id) {
            print("\(CapacitorUpdater.TAG) Set next version failed. id \(id) does not exist.")
            call.reject("Set next version failed. id \(id) does not exist.")
        } else {
            call.resolve(self.implementation.getBundleInfo(id: id).toJSON())
        }
    }

    @objc func set(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(CapacitorUpdater.TAG) Set called without id")
            call.reject("Set called without id")
            return
        }
        let res = implementation.set(id: id)
        print("\(CapacitorUpdater.TAG) Set active bundle: \(id)")
        if !res {
            print("\(CapacitorUpdater.TAG) Bundle successfully set to: \(id) ")
            call.reject("Update failed, id \(id) doesn't exist")
        } else {
            self.reload(call)
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(CapacitorUpdater.TAG) Delete called without version")
            call.reject("Delete called without id")
            return
        }
        let res = implementation.delete(id: id)
        if res {
            call.resolve()
        } else {
            print("\(CapacitorUpdater.TAG) Delete failed, id \(id) doesn't exist or it cannot be deleted (perhaps it is the 'next' bundle)")
            call.reject("Delete failed, id \(id) does not exist or it cannot be deleted (perhaps it is the 'next' bundle)")
        }
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
            let res = self.implementation.unsetChannel()
            if res.error != "" {
                call.reject(res.error)
            } else {
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
                    print("\(CapacitorUpdater.TAG) Calling autoupdater after channel change!")
                    self.backgroundDownload()
                }
                call.resolve(res.toDict())
            }
        }
    }

    @objc func setChannel(_ call: CAPPluginCall) {
        guard let channel = call.getString("channel") else {
            print("\(CapacitorUpdater.TAG) setChannel called without channel")
            call.reject("setChannel called without channel")
            return
        }
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate") ?? false
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.setChannel(channel: channel)
            if res.error != "" {
                call.reject(res.error)
            } else {
                if self._isAutoUpdateEnabled() && triggerAutoUpdate {
                    print("\(CapacitorUpdater.TAG) Calling autoupdater after channel change!")
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
                call.reject(res.error)
            } else {
                call.resolve(res.toDict())
            }
        }
    }
    @objc func setCustomId(_ call: CAPPluginCall) {
        guard let customId = call.getString("customId") else {
            print("\(CapacitorUpdater.TAG) setCustomId called without customId")
            call.reject("setCustomId called without customId")
            return
        }
        self.implementation.customId = customId
    }

    @objc func _reset(toLastSuccessful: Bool) -> Bool {
        guard let bridge = self.bridge else { return false }

        if (bridge.viewController as? CAPBridgeViewController) != nil {
            let fallback: BundleInfo = self.implementation.getFallbackBundle()

            // If developer wants to reset to the last successful bundle, and that bundle is not
            // the built-in bundle, set it as the bundle to use and reload.
            if toLastSuccessful && !fallback.isBuiltin() {
                print("\(CapacitorUpdater.TAG) Resetting to: \(fallback.toString())")
                return self.implementation.set(bundle: fallback) && self._reload()
            }

            print("\(CapacitorUpdater.TAG) Resetting to builtin version")

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
            print("\(CapacitorUpdater.TAG) Reset failed")
            call.reject("\(CapacitorUpdater.TAG) Reset failed")
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
        print("\(CapacitorUpdater.TAG) Current bundle loaded successfully. ['notifyAppReady()' was called] \(bundle.toString())")
        call.resolve(["bundle": bundle.toJSON()])
    }

    @objc func setMultiDelay(_ call: CAPPluginCall) {
        guard let delayConditionList = call.getValue("delayConditions") else {
            print("\(CapacitorUpdater.TAG) setMultiDelay called without delayCondition")
            call.reject("setMultiDelay called without delayCondition")
            return
        }
        let delayConditions: String = toJson(object: delayConditionList)
        if _setMultiDelay(delayConditions: delayConditions) {
            call.resolve()
        } else {
            call.reject("Failed to delay update")
        }
    }

    private func _setMultiDelay(delayConditions: String?) -> Bool {
        if delayConditions != nil && "" != delayConditions {
            UserDefaults.standard.set(delayConditions, forKey: DELAY_CONDITION_PREFERENCES)
            UserDefaults.standard.synchronize()
            print("\(CapacitorUpdater.TAG) Delay update saved.")
            return true
        } else {
            print("\(CapacitorUpdater.TAG) Failed to delay update, [Error calling '_setMultiDelay()']")
            return false
        }
    }

    private func _cancelDelay(source: String) {
        print("\(CapacitorUpdater.TAG) delay Canceled from \(source)")
        UserDefaults.standard.removeObject(forKey: DELAY_CONDITION_PREFERENCES)
        UserDefaults.standard.synchronize()
    }

    @objc func cancelDelay(_ call: CAPPluginCall) {
        self._cancelDelay(source: "JS")
        call.resolve()
    }

    private func _checkCancelDelay(killed: Bool) {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
            let kind: String = obj.value(forKey: "kind") as! String
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
        for condition in delayConditionList {
            let kind: String? = condition.getKind()
            let value: String? = condition.getValue()
            if kind != nil {
                switch kind {
                case "background":
                    if !killed {
                        self._cancelDelay(source: "background check")
                    }
                case "kill":
                    if killed {
                        self._cancelDelay(source: "kill check")
                        // instant install for kill action
                        self.installNext()
                    }
                case "date":
                    if value != nil && value != "" {
                        let dateFormatter = ISO8601DateFormatter()
                        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        guard let ExpireDate = dateFormatter.date(from: value!) else {
                            self._cancelDelay(source: "date parsing issue")
                            return
                        }
                        if ExpireDate < Date() {
                            self._cancelDelay(source: "date expired")
                        }
                    } else {
                        self._cancelDelay(source: "delayVal absent")
                    }
                case "nativeVersion":
                    if value != nil && value != "" {
                        do {
                            let versionLimit = try Version(value!)
                            if self.currentVersionNative >= versionLimit {
                                self._cancelDelay(source: "nativeVersion above limit")
                            }
                        } catch {
                            self._cancelDelay(source: "nativeVersion parsing issue")
                        }
                    } else {
                        self._cancelDelay(source: "delayVal absent")
                    }
                case .none:
                    print("\(CapacitorUpdater.TAG) _checkCancelDelay switch case none error")
                case .some:
                    print("\(CapacitorUpdater.TAG) _checkCancelDelay switch case some error")
                }
            }
        }
        // self.checkAppReady() why this here?
    }

    private func _isAutoUpdateEnabled() -> Bool {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        if instanceDescriptor?.serverURL != nil {
            print("⚠️ \(CapacitorUpdater.TAG) AutoUpdate is automatic disabled when serverUrl is set.")
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
        print("\(CapacitorUpdater.TAG) Wait for \(self.appReadyTimeout) ms, then check for notifyAppReady")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.appReadyTimeout), execute: self.appReadyCheck!)
    }

    func checkRevert() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        let current: BundleInfo = self.implementation.getCurrentBundle()
        if current.isBuiltin() {
            print("\(CapacitorUpdater.TAG) Built-in bundle is active. We skip the check for notifyAppReady.")
            return
        }

        print("\(CapacitorUpdater.TAG) Current bundle is: \(current.toString())")

        if BundleStatus.SUCCESS.localizedString != current.getStatus() {
            print("\(CapacitorUpdater.TAG) notifyAppReady was not called, roll back current bundle: \(current.toString())")
            print("\(CapacitorUpdater.TAG) Did you forget to call 'notifyAppReady()' in your Capacitor App code?")
            self.notifyListeners("updateFailed", data: [
                "bundle": current.toJSON()
            ])
            self.implementation.sendStats(action: "update_fail", versionName: current.getVersionName())
            self.implementation.setError(bundle: current)
            _ = self._reset(toLastSuccessful: true)
            if self.autoDeleteFailed && !current.isBuiltin() {
                print("\(CapacitorUpdater.TAG) Deleting failing bundle: \(current.toString())")
                let res = self.implementation.delete(id: current.getId(), removeInfo: false)
                if !res {
                    print("\(CapacitorUpdater.TAG) Delete version deleted: \(current.toString())")
                } else {
                    print("\(CapacitorUpdater.TAG) Failed to delete failed bundle: \(current.toString())")
                }
            }
        } else {
            print("\(CapacitorUpdater.TAG) notifyAppReady was called. This is fine: \(current.toString())")
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
        print("\(CapacitorUpdater.TAG) sendReadyToJs")
        DispatchQueue.global().async {
            self.semaphoreWait(waitTime: self.appReadyTimeout)
            self.notifyListeners("appReady", data: ["bundle": current.toJSON(), "status": msg])
        }
    }

    func endBackGroundTaskWithNotif(msg: String, latestVersionName: String, current: BundleInfo, error: Bool = true) {
        if error {
            self.implementation.sendStats(action: "download_fail", versionName: current.getVersionName())
            self.notifyListeners("downloadFailed", data: ["version": latestVersionName])
        }
        self.notifyListeners("noNeedUpdate", data: ["bundle": current.toJSON()])
        self.sendReadyToJs(current: current, msg: msg)
        print("\(CapacitorUpdater.TAG) endBackGroundTaskWithNotif \(msg) current: \(current.getVersionName()) latestVersionName: \(latestVersionName)")
        self.endBackGroundTask()
    }

    func backgroundDownload() {
        let messageUpdate = self.directUpdate ? "Update will occur now." : "Update will occur next time app moves to background."
        guard let url = URL(string: self.updateUrl) else {
            print("\(CapacitorUpdater.TAG) Error no url or wrong format")
            return
        }
        DispatchQueue.global(qos: .background).async {
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Download Tasks") {
                // End the task if time expires.
                self.endBackGroundTask()
            }
            print("\(CapacitorUpdater.TAG) Check for update via \(self.updateUrl)")
            let res = self.implementation.getLatest(url: url, channel: nil)
            let current = self.implementation.getCurrentBundle()

            if (res.message) != nil {
                print("\(CapacitorUpdater.TAG) API message: \(res.message ?? "")")
                if res.major == true {
                    self.notifyListeners("majorAvailable", data: ["version": res.version])
                }
                self.endBackGroundTaskWithNotif(msg: res.message ?? "", latestVersionName: res.version, current: current, error: true)
                return
            }
            if res.version == "builtin" {
                print("\(CapacitorUpdater.TAG) Latest version is builtin")
                if self.directUpdate {
                    print("\(CapacitorUpdater.TAG) Direct update to builtin version")
                    _ = self._reset(toLastSuccessful: false)
                    self.endBackGroundTaskWithNotif(msg: "Updated to builtin version", latestVersionName: res.version, current: self.implementation.getCurrentBundle(), error: false)
                } else {
                    print("\(CapacitorUpdater.TAG) Setting next bundle to builtin")
                    _ = self.implementation.setNextBundle(next: BundleInfo.ID_BUILTIN)
                    self.endBackGroundTaskWithNotif(msg: "Next update will be to builtin version", latestVersionName: res.version, current: current, error: false)
                }
                return
            }
            let sessionKey = res.sessionKey ?? ""
            guard let downloadUrl = URL(string: res.url) else {
                print("\(CapacitorUpdater.TAG) Error no url or wrong format")
                self.endBackGroundTaskWithNotif(msg: "Error no url or wrong format", latestVersionName: res.version, current: current)
                return
            }
            let latestVersionName = res.version
            if latestVersionName != "" && current.getVersionName() != latestVersionName {
                do {
                    print("\(CapacitorUpdater.TAG) New bundle: \(latestVersionName) found. Current is: \(current.getVersionName()). \(messageUpdate)")
                    var nextImpl = self.implementation.getBundleInfoByVersionName(version: latestVersionName)
                    if nextImpl == nil || nextImpl?.isDeleted() == true {
                        if nextImpl?.isDeleted() == true {
                            print("\(CapacitorUpdater.TAG) Latest bundle already exists and will be deleted, download will overwrite it.")
                            let res = self.implementation.delete(id: nextImpl!.getId(), removeInfo: true)
                            if res {
                                print("\(CapacitorUpdater.TAG) Failed bundle deleted: \(nextImpl!.toString())")
                            } else {
                                print("\(CapacitorUpdater.TAG) Failed to delete failed bundle: \(nextImpl!.toString())")
                            }
                        }
                        if res.manifest != nil {
                            nextImpl = try self.implementation.downloadManifest(manifest: res.manifest!, version: latestVersionName, sessionKey: sessionKey)
                        } else {
                            nextImpl = try self.implementation.download(url: downloadUrl, version: latestVersionName, sessionKey: sessionKey)
                        }
                    }
                    guard let next = nextImpl else {
                        print("\(CapacitorUpdater.TAG) Error downloading file")
                        self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    if next.isErrorStatus() {
                        print("\(CapacitorUpdater.TAG) Latest bundle already exists and is in error state. Aborting update.")
                        self.endBackGroundTaskWithNotif(msg: "Latest version is in error state. Aborting update.", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    do {
                        res.checksum = try CryptoCipher.decryptChecksum(checksum: res.checksum, publicKey: self.implementation.publicKey, version: latestVersionName)
                    } catch {
                        self.implementation.sendStats(action: "decrypt_fail", versionName: latestVersionName)
                        throw error
                    }
                    if res.checksum != "" && next.getChecksum() != res.checksum && res.manifest == nil {
                        print("\(CapacitorUpdater.TAG) Error checksum", next.getChecksum(), res.checksum)
                        self.implementation.sendStats(action: "checksum_fail", versionName: next.getVersionName())
                        let id = next.getId()
                        let resDel = self.implementation.delete(id: id)
                        if !resDel {
                            print("\(CapacitorUpdater.TAG) Delete failed, id \(id) doesn't exist")
                        }
                        self.endBackGroundTaskWithNotif(msg: "Error checksum", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    if self.directUpdate {
                        _ = self.implementation.set(bundle: next)
                        _ = self._reload()
                        self.directUpdate = false
                        self.endBackGroundTaskWithNotif(msg: "update installed", latestVersionName: latestVersionName, current: current, error: false)
                    } else {
                        self.notifyListeners("updateAvailable", data: ["bundle": next.toJSON()])
                        _ = self.implementation.setNextBundle(next: next.getId())
                        self.endBackGroundTaskWithNotif(msg: "update downloaded, will install next background", latestVersionName: latestVersionName, current: current, error: false)
                    }
                    return
                } catch {
                    print("\(CapacitorUpdater.TAG) Error downloading file", error.localizedDescription)
                    let current: BundleInfo = self.implementation.getCurrentBundle()
                    self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
                    return
                }
            } else {
                print("\(CapacitorUpdater.TAG) No need to update, \(current.getId()) is the latest bundle.")
                self.endBackGroundTaskWithNotif(msg: "No need to update, \(current.getId()) is the latest bundle.", latestVersionName: latestVersionName, current: current, error: false)
                return
            }
        }
    }

    @objc func appKilled() {
        print("\(CapacitorUpdater.TAG) onActivityDestroyed: all activity destroyed")
        self._checkCancelDelay(killed: true)
    }

    private func installNext() {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition]? = fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
            let kind: String = obj.value(forKey: "kind") as! String
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
        if delayConditionList != nil && delayConditionList?.capacity != 0 {
            print("\(CapacitorUpdater.TAG) Update delayed until delay conditions met")
            return
        }
        let current: BundleInfo = self.implementation.getCurrentBundle()
        let next: BundleInfo? = self.implementation.getNextBundle()

        if next != nil && !next!.isErrorStatus() && next!.getVersionName() != current.getVersionName() {
            print("\(CapacitorUpdater.TAG) Next bundle is: \(next!.toString())")
            if self.implementation.set(bundle: next!) && self._reload() {
                print("\(CapacitorUpdater.TAG) Updated to bundle: \(next!.toString())")
                _ = self.implementation.setNextBundle(next: Optional<String>.none)
            } else {
                print("\(CapacitorUpdater.TAG) Update to bundle: \(next!.toString()) Failed!")
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
        if backgroundWork != nil && taskRunning {
            backgroundWork!.cancel()
            print("\(CapacitorUpdater.TAG) Background Timer Task canceled, Activity resumed before timer completes")
        }
        if self._isAutoUpdateEnabled() {
            self.backgroundDownload()
        } else {
            print("\(CapacitorUpdater.TAG) Auto update is disabled")
            self.sendReadyToJs(current: current, msg: "disabled")
        }
        self.checkAppReady()
    }

    @objc func checkForUpdateAfterDelay() {
        if periodCheckDelay == 0 || !self._isAutoUpdateEnabled() {
            return
        }
        guard let url = URL(string: self.updateUrl) else {
            print("\(CapacitorUpdater.TAG) Error no url or wrong format")
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(periodCheckDelay), repeats: true) { _ in
            DispatchQueue.global(qos: .background).async {
                let res = self.implementation.getLatest(url: url, channel: nil)
                let current = self.implementation.getCurrentBundle()

                if res.version != current.getVersionName() {
                    print("\(CapacitorUpdater.TAG) New version found: \(res.version)")
                    self.backgroundDownload()
                }
            }
        }
        RunLoop.current.add(timer, forMode: .default)
    }

    @objc func appMovedToBackground() {
        self.implementation.sendStats(action: "app_moved_to_background")
        print("\(CapacitorUpdater.TAG) Check for pending update")
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DELAY_CONDITION_PREFERENCES) ?? "[]"

        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
            let kind: String = obj.value(forKey: "kind") as! String
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }
        var backgroundValue: String?
        for delayCondition in delayConditionList {
            if delayCondition.getKind() == "background" {
                let value: String? = delayCondition.getValue()
                backgroundValue = (value != nil && value != "") ? value! : "0"
            }
        }
        if backgroundValue != nil {
            self.taskRunning = true
            let interval: Double = (Double(backgroundValue!) ?? 0.0) / 1000
            self.backgroundWork?.cancel()
            self.backgroundWork = DispatchWorkItem(block: {
                // IOS never executes this task in background
                self.taskRunning = false
                self._checkCancelDelay(killed: false)
                self.installNext()
            })
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + interval, execute: self.backgroundWork!)
        } else {
            self._checkCancelDelay(killed: false)
            self.installNext()
        }

    }

    @objc func getNextBundle(_ call: CAPPluginCall) {
        let bundle = self.implementation.getNextBundle()
        if bundle == nil || bundle?.isUnknown() == true {
            call.resolve()
            return
        }

        call.resolve(bundle!.toJSON())
    }
}
