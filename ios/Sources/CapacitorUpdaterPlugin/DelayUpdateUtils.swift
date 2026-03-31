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
                    guard let backgroundedAt = getBackgroundTimestamp() else {
                        delayConditionListToKeep.append(condition)
                        // swiftlint:disable:next line_length
                        logger.info("Background delay (value: \(value ?? "")) condition kept at index \(index) because no background timestamp was found")
                        index += 1
                        continue
                    }
                    let now = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
                    let delta = max(0, now - backgroundedAt)

                    var longValue: Int64 = 0
                    if let value = value, !value.isEmpty {
                        longValue = Int64(value) ?? 0
                    }

                    if delta > longValue {
                        // swiftlint:disable:next line_length
                        logger.info("Background condition (value: \(value ?? "")) deleted at index \(index). Delta: \(delta), longValue: \(longValue)")
                    } else {
                        delayConditionListToKeep.append(condition)
                        // swiftlint:disable:next line_length
                        logger.info("Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                    }
                } else {
                    delayConditionListToKeep.append(condition)
                    // swiftlint:disable:next line_length
                    logger.info("Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }

            case "kill":
                if source == .killed {
                    logger.info("Kill delay (value: \(value ?? "")) removed at index \(index) after app kill")
                } else {
                    delayConditionListToKeep.append(condition)
                    // swiftlint:disable:next line_length
                    logger.info("Kill delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }

            case "date":
                if let value = value, !value.isEmpty {
                    if let date = parseDateCondition(value) {
                        if Date() > date {
                            // swiftlint:disable:next line_length
                            logger.info("Date delay (value: \(value)) condition removed due to expired date at index \(index)")
                        } else {
                            delayConditionListToKeep.append(condition)
                            logger.info("Date delay (value: \(value)) kept at index \(index)")
                        }
                    } else {
                        // swiftlint:disable:next line_length
                        logger.error("Date delay (value: \(value)) condition removed due to parsing issue at index \(index)")
                    }
                } else {
                    // swiftlint:disable:next line_length
                    logger.error("Date delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }

            case "nativeVersion":
                if let value = value, !value.isEmpty {
                    do {
                        let versionLimit = try Version(value)
                        if currentVersionNative >= versionLimit {
                            // swiftlint:disable:next line_length
                            logger.info("Native version delay (value: \(value)) condition removed due to above limit at index \(index)")
                        } else {
                            delayConditionListToKeep.append(condition)
                            logger.info("Native version delay (value: \(value)) kept at index \(index)")
                        }
                    } catch {
                        // swiftlint:disable:next line_length
                        logger.error("Native version delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)")
                    }
                } else {
                    // swiftlint:disable:next line_length
                    logger.error("Native version delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }

            default:
                logger.error("Unknown delay condition kind: \(kind) at index \(index)")
            }

            index += 1
        }

        if !delayConditionListToKeep.isEmpty {
            let json = toJson(object: delayConditionListToKeep.map { $0.toJSON() })
            setMultiDelay(delayConditions: json)
        } else {
            // Clear all delay conditions if none are left to keep
            cancelDelay(source: "checkCancelDelay")
        }
    }

    @discardableResult
    public func setMultiDelay(delayConditions: String) -> Bool {
        UserDefaults.standard.set(delayConditions, forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
        UserDefaults.standard.synchronize()
        logger.info("Delay update saved")
        return true
    }

    public func setBackgroundTimestamp(_ backgroundTimestamp: Int64) {
        UserDefaults.standard.set(backgroundTimestamp, forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
        UserDefaults.standard.synchronize()
        logger.info("Background timestamp saved")
    }

    public func unsetBackgroundTimestamp() {
        UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
        UserDefaults.standard.synchronize()
        logger.info("Background timestamp removed")
    }

    private func getBackgroundTimestamp() -> Int64? {
        let key = DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY
        return (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
    }

    @discardableResult
    public func cancelDelay(source: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
        UserDefaults.standard.synchronize()
        logger.info("All delays canceled from \(source)")
        return true
    }

    // MARK: - Helper methods

    private func parseDateCondition(_ value: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: value) {
            return date
        }

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        if let date = withoutFractionalSeconds.date(from: value) {
            return date
        }

        // Legacy fallback for strings without timezone.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

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
