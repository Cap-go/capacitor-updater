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
//            guard let bridge = self.bridge else { return call.reject("bridge missing") }
//
//            if let vc = bridge.viewController as? CAPBridgeViewController {
//                let path = implementation.getLastPath()
//                if (path != "") {
//                    vc.setServerBasePath(path: path)
//                    let defaults = UserDefaults.standard
//                    defaults.set(path, forKey: "serverBasePath")
//                    call.resolve()
//                }
//            }
            call.resolve()
        } else {
            call.reject("update failed, version don't exist")
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        let version = call.getString("version") ?? ""
        let res = implementation.delete(version: version)
        if (res) {
            call.resolve()
        } else {
            call.reject("delete failed, version don't exist")
        }
    }

    @objc func list(_ call: CAPPluginCall) {
        let res = implementation.list()
        call.resolve([
            "versions": res
        ])
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let bridge = self.bridge else { return }

        if let vc = bridge.viewController as? CAPBridgeViewController {
            let path = implementation.getLastPath()
            if (path != "") {
                vc.setServerBasePath(path: implementation.getLastPath())
            }
        }
        call.resolve()
    }
}
