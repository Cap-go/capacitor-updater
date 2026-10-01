/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor
import UIKit
import WebKit

/// WebView side of the engine hooks: serving a bundle, stamping the page
/// generation for `notifyAppReady`, the keep-URL-path flag and the preview notice.
extension CapacitorUpdaterPlugin {
    var builtinFolder: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("public")
    }

    /// Folder served for the engine's current bundle path. The id is re-resolved
    /// under the bundle root: the app container path changes across installs.
    func bundleFolder(path: String, isBuiltin: Bool) -> URL {
        if isBuiltin || path.isEmpty {
            return builtinFolder
        }
        let id = URL(fileURLWithPath: path).lastPathComponent
        return (try? implementation.bundleDirectory(id: id)) ?? builtinFolder
    }

    func initialLoad(_ loaded: [String: Any]) -> Bool {
        guard let bridge = self.bridge else { return false }
        let id = (loaded["bundle"] as? [String: Any])?["id"] as? String ?? "builtin"
        var dest = bundleFolder(path: loaded["path"] as? String ?? "", isBuiltin: loaded["isBuiltin"] as? Bool ?? true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            logger.error("Initial load fail - file at path \(dest.path) doesn't exist. Defaulting to buildin!! \(id)")
            dest = builtinFolder
        }
        logger.info("Initial load \(id)")
        // The view controller does not work during the initial load state.
        bridge.setServerBasePath(dest.path)
        return true
    }

    /// `applyBundle` hook: stamps the page generation and points the WebView at the bundle.
    func applyBundle(_ payload: [String: Any]) -> [String: Any] {
        guard let viewController = self.bridge?.viewController as? CAPBridgeViewController else {
            logger.error("Cannot get viewController")
            return ["ok": false]
        }
        guard let capBridge = viewController.bridge else {
            logger.error("Cannot get capBridge")
            return ["ok": false]
        }
        let guarded = stampReadyGeneration(payload["readyScript"] as? String ?? "", webView: viewController.webView)
        let dest = bundleFolder(path: payload["path"] as? String ?? "", isBuiltin: payload["isBuiltin"] as? Bool ?? false)
        if keepUrlPathAfterReload {
            if let currentURL = viewController.webView?.url {
                capBridge.setServerBasePath(dest.path)
                var urlComponents = URLComponents(url: capBridge.config.serverURL, resolvingAgainstBaseURL: false)
                urlComponents?.path = currentURL.path
                urlComponents?.query = currentURL.query
                urlComponents?.fragment = currentURL.fragment
                if let finalUrl = urlComponents?.url {
                    _ = viewController.webView?.load(URLRequest(url: finalUrl))
                } else {
                    logger.error("Unable to build final URL when keeping path after reload; falling back to base path")
                    viewController.setServerBasePath(path: dest.path)
                }
            } else {
                logger.error("vc.webView?.url is null? Falling back to base path reload.")
                viewController.setServerBasePath(path: dest.path)
            }
        } else {
            viewController.setServerBasePath(path: dest.path)
        }
        return ["ok": true, "guard": guarded]
    }

    /// Makes the next document report its generation with notifyAppReady (`script` is the
    /// engine's `readyScript`); false without a webview or a script.
    func stampReadyGeneration(_ script: String, webView: WKWebView?) -> Bool {
        guard let webView else {
            logger.warn("Cannot stamp notifyAppReady generation without a webview")
            return false
        }
        guard !script.isEmpty else {
            return false
        }
        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        return true
    }

    func syncKeepUrlPathFlag(enabled: Bool) {
        let script: String
        if enabled {
            script = "(function(){ try { localStorage.setItem('\(keepUrlPathFlagKey)', '1'); } catch (err) {} window.__capgoKeepUrlPathAfterReload = true; var evt; try { evt = new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', { detail: { enabled: true } }); } catch (e) { evt = document.createEvent('CustomEvent'); evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', false, false, { enabled: true }); } window.dispatchEvent(evt); })();"
        } else {
            script = "(function(){ try { localStorage.removeItem('\(keepUrlPathFlagKey)'); } catch (err) {} delete window.__capgoKeepUrlPathAfterReload; var evt; try { evt = new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', { detail: { enabled: false } }); } catch (e) { evt = document.createEvent('CustomEvent'); evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload', false, false, { enabled: false }); } window.dispatchEvent(evt); })();"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.bridge?.webView else {
                return
            }
            if self.keepUrlPathFlagLastValue != enabled {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                webView.configuration.userContentController.addUserScript(userScript)
                self.keepUrlPathFlagLastValue = enabled
            }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Preview notice

    /// "Preview started" alert; false when it cannot be shown now (the engine retries later).
    func showPreviewNotice(gesture: String) -> Bool {
        guard let topVC = UIApplication.topViewController(self.bridge?.viewController),
              !topVC.isKind(of: UIAlertController.self) else {
            return false
        }
        let alert = UIAlertController(
            title: "Preview started",
            message: gesture == Self.shakeMenuGestureThreeFingerPinch ? "Three-finger pinch to open menu." : "Shake to open menu.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Got it", style: .default))
        topVC.present(alert, animated: true)
        return true
    }
}
