/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit

/// Splash screen invocation and loader overlays requested by the engine hooks.
extension CapacitorUpdaterPlugin {
    // MARK: - Splash screen

    func performHideSplashscreen() {
        self.removeSplashscreenLoader()
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenAction(.hide, retriesRemaining: self.splashscreenMaxRetries, requestToken: self.splashscreenInvocationToken)
    }

    func performShowSplashscreen() {
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenAction(.show, retriesRemaining: self.splashscreenMaxRetries, requestToken: self.splashscreenInvocationToken)
        self.addSplashscreenLoaderIfNeeded()
    }

    private func splashscreenOptions(methodName: String) -> [String: Any] {
        methodName == "show" ? ["autoHide": false, "fadeInDuration": 0] : [:]
    }

    private func splashscreenCompletedMessage(methodName: String) -> String {
        methodName == "show" ? "Splashscreen shown automatically" : "Splashscreen hidden automatically"
    }

    func splashscreenOptionsForTesting(methodName: String) -> [String: Any] {
        self.splashscreenOptions(methodName: methodName)
    }

    func isCurrentSplashscreenInvocationTokenForTesting(_ requestToken: Int) -> Bool {
        requestToken == self.splashscreenInvocationToken
    }

    func advanceSplashscreenInvocationTokenForTesting() {
        self.splashscreenInvocationToken += 1
    }

    enum SplashscreenAction {
        case show
        case hide

        var methodName: String {
            self == .show ? "show" : "hide"
        }

        var unavailableMessageVerb: String {
            self == .show ? "showing" : "hiding"
        }
    }

    private func splashscreenOptionsJSON(methodName: String) -> String {
        let options = self.splashscreenOptions(methodName: methodName)
        guard !options.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: options),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func splashscreenPluginExposesMethod(_ methodName: String, on plugin: CAPPlugin) -> Bool {
        guard let bridgedPlugin = plugin as? CAPBridgedPlugin else {
            return false
        }
        return bridgedPlugin.pluginMethods.contains { $0.name == methodName }
    }

    private func splashscreenBridgeScript(for action: SplashscreenAction) -> String {
        let optionsJSON = self.splashscreenOptionsJSON(methodName: action.methodName)
        return """
        var cap = window.Capacitor;
        if (!cap || typeof cap.nativePromise !== 'function') {
          throw new Error('Capacitor bridge not ready');
        }
        return await cap.nativePromise('\(self.splashscreenPluginName)', '\(action.methodName)', \(optionsJSON));
        """
    }

