/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import UIKit
import Capacitor

extension UIApplication {
    // swiftlint:disable:next line_length
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

            // Check if channel selector mode is enabled
            if plugin.shakeChannelSelectorEnabled {
                showChannelSelector(plugin: plugin, bridge: bridge)
            } else {
                showDefaultMenu(plugin: plugin, bridge: bridge)
            }
        }
    }

    private func showDefaultMenu(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
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
                if let viewController = (self.rootViewController as? CAPBridgeViewController) {
                    viewController.loadView()
                    viewController.viewDidLoad()
                }
                _ = updater.delete(id: updater.getCurrentBundleId())
                plugin.logger.info("Reset to builtin version")
            }
        }

        let bundleId = updater.getCurrentBundleId()
        if let viewController = (self.rootViewController as? CAPBridgeViewController) {
            plugin.logger.info("getServerBasePath: \(viewController.getServerBasePath())")
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

    private func showChannelSelector(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        // Prevent multiple alerts from showing
        if let topVC = UIApplication.topViewController(),
           topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return
        }

        let updater = plugin.implementation

        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Loading Channels...", message: nil, preferredStyle: .alert)
        var didCancel = false
        let loadingIndicator = UIActivityIndicatorView(style: .medium)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimating()
        loadingAlert.view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: loadingAlert.view.centerXAnchor),
            loadingIndicator.bottomAnchor.constraint(equalTo: loadingAlert.view.bottomAnchor, constant: -20)
        ])

        // Add cancel button to loading alert
        loadingAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            didCancel = true
        })

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(loadingAlert, animated: true) {
                    // Fetch channels in background
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = updater.listChannels()

                        DispatchQueue.main.async {
                            loadingAlert.dismiss(animated: true) {
                                guard !didCancel else { return }
                                if !result.error.isEmpty {
                                    self.showError(message: "Failed to load channels: \(result.error)", plugin: plugin)
                                } else if result.channels.isEmpty {
                                    self.showError(message: "No channels available for self-assignment", plugin: plugin)
                                } else {
                                    self.presentChannelPicker(channels: result.channels, plugin: plugin, bridge: bridge)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func presentChannelPicker(channels: [[String: Any]], plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        let alert = UIAlertController(title: "Select Channel", message: "Choose a channel to switch to", preferredStyle: .actionSheet)

        // Get channel names
        let channelNames = channels.compactMap { $0["name"] as? String }

        // Show first 5 channels as actions
        let channelsToShow = Array(channelNames.prefix(5))

        for channelName in channelsToShow {
            alert.addAction(UIAlertAction(title: channelName, style: .default) { [weak self] _ in
                self?.selectChannel(name: channelName, plugin: plugin, bridge: bridge)
            })
        }

        // If there are more channels, add a "More..." option
        if channelNames.count > 5 {
            alert.addAction(UIAlertAction(title: "More channels...", style: .default) { [weak self] _ in
                self?.showSearchableChannelPicker(channels: channels, plugin: plugin, bridge: bridge)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // For iPad support
        if let popoverController = alert.popoverPresentationController {
            popoverController.sourceView = self
            popoverController.sourceRect = CGRect(x: self.bounds.midX, y: self.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func showSearchableChannelPicker(channels: [[String: Any]], plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        let alert = UIAlertController(title: "Search Channels", message: "Enter channel name to search", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "Channel name..."
        }

        let channelNames = channels.compactMap { $0["name"] as? String }

        alert.addAction(UIAlertAction(title: "Search", style: .default) { [weak self, weak alert] _ in
            guard let searchText = alert?.textFields?.first?.text?.lowercased(), !searchText.isEmpty else {
                // If empty, show first 5
                self?.presentChannelPicker(channels: channels, plugin: plugin, bridge: bridge)
                return
            }

            // Filter channels
            let filtered = channelNames.filter { $0.lowercased().contains(searchText) }

            if filtered.isEmpty {
                self?.showError(message: "No channels found matching '\(searchText)'", plugin: plugin)
            } else if filtered.count == 1 {
                // Directly select if only one match
                self?.selectChannel(name: filtered[0], plugin: plugin, bridge: bridge)
            } else {
                // Show filtered results
                let filteredChannels = channels.filter { channel in
                    if let name = channel["name"] as? String {
                        return name.lowercased().contains(searchText)
                    }
                    return false
                }
                self?.presentChannelPicker(channels: filteredChannels, plugin: plugin, bridge: bridge)
            }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func selectChannel(name: String, plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        let updater = plugin.implementation

        // Show progress indicator
        let progressAlert = UIAlertController(title: "Switching to \(name)", message: "Setting channel...", preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        progressAlert.view.addSubview(indicator)

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: progressAlert.view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: progressAlert.view.bottomAnchor, constant: -20)
        ])

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(progressAlert, animated: true) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        // Set the channel - respect plugin's allowSetDefaultChannel config
                        let setResult = updater.setChannel(
                            channel: name,
                            defaultChannelKey: "CapacitorUpdater.defaultChannel",
                            allowSetDefaultChannel: plugin.allowSetDefaultChannel
                        )

                        if !setResult.error.isEmpty {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(message: "Failed to set channel: \(setResult.error)", plugin: plugin)
                                }
                            }
                            return
                        }

                        // Update progress message
                        DispatchQueue.main.async {
                            progressAlert.message = "Checking for updates..."
                        }

                        // Check for updates with the new channel
                        let pluginUpdateUrl = plugin.getUpdateUrl()
                        let updateUrlStr = pluginUpdateUrl.isEmpty ? CapacitorUpdaterPlugin.updateUrlDefault : pluginUpdateUrl
                        guard let updateUrl = URL(string: updateUrlStr) else {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(
                                        message: "Channel set to \(name). Invalid update URL, could not check for updates.",
                                        plugin: plugin
                                    )
                                }
                            }
                            return
                        }

                        let latest = updater.getLatest(url: updateUrl, channel: name)

                        // Handle update errors first (before "no new version" check)
                        if let error = latest.error, !error.isEmpty && error != "no_new_version_available" {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(message: "Channel set to \(name). Update check failed: \(error)", plugin: plugin)
                                }
                            }
                            return
                        }

                        // Check if there's an actual update available
                        if latest.error == "no_new_version_available" || latest.url.isEmpty {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showSuccess(message: "Channel set to \(name). Already on latest version.", plugin: plugin)
                                }
                            }
                            return
                        }

                        // Update message
                        DispatchQueue.main.async {
                            progressAlert.message = "Downloading update \(latest.version)..."
                        }

                        // Download the update
                        do {
                            let bundle: BundleInfo
                            if let manifest = latest.manifest, !manifest.isEmpty {
                                bundle = try updater.downloadManifest(
                                    manifest: manifest,
                                    version: latest.version,
                                    sessionKey: latest.sessionKey ?? ""
                                )
                            } else {
                                // Safe unwrap URL
                                guard let downloadUrl = URL(string: latest.url) else {
                                    DispatchQueue.main.async {
                                        progressAlert.dismiss(animated: true) {
                                            self.showError(message: "Failed to download update: invalid update URL.", plugin: plugin)
                                        }
                                    }
                                    return
                                }
                                bundle = try updater.download(
                                    url: downloadUrl,
                                    version: latest.version,
                                    sessionKey: latest.sessionKey ?? ""
                                )
                            }

                            // Set as next bundle
                            _ = updater.setNextBundle(next: bundle.getId())

                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showSuccessWithReload(
                                        message: "Update downloaded! Reload to apply version \(latest.version)?",
                                        plugin: plugin,
                                        bridge: bridge
                                    )
                                }
                            }
                        } catch {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(message: "Failed to download update: \(error.localizedDescription)", plugin: plugin)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func showError(message: String, plugin: CapacitorUpdaterPlugin) {
        plugin.logger.error(message)
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func showSuccess(message: String, plugin: CapacitorUpdaterPlugin) {
        plugin.logger.info(message)
        let alert = UIAlertController(title: "Success", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func showSuccessWithReload(message: String, plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
        plugin.logger.info(message)
        let alert = UIAlertController(title: "Update Ready", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reload Now", style: .default) { _ in
            DispatchQueue.main.async {
                bridge.webView?.reload()
            }
        })

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }
}
