import Foundation
import Capacitor
import Version

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private var implementation = CapacitorUpdater()
    static let autoUpdateUrlDefault = "https://capgo.app/api/auto_update"
    static let statsUrlDefault = "https://capgo.app/api/stats"
    static final let DELAY_UPDATE = "delayUpdate"
    private var autoUpdateUrl = ""
    private var statsUrl = ""
    private var currentVersionNative: Version = "0.0.0"
    private var autoUpdate = false
    private var appReadyTimeout = 10000
    private var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    private var resetWhenUpdate = true
    private var resetWhenUpdate = true
    
    override public func load() {
        do {
            currentVersionNative = try Version(Bundle.main.buildVersionNumber ?? "0.0.0")
        } catch {
            print("\(self.implementation.TAG) Cannot get version native \(currentVersionNative)")
        }
        autoDeleteFailed = getConfigValue("autoDeleteFailed") as? Bool ?? false
        autoDeletePrevious = getConfigValue("autoDeletePrevious") as? Bool ?? false
        autoUpdateUrl = getConfigValue("autoUpdateUrl") as? String ?? CapacitorUpdaterPlugin.autoUpdateUrlDefault
        autoUpdate = getConfigValue("autoUpdate") as? Bool ?? false
        appReadyTimeout = getConfigValue("appReadyTimeout") as? Int ?? 10000
        resetWhenUpdate = getConfigValue("resetWhenUpdate") as? Bool ?? true


        implementation.appId = Bundle.main.bundleIdentifier ?? ""
        implementation.notifyDownload = notifyDownload
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        if (config?["appId"] != nil) {
            implementation.appId = config?["appId"] as! String
        }
        implementation.statsUrl = getConfigValue("statsUrl") as? String ?? CapacitorUpdaterPlugin.statsUrlDefault

        if (resetWhenUpdate) {
            self.cleanupObsoleteVersions()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        self.appMovedToForeground()
    }

    private func cleanupObsoleteVersions() {
        var LatestVersionNative: Version = "0.0.0"
        do {
            LatestVersionNative = try Version(UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0.0.0")
        } catch {
            print("\(self.implementation.TAG) Cannot get version native \(currentVersionNative)")
        }
        if (LatestVersionNative != "0.0.0" && currentVersionNative.major > LatestVersionNative.major) {
            _ = self._reset(toAutoUpdate: false)
            UserDefaults.standard.set("", forKey: "LatestVersionAutoUpdate")
            UserDefaults.standard.set("", forKey: "LatestVersionNameAutoUpdate")
            let res = implementation.list()
            res.forEach { version in
                print("\(self.implementation.TAG) Deleting obsolete version: \(version)")
                _ = implementation.delete(version: version, versionName: "")
            }
        }
        UserDefaults.standard.set( Bundle.main.buildVersionNumber, forKey: "LatestVersionNative")
        this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
        this.editor.commit();
    }

    @objc func notifyDownload(percent: Int) {
        self.notifyListeners("download", data: ["percent": percent])
    }

    @objc func getId(_ call: CAPPluginCall) {
        call.resolve(["id": implementation.deviceID])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": implementation.pluginVersion])
    }
    
    @objc func download(_ call: CAPPluginCall) {
        let url = URL(string: call.getString("url") ?? "")
        let versionName: String = call.getString("versionName") ?? ""
        print("\(self.implementation.TAG) Downloading \(url)")
        do {
            let res = try implementation.download(url: url!)
            call.resolve([
                "version": res
            ])
        } catch {
            call.reject("download failed", error.localizedDescription)
        }
    }

    private func _reload() -> Bool {
        guard let bridge = self.bridge else { return false }
        print("\(self.implementation.TAG) Reloading \(path)")

        if let vc = bridge.viewController as? CAPBridgeViewController {
            let pathHot = self.implementation.getLastPathHot()
            let pathPersist = self.implementation.getCurrentBundlePath()
            if (pathHot != "" && pathPersist != "") {
                self.setCurrentBundle(path: path)
                vc.setServerBasePath(path: pathHot)
                print("\(self.implementation.TAG) Reload app done")
                self.checkAppReady()
                return true
            } else {
                return false
            }
        }
        return false
    }
    
    @objc func reload(_ call: CAPPluginCall) {
        if (self._reload()) {
            call.resolve()
        } else {
            call.reject("Cannot reload")
        }
    }

    @objc func next(_ call: CAPPluginCall) {
        letg version = call.getString("version");
        let versionName = call.getString("versionName", "");

        try {
            print("\(self.implementation.TAG) Setting next active version \(version)")
            if (!self.implementation.setNextVersion(version)) {
                call.reject("Set next version failed. Version \(version) does not exist.");
            } else {
                if(versionName != "") {
                    self.implementation.setVersionName(version, versionName);
                }
                call.resolve(self.implementation.getVersionInfo(version).toJSON());
            }
        } catch () {
            print("\(self.implementation.TAG) Could not set next version  \(version)", error.localizedDescription)
            call.reject("Could not set next version \(version)", e);
        }
    }
    
    @objc func set(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        try {
            let res = implementation.set(version: version)
            print("\(self.implementation.TAG) Set active bundle: \(version)")
            if (!res) {
                print("\(self.implementation.TAG) Bundle successfully set to: \(version) ")
                call.reject("Update failed, version \(version) doesn't exist")
            } else {
                self.reload(call)
            }
        } catch {
            print("\(self.implementation.TAG) Could not set version: \(version) \(error.localizedDescription)")
            call.reject("Could not set version " + version, error);
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.delete(version: version, versionName: "")
        if (res) {
            call.resolve()
        } else {
            call.reject("Delete failed, version \(version) doesn't exist")
        }
    }

    @objc func list(_ call: CAPPluginCall) {
        let res = implementation.list()
        call.resolve([
            "versions": res
        ])
    }

    @objc func _reset(toAutoUpdate: Bool) -> Bool {
        guard let bridge = self.bridge else { return false }
        if let vc = bridge.viewController as? CAPBridgeViewController {
            let LatestVersionAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionAutoUpdate") ?? ""
            let LatestVersionNameAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionNameAutoUpdate") ?? ""
            if(toAutoUpdate && LatestVersionAutoUpdate != "" && LatestVersionNameAutoUpdate != "") {
                let res = implementation.set(version: LatestVersionAutoUpdate, versionName: LatestVersionNameAutoUpdate)
                return res && self._reload()
            }
            implementation.reset()
            let pathPersist = implementation.getLastPathPersist()
            vc.setServerBasePath(path: pathPersist)
            UserDefaults.standard.set(pathPersist, forKey: self.implementation.CAP_SERVER_PATH)
            DispatchQueue.main.async {
                vc.loadView()
                vc.viewDidLoad()
                print("\(self.implementation.TAG) Reset to original version")
            }
            return true
        }
        return false
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toAutoUpdate = call.getBool("toAutoUpdate") ?? false
        if (self._reset(toAutoUpdate: toAutoUpdate)) {
            return call.resolve()
        }
        call.reject("\(self.implementation.TAG) Reset failed")
    }

    @objc func versionName(_ call: CAPPluginCall) {
        let name = implementation.getVersionName()
        call.resolve([
            "versionName": name
        ])
    }
    
    @objc func current(_ call: CAPPluginCall) {
        let pathHot = implementation.getLastPathHot()
        let current  = pathHot.count >= 10 ? pathHot.suffix(10) : "builtin"
        call.resolve([
            "current": current,
            "currentNative": currentVersionNative
        ])
    }

    @objc func notifyAppReady(_ call: CAPPluginCall) {
        UserDefaults.standard.set(true, forKey: "notifyAppReady")
        call.resolve()
    }
    
    @objc func delayUpdate(_ call: CAPPluginCall) {
        UserDefaults.standard.set(true, forKey: "delayUpdate")
        call.resolve()
    }
    
    @objc func cancelDelay(_ call: CAPPluginCall) {
        UserDefaults.standard.set(false, forKey: "delayUpdate")
        call.resolve()
    }

    func checkAppReady() {
        do {
            self.appReadyCheck?.cancel()
            self.appReadyCheck = DispatchWorkItem(block: {
                self.DeferredNotifyAppReadyCheck()
            })
            print("\(self.implementation.TAG) Wait for \(self.appReadyTimeout) ms, then check for notifyAppReady")
            DispatchQueue.main.asyncAfter(deadline: .now() + self.appReadyTimeout, execute: self.appReadyCheck)
        } catch {
            print("\(self.implementation.TAG) Failed to start \"DeferredNotifyAppReadyCheck\"", error.localizedDescription)
        }
    }

    func DeferredNotifyAppReadyCheck() {
            do {
                // Automatically roll back to fallback version if notifyAppReady has not been called yet
                final VersionInfo current = self.implementation.getCurrentBundle();
                if(current.isBuiltin()) {
                    print("\(self.implementation.TAG) Built-in bundle is active. Nothing to do.")
                    return
                }

                if(VersionStatus.SUCCESS != current.getStatus()) {
                    print("\(self.implementation.TAG) notifyAppReady was not called, roll back current version: \(current)")
                    self.implementation.rollback(current);
                    self._reset(true);
                } else {
                    print("\(self.implementation.TAG) notifyAppReady was called. This is fine: \(current)")
                }
                self.appReadyCheck = false;
            } catch () {
                print("\(self.implementation.TAG) DeferredNotifyAppReadyCheck was interrupted.")
            }
    }

    @objc func appMovedToForeground() {
        DispatchQueue.global(qos: .background).async {
            print("\(self.implementation.TAG) Check for update in the server")
            let url = URL(string: self.autoUpdateUrl)!
            let res = self.implementation.getLatest(url: url)
            if (res == nil) {
                return
            }
            guard let downloadUrl = URL(string: res?.url ?? "") else {
                print("\(self.implementation.TAG) Error \(res?.message ?? "Unknow error")")
                if (res?.major == true) {
                    self.notifyListeners("majorAvailable", data: ["version": res?.version ?? "0.0.0"])
                }
                return
            }
            let currentVersion = self.implementation.getVersionName()
            var failingVersion: Version = "0.0.0"
            var newVersion: Version = "0.0.0"
            do {
                newVersion = try Version(res?.version ?? "0.0.0")
                failingVersion = try Version(UserDefaults.standard.string(forKey: "failingVersion") ?? "0.0.0")
            } catch {
                print("\(self.implementation.TAG) Cannot get version \(failingVersion) \(newVersion)", error.localizedDescription)
            }
            if (newVersion != "0.0.0" && newVersion != failingVersion) {
                do {
                    let dl = try self.implementation.download(url: downloadUrl)
                    print("\(self.implementation.TAG) New version: \(newVersion) found. Current is \(currentVersion == "" ? "builtin" : currentVersion), next backgrounding will trigger update")
                    UserDefaults.standard.set(dl, forKey: "nextVersion")
                    UserDefaults.standard.set(newVersion.description, forKey: "nextVersionName")
                    self.notifyListeners("updateAvailable", data: ["version": newVersion])
                } catch {
                    print("\(self.implementation.TAG) Download version \(newVersion) fail", error.localizedDescription)
                }
            } else {
                print("\(self.implementation.TAG) No need to update, \(currentVersion) is the latest")
            }
            self.checkAppReady()
        }
    }

    @objc func appMovedToBackground() {
        print("\(self.implementation.TAG) Check for waiting update")
        let delayUpdate = UserDefaults.standard.bool(forKey: "delayUpdate")
        UserDefaults.standard.set(false, forKey: "delayUpdate")
        if (delayUpdate) {
            print("\(self.implementation.TAG) Update delayed to next backgrounding")
            return
        }
        let nextVersion = UserDefaults.standard.string(forKey: "nextVersion") ?? ""
        let nextVersionName = UserDefaults.standard.string(forKey: "nextVersionName") ?? ""
        let pastVersion = UserDefaults.standard.string(forKey: "pastVersion") ?? ""
        let pastVersionName = UserDefaults.standard.string(forKey: "pastVersionName") ?? ""
        let notifyAppReady = UserDefaults.standard.bool(forKey: "notifyAppReady")
        let curVersion = implementation.getLastPathPersist().components(separatedBy: "/").last!
        let curVersionName = implementation.getVersionName()
        if (nextVersion != "" && nextVersionName != "") {
            let res = implementation.set(version: nextVersion, versionName: nextVersionName)
            if (res && self._reload()) {
                print("\(self.implementation.TAG) Auto update to version: \(nextVersionName)")
                UserDefaults.standard.set(nextVersion, forKey: "LatestVersionAutoUpdate")
                UserDefaults.standard.set(nextVersionName, forKey: "LatestVersionNameAutoUpdate")
                UserDefaults.standard.set("", forKey: "nextVersion")
                UserDefaults.standard.set("", forKey: "nextVersionName")
                UserDefaults.standard.set(curVersion, forKey: "pastVersion")
                UserDefaults.standard.set(curVersionName, forKey: "pastVersionName")
                UserDefaults.standard.set(false, forKey: "notifyAppReady")
            } else {
                print("\(self.implementation.TAG) Auto update to version: \(nextVersionName) Failed");
            }
        } else if (!notifyAppReady && curVersionName != "") {
            print("\(self.implementation.TAG) notifyAppReady never trigger")
            print("\(self.implementation.TAG) Version: \(curVersionName), is considered broken")
            print("\(self.implementation.TAG) Will downgraded to version: \(pastVersionName == "" ? "builtin" : pastVersionName) for next start")
            print("\(self.implementation.TAG) Don't forget to trigger 'notifyAppReady()' in js code to validate a version.")
            self.notifyListeners("updateFailed", data: ["version": curVersionName])
            implementation.sendStats(action: "revert", version: curVersionName)
            if (pastVersion != "" && pastVersionName != "") {
                let res = implementation.set(version: pastVersion, versionName: pastVersionName)
                if (res && self._reload()) {
                    print("\(self.implementation.TAG) Revert to version: \(pastVersionName == "" ? "builtin" : pastVersionName)")
                    UserDefaults.standard.set(pastVersion, forKey: "LatestVersionAutoUpdate")
                    UserDefaults.standard.set(pastVersionName, forKey: "LatestVersionNameAutoUpdate")
                    UserDefaults.standard.set("", forKey: "pastVersion")
                    UserDefaults.standard.set("", forKey: "pastVersionName")
                } else {
                    print("\(self.implementation.TAG) Revert to version: \(pastVersionName == "" ? "builtin" : pastVersionName) Failed");
                }
            } else {
                if self._reset(toAutoUpdate: false) {
                    UserDefaults.standard.set("", forKey: "LatestVersionAutoUpdate")
                    UserDefaults.standard.set("", forKey: "LatestVersionNameAutoUpdate")
                    print("\(self.implementation.TAG) Auto reset done")
                }
            }
            UserDefaults.standard.set(curVersionName, forKey: "failingVersion")
            let res = implementation.delete(version: curVersion, versionName: curVersionName)
            if (res) {
                print("\(self.implementation.TAG) Delete failing version: \(curVersionName)")
            }
        } else if (pastVersion != "") {
            print("\(self.implementation.TAG) Validated version: \(curVersionName)")
            let res = implementation.delete(version: pastVersion, versionName: curVersionName)
            if (res) {
                print("\(self.implementation.TAG) Delete past version: \(pastVersionName)")
            }
            UserDefaults.standard.set("", forKey: "pastVersion")
            UserDefaults.standard.set("", forKey: "pastVersionName")
        }
    }
}
