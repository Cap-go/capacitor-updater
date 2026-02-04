/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

// MARK: - Delay and AutoUpdate Methods
extension CapacitorUpdaterPlugin {
    @objc func notifyAppReady(_ call: CAPPluginCall) {
        self.semaphoreDown()
        let bundle = self.implementation.getCurrentBundle()
        self.implementation.setSuccess(bundle: bundle, autoDeletePrevious: self.autoDeletePrevious)
        logger.info("Current bundle loaded successfully. [notifyAppReady was called] \(bundle.toString())")
        call.resolve(["bundle": bundle.toJSON()])
    }

    @objc func setMultiDelay(_ call: CAPPluginCall) {
        guard let delayConditionList = call.getValue("delayConditions") else {
            logger.error("setMultiDelay called without delayCondition")
            call.reject("setMultiDelay called without delayCondition")
            return
        }

        // Handle background conditions with empty value (set to "0")
        if var modifiableList = delayConditionList as? [[String: Any]] {
            for index in 0..<modifiableList.count {
                if let kind = modifiableList[index]["kind"] as? String,
                   kind == "background",
                   let value = modifiableList[index]["value"] as? String,
                   value.isEmpty {
                    modifiableList[index]["value"] = "0"
                }
            }
            let delayConditions: String = toJson(object: modifiableList)
            if delayUpdateUtils.setMultiDelay(delayConditions: delayConditions) {
                call.resolve()
            } else {
                call.reject("Failed to delay update")
            }
        } else {
            let delayConditions: String = toJson(object: delayConditionList)
            if delayUpdateUtils.setMultiDelay(delayConditions: delayConditions) {
                call.resolve()
            } else {
                call.reject("Failed to delay update")
            }
        }
    }

    // Note: _setMultiDelay and _cancelDelay methods have been moved to DelayUpdateUtils class

    @objc func cancelDelay(_ call: CAPPluginCall) {
        if delayUpdateUtils.cancelDelay(source: "JS") {
            call.resolve()
        } else {
            call.reject("Failed to cancel delay")
        }
    }

    // Note: _checkCancelDelay method has been moved to DelayUpdateUtils class

    func checkAutoUpdateEnabled() -> Bool {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        if instanceDescriptor?.serverURL != nil {
            logger.warn("AutoUpdate is automatic disabled when serverUrl is set.")
        }
        return self.autoUpdate && self.updateUrl != "" && instanceDescriptor?.serverURL == nil
    }

    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.checkAutoUpdateEnabled()
        ])
    }

    @objc func isAutoUpdateAvailable(_ call: CAPPluginCall) {
        let instanceDescriptor = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor()
        let isAvailable = instanceDescriptor?.serverURL == nil
        call.resolve([
            "available": isAvailable
        ])
    }

    @objc func setShakeMenu(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else {
            logger.error("setShakeMenu called without enabled parameter")
            call.reject("setShakeMenu called without enabled parameter")
            return
        }

        self.shakeMenuEnabled = enabled
        logger.info("Shake menu \(enabled ? "enabled" : "disabled")")
        call.resolve()
    }

    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self.shakeMenuEnabled
        ])
    }

    @objc func toJson(object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return ""
        }
        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }

    @objc func fromJsonArr(json: String) -> [NSObject] {
        guard let jsonData = json.data(using: .utf8) else {
            return []
        }
        let object = try? JSONSerialization.jsonObject(
            with: jsonData,
            options: .mutableContainers
        ) as? [NSObject]
        return object ?? []
    }
}
