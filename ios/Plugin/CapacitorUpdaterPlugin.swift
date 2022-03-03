import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private var implementation = CapacitorUpdater()
    private var autoUpdateUrl = ""
    private var statsUrl = ""
    
    override public func load() {
        autoUpdateUrl = getConfigValue("autoUpdateUrl") as? String ?? ""
        implementation.appId = Bundle.main.bundleIdentifier ?? ""
        implementation.notifyDownload = notifyDownload
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        if (config?["appId"] != nil) {
            implementation.appId = config?["appId"] as! String
        }
        implementation.statsUrl = getConfigValue("statsUrl") as? String ?? "https://capgo.app/api/stats"
        if (autoUpdateUrl == "") { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        self.appMovedToForeground()
    }
    
    @objc func notifyDownload(percent: Int) {
        self.notifyListeners("download", data: ["percent": percent])
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
        print("✨  Capacitor-updater: next version: \(nextVersionName), past version: \(pastVersionName == "" ? "builtin" : pastVersionName)")
        print("✨  Capacitor-updater: notifyAppReady: \(notifyAppReady ? "true" :  "false"), current version: \(curVersionName  == "" ? "builtin" : curVersionName)")
        if (nextVersion != "" && nextVersionName != "") {
            let res = implementation.set(version: nextVersion, versionName: nextVersionName)
            if (res) {
                if (self._reload()) {
                    print("✨  Capacitor-updater: Auto update to version: \(nextVersionName)")
                }
                UserDefaults.standard.set("", forKey: "nextVersion")
                UserDefaults.standard.set("", forKey: "nextVersionName")
                UserDefaults.standard.set(curVersion, forKey: "pastVersion")
                UserDefaults.standard.set(curVersionName, forKey: "pastVersionName")
                UserDefaults.standard.set(false, forKey: "notifyAppReady")
            }
        } else if (!notifyAppReady) {
            print("✨  Capacitor-updater: notifyAppReady never trigger")
            print("✨  Capacitor-updater: Version: \(curVersionName), is considered broken")
            print("✨  Capacitor-updater: Will downgraded to \(pastVersionName) for next start")
            print("✨  Capacitor-updater: Don't forget to trigger 'notifyAppReady()' in js code to validate a version.")
            implementation.sendStats(action: "revert", version: curVersionName)
            if (pastVersion != "" && pastVersionName != "") {
                let res = implementation.set(version: pastVersion, versionName: pastVersionName)
                if (res) {
                    if (self._reload()) {
                        print("✨  Capacitor-updater: Revert update to version: \(pastVersionName)")
                    }
                    UserDefaults.standard.set("", forKey: "pastVersion")
                    UserDefaults.standard.set("", forKey: "pastVersionName")
                }
            } else {
                if self._reset() {
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
            let failingVersion = UserDefaults.standard.string(forKey: "failingVersion") ?? ""
            let newVersion = res?.version ?? ""
            if (newVersion != "" && newVersion != currentVersion && newVersion != failingVersion) {
                let dlOp = self.implementation.download(url: downloadUrl)
                if let dl = dlOp {
                    print("✨  Capacitor-updater: New version: \(newVersion) found. Current is \(currentVersion == "" ? "builtin" : currentVersion), next backgrounding will trigger update")
                    UserDefaults.standard.set(dl, forKey: "nextVersion")
                    UserDefaults.standard.set(newVersion, forKey: "nextVersionName")
                } else {
                    print("✨  Capacitor-updater: Download fail")
                }
            } else {
                print("✨  Capacitor-updater: No need to update, \(currentVersion) is the latest")
            }
        }
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
        
        if (res) {
            if (self._reload()) {
                print("✨  Capacitor-updater: Set to version: \(version) versionName: \(versionName)")
                call.resolve()
            } else {
                call.reject("Cannot reload")
            }
        } else {
            call.reject("Update failed, version \(version) don't exist")
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.delete(version: version, versionName: "")
        if (res) {
            call.resolve()
        } else {
            call.reject("Delete failed, version don't exist")
        }
    }

    @objc func list(_ call: CAPPluginCall) {
        let res = implementation.list()
        call.resolve([
            "versions": res
        ])
    }

    @objc func _reset() -> Bool {
        guard let bridge = self.bridge else { return false }
        if let vc = bridge.viewController as? CAPBridgeViewController {
            implementation.reset()
            let pathPersist = implementation.getLastPathPersist()
            vc.setServerBasePath(path: pathPersist)
            UserDefaults.standard.set("", forKey: "serverBasePath")
            DispatchQueue.global(qos: .background).async {
                vc.loadView()
                vc.viewDidLoad()
                print("✨  Capacitor-updater: Reset to original version")
            }
            return true
        }
        return false
    }

    @objc func reset(_ call: CAPPluginCall) {
        if (self._reset()) {
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
        let current  = pathHot.count >= 10 ? pathHot.suffix(10) : "default"
        call.resolve([
            "current": current
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
}
