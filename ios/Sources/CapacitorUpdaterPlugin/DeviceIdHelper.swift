/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Security

/**
 * Helper class to manage device ID persistence across app installations.
 * Uses iOS Keychain to persist the device ID.
 */
class DeviceIdHelper {
    private static let keychainService = "app.capgo.updater"
    private static let keychainAccount = "deviceId"
    private static let legacyDefaultsKey = "appUUID"

    /**
     * Gets or creates a device ID that persists across reinstalls.
     *
     * This method:
     * 1. First checks for an existing ID in Keychain (persists across reinstalls)
     * 2. Falls back to UserDefaults (for migration from older versions)
     * 3. Generates a new UUID if neither exists
     * 4. Stores the ID in Keychain for future use
     *
     * @return Device ID as a lowercase UUID string
     */
    static func getOrCreateDeviceId() -> String {
        // Try to get device ID from Keychain first
        if let keychainDeviceId = getDeviceIdFromKeychain() {
            return keychainDeviceId.lowercased()
        }

        // Migration: Check UserDefaults for existing device ID
        var deviceId = UserDefaults.standard.string(forKey: legacyDefaultsKey)

        if deviceId == nil || deviceId!.isEmpty {
            // Generate new device ID if none exists
            deviceId = UUID().uuidString
        }

        // Ensure lowercase for consistency
        deviceId = deviceId!.lowercased()

        // Save to Keychain for persistence across reinstalls
        saveDeviceIdToKeychain(deviceId: deviceId!)

        return deviceId!
    }

    /**
     * Retrieves the device ID from iOS Keychain.
     *
     * @return Device ID string or nil if not found
     */
    private static func getDeviceIdFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let deviceId = String(data: data, encoding: .utf8) else {
            return nil
        }

        return deviceId
    }

    /**
     * Saves the device ID to iOS Keychain with appropriate accessibility settings.
     *
     * Uses kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly:
     * - Data persists across reinstalls
     * - Data is NOT synced to iCloud
     * - Data is accessible after first device unlock
     * - Data stays on this device only (privacy-friendly)
     *
     * @param deviceId The device ID to save
     */
    private static func saveDeviceIdToKeychain(deviceId: String) {
        guard let data = deviceId.data(using: .utf8) else {
            return
        }

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry with appropriate accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            // This ensures data persists across reinstalls but stays on device (not synced)
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status != errSecSuccess {
            // Log error but don't crash - we'll fall back to UserDefaults on next launch
            print("Failed to save device ID to Keychain: \(status)")
        }
    }
}
