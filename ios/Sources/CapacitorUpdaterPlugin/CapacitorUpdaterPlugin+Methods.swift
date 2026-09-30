/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

/// JavaScript methods implemented by the engine (`pluginMethod`).
extension CapacitorUpdaterPlugin {
    /// Forwards a plugin call to the engine off the main thread and settles it.
    func forward(_ call: CAPPluginCall) {
        let name = call.methodName ?? ""
        let args = (call.options as? [String: Any]) ?? [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                call.reject("Plugin unavailable")
                return
            }
            switch self.runEngineMethod(name, args) {
            case .resolved(let value):
                if let value = value as? [String: Any] {
                    call.resolve(value)
                } else {
                    call.resolve()
                }
            case .rejected(let message, let code, let data):
                call.reject(message, code, nil, data)
            }
        }
    }

    @objc func notifyAppReady(_ call: CAPPluginCall) { forward(call) }
    @objc func setUpdateUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func setStatsUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func setChannelUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func download(_ call: CAPPluginCall) { forward(call) }
    @objc func next(_ call: CAPPluginCall) { forward(call) }
    @objc func set(_ call: CAPPluginCall) { forward(call) }
    @objc func startPreviewSession(_ call: CAPPluginCall) { forward(call) }
    @objc func listPreviews(_ call: CAPPluginCall) { forward(call) }
    @objc func setPreview(_ call: CAPPluginCall) { forward(call) }
    @objc func resetPreview(_ call: CAPPluginCall) { forward(call) }
    @objc func deletePreview(_ call: CAPPluginCall) { forward(call) }
    @objc func checkPreviewUpdate(_ call: CAPPluginCall) { forward(call) }
    @objc func updatePreview(_ call: CAPPluginCall) { forward(call) }
    @objc func delete(_ call: CAPPluginCall) { forward(call) }
    @objc func setBundleError(_ call: CAPPluginCall) { forward(call) }
    @objc func list(_ call: CAPPluginCall) { forward(call) }
    @objc func reset(_ call: CAPPluginCall) { forward(call) }
    @objc func current(_ call: CAPPluginCall) { forward(call) }
    @objc func reload(_ call: CAPPluginCall) { forward(call) }
    @objc func setMultiDelay(_ call: CAPPluginCall) { forward(call) }
    @objc func cancelDelay(_ call: CAPPluginCall) { forward(call) }
    @objc func triggerUpdateCheck(_ call: CAPPluginCall) { forward(call) }
    @objc func getLatest(_ call: CAPPluginCall) { forward(call) }
    @objc func getMissingBundleFiles(_ call: CAPPluginCall) { forward(call) }
    @objc func getBundleDownloadSize(_ call: CAPPluginCall) { forward(call) }
    @objc func setChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func unsetChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func getChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func listChannels(_ call: CAPPluginCall) { forward(call) }
    @objc func setCustomId(_ call: CAPPluginCall) { forward(call) }
    @objc func getBuiltinVersion(_ call: CAPPluginCall) { forward(call) }
    @objc func getDeviceId(_ call: CAPPluginCall) { forward(call) }
    @objc func getPluginVersion(_ call: CAPPluginCall) { forward(call) }
    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func isAutoUpdateAvailable(_ call: CAPPluginCall) { forward(call) }
    @objc func getNextBundle(_ call: CAPPluginCall) { forward(call) }
    @objc func getFailedUpdate(_ call: CAPPluginCall) { forward(call) }
    @objc func setShakeMenu(_ call: CAPPluginCall) { forward(call) }
    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func setShakeChannelSelector(_ call: CAPPluginCall) { forward(call) }
    @objc func isShakeChannelSelectorEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func getAppId(_ call: CAPPluginCall) { forward(call) }
    @objc func setAppId(_ call: CAPPluginCall) { forward(call) }
    @objc func reportWebViewError(_ call: CAPPluginCall) { forward(call) }
}
