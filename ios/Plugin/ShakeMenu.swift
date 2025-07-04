/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import UIKit
import Capacitor

extension UIApplication {
    public class func topViewController(_ base: UIViewController? = UIApplication.shared.windows.first?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(presented)
        }
        return base
    }
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            // Find the CapacitorUpdaterPlugin instance
            guard let bridge = (rootViewController as? CAPBridgeProtocol),
                  let plugin = bridge.plugin(withName: "CapacitorUpdaterPlugin") as? CapacitorUpdaterPlugin else {
                return
            }

            // Check if shake menu is enabled
            if !plugin.shakeMenuEnabled {
                return
            }

            showShakeMenu(plugin: plugin, bridge: bridge)
        }
    }

    private func showShakeMenu(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        // Prevent multiple alerts from showing
        if let topVC = UIApplication.topViewController(),
           topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return
        }

        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "App"
        let title = "Preview \(appName) Menu"
        let message = "What would you like to do?"
        let okButtonTitle = "Go Home"
        let reloadButtonTitle = "Reload app"
        let cancelButtonTitle = "Close menu"

        let updater = plugin.implementation

        func resetBuiltin() {
            updater.reset()
            bridge.setServerBasePath("")
            DispatchQueue.main.async {
                if let vc = (self.rootViewController as? CAPBridgeViewController) {
                    vc.loadView()
                    vc.viewDidLoad()
                }
                _ = updater.delete(id: updater.getCurrentBundleId())
                plugin.logger.info("Reset to builtin version")
            }
        }

        let bundleId = updater.getCurrentBundleId()
        if let vc = (self.rootViewController as? CAPBridgeViewController) {
            plugin.logger.info("getServerBasePath: \(vc.getServerBasePath())")
        }
        plugin.logger.info("bundleId: \(bundleId)")

        let alertShake = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alertShake.addAction(UIAlertAction(title: okButtonTitle, style: .default) { _ in
            guard let next = updater.getNextBundle() else {
                resetBuiltin()
                return
            }
            if !next.isBuiltin() {
                plugin.logger.info("Resetting to: \(next.toString())")
                _ = updater.set(bundle: next)
                let destHot = updater.getBundleDirectory(id: next.getId())
                plugin.logger.info("Reloading \(next.toString())")
                bridge.setServerBasePath(destHot.path)
            } else {
                resetBuiltin()
            }
            plugin.logger.info("Reload app done")
        })

        alertShake.addAction(UIAlertAction(title: cancelButtonTitle, style: .default))

        alertShake.addAction(UIAlertAction(title: reloadButtonTitle, style: .default) { _ in
            DispatchQueue.main.async {
                bridge.webView?.reload()
            }
        })

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alertShake, animated: true)
            }
        }
    }
}
