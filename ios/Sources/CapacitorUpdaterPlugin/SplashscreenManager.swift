/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit

/// Manages the auto-splashscreen functionality for the CapacitorUpdater plugin.
/// Handles showing, hiding, timeout, and loader overlay for the splashscreen.
class SplashscreenManager {
    private weak var bridge: CAPBridgeProtocol?
    private let logger: Logger

    // Configuration
    private var autoSplashscreenEnabled = false
    private var autoSplashscreenLoaderEnabled = false
    private var autoSplashscreenTimeout = 10000

    // State
    private var autoSplashscreenTimeoutWorkItem: DispatchWorkItem?
    private var splashscreenLoaderView: UIActivityIndicatorView?
    private var splashscreenLoaderContainer: UIView?

    // Thread-safe hasTimedOut property
    private let hasTimedOutLock = NSLock()
    private var _hasTimedOut = false
    private(set) var hasTimedOut: Bool {
        get {
            hasTimedOutLock.lock()
            defer { hasTimedOutLock.unlock() }
            return _hasTimedOut
        }
        set {
            hasTimedOutLock.lock()
            defer { hasTimedOutLock.unlock() }
            _hasTimedOut = newValue
        }
    }

    init(bridge: CAPBridgeProtocol?, logger: Logger) {
        self.bridge = bridge
        self.logger = logger
    }

    /// Update the bridge reference (needed if bridge changes)
    func setBridge(_ bridge: CAPBridgeProtocol?) {
        self.bridge = bridge
    }

    /// Configure the splashscreen manager with the given settings
    func configure(enabled: Bool, loaderEnabled: Bool, timeout: Int) {
        self.autoSplashscreenEnabled = enabled
        self.autoSplashscreenLoaderEnabled = loaderEnabled
        self.autoSplashscreenTimeout = max(0, timeout)
    }

    /// Returns whether auto-splashscreen is enabled
    var isEnabled: Bool {
        return autoSplashscreenEnabled
    }

    /// Show the splashscreen
    func show() {
        if Thread.isMainThread {
            performShow()
        } else {
            DispatchQueue.main.async {
                self.performShow()
            }
        }
    }

    /// Hide the splashscreen
    func hide() {
        if Thread.isMainThread {
            performHide()
        } else {
            DispatchQueue.main.async {
                self.performHide()
            }
        }
    }

    /// Reset timeout state (called when entering background)
    func resetTimeoutState() {
        hasTimedOut = false
    }

    // MARK: - Private Methods

    private func performShow() {
        cancelTimeout()
        hasTimedOut = false

        guard let bridge = self.bridge else {
            logger.warn("Bridge not available for showing splashscreen with autoSplashscreen")
            return
        }

        // Create a plugin call for the show method
        let call = CAPPluginCall(callbackId: "autoShowSplashscreen", options: [:], success: { (_, _) in
            self.logger.info("Splashscreen shown automatically")
        }, error: { (_) in
            self.logger.error("Failed to auto-show splashscreen")
        })

        // Try to call the SplashScreen show method directly through the bridge
        if let splashScreenPlugin = bridge.plugin(withName: "SplashScreen") {
            let selector = NSSelectorFromString("show:")
            if splashScreenPlugin.responds(to: selector) {
                _ = splashScreenPlugin.perform(selector, with: call)
                logger.info("Called SplashScreen show method")
            } else {
                logger.warn("autoSplashscreen: SplashScreen plugin does not respond to show: method. Make sure @capacitor/splash-screen plugin is properly installed.")
            }
        } else {
            logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.")
        }

        addLoaderIfNeeded()
        scheduleTimeout()
    }

    private func performHide() {
        cancelTimeout()
        removeLoader()

        guard let bridge = self.bridge else {
            logger.warn("Bridge not available for hiding splashscreen with autoSplashscreen")
            return
        }

        // Create a plugin call for the hide method
        let call = CAPPluginCall(callbackId: "autoHideSplashscreen", options: [:], success: { (_, _) in
            self.logger.info("Splashscreen hidden automatically")
        }, error: { (_) in
            self.logger.error("Failed to auto-hide splashscreen")
        })

        // Try to call the SplashScreen hide method directly through the bridge
        if let splashScreenPlugin = bridge.plugin(withName: "SplashScreen") {
            let selector = NSSelectorFromString("hide:")
            if splashScreenPlugin.responds(to: selector) {
                _ = splashScreenPlugin.perform(selector, with: call)
                logger.info("Called SplashScreen hide method")
            } else {
                logger.warn("autoSplashscreen: SplashScreen plugin does not respond to hide: method. Make sure @capacitor/splash-screen plugin is properly installed.")
            }
        } else {
            logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.")
        }
    }

    private func addLoaderIfNeeded() {
        guard autoSplashscreenLoaderEnabled else {
            return
        }

        let addLoader = {
            guard self.splashscreenLoaderContainer == nil else {
                return
            }
            guard let rootView = self.bridge?.viewController?.view else {
                self.logger.warn("autoSplashscreen: Unable to access root view for loader overlay")
                return
            }

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = UIColor.clear
            container.isUserInteractionEnabled = false

            let indicatorStyle: UIActivityIndicatorView.Style
            if #available(iOS 13.0, *) {
                indicatorStyle = .large
            } else {
                indicatorStyle = .whiteLarge
            }

            let indicator = UIActivityIndicatorView(style: indicatorStyle)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.hidesWhenStopped = false
            if #available(iOS 13.0, *) {
                indicator.color = UIColor.label
            }
            indicator.startAnimating()

            container.addSubview(indicator)
            rootView.addSubview(container)

            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                container.topAnchor.constraint(equalTo: rootView.topAnchor),
                container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])

            self.splashscreenLoaderContainer = container
            self.splashscreenLoaderView = indicator
        }

        if Thread.isMainThread {
            addLoader()
        } else {
            DispatchQueue.main.async {
                addLoader()
            }
        }
    }

    private func removeLoader() {
        let removeLoader = {
            self.splashscreenLoaderView?.stopAnimating()
            self.splashscreenLoaderContainer?.removeFromSuperview()
            self.splashscreenLoaderView = nil
            self.splashscreenLoaderContainer = nil
        }

        if Thread.isMainThread {
            removeLoader()
        } else {
            DispatchQueue.main.async {
                removeLoader()
            }
        }
    }

    private func scheduleTimeout() {
        guard autoSplashscreenTimeout > 0 else {
            return
        }

        let scheduleTimeout = {
            self.autoSplashscreenTimeoutWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.hasTimedOut = true
                self.logger.info("autoSplashscreen timeout reached, hiding splashscreen")
                self.hide()
            }
            self.autoSplashscreenTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.autoSplashscreenTimeout), execute: workItem)
        }

        if Thread.isMainThread {
            scheduleTimeout()
        } else {
            DispatchQueue.main.async {
                scheduleTimeout()
            }
        }
    }

    private func cancelTimeout() {
        let cancelTimeout = {
            self.autoSplashscreenTimeoutWorkItem?.cancel()
            self.autoSplashscreenTimeoutWorkItem = nil
        }

        if Thread.isMainThread {
            cancelTimeout()
        } else {
            DispatchQueue.main.async {
                cancelTimeout()
            }
        }
    }
}
