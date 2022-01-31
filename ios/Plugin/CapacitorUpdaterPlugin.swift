import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private let implementation = CapacitorUpdater()
    private var autoUpdate = false
    private var autoUpdateUrl = ""
    
    override public func load() {
        autoUpdateUrl = getConfigValue("autoUpdateUrl") as? String ?? ""
        if autoUpdateUrl != "" {
            autoUpdate = true
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
            appMovedToForeground() // check for update on startup
        }
    }
    
    @objc func appMovedToBackground() {
        print("appMovedToBackground")
        let nextVersion = UserDefaults.standard.string(forKey: "nextVersion") ?? ""
        let nextVersionName = UserDefaults.standard.string(forKey: "nextVersionName") ?? ""
        if (nextVersion != "" && nextVersionName != "") {
            let res = implementation.set(version: nextVersion, versionName: nextVersionName)
            if (res) {
                if (self._reload()) {
                    print("Auto update to VersionName: " + nextVersionName + ", Version: " + nextVersion)
                }
                UserDefaults.standard.set("", forKey: "nextVersion")
                UserDefaults.standard.set("", forKey: "nextVersionName")
            }

        }
    }

    @objc func appMovedToForeground() {
        print("appMovedToForeground")
        let url = URL(string: autoUpdateUrl)!
        let res = implementation.getLatest(url: url)
        if (res == nil) {
            return
        }
        guard let downloadUrl = URL(string: res?.url ?? "") else {
            return
        }
        let name = implementation.getVersionName()
        if (res?.version != name) {
            let dl = implementation.download(url: downloadUrl)
            UserDefaults.standard.set(dl, forKey: "nextVersion")
            UserDefaults.standard.set(res?.version, forKey: "nextVersionName")
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
                call.resolve()
            } else {
                call.reject("Cannot reload")
            }
        } else {
            call.reject("Update failed, version " + version + " don't exist")
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.delete(version: version)
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

    @objc func reset(_ call: CAPPluginCall) {
        guard let bridge = self.bridge else { return call.reject("bridge missing") }
        if let vc = bridge.viewController as? CAPBridgeViewController {
            implementation.reset()
            let pathPersist = implementation.getLastPathPersist()
            vc.setServerBasePath(path: pathPersist)
            UserDefaults.standard.set("", forKey: "serverBasePath")
            DispatchQueue.main.async {
                vc.loadView()
                vc.viewDidLoad()
            }
            return call.resolve()
        }
        call.reject("Reset failed, not implemented")
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
}
