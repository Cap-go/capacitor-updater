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
        guard let bridge = self.bridge else { return }
        let url = URL(string: call.getString("url") ?? "")

        let res = implementation.download(url: url!)
        if ((res) != nil) {
            call.resolve([
                "version": res
            ])
        } else {
            call.reject("download failed")
        }
    }

    @objc func setVersion(_ call: CAPPluginCall) {
        guard let bridge = self.bridge else { return }
        let version = URL(string: call.getString("version") ?? "")
        let res = implementation.setVersion(version: version)
        if (res) {
            call.resolve()
        } else {
            call.reject("update failed, version don't exist")
        }
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
