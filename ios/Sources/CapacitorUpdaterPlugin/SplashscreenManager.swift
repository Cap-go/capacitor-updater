import Foundation
import UIKit
import Capacitor

/// Delegate protocol for splashscreen manager callbacks
public protocol SplashscreenManagerDelegate: AnyObject {
    /// Get the Capacitor bridge
    func getSplashscreenBridge() -> CAPBridgeProtocol?
    /// Called when splashscreen timeout occurs
    func onSplashscreenTimeout()
}

/// Manages auto splashscreen functionality.
/// Handles showing/hiding splashscreen and loader overlay.
///
/// **IMPORTANT: Capacitor Version Dependency**
///
/// This class uses dynamic method invocation (`NSSelectorFromString`) to call
/// the SplashScreen plugin's show/hide methods directly from native code.
/// This is necessary because Capacitor does not expose a public API for
/// invoking plugin methods from native code without JavaScript involvement.
///
/// **Tested with:** Capacitor 6.x, 7.x
///
/// If Capacitor changes the SplashScreen plugin's method signatures in future
/// versions, the dynamic invocation may fail. In such cases, the splashscreen
/// operations will fail gracefully with a warning logged, and the app will
/// continue to function (just without automatic splashscreen management).
public class SplashscreenManager {
    private let logger: Logger
    private let timeout: Int
    private let loaderEnabled: Bool
    private weak var delegate: SplashscreenManagerDelegate?

    private var timeoutWorkItem: DispatchWorkItem?
    private var loaderContainer: UIView?
    private var loaderView: UIActivityIndicatorView?
    private var timedOut = false

    /// Whether the splashscreen has timed out
    public var hasTimedOut: Bool {
        return timedOut
    }

    public init(logger: Logger, timeout: Int, loaderEnabled: Bool, delegate: SplashscreenManagerDelegate) {
        self.logger = logger
        self.timeout = timeout
        self.loaderEnabled = loaderEnabled
        self.delegate = delegate
    }

    // MARK: - Public Methods

    /// Hide the splashscreen
    public func hide() {
        if Thread.isMainThread {
            performHide()
        } else {
            DispatchQueue.main.async {
                self.performHide()
            }
        }
    }

    /// Show the splashscreen
    public func show() {
        if Thread.isMainThread {
            performShow()
        } else {
            DispatchQueue.main.async {
                self.performShow()
            }
        }
    }

    /// Reset timeout state (call before showing splashscreen)
    public func resetTimeoutState() {
        timedOut = false
    }

    // MARK: - Private Methods

    private func performHide() {
        cancelTimeout()
        removeLoader()

        guard let bridge = delegate?.getSplashscreenBridge() else {
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

    private func performShow() {
        cancelTimeout()
        timedOut = false

        guard let bridge = delegate?.getSplashscreenBridge() else {
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

    // MARK: - Loader Management

    private func addLoaderIfNeeded() {
        guard loaderEnabled else {
            return
        }

        let addLoader = {
            guard self.loaderContainer == nil else {
                return
            }
            guard let rootView = self.delegate?.getSplashscreenBridge()?.viewController?.view else {
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

            self.loaderContainer = container
            self.loaderView = indicator
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
            self.loaderView?.stopAnimating()
            self.loaderContainer?.removeFromSuperview()
            self.loaderView = nil
            self.loaderContainer = nil
        }

        if Thread.isMainThread {
            removeLoader()
        } else {
            DispatchQueue.main.async {
                removeLoader()
            }
        }
    }

    // MARK: - Timeout Management

    private func scheduleTimeout() {
        guard timeout > 0 else {
            return
        }

        let scheduleTimeout = {
            self.timeoutWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.timedOut = true
                self.logger.info("autoSplashscreen timeout reached, hiding splashscreen")
                self.delegate?.onSplashscreenTimeout()
                self.hide()
            }
            self.timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.timeout), execute: workItem)
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
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
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