    private func invokeSplashscreenAction(_ action: SplashscreenAction, retriesRemaining: Int, requestToken: Int) {
        guard requestToken == self.splashscreenInvocationToken else {
            return
        }
        guard let bridge = self.bridge else {
            self.retrySplashscreenAction(
                action,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "Bridge not available for \(action.unavailableMessageVerb) splashscreen with autoSplashscreen"
            )
            return
        }
        guard let splashScreenPlugin = bridge.plugin(withName: self.splashscreenPluginName) else {
            self.retrySplashscreenAction(
                action,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin."
            )
            return
        }
        guard self.splashscreenPluginExposesMethod(action.methodName, on: splashScreenPlugin) else {
            self.retrySplashscreenAction(
                action,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin does not expose \(action.methodName)(). Make sure @capacitor/splash-screen plugin is properly installed."
            )
            return
        }
        guard let webView = bridge.webView else {
            self.retrySplashscreenAction(
                action,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "WebView not available for \(action.unavailableMessageVerb) splashscreen with autoSplashscreen"
            )
            return
        }

        let script = self.splashscreenBridgeScript(for: action)
        let runInvocation = { [weak self] in
            guard let self = self, requestToken == self.splashscreenInvocationToken else {
                return
            }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] (result: Result<Any, Error>) in
                guard let self = self, requestToken == self.splashscreenInvocationToken else {
                    return
                }
                if case .failure(let error) = result {
                    self.retrySplashscreenAction(
                        action,
                        retriesRemaining: retriesRemaining,
                        requestToken: requestToken,
                        message: "Failed to invoke SplashScreen \(action.methodName) via Capacitor bridge: \(error.localizedDescription)"
                    )
                    return
                }
                self.logger.info("Called SplashScreen \(action.methodName) method")
                self.logger.info(self.splashscreenCompletedMessage(methodName: action.methodName))
            }
        }
        onMainAsync(runInvocation)
    }

    private func retrySplashscreenAction(_ action: SplashscreenAction, retriesRemaining: Int, requestToken: Int, message: String) {
        guard retriesRemaining > 0 else {
            if action == .show {
                self.logger.warn(message)
                return
            }
            self.logger.error("\(message). Scheduling another hide retry.")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.splashscreenRetryDelayMilliseconds)) { [weak self] in
                guard let self = self, requestToken == self.splashscreenInvocationToken else {
                    return
                }
                self.invokeSplashscreenAction(action, retriesRemaining: self.splashscreenMaxRetries, requestToken: requestToken)
            }
            return
        }
        self.logger.info("\(message). Retrying.")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.splashscreenRetryDelayMilliseconds)) { [weak self] in
            guard let self = self, requestToken == self.splashscreenInvocationToken else {
                return
            }
            self.invokeSplashscreenAction(action, retriesRemaining: retriesRemaining - 1, requestToken: requestToken)
        }
    }

    // MARK: - Loader overlays

    private func createLoaderOverlay(
        backgroundColor: UIColor,
        isUserInteractionEnabled: Bool,
        indicatorColor: UIColor
    ) -> (container: UIView, indicator: UIActivityIndicatorView) {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = backgroundColor
        container.isUserInteractionEnabled = isUserInteractionEnabled

        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = false
        indicator.color = indicatorColor
        indicator.startAnimating()
        return (container, indicator)
    }

    private func attachLoaderOverlay(_ overlay: (container: UIView, indicator: UIActivityIndicatorView), to rootView: UIView) {
        overlay.container.addSubview(overlay.indicator)
        rootView.addSubview(overlay.container)
        NSLayoutConstraint.activate([
            overlay.container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            overlay.container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            overlay.container.topAnchor.constraint(equalTo: rootView.topAnchor),
            overlay.container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            overlay.indicator.centerXAnchor.constraint(equalTo: overlay.container.centerXAnchor),
            overlay.indicator.centerYAnchor.constraint(equalTo: overlay.container.centerYAnchor)
        ])
    }

    private func addSplashscreenLoaderIfNeeded() {
        guard self.autoSplashscreenLoader, self.splashscreenLoaderContainer == nil else {
            return
        }
        guard let rootView = self.bridge?.viewController?.view else {
            self.logger.warn("autoSplashscreen: Unable to access root view for loader overlay")
            return
        }
        let overlay = self.createLoaderOverlay(backgroundColor: .clear, isUserInteractionEnabled: false, indicatorColor: .label)
        self.attachLoaderOverlay(overlay, to: rootView)
        self.splashscreenLoaderContainer = overlay.container
        self.splashscreenLoaderView = overlay.indicator
    }

    private func removeSplashscreenLoader() {
        self.splashscreenLoaderView?.stopAnimating()
        self.splashscreenLoaderContainer?.removeFromSuperview()
        self.splashscreenLoaderView = nil
        self.splashscreenLoaderContainer = nil
    }

    func showPreviewTransitionLoader(reason: String) {
        onMainAsync {
            self.previewTransitionLoaderRequested = true
            if let container = self.previewTransitionLoaderContainer {
                self.schedulePreviewTransitionLoaderTimeout()
                container.superview?.bringSubviewToFront(container)
                return
            }
            guard let rootView = self.bridge?.viewController?.view else {
                self.logger.warn("Preview transition loader unavailable: root view missing for \(reason)")
                self.previewTransitionLoaderRequested = false
                return
            }
            self.schedulePreviewTransitionLoaderTimeout()
            let overlay = self.createLoaderOverlay(
                backgroundColor: UIColor.black.withAlphaComponent(0.18),
                isUserInteractionEnabled: true,
                indicatorColor: .white
            )
            self.attachLoaderOverlay(overlay, to: rootView)
            self.previewTransitionLoaderContainer = overlay.container
            self.previewTransitionLoaderView = overlay.indicator
            self.logger.info("Preview transition loader shown: \(reason)")
        }
    }

    func hidePreviewTransitionLoader(reason: String) {
        onMainAsync {
            guard self.previewTransitionLoaderRequested ||
                    self.previewTransitionLoaderContainer != nil ||
                    self.previewTransitionLoaderTimeoutWorkItem != nil else {
                return
            }
            self.previewTransitionLoaderRequested = false
            self.previewTransitionLoaderTimeoutWorkItem?.cancel()
            self.previewTransitionLoaderTimeoutWorkItem = nil
            guard self.previewTransitionLoaderContainer != nil else {
                return
            }
            self.previewTransitionLoaderView?.stopAnimating()
            self.previewTransitionLoaderContainer?.removeFromSuperview()
            self.previewTransitionLoaderView = nil
            self.previewTransitionLoaderContainer = nil
            self.logger.info("Preview transition loader hidden: \(reason)")
        }
    }

    private func schedulePreviewTransitionLoaderTimeout() {
        self.previewTransitionLoaderTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hidePreviewTransitionLoader(reason: "preview-transition-timeout")
        }
        self.previewTransitionLoaderTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.previewLoaderTimeoutMs), execute: workItem)
    }
}
