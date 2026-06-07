/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import UIKit
import Capacitor

private var lastShakeMenuShownAt: TimeInterval = 0
private let shakeMenuCooldownSeconds: TimeInterval = 1.2
private let threeFingerPinchScaleDelta: CGFloat = 0.12

final class ThreeFingerPinchGestureRecognizer: UIGestureRecognizer {
    private var initialSpan: CGFloat = 0
    private(set) var scale: CGFloat = 1

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view = self.view, let activeTouches = activeTouches(in: view, with: event), activeTouches.count <= 3 else {
            self.state = .failed
            return
        }

        if activeTouches.count == 3 {
            self.initialSpan = span(for: activeTouches, in: view)
            self.scale = 1
            self.state = self.initialSpan > 0 ? .began : .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view = self.view,
              let activeTouches = activeTouches(in: view, with: event),
              activeTouches.count == 3,
              self.initialSpan > 0 else {
            self.state = .failed
            return
        }

        self.scale = span(for: activeTouches, in: view) / self.initialSpan
        self.state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        self.state = self.state == .possible || self.state == .began ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        self.state = .cancelled
    }

    override func reset() {
        super.reset()
        self.initialSpan = 0
        self.scale = 1
    }

    private func activeTouches(in view: UIView, with event: UIEvent) -> [UITouch]? {
        event.touches(for: view)?.filter { touch in
            touch.phase != .ended && touch.phase != .cancelled
        }
    }

    private func span(for touches: [UITouch], in view: UIView) -> CGFloat {
        guard !touches.isEmpty else {
            return 0
        }

        let points = touches.map { $0.location(in: view) }
        let center = points.reduce(CGPoint.zero) { result, point in
            CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        let centerPoint = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))
        let totalDistance = points.reduce(CGFloat(0)) { result, point in
            result + hypot(point.x - centerPoint.x, point.y - centerPoint.y)
        }
        return totalDistance / CGFloat(points.count)
    }
}

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

extension CapacitorUpdaterPlugin: UIGestureRecognizerDelegate {
    func syncShakeMenuGestureRecognizer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let shouldInstall = self.shakeMenuGesture == Self.shakeMenuGestureThreeFingerPinch &&
                (self.shakeMenuEnabled || self.shakeChannelSelectorEnabled)

            guard shouldInstall, let targetView = self.bridge?.webView ?? self.bridge?.viewController?.view else {
                self.removeShakeMenuGestureRecognizer()
                return
            }

            if self.shakeMenuPinchGestureRecognizer?.view === targetView {
                return
            }

            self.removeShakeMenuGestureRecognizer()

