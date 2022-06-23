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
    static let DELAY_UPDATE = "delayUpdate"
    private var autoUpdateUrl = ""
    private var statsUrl = ""
    private var currentVersionNative: Version = "0.0.0"
    private var autoUpdate = false
    private var appReadyTimeout = 10000
    private var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    
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
                _ = implementation.delete(version: version.getName())
            }
        }
        UserDefaults.standard.set( self.currentVersionNative, forKey: "LatestVersionNative")
        UserDefaults.standard.synchronize()
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
        print("\(self.implementation.TAG) Downloading \(url!)")
        do {
            let res = try implementation.download(url: url!, versionName: versionName)
            call.resolve([
                "version": res
            ])
        } catch {
            call.reject("download failed", error.localizedDescription)
        }
    }

    private func _reload() -> Bool {
        guard let bridge = self.bridge else { return false }
        let path = self.implementation.getCurrentBundlePath()
        print("\(self.implementation.TAG) Reloading \(path)")
        if let vc = bridge.viewController as? CAPBridgeViewController {
            vc.setServerBasePath(path: path)
            self.checkAppReady()
            return true
        }
        return false
    }
    
    @objc func reload(_ call: CAPPluginCall) {
        if (self._reload()) {
            call.resolve()
        } else {
            call.reject("Reload failed")
            print("\(self.implementation.TAG) Reload failed")
        }
    }

    @objc func next(_ call: CAPPluginCall) {
        guard let version = call.getString("version") else {
            print("\(self.implementation.TAG) Next call version missing")
            call.reject("Next called without version")
            return
        }
        guard let versionName = call.getString("versionName") else {
            print("\(self.implementation.TAG) Next call versionName missing")
            call.reject("Next called without versionName")
            return
        }

        print("\(self.implementation.TAG) Setting next active version \(version)")
        if (!self.implementation.setNextVersion(next: version)) {
            call.reject("Set next version failed. Version \(version) does not exist.");
        } else {
            if(versionName != "") {
                self.implementation.setVersionName(version: version, name: versionName);
            }
            call.resolve(self.implementation.getVersionInfo(version: version).toJSON());
        }
    }
    
    @objc func set(_ call: CAPPluginCall) {
        guard let version = call.getString("version") else {
            print("\(self.implementation.TAG) Set called without version")
            call.reject("Next call version missing")
            return
        }
        let res = implementation.set(versionName: version)
        print("\(self.implementation.TAG) Set active bundle: \(version)")
        if (!res) {
            print("\(self.implementation.TAG) Bundle successfully set to: \(version) ")
            call.reject("Update failed, version \(version) doesn't exist")
        } else {
            self.reload(call)
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.delete(version: version)
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
            self.implementation.reset()
            
            let LatestVersionAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionAutoUpdate") ?? ""
            let LatestVersionNameAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionNameAutoUpdate") ?? ""
            if(toAutoUpdate && LatestVersionAutoUpdate != "" && LatestVersionNameAutoUpdate != "") {
                let res = implementation.set(versionName: LatestVersionNameAutoUpdate)
                return res && self._reload()
            }
            implementation.reset()
            let curr = implementation.getCurrentBundle()
            let pathPersist = implementation.getPathPersist(folderName: curr.getName())
            vc.setServerBasePath(path: pathPersist.path)
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
    
    @objc func current(_ call: CAPPluginCall) {
        let bundle: VersionInfo = self.implementation.getCurrentBundle()
        call.resolve([
            "bundle": bundle.toJSON(),
            "native": self.currentVersionNative
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
    
    private func _isAutoUpdateEnabled() -> Bool {
        return self.autoUpdate && !(self.autoUpdateUrl != "")
    }

    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self._isAutoUpdateEnabled()
        ])
    }

    func checkAppReady() {
        self.appReadyCheck?.cancel()
        self.appReadyCheck = DispatchWorkItem(block: {
            self.DeferredNotifyAppReadyCheck()
        })
        print("\(self.implementation.TAG) Wait for \(self.appReadyTimeout) ms, then check for notifyAppReady")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.appReadyTimeout), execute: self.appReadyCheck!)
    }

    func DeferredNotifyAppReadyCheck() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        let current: VersionInfo = self.implementation.getCurrentBundle();
        if(current.isBuiltin()) {
            print("\(self.implementation.TAG) Built-in bundle is active. Nothing to do.")
            return
        }

        if(VersionStatus.SUCCESS != current.getStatus()) {
            print("\(self.implementation.TAG) notifyAppReady was not called, roll back current version: \(current)")
            self.implementation.rollback(version: current)
            let res = self._reset(toAutoUpdate: true)
            if (!res) {
                return
            }
        } else {
            print("\(self.implementation.TAG) notifyAppReady was called. This is fine: \(current)")
        }
        self.appReadyCheck = nil;
    }

    @objc func appMovedToForeground() {
        if (self._isAutoUpdateEnabled()) {
            DispatchQueue.global(qos: .background).async {
                print("\(self.implementation.TAG) Check for update via \(self.autoUpdateUrl)")
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
                let current = self.implementation.getCurrentBundle()
                let latestVersionName = res?.version
                if (latestVersionName != nil && latestVersionName != "" && current.getName() != latestVersionName) {
                    let latest = self.implementation.getVersionInfoByName(version: latestVersionName!)
                    if (latest != nil) {
                        if(latest!.isErrorStatus()) {
                            print("\(self.implementation.TAG) Latest version already exists, and is in error state. Aborting update.")
                            return;
                        }
                        if(latest!.isDownloaded()){
                            print("\(self.implementation.TAG) Latest version already exists and download is NOT required. Update will occur next time app moves to background.")
                            let _ = self.implementation.setNextVersion(next: latest!.getVersion());
                            return;
                        }
                    }

                    do {
                        print("\(self.implementation.TAG) New version: \(latestVersionName!) found. Current is: \(current.getName()). Update will occur next time app moves to background.")
                        let next = try self.implementation.download(url: downloadUrl, versionName: latestVersionName!)

                        let _ = self.implementation.setNextVersion(next: next.getVersion());

                        self.notifyListeners("updateAvailable", data: [
                            "version": next.getVersion()
                        ])
                    } catch {
                        print("\(self.implementation.TAG) Error downloading file", error.localizedDescription)
                    }
                }
        }

        self.checkAppReady()
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
            let current = self.implementation.getCurrentBundle()
            let latestVersionName: String = res!.version
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
                    let next = try self.implementation.download(url: downloadUrl, versionName: latestVersionName)
                    print("\(self.implementation.TAG) New version: \(latestVersionName) found. Current is \(current.getName()). Update will occur next time app moves to background.")
                    let _ = self.implementation.setNextVersion(next: next.getVersion())
                    self.notifyListeners("updateAvailable", data: ["version": newVersion])
                } catch {
                    print("\(self.implementation.TAG) Download version \(newVersion) fail", error.localizedDescription)
                }
            } else {
                print("\(self.implementation.TAG) No need to update, \(current.getName()) is the latest")
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

        let fallback: VersionInfo = self.implementation.getFallbackVersion()
        let current: VersionInfo = self.implementation.getCurrentBundle()
        let next: VersionInfo? = self.implementation.getNextVersion()

        let success: Bool = current.getStatus() == VersionStatus.SUCCESS

        print("\(self.implementation.TAG) Fallback version is: \(fallback)")
        print("\(self.implementation.TAG) Current version is: \(current)")

        if (next != nil && !next!.isErrorStatus() && (next!.getVersion() != current.getVersion())) {
            print("\(self.implementation.TAG) Next version is: \(next!)")
            if (self.implementation.set(version: next!) && self._reload()) {
                print("\(self.implementation.TAG) Updated to version: \(next!)")
                let _ = self.implementation.setNextVersion(next: Optional<String>.none)
            } else {
                print("\(self.implementation.TAG) Updated to version: \(next!) Failed!")
            }
        } else if (!success) {
            // There is a no next version, and the current version has failed

            if(!current.isBuiltin()) {
                // Don't try to roll back the builtin version. Nothing we can do.

                self.implementation.rollback(version: current)
                
                print("\(self.implementation.TAG) Update failed: 'notifyAppReady()' was never called.")
                print("\(self.implementation.TAG) Version: \(current), is in error state.")
                print("\(self.implementation.TAG) Will fallback to: \(fallback) on application restart.")
                print("\(self.implementation.TAG) Did you forget to call 'notifyAppReady()' in your Capacitor App code?")

                self.notifyListeners("updateFailed", data: [
                    "version": current
                ])
                self.implementation.sendStats(action: "revert", version: current);
                if (!fallback.isBuiltin() && !(fallback == current)) {
                    let res = self.implementation.set(version: fallback);
                    if (res && self._reload()) {
                        print("\(self.implementation.TAG) Revert to version: \(fallback)")
                    } else {
                        print("\(self.implementation.TAG) Revert to version: \(fallback) Failed!")
                    }
                } else {
                    if (self._reset(toAutoUpdate: false)) {
                        print("\(self.implementation.TAG) Reverted to 'builtin' bundle.")
                    }
                }

                if (self.autoDeleteFailed) {
                    print("\(self.implementation.TAG) Deleting failing version: \(current)")
                    let res = self.implementation.delete(version: current.getVersion());
                    if (!res) {
                        print("\(self.implementation.TAG) Delete version deleted: \(current)")
                    } else {
                        print("\(self.implementation.TAG) Failed to delete failed version: \(current)")
                    }
                }
            } else {
                // Nothing we can/should do by default if the 'builtin' bundle fails to call 'notifyAppReady()'.
            }
        } else if (!fallback.isBuiltin()) {
            // There is a no next version, and the current version has succeeded
            self.implementation.commit(version: current);

            if(self.autoDeletePrevious) {
                print("\(self.implementation.TAG) Version successfully loaded: \(current)")
                let res = self.implementation.delete(version: fallback.getVersion())
                if (res) {
                    print("\(self.implementation.TAG) Deleted previous version: \(fallback)")
                } else {
                    print("\(self.implementation.TAG) Failed to delete previous version: \(fallback)")
                }
            }
        }
    }
}
