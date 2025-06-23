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
    
    static let DELAY_CONDITION_PREFERENCES = "DELAY_CONDITION_PREFERENCES_CAPGO"
    static let BACKGROUND_TIMESTAMP_KEY = "BACKGROUND_TIMESTAMP_KEY_CAPGO"
    
    private let currentVersionNative: Version
    private let installNext: () -> Void
    
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
    
    public init(currentVersionNative: Version, installNext: @escaping () -> Void) {
        self.currentVersionNative = currentVersionNative
        self.installNext = installNext
    }
    
    public func checkCancelDelay(source: CancelDelaySource) {
        let delayUpdatePreferences = UserDefaults.standard.string(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES) ?? "[]"
        let delayConditionList: [DelayCondition] = fromJsonArr(json: delayUpdatePreferences).map { obj -> DelayCondition in
            let kind: String = obj.value(forKey: "kind") as! String
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
                        print("\(CapacitorUpdater.TAG) Background condition (value: \(value ?? "")) deleted at index \(index). Delta: \(delta), longValue: \(longValue)")
                    } else {
                        delayConditionListToKeep.append(condition)
                        print("\(CapacitorUpdater.TAG) Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                    }
                } else {
                    delayConditionListToKeep.append(condition)
                    print("\(CapacitorUpdater.TAG) Background delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }
                
            case "kill":
                if source == .killed {
                    self.installNext()
                } else {
                    delayConditionListToKeep.append(condition)
                    print("\(CapacitorUpdater.TAG) Kill delay (value: \(value ?? "")) condition kept at index \(index) (source: \(source.description))")
                }
                
            case "date":
                if let value = value, !value.isEmpty {
                    do {
                        let dateFormatter = ISO8601DateFormatter()
                        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        
                        if let date = dateFormatter.date(from: value) {
                            if Date() > date {
                                print("\(CapacitorUpdater.TAG) Date delay (value: \(value)) condition removed due to expired date at index \(index)")
                            } else {
                                delayConditionListToKeep.append(condition)
                                print("\(CapacitorUpdater.TAG) Date delay (value: \(value)) condition kept at index \(index)")
                            }
                        } else {
                            print("\(CapacitorUpdater.TAG) Date delay (value: \(value)) condition removed due to parsing issue at index \(index)")
                        }
                    } catch {
                        print("\(CapacitorUpdater.TAG) Date delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)")
                    }
                } else {
                    print("\(CapacitorUpdater.TAG) Date delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }
                
            case "nativeVersion":
                if let value = value, !value.isEmpty {
                    do {
                        let versionLimit = try Version(value)
                        if currentVersionNative >= versionLimit {
                            print("\(CapacitorUpdater.TAG) Native version delay (value: \(value)) condition removed due to above limit at index \(index)")
                        } else {
                            delayConditionListToKeep.append(condition)
                            print("\(CapacitorUpdater.TAG) Native version delay (value: \(value)) condition kept at index \(index)")
                        }
                    } catch {
                        print("\(CapacitorUpdater.TAG) Native version delay (value: \(value)) condition removed due to parsing issue at index \(index): \(error)")
                    }
                } else {
                    print("\(CapacitorUpdater.TAG) Native version delay (value: \(value ?? "")) condition removed due to empty value at index \(index)")
                }
                
            default:
                print("\(CapacitorUpdater.TAG) Unknown delay condition kind: \(kind) at index \(index)")
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
            print("\(CapacitorUpdater.TAG) Delay update saved")
            return true
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to delay update, [Error calling 'setMultiDelay()']: \(error)")
            return false
        }
    }
    
    public func setBackgroundTimestamp(_ backgroundTimestamp: Int64) {
        do {
            UserDefaults.standard.set(backgroundTimestamp, forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
            UserDefaults.standard.synchronize()
            print("\(CapacitorUpdater.TAG) Background timestamp saved")
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to save background timestamp, [Error calling 'setBackgroundTimestamp()']: \(error)")
        }
    }
    
    public func unsetBackgroundTimestamp() {
        do {
            UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY)
            UserDefaults.standard.synchronize()
            print("\(CapacitorUpdater.TAG) Background timestamp removed")
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to remove background timestamp, [Error calling 'unsetBackgroundTimestamp()']: \(error)")
        }
    }
    
    private func getBackgroundTimestamp() -> Int64 {
        do {
            let timestamp = UserDefaults.standard.object(forKey: DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY) as? Int64 ?? 0
            return timestamp
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to get background timestamp, [Error calling 'getBackgroundTimestamp()']: \(error)")
            return 0
        }
    }
    
    public func cancelDelay(source: String) -> Bool {
        do {
            UserDefaults.standard.removeObject(forKey: DelayUpdateUtils.DELAY_CONDITION_PREFERENCES)
            UserDefaults.standard.synchronize()
            print("\(CapacitorUpdater.TAG) All delays canceled from \(source)")
            return true
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to cancel update delay: \(error)")
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