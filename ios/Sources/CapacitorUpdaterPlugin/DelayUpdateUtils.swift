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

public class DelayUpdateUtils {

    // swiftlint:disable identifier_name
    static let DELAY_CONDITION_PREFERENCES = "DELAY_CONDITION_PREFERENCES_CAPGO"
    static let DELAY_CONDITION_MODE_PREFERENCES = "DELAY_CONDITION_MODE_PREFERENCES_CAPGO"
    static let DELAY_CONDITION_MODE_AND = "and"
    static let DELAY_CONDITION_MODE_OR = "or"
    static let BACKGROUND_TIMESTAMP_KEY = "BACKGROUND_TIMESTAMP_KEY_CAPGO"
    // swiftlint:enable identifier_name
    private let logger: Logger

    private let currentVersionNative: CapgoSemanticVersion

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

    public init(currentVersionNative: CapgoSemanticVersion, logger: Logger) {
        self.currentVersionNative = currentVersionNative
        self.logger = logger
    }

    public func checkCancelDelay(source: CancelDelaySource) {
        let delayUpdatePreferences = UserDefaults.standard.string(
            forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList = DelayUpdateUtils.parseDelayConditions(json: delayUpdatePreferences)
        if delayConditionList.isEmpty {
            return
        }

        let useOrMode = isOrConditionMode()
        var delayConditionListToKeep: [DelayCondition] = []
        var index = 0
        var anyConditionMet = false

        for condition in delayConditionList {
            let result = evaluateCondition(condition, source: source, index: index)
            if result.met {
                anyConditionMet = true
                if !useOrMode, let logMessage = result.logMessage {
                    logger.info(logMessage)
                }
            } else if !useOrMode {
                if result.keep {
                    delayConditionListToKeep.append(condition)
                }
                if let logMessage = result.logMessage {
                    if result.error {
                        logger.error(logMessage)
                    } else {
                        logger.info(logMessage)
                    }
                }
            }
            index += 1
        }

        if useOrMode {
            if anyConditionMet {
                logger.info("Delay condition met in OR mode (source: \(source.description)), canceling delay")
                _ = cancelDelay(source: "checkCancelDelay")
            }
            return
        }

        if !delayConditionListToKeep.isEmpty {
            let json = toJson(object: delayConditionListToKeep.map { $0.toJSON() })
            _ = setMultiDelay(delayConditions: json)
        } else {
            _ = cancelDelay(source: "checkCancelDelay")
        }
    }

    private struct ConditionCheckResult {
        let met: Bool
        let keep: Bool
        let error: Bool
        let logMessage: String?
    }

    private func evaluateCondition(_ condition: DelayCondition, source: CancelDelaySource, index: Int) -> ConditionCheckResult {
        let kind = condition.getKind()
        let value = condition.getValue()

        switch kind {
        case "background":
            if source == .foreground {
                let backgroundedAt = getBackgroundTimestamp()
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let delta = max(0, now - backgroundedAt)
                var longValue: Int64 = 0
                if let value = value, !value.isEmpty {
                    longValue = Int64(value) ?? 0
                }

                if delta > longValue {
                    return ConditionCheckResult(
                        met: true,
                        keep: false,
                        error: false,
                        logMessage: "Background condition (value: \(value ?? "")) deleted at index \(index). Delta: \(delta), longValue: \(longValue)"
                    )
                }
                return ConditionCheckResult(
                    met: false,
                    keep: true,
                    error: false,
                    logMessage: "Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))"
                )
            }
            return ConditionCheckResult(
                met: false,
                keep: true,
                error: false,
                logMessage: "Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))"
            )

        case "kill":
            if source == .killed {
                return ConditionCheckResult(
                    met: true,
                    keep: false,
                    error: false,
                    logMessage: "Kill delay (value: \(value ?? "")) removed at index \(index) after app kill"
                )
            }
            return ConditionCheckResult(
                met: false,
                keep: true,
                error: false,
                logMessage: "Kill delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))"
            )

        case "date":
            if let value = value, !value.isEmpty {
                if let date = parseDateCondition(value) {
                    if Date() > date {
                        return ConditionCheckResult(
                            met: true,
                            keep: false,
                            error: false,
                            logMessage: "Date delay (value: \(value)) condition removed due to expired date at index \(index)"
                        )
                    }
                    return ConditionCheckResult(met: false, keep: true, error: false, logMessage: "Date delay (value: \(value)) kept at index \(index)")
                }
                return ConditionCheckResult(
                    met: false,
                    keep: false,
                    error: true,
                    logMessage: "Date delay (value: \(value)) condition removed due to parsing issue at index \(index)"
                )
            }
            return ConditionCheckResult(
                met: false,
                keep: false,
                error: true,
                logMessage: "Date delay (value: \(value ?? "")) condition removed due to empty value at index \(index)"
            )

        case "nativeVersion":
            if let value = value, !value.isEmpty {
                do {
                    let versionLimit = try CapgoSemanticVersion(value)
                    if currentVersionNative >= versionLimit {
                        return ConditionCheckResult(
                            met: true,
                            keep: false,
                            error: false,
                            logMessage: "Native version delay (value: \(value)) condition removed due to above limit at index \(index)"
                        )
                    }
                    return ConditionCheckResult(met: false, keep: true, error: false, logMessage: "Native version delay (value: \(value)) kept at index \(index)")
                } catch {
                    return ConditionCheckResult(
                        met: false,
                        keep: false,
                        error: true,
                        logMessage: "Native version delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)"
                    )
                }
            }
            return ConditionCheckResult(
                met: false,
                keep: false,
                error: true,
                logMessage: "Native version delay (value: \(value ?? "")) condition removed due to empty value at index \(index)"
            )

        default:
            return ConditionCheckResult(met: false, keep: false, error: true, logMessage: "Unknown delay condition kind: \(kind) at index \(index)")
        }
    }

    public func isOrConditionMode() -> Bool {
        return getConditionMode() == DelayUpdateUtils.DELAY_CONDITION_MODE_OR
    }

    public func getConditionMode() -> String {
        let mode = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_MODE_PREFERENCES)
            ?? DelayUpdateUtils.DELAY_CONDITION_MODE_AND
        return mode == DelayUpdateUtils.DELAY_CONDITION_MODE_OR
            ? DelayUpdateUtils.DELAY_CONDITION_MODE_OR
            : DelayUpdateUtils.DELAY_CONDITION_MODE_AND
    }

