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
    private var autoUpdateUrl = ""
    private var autoUpdate = false
    private var statsUrl = ""
    private var disableAutoUpdateUnderNative = false;
    private var disableAutoUpdateToMajor = false;
    private var resetWhenUpdate = false;
    
    override public func load() {
        autoUpdateUrl = getConfigValue("autoUpdateUrl") as? String ?? autoUpdateUrlDefault
        autoUpdate = getConfigValue("autoUpdate") as? Bool ?? false
        implementation.appId = Bundle.main.bundleIdentifier ?? ""
        implementation.notifyDownload = notifyDownload
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        if (config?["appId"] != nil) {
            implementation.appId = config?["appId"] as! String
        }
        implementation.statsUrl = getConfigValue("statsUrl") as? String ?? statsUrlDefault
        if (!autoUpdate || autoUpdateUrl == "") { return }
        disableAutoUpdateUnderNative = getConfigValue("disableAutoUpdateUnderNative") as? Bool ?? false
        disableAutoUpdateToMajor = getConfigValue("disableAutoUpdateBreaking") as? Bool ?? false
        resetWhenUpdate = getConfigValue("resetWhenUpdate") as? Bool ?? false
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        if (resetWhenUpdate) {
            var LatestVersionNative: Version = "0.0.0"
            var currentVersionNative: Version = "0.0.0"
            do {
                currentVersionNative = try Version(Bundle.main.buildVersionNumber ?? "0.0.0")
                LatestVersionNative = try Version(UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0.0.0")
            } catch {
                print("✨  Capacitor-updater: Cannot get version native \(currentVersionNative)")
            }
            if (LatestVersionNative != "0.0.0" && currentVersionNative.major > LatestVersionNative.major) {
                _ = self._reset(toAutoUpdate: false)
                UserDefaults.standard.set("", forKey: "LatestVersionAutoUpdate")
                UserDefaults.standard.set("", forKey: "LatestVersionNameAutoUpdate")
                let res = implementation.list()
                res.forEach { version in
                    implementation.delete(version: version, versionName: "")
                }
            }
            UserDefaults.standard.set( Bundle.main.buildVersionNumber, forKey: "LatestVersionNative")
        }
        self.appMovedToForeground()
    }
    
    @objc func notifyDownload(percent: Int) {
        self.notifyListeners("download", data: ["percent": percent])
    }

    @objc func getId(_ call: CAPPluginCall) {
        call.resolve(["id": implementation.deviceID])
    }
    
    @objc func download(_ call: CAPPluginCall) {
        let url = URL(string: call.getString("url") ?? "")
        let res = implementation.download(url: url!)
        if ((res) != nil) {
            call.resolve([
                "version": res!
            ])
        } else {
            call.reject("download failed")
        }
    }

    private func _reload() -> Bool {
        guard let bridge = self.bridge else { return false }

        if let vc = bridge.viewController as? CAPBridgeViewController {
            let pathHot = implementation.getLastPathHot()
            let pathPersist = implementation.getLastPathPersist()
            if (pathHot != "" && pathPersist != "") {
                UserDefaults.standard.set(String(pathPersist.suffix(10)), forKey: "serverBasePath")
                vc.setServerBasePath(path: pathHot)
                print("✨  Capacitor-updater: Reload app done")
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
    
    @objc func set(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let versionName = call.getString("versionName") ?? version
        let res = implementation.set(version: version, versionName: versionName)
        
        if (res && self._reload()) {
            print("✨  Capacitor-updater: Set to version: \(version) versionName: \(versionName)")
            call.resolve()
        } else {
            call.reject("Update failed, version \(version) doesn't exist")
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
            UserDefaults.standard.set(pathPersist, forKey: "serverBasePath")
            DispatchQueue.main.async {
                vc.loadView()
                vc.viewDidLoad()
                print("✨  Capacitor-updater: Reset to original version")
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
        call.reject("✨  Capacitor-updater: Reset failed")
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
        let currentVersionNative = Bundle.main.buildVersionNumber ?? "0.0.0"
        call.resolve([
            "current": current
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

    @objc func appMovedToForeground() {
        DispatchQueue.global(qos: .background).async {
            print("✨  Capacitor-updater: Check for update in the server")
            let url = URL(string: self.autoUpdateUrl)!
            let res = self.implementation.getLatest(url: url)
            if (res == nil) {
                return
            }
            guard let downloadUrl = URL(string: res?.url ?? "") else {
                return
            }
            let currentVersion = self.implementation.getVersionName()
            var failingVersion: Version = "0.0.0"
            var currentVersionForCompare: Version = "0.0.0"
            var newVersion: Version = "0.0.0"
            var currentVersionNative: Version = "0.0.0"
            do {
                currentVersionForCompare = try Version(currentVersion == "" ? "0.0.0" : currentVersion)
                newVersion = try Version(res?.version ?? "0.0.0")
                currentVersionNative = try Version(Bundle.main.buildVersionNumber ?? "0.0.0")
                failingVersion = try Version(UserDefaults.standard.string(forKey: "failingVersion") ?? "0.0.0")
            } catch {
                print("✨  Capacitor-updater: Cannot get version \(failingVersion) \(currentVersionForCompare) \(newVersion) \(currentVersionNative)")
            }
            if (self.disableAutoUpdateUnderNative && newVersion < currentVersionNative) {
                print("✨  Capacitor-updater: Cannot download revert, \(newVersion) is lest than native version \(currentVersionNative)")
            }
            else if (self.disableAutoUpdateToMajor && newVersion.major > currentVersionNative.major) {
                print("✨  Capacitor-updater: Cannot download Major, \(newVersion) is Breaking change from \(currentVersion)")
                self.notifyListeners("majorAvailable", data: ["version": newVersion])
            }
            else if (newVersion != "0.0.0" && newVersion != currentVersionForCompare && newVersion != failingVersion) {
                let dlOp = self.implementation.download(url: downloadUrl)
                if let dl = dlOp {
                    print("✨  Capacitor-updater: New version: \(newVersion) found. Current is \(currentVersion == "" ? "builtin" : currentVersion), next backgrounding will trigger update")
                    UserDefaults.standard.set(dl, forKey: "nextVersion")
                    UserDefaults.standard.set(newVersion.description, forKey: "nextVersionName")
                    self.notifyListeners("updateAvailable", data: ["version": newVersion])
                } else {
                    print("✨  Capacitor-updater: Download version \(newVersion) fail")
                }
            } else {
                print("✨  Capacitor-updater: No need to update, \(currentVersion) is the latest")
            }
        }
    }

    @objc func appMovedToBackground() {
        print("✨  Capacitor-updater: Check for waiting update")
        let delayUpdate = UserDefaults.standard.bool(forKey: "delayUpdate")
        UserDefaults.standard.set(false, forKey: "delayUpdate")
        if (delayUpdate) {
            print("✨  Capacitor-updater: Update delayed to next backgrounding")
            return
        }
        let nextVersion = UserDefaults.standard.string(forKey: "nextVersion") ?? ""
        let nextVersionName = UserDefaults.standard.string(forKey: "nextVersionName") ?? ""
        let pastVersion = UserDefaults.standard.string(forKey: "pastVersion") ?? ""
        let pastVersionName = UserDefaults.standard.string(forKey: "pastVersionName") ?? ""
        let notifyAppReady = UserDefaults.standard.bool(forKey: "notifyAppReady")
        let curVersion = implementation.getLastPathPersist().components(separatedBy: "/").last!
        let curVersionName = implementation.getVersionName()
        print("✨  Capacitor-updater: Next version: \(nextVersionName), past version: \(pastVersionName == "" ? "builtin" : pastVersionName)");
        if (nextVersion != "" && nextVersionName != "") {
            let res = implementation.set(version: nextVersion, versionName: nextVersionName)
            if (res && self._reload()) {
                print("✨  Capacitor-updater: Auto update to version: \(nextVersionName)")
                UserDefaults.standard.set(nextVersion, forKey: "LatestVersionAutoUpdate")
                UserDefaults.standard.set(nextVersionName, forKey: "LatestVersionNameAutoUpdate")
                UserDefaults.standard.set("", forKey: "nextVersion")
                UserDefaults.standard.set("", forKey: "nextVersionName")
                UserDefaults.standard.set(curVersion, forKey: "pastVersion")
                UserDefaults.standard.set(curVersionName, forKey: "pastVersionName")
                UserDefaults.standard.set(false, forKey: "notifyAppReady")
            } else {
                print("✨  Capacitor-updater: Auto update to version: \(nextVersionName) Failed");
            }
        } else if (!notifyAppReady && curVersionName != "") {
            print("✨  Capacitor-updater: notifyAppReady never trigger")
            print("✨  Capacitor-updater: Version: \(curVersionName), is considered broken")
            print("✨  Capacitor-updater: Will downgraded to version: \(pastVersionName == "" ? "builtin" : pastVersionName) for next start")
            print("✨  Capacitor-updater: Don't forget to trigger 'notifyAppReady()' in js code to validate a version.")
            implementation.sendStats(action: "revert", version: curVersionName)
            if (pastVersion != "" && pastVersionName != "") {
                let res = implementation.set(version: pastVersion, versionName: pastVersionName)
                if (res && self._reload()) {
                    print("✨  Capacitor-updater: Revert to version: \(pastVersionName == "" ? "builtin" : pastVersionName)")
                    UserDefaults.standard.set(pastVersion, forKey: "LatestVersionAutoUpdate")
                    UserDefaults.standard.set(pastVersionName, forKey: "LatestVersionNameAutoUpdate")
                    UserDefaults.standard.set("", forKey: "pastVersion")
                    UserDefaults.standard.set("", forKey: "pastVersionName")
                } else {
                    print("✨  Capacitor-updater: Revert to version: \(pastVersionName == "" ? "builtin" : pastVersionName) Failed");
                }
            } else {
                if self._reset(toAutoUpdate: false) {
                    UserDefaults.standard.set("", forKey: "LatestVersionAutoUpdate")
                    UserDefaults.standard.set("", forKey: "LatestVersionNameAutoUpdate")
                    print("✨  Capacitor-updater: Auto reset done")
                }
            }
            UserDefaults.standard.set(curVersionName, forKey: "failingVersion")
            let res = implementation.delete(version: curVersion, versionName: curVersionName)
            if (res) {
                print("✨  Capacitor-updater: Delete failing version: \(curVersionName)")
            }
        } else if (pastVersion != "") {
            print("✨  Capacitor-updater: Validated version: \(curVersionName)")
            let res = implementation.delete(version: pastVersion, versionName: curVersionName)
            if (res) {
                print("✨  Capacitor-updater: Delete past version: \(pastVersionName)")
            }
            UserDefaults.standard.set("", forKey: "pastVersion")
            UserDefaults.standard.set("", forKey: "pastVersionName")
        }
    }
}
