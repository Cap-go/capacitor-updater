/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit
import WebKit
import Version

extension CapacitorUpdaterPlugin {
    func notifyBundleSet(_ bundle: BundleInfo) {
        self.notifyListeners("set", data: ["bundle": bundle.toJSON()], retainUntilConsumed: true)
    }

    func sendReadyToJsImpl(current: BundleInfo, msg: String) {
        logger.info("sendReadyToJs")
        DispatchQueue.global().async {
            self.semaphoreWait(waitTime: self.appReadyTimeout)
            self.notifyListeners("appReady", data: ["bundle": current.toJSON(), "status": msg], retainUntilConsumed: true)

            // Auto hide splashscreen if enabled
            // We show it on background when conditions are met, so we should hide it on foreground regardless of update outcome
            if self.autoSplashscreen {
                self.hideSplashscreen()
            }
        }
    }

    func hideSplashscreen() {
        if Thread.isMainThread {
            self.performHideSplashscreen()
        } else {
            DispatchQueue.main.async {
                self.performHideSplashscreen()
            }
        }
    }

    func performHideSplashscreen() {
        self.cancelSplashscreenTimeout()
        self.removeSplashscreenLoader()
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenMethod(
            methodName: "hide",
            callbackId: "autoHideSplashscreen",
            options: self.splashscreenOptions(methodName: "hide"),
            retriesRemaining: self.splashscreenMaxRetries,
            requestToken: self.splashscreenInvocationToken
        )
    }

    func showSplashscreen() {
        if Thread.isMainThread {
            self.performShowSplashscreen()
        } else {
            DispatchQueue.main.async {
                self.performShowSplashscreen()
            }
        }
    }

    func performShowSplashscreen() {
        self.cancelSplashscreenTimeout()
        self.autoSplashscreenTimedOut = false
        self.splashscreenInvocationToken += 1
        self.invokeSplashscreenMethod(
            methodName: "show",
            callbackId: "autoShowSplashscreen",
            options: self.splashscreenOptions(methodName: "show"),
            retriesRemaining: self.splashscreenMaxRetries,
            requestToken: self.splashscreenInvocationToken
        )

        self.addSplashscreenLoaderIfNeeded()
        self.scheduleSplashscreenTimeout()
    }

    func splashscreenOptions(methodName: String) -> [String: Any] {
        methodName == "show" ? ["autoHide": false] : [:]
    }

    func splashscreenCompletedMessage(methodName: String) -> String {
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

    func makeSplashscreenCall(callbackId: String, options: [String: Any], methodName: String) -> CAPPluginCall {
        CAPPluginCall(callbackId: callbackId, options: options, success: { [weak self] (_, _) in
            guard let self = self else { return }
            self.logger.info(self.splashscreenCompletedMessage(methodName: methodName))
        }, error: { [weak self] (_) in
            guard let self = self else { return }
            self.logger.error("Failed to auto-\(methodName) splashscreen")
        })
    }

    func invokeSplashscreenMethod(
        methodName: String,
        callbackId: String,
        options: [String: Any],
        retriesRemaining: Int,
        requestToken: Int
    ) {
        guard requestToken == self.splashscreenInvocationToken else {
            return
        }

        guard let bridge = self.bridge else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "Bridge not available for \(methodName == "show" ? "showing" : "hiding") splashscreen with autoSplashscreen"
            )
            return
        }

        guard let splashScreenPlugin = bridge.plugin(withName: self.splashscreenPluginName) else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin."
            )
            return
        }

        let selector = NSSelectorFromString("\(methodName):")
        guard splashScreenPlugin.responds(to: selector) else {
            self.retrySplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining,
                requestToken: requestToken,
                message: "autoSplashscreen: SplashScreen plugin does not respond to \(methodName): method. Make sure @capacitor/splash-screen plugin is properly installed."
            )
            return
        }

        let call = self.makeSplashscreenCall(callbackId: callbackId, options: options, methodName: methodName)
        _ = splashScreenPlugin.perform(selector, with: call)
        self.logger.info("Called SplashScreen \(methodName) method")
    }

    func retrySplashscreenMethod(
        methodName: String,
        callbackId: String,
        options: [String: Any],
        retriesRemaining: Int,
        requestToken: Int,
        message: String
    ) {
        guard retriesRemaining > 0 else {
            if methodName == "show" {
                self.logger.warn(message)
            } else {
                self.logger.error(message)
            }
            return
        }

        self.logger.info("\(message). Retrying.")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.splashscreenRetryDelayMilliseconds)) { [weak self] in
            guard let self = self, requestToken == self.splashscreenInvocationToken else {
                return
            }
            self.invokeSplashscreenMethod(
                methodName: methodName,
                callbackId: callbackId,
                options: options,
                retriesRemaining: retriesRemaining - 1,
                requestToken: requestToken
            )
        }
    }

    func addSplashscreenLoaderIfNeeded() {
        guard self.autoSplashscreenLoader else {
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

    func removeSplashscreenLoader() {
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

    func scheduleSplashscreenTimeout() {
        guard self.autoSplashscreenTimeout > 0 else {
            return
        }

        let scheduleTimeout = {
            self.autoSplashscreenTimeoutWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.autoSplashscreenTimedOut = true
                self.logger.info("autoSplashscreen timeout reached, hiding splashscreen")
                self.hideSplashscreen()
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

    func cancelSplashscreenTimeout() {
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
