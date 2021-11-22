import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private let implementation = CapacitorUpdater()

    @objc func updateApp(_ call: CAPPluginCall) {
        let url = URL(string: call.getString("url") ?? "")

        let res = implementation.updateApp(url: url!)
        if ((res) != nil) {
            print("PATH " + res!.path)
            DispatchQueue.main.async {
                let vc = self.bridge?.viewController as! CAPBridgeViewController
                vc.setServerBasePath(path: res!.path)
            }
            call.resolve([
                "done": res!.path
            ])
        }
        call.reject("error")
    }
}
