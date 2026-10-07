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
    var onTrackingStarted: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view = self.view, let activeTouches = activeTouches(with: event), activeTouches.count <= 3 else {
            self.state = .failed
            return
        }

        if activeTouches.count == 3 {
            self.initialSpan = span(for: activeTouches, in: view)
            self.scale = 1
            if self.initialSpan > 0 {
                self.onTrackingStarted?()
            } else {
                self.state = .failed
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view = self.view,
              let activeTouches = activeTouches(with: event),
              activeTouches.count == 3,
              self.initialSpan > 0 else {
            self.state = .failed
            return
        }

        self.scale = span(for: activeTouches, in: view) / self.initialSpan
        if abs(self.scale - 1) >= threeFingerPinchScaleDelta {
            self.state = .recognized
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if self.state == .possible {
            self.state = .failed
        }
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

    private func activeTouches(with event: UIEvent) -> [UITouch]? {
        event.touches(for: self)?.filter { touch in
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
    public class func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let resolvedBase = base ?? keyWindowRootViewController
        if let nav = resolvedBase as? UINavigationController {
            return topViewController(nav.visibleViewController)
        }
        if let tab = resolvedBase as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(selected)
        }
        if let presented = resolvedBase?.presentedViewController {
            return topViewController(presented)
        }
        return resolvedBase
    }

    private static var keyWindowRootViewController: UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foregroundScenes = scenes.filter { $0.activationState == .foregroundActive }
        let candidates = foregroundScenes.isEmpty ? scenes : foregroundScenes
        let window = candidates.flatMap(\.windows).first(where: \.isKeyWindow) ?? candidates.first?.windows.first
        return window?.rootViewController
    }
}

extension CapacitorUpdaterPlugin: UIGestureRecognizerDelegate {
    func hasActivePreviewSession() -> Bool {
        (engineOp("previewSessionActive") as? [String: Any])?["active"] as? Bool ?? false
    }

    func previewMenuPreviews() -> [[String: Any]] {
        engineOp("previewMenuPreviews") as? [[String: Any]] ?? []
    }

    /// Preview menu actions reload the WebView: run them off the main thread.
    func runPreviewMenuAction(_ operation: String, _ input: [String: Any?] = [:]) -> Bool {
        (engineOp(operation, input) as? [String: Any])?["ok"] as? Bool ?? false
    }

    func syncShakeMenuGestureRecognizer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let shouldInstall = self.shakeMenuGesture == Self.shakeMenuGestureThreeFingerPinch &&
                (self.shakeMenuEnabled || self.shakeChannelSelectorEnabled)

            guard shouldInstall, let targetView = self.bridge?.viewController?.view ?? self.bridge?.webView else {
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
            recognizer.onTrackingStarted = { [weak self] in
                self?.logger.info("Three finger pinch tracking started")
            }
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
        guard recognizer.state == .recognized, !self.shakeMenuPinchGestureTriggered else {
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
        self.logger.info("Three finger pinch detected")
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
    private var menuHostViewController: UIViewController? {
        UIApplication.topViewController(rootViewController)
    }

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
        guard let topVC = self.menuHostViewController else {
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
                if !plugin.runPreviewMenuAction("previewMenuReload") {
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
                if !plugin.runPreviewMenuAction("previewMenuLeave") {
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
        guard let topVC = self.menuHostViewController else {
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
            if let topVC = self.menuHostViewController {
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
            if let topVC = self.menuHostViewController {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func selectPreview(id: String, plugin: CapacitorUpdaterPlugin) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !plugin.runPreviewMenuAction("previewMenuSet", ["id": id]) {
                DispatchQueue.main.async {
                    self.showError(message: "Could not switch preview.", plugin: plugin)
                }
            }
        }
    }

    @discardableResult
    private func showChannelSelector(plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) -> Bool {
        // Prevent multiple alerts from showing
        guard let topVC = self.menuHostViewController else {
            return false
        }
        if topVC.isKind(of: UIAlertController.self) {
            plugin.logger.info("UIAlertController is already presented")
            return false
        }

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
                    var channels: [[String: Any]] = []
                    var failure: String?
                    switch plugin.runEngineMethod("listChannels", [:]) {
                    case .resolved(let value):
                        channels = (value as? [String: Any])?["channels"] as? [[String: Any]] ?? []
                    case .rejected(let message, _, _):
                        failure = message
                    }

                    DispatchQueue.main.async {
                        loadingAlert.dismiss(animated: true) {
                            guard !didCancel else { return }
                            if let failure {
                                self.showError(message: "Failed to load channels: \(failure)", plugin: plugin)
                            } else if channels.isEmpty {
                                self.showError(message: "No channels available for self-assignment", plugin: plugin)
                            } else {
                                self.presentChannelPicker(channels: channels, plugin: plugin, bridge: bridge)
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
            if let topVC = self.menuHostViewController {
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
            if let topVC = self.menuHostViewController {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func selectChannel(name: String, plugin: CapacitorUpdaterPlugin, bridge: CAPBridgeProtocol) {
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

        func finish(_ present: @escaping () -> Void) {
            DispatchQueue.main.async {
                progressAlert.dismiss(animated: true, completion: present)
            }
        }

        DispatchQueue.main.async {
            guard let topVC = self.menuHostViewController else {
                return
            }
            topVC.present(progressAlert, animated: true) {
                DispatchQueue.global(qos: .userInitiated).async {
                    // The engine runs setChannel, getLatest, download and next; progress
                    // arrives through the shakeMenuProgress hook.
                    plugin.shakeMenuProgress = { message in
                        DispatchQueue.main.async {
                            progressAlert.message = message
                        }
                    }
                    let result = plugin.engineOp("shakeMenuSwitchChannel", ["channel": name]) as? [String: Any] ?? [:]
                    plugin.shakeMenuProgress = nil
                    let message = result["message"] as? String ?? "Failed to set channel"
                    let bundleId = result["bundleId"] as? String ?? ""
                    switch result["status"] as? String {
                    case "updateReady":
                        finish {
                            self.showSuccessWithReload(
                                message: message,
                                plugin: plugin,
                                bridge: bridge,
                                onReload: {
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        _ = plugin.runEngineMethod("set", ["id": bundleId])
                                    }
                                }
                            )
                        }
                    case "success":
                        finish { self.showSuccess(message: message, plugin: plugin) }
                    default:
                        finish { self.showError(message: message, plugin: plugin) }
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
            if let topVC = self.menuHostViewController {
                topVC.present(alert, animated: true)
            }
        }
    }

    private func showSuccess(message: String, plugin: CapacitorUpdaterPlugin) {
        plugin.logger.info(message)
        let alert = UIAlertController(title: "Success", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        DispatchQueue.main.async {
            if let topVC = self.menuHostViewController {
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
            if let topVC = self.menuHostViewController {
                topVC.present(alert, animated: true)
            }
        }
    }
}
