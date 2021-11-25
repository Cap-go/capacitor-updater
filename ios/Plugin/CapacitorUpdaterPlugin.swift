import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private let implementation = CapacitorUpdater()
    private var lastPath = ""


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

    @objc func set(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.set(version: version)
        
        if (res) {
            guard let bridge = self.bridge else { return call.reject("bridge missing") }

            if let vc = bridge.viewController as? CAPBridgeViewController {
                let pathHot = implementation.getLastPathHot()
                let pathPersist = implementation.getLastPathPersist()
                if (pathHot != "" && pathPersist != "") {
                    vc.setServerBasePath(path: pathHot)
                    let defaults = UserDefaults.standard
                    defaults.set(String(pathPersist.suffix(10)), forKey: "serverBasePath")
                    return call.resolve()
                } else {
                    return call.reject("cannot set " + version)
                }
            }
            call.reject("Update failed, viewController missing")
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
            vc.setServerBasePath(path: "")
            let defaults = UserDefaults.standard
            defaults.set(String(""), forKey: "serverBasePath")
            return call.resolve()
        }
        call.reject("Update failed, viewController missing")
    }

    @objc func current(_ call: CAPPluginCall) {
        let pathHot = implementation.getLastPathHot()
        let current  = pathHot.length >= 10 ? pathHot.suffix(10) : "default"
        call.resolve([
            "current": current
        ])
    }
}