            let recognizer = ThreeFingerPinchGestureRecognizer(target: self, action: #selector(self.handleShakeMenuPinch(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            targetView.addGestureRecognizer(recognizer)
            self.shakeMenuPinchGestureRecognizer = recognizer
            self.logger.info("Three finger pinch menu gesture initialized")
        }
    }

    func removeShakeMenuGestureRecognizer() {
        if let recognizer = self.shakeMenuPinchGestureRecognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.shakeMenuPinchGestureRecognizer = nil
            self.shakeMenuPinchGestureTriggered = false
            self.logger.info("Three finger pinch menu gesture stopped")
        }
    }

    @objc func handleShakeMenuPinch(_ recognizer: ThreeFingerPinchGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            self.shakeMenuPinchGestureTriggered = false
            return
        }
        guard recognizer.state == .changed, !self.shakeMenuPinchGestureTriggered else {
            return
        }
        guard abs(recognizer.scale - 1) >= threeFingerPinchScaleDelta else {
            return
        }
        guard self.shakeMenuGesture == Self.shakeMenuGestureThreeFingerPinch, let bridge = self.bridge else {
            return
        }
        guard let window = recognizer.view?.window ?? bridge.viewController?.view.window else {
            return
        }

        self.shakeMenuPinchGestureTriggered = true
        _ = window.showCapacitorUpdaterMenu(plugin: self, bridge: bridge, gestureName: "Three finger pinch")
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === self.shakeMenuPinchGestureRecognizer {
            self.shakeMenuPinchGestureTriggered = false
        }
        return true
    }

    public func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            guard let bridgeViewController = rootViewController as? CAPBridgeViewController,
                  let bridge = bridgeViewController.bridge,
                  let plugin = bridge.plugin(withName: "CapacitorUpdater") as? CapacitorUpdaterPlugin else {
                return
            }
            guard plugin.shakeMenuGesture == CapacitorUpdaterPlugin.shakeMenuGestureShake else {
                return
            }

            _ = showCapacitorUpdaterMenu(plugin: plugin, bridge: bridge, gestureName: "Shake")
        }
    }

    @discardableResult
    fileprivate func showCapacitorUpdaterMenu(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol, gestureName: String) -> Bool {
        let canShowPreviewMenu = plugin.shakeMenuEnabled && plugin.hasActivePreviewSession()
        let canShowChannelSelector = plugin.shakeChannelSelectorEnabled

        if !canShowPreviewMenu && !canShowChannelSelector {
            if plugin.shakeMenuEnabled {
                plugin.logger.info("\(gestureName) preview menu ignored because no preview session is active")
            }
            return false
        }

        let now = Date().timeIntervalSince1970
        guard now - lastShakeMenuShownAt >= shakeMenuCooldownSeconds else {
            plugin.logger.info("\(gestureName) menu ignored because cooldown is active")
            return false
        }

        let didShow = canShowPreviewMenu
            ? showDefaultMenu(plugin: plugin, bridge: bridge)
            : showChannelSelector(plugin: plugin, bridge: bridge)

        if didShow {
            lastShakeMenuShownAt = now
        }
        return didShow
    }

    @discardableResult
    private func showDefaultMenu(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) -> Bool {
        // Prevent multiple alerts from showing
        guard let topVC = UIApplication.topViewController() else {
            return false
        }
        if topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return false
        }

        guard plugin.hasActivePreviewSession() else {
            plugin.logger.info("Shake preview menu ignored because no preview session is active")
            return false
        }

        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "App"
        let title = "Preview \(appName) Menu"
        let message = "Reload, switch, or leave the current preview."
        let okButtonTitle = "Leave test app"
        let reloadButtonTitle = "Reload preview"
        let cancelButtonTitle = "Close menu"

        let alertShake = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alertShake.addAction(UIAlertAction(title: reloadButtonTitle, style: .default) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                if !plugin.reloadPreviewSessionFromShakeMenu() {
                    DispatchQueue.main.async {
                        self.showError(message: "Could not reload the test app.", plugin: plugin)
                    }
                }
            }
        })

        if !plugin.previewMenuPreviews().isEmpty {
            alertShake.addAction(UIAlertAction(title: "Switch preview", style: .default) { _ in
                let showSelector = {
                    self.showPreviewSelector(plugin: plugin)
                }

                if let presenter = alertShake.presentingViewController {
                    presenter.dismiss(animated: true, completion: showSelector)
                } else {
                    DispatchQueue.main.async(execute: showSelector)
                }
            })
        }

        if plugin.shakeChannelSelectorEnabled {
            alertShake.addAction(UIAlertAction(title: "Switch channel", style: .default) { _ in
                let showSelector = {
                    _ = self.showChannelSelector(plugin: plugin, bridge: bridge)
                }

                if let presenter = alertShake.presentingViewController {
                    presenter.dismiss(animated: true, completion: showSelector)
                } else {
                    DispatchQueue.main.async(execute: showSelector)
                }
            })
        }

        alertShake.addAction(UIAlertAction(title: okButtonTitle, style: .default) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                if !plugin.leavePreviewSessionFromShakeMenu() {
                    DispatchQueue.main.async {
                        self.showError(message: "Could not leave the test app.", plugin: plugin)
                    }
                }
            }
        })

        alertShake.addAction(UIAlertAction(title: cancelButtonTitle, style: .default))

        DispatchQueue.main.async {
            topVC.present(alertShake, animated: true)
        }
        return true
    }

    private func showConfiguredDefaultMenu(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
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

    private func previewLabel(_ preview: [String: Any]) -> String {
        let bundle = preview["bundle"] as? [String: Any]
        let name = preview["name"] as? String
        let version = bundle?["version"] as? String
        var label = [name, version, preview["id"] as? String]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first ?? "Preview"
        if preview["isActive"] as? Bool == true {
            label += " (current)"
        }
        return label
    }

    private func showPreviewSelector(plugin: CapacitorUpdaterPlugin) {
        guard let topVC = UIApplication.topViewController() else {
            return
        }
        if topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return
        }

        let previews = plugin.previewMenuPreviews()
        guard !previews.isEmpty else {
            self.showError(message: "No saved previews available on this device.", plugin: plugin)
            return
        }

        let alert = UIAlertController(title: "Select Preview", message: "Choose a local preview to open", preferredStyle: .actionSheet)
        let previewsToShow = Array(previews.prefix(5))
        for preview in previewsToShow {
            let title = self.previewLabel(preview)
            let id = preview["id"] as? String ?? ""
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.selectPreview(id: id, plugin: plugin)
            })
        }

        if previews.count > 5 {
            alert.addAction(UIAlertAction(title: "More previews...", style: .default) { [weak self] _ in
                self?.showSearchablePreviewPicker(previews: previews, plugin: plugin)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popoverController = alert.popoverPresentationController {
            popoverController.sourceView = self
            popoverController.sourceRect = CGRect(x: self.bounds.midX, y: self.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }

        topVC.present(alert, animated: true)
    }

    private func showSearchablePreviewPicker(previews: [[String: Any]], plugin: CapacitorUpdaterPlugin) {
        let alert = UIAlertController(title: "Search Previews", message: "Enter preview name or version", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "Preview name..."
        }

        alert.addAction(UIAlertAction(title: "Search", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let searchText = alert?.textFields?.first?.text?.lowercased(), !searchText.isEmpty else {
                self.showPreviewSelector(plugin: plugin)
                return
            }

            let filtered = previews.filter { self.previewLabel($0).lowercased().contains(searchText) }
            if filtered.isEmpty {
                self.showError(message: "No previews found matching '\(searchText)'", plugin: plugin)
            } else if filtered.count == 1, let id = filtered[0]["id"] as? String {
                self.selectPreview(id: id, plugin: plugin)
            } else {
                self.presentPreviewPicker(previews: filtered, plugin: plugin)
            }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func presentPreviewPicker(previews: [[String: Any]], plugin: CapacitorUpdaterPlugin) {
        let alert = UIAlertController(title: "Select Preview", message: "Choose a local preview to open", preferredStyle: .actionSheet)
        for preview in previews.prefix(5) {
            let id = preview["id"] as? String ?? ""
            alert.addAction(UIAlertAction(title: self.previewLabel(preview), style: .default) { [weak self] _ in
                self?.selectPreview(id: id, plugin: plugin)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

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

    private func selectPreview(id: String, plugin: CapacitorUpdaterPlugin) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !plugin.setPreviewFromShakeMenu(id: id) {
                DispatchQueue.main.async {
                    self.showError(message: "Could not switch preview.", plugin: plugin)
                }
            }
        }
    }

    @discardableResult
    private func showChannelSelector(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) -> Bool {
        // Prevent multiple alerts from showing
        guard let topVC = UIApplication.topViewController() else {
            return false
        }
        if topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return false
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
        return true
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
                            allowSetDefaultChannel: plugin.allowSetDefaultChannel,
                            configDefaultChannel: plugin.getConfig().getString("defaultChannel", "") ?? ""
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
                        let latestKind = latest.kind

                        let detail = [latest.message, latest.error, latestKind]
                            .compactMap { value in
                                guard let value, !value.isEmpty else { return nil }
                                return value
                            }
                            .first ?? "server did not provide a message"

                        // Handle update errors first (before "no new version" check)
                        if latestKind == "failed" || (latest.error?.isEmpty == false && latestKind != "up_to_date" && latestKind != "blocked") {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(message: "Channel set to \(name). Update check failed: \(detail)", plugin: plugin)
                                }
                            }
                            return
                        }

                        if latestKind == "blocked" {
                            DispatchQueue.main.async {
                                progressAlert.dismiss(animated: true) {
                                    self.showError(message: "Channel set to \(name). Update check blocked: \(detail)", plugin: plugin)
                                }
                            }
                            return
                        }

                        // Check if there's an actual update available
                        if latestKind == "up_to_date" || latest.url.isEmpty {
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
                                        bridge: bridge,
                                        onReload: { [weak plugin] in
                                            _ = updater.set(bundle: bundle)
                                            _ = plugin?._reload()
                                        }
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

    private func showSuccessWithReload(
        message: String,
        plugin: CapacitorUpdaterPlugin,
        bridge: CAPBridgeProtocol,
        onReload: (() -> Void)? = nil
    ) {
        plugin.logger.info(message)
        let alert = UIAlertController(title: "Update Ready", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reload Now", style: .default) { _ in
            if let onReload = onReload {
                onReload()
            } else {
                DispatchQueue.main.async {
                    bridge.webView?.reload()
                }
            }
        })

        DispatchQueue.main.async {
            if let topVC = UIApplication.topViewController() {
                topVC.present(alert, animated: true)
            }
        }
    }
}