    public func setConditionMode(_ conditionMode: String) -> Bool {
        let normalized = conditionMode == DelayUpdateUtils.DELAY_CONDITION_MODE_OR
            ? DelayUpdateUtils.DELAY_CONDITION_MODE_OR
            : DelayUpdateUtils.DELAY_CONDITION_MODE_AND
        if conditionMode != DelayUpdateUtils.DELAY_CONDITION_MODE_AND
            && conditionMode != DelayUpdateUtils.DELAY_CONDITION_MODE_OR {
            logger.warn("Unknown delay condition mode '\(conditionMode)', defaulting to '\(DelayUpdateUtils.DELAY_CONDITION_MODE_AND)'")
        }
        UserDefaults.standard.set(normalized, forKey: DelayUpdateUtils.DELAY_CONDITION_MODE_PREFERENCES)
        UserDefaults.standard.synchronize()
        logger.info("Delay condition mode saved: \(normalized)")
        return true
    }

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

    private func getBackgroundTimestamp() -> Int64 {
        let key = DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY
        return UserDefaults.standard.object(forKey: key) as? Int64 ?? 0
    }

    public func cancelDelay(source: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
        UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.DELAY_CONDITION_MODE_PREFERENCES)
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

    /// Parses stored delay conditions. Malformed JSON and entries without a string `kind` are dropped.
    static func parseDelayConditions(json: String) -> [DelayCondition] {
        guard let jsonData = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: jsonData)) as? [Any] else {
            return []
        }
        return entries.compactMap { entry in
            guard let object = entry as? [String: Any], let kind = object["kind"] as? String else {
                return nil
            }
            return DelayCondition(kind: kind, value: object["value"] as? String)
        }
    }
}
