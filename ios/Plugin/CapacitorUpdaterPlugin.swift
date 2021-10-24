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
        let url = call.getString("url") ?? ""
        call.resolve([
            "done": implementation.updateApp(url)
        ])
    }
}
