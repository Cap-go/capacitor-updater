/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

//
//  DelayUpdateUtils.swift
//  Plugin
//
//  Created by Auto-generated based on Android implementation
//  Copyright © 2024 Capgo. All rights reserved.
//

import Foundation
import Version

public class DelayUpdateUtils {

    // swiftlint:disable identifier_name
    static let DELAY_CONDITION_PREFERENCES = "DELAY_CONDITION_PREFERENCES_CAPGO"
    static let BACKGROUND_TIMESTAMP_KEY = "BACKGROUND_TIMESTAMP_KEY_CAPGO"
    // swiftlint:enable identifier_name
    private let logger: Logger

    private let currentVersionNative: Version

    public enum CancelDelaySource {
        case killed
        case background
        case foreground

        var description: String {
            switch self {
            case .killed: return "KILLED"
            case .background: return "BACKGROUND"
            case .foreground: return "FOREGROUND"
            }
        }
    }

    public init(currentVersionNative: Version, logger: Logger) {
        self.currentVersionNative = currentVersionNative
        self.logger = logger
    }

    public func checkCancelDelay(source: CancelDelaySource) {
        let delayUpdatePreferences = UserDefaults.standard.string(
            forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).compactMap { obj in
            guard let kind = obj.value(forKey: "kind") as? String else { return nil }
            let value: String? = obj.value(forKey: "value") as? String
            return DelayCondition(kind: kind, value: value)
        }

        var delayConditionListToKeep: [DelayCondition] = []
        var index = 0

        for condition in delayConditionList {
            let kind = condition.getKind()
            let value = condition.getValue()

            switch kind {
            case "background":
                if source == .foreground {
                    let backgroundedAt = getBackgroundTimestamp()
                    let now = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
                    let delta = max(0, now - backgroundedAt)

                    var longValue: Int64 = 0
                    if let value = value, !value.isEmpty {
                        longValue = Int64(value) ?? 0
                    }

                    if delta > longValue {
                        logger.info("Background condition (value: \(value ?? "")) deleted at index \(index). Delta: \(delta), longValue: \(longValue)")
                    } else {
                        delayConditionListToKeep.append(condition)
                        logger.info("Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                    }
                } else {
                    delayConditionListToKeep.append(condition)
                    logger.info("Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }

            case "kill":
                if source == .killed {
                    logger.info("Kill delay (value: \(value ?? "")) removed at index \(index) after app kill")
                } else {
                    delayConditionListToKeep.append(condition)
                    logger.info("Kill delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }

            case "date":
                if let value = value, !value.isEmpty {
                    do {
                        let dateFormatter = ISO8601DateFormatter()
                        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                        if let date = dateFormatter.date(from: value) {
                            if Date() > date {
                                logger.info("Date delay (value: \(value)) condition removed due to expired date at index \(index)")
                            } else {
                                delayConditionListToKeep.append(condition)
                                logger.info("Date delay (value: \(value)) kept at index \(index)")
                            }
                        } else {
                            logger.error("Date delay (value: \(value)) condition removed due to parsing issue at index \(index)")
                        }
                    } catch {
                        logger.error("Date delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)")
                    }
                } else {
                    logger.error("Date delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }

            case "nativeVersion":
                if let value = value, !value.isEmpty {
                    do {
                        let versionLimit = try Version(value)
                        if currentVersionNative >= versionLimit {
                            logger.info("Native version delay (value: \(value)) condition removed due to above limit at index \(index)")
                        } else {
                            delayConditionListToKeep.append(condition)
                            logger.info("Native version delay (value: \(value)) kept at index \(index)")
                        }
                    } catch {
                        logger.error("Native version delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)")
                    }
                } else {
                    logger.error("Native version delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }

            default:
                logger.error("Unknown delay condition kind: \(kind) at index \(index)")
            }

            index += 1
        }

        if !delayConditionListToKeep.isEmpty {
            let json = toJson(object: delayConditionListToKeep.map { $0.toJSON() })
            _ = setMultiDelay(delayConditions: json)
        } else {
            // Clear all delay conditions if none are left to keep
            _ = cancelDelay(source: "checkCancelDelay")
        }
    }

    public func setMultiDelay(delayConditions: String) -> Bool {
        do {
            UserDefaults.standard.set(delayConditions, forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
            UserDefaults.standard.synchronize()
            logger.info("Delay update saved")
            return true
        } catch {
            logger.error("Failed to delay update, [Error calling 'setMultiDelay()']: \(error)")
            return false
        }
    }

    public func setBackgroundTimestamp(_ backgroundTimestamp: Int64) {
        do {
            UserDefaults.standard.set(backgroundTimestamp, forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
            UserDefaults.standard.synchronize()
            logger.info("Background timestamp saved")
        } catch {
            logger.error("Failed to save background timestamp, [Error calling 'setBackgroundTimestamp()']: \(error)")
        }
    }

    public func unsetBackgroundTimestamp() {
        do {
            UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
            UserDefaults.standard.synchronize()
            logger.info("Background timestamp removed")
        } catch {
            logger.error("Failed to remove background timestamp, [Error calling 'unsetBackgroundTimestamp()']: \(error)")
        }
    }

    private func getBackgroundTimestamp() -> Int64 {
        do {
            let key = DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY
            let timestamp = UserDefaults.standard.object(forKey: key) as? Int64 ?? 0
            return timestamp
        } catch {
            logger.error("Failed to get background timestamp, [Error calling 'getBackgroundTimestamp()']: \(error)")
            return 0
        }
    }

    public func cancelDelay(source: String) -> Bool {
        do {
            UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
            UserDefaults.standard.synchronize()
            logger.info("All delays canceled from \(source)")
            return true
        } catch {
            logger.error("Failed to cancel update delay: \(error)")
            return false
        }
    }

    // MARK: - Helper methods

    private func toJson(object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return ""
        }
        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }

    private func fromJsonArr(json: String) -> [NSObject] {
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
