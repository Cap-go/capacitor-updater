/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.UnrecoverableEntryException;
import java.security.cert.CertificateException;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Helper class to manage device ID persistence across app installations.
 * Uses Android Keystore to persist the device ID across reinstalls.
 *
 * The device ID is a random UUID stored in the Android Keystore, which persists
 * even after app uninstall/reinstall on Android 6.0+ (API 23+).
 */
public class DeviceIdHelper {
    private static final String KEYSTORE_ALIAS = "capgo_device_id_key";
    private static final String ANDROID_KEYSTORE = "AndroidKeyStore";
    private static final String LEGACY_PREFS_KEY = "appUUID";
    private static final String DEVICE_ID_PREFS = "capgo_device_id";
    private static final String DEVICE_ID_KEY = "deviceId";
    private static final String IV_KEY = "iv";
    private static final int GCM_TAG_LENGTH = 128;

    /**
     * Gets or creates a device ID that persists across reinstalls.
     *
     * This method:
     * 1. First checks for an existing ID in Keystore-encrypted storage (persists across reinstalls)
     * 2. Falls back to legacy SharedPreferences (for migration)
     * 3. Generates a new UUID if neither exists
     * 4. Stores the ID in Keystore-encrypted storage for future use
     *
     * @param context Application context
     * @param legacyPrefs Legacy SharedPreferences (for migration)
     * @return Device ID as a lowercase UUID string
     */
    public static String getOrCreateDeviceId(Context context, SharedPreferences legacyPrefs) {
        // API 23+ required for Android Keystore
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return getFallbackDeviceId(legacyPrefs);
        }

        try {
            // Try to get device ID from Keystore storage
            String deviceId = getDeviceIdFromKeystore(context);

            if (deviceId != null && !deviceId.isEmpty()) {
                return deviceId.toLowerCase();
            }

            // Migration: Check legacy SharedPreferences for existing device ID
            deviceId = legacyPrefs.getString(LEGACY_PREFS_KEY, null);

            if (deviceId == null || deviceId.isEmpty()) {
                // Generate new device ID if none exists
                deviceId = UUID.randomUUID().toString();
            }

            // Ensure lowercase for consistency
            deviceId = deviceId.toLowerCase();

            // Save to Keystore storage
            saveDeviceIdToKeystore(context, deviceId);

            return deviceId;
        } catch (Exception e) {
            // Fallback to legacy method if Keystore fails
            return getFallbackDeviceId(legacyPrefs);
        }
    }

    /**
     * Retrieves the device ID from Keystore-encrypted storage.
     *
     * @param context Application context
     * @return Device ID string or null if not found
     */
    private static String getDeviceIdFromKeystore(Context context) throws Exception {
        SharedPreferences prefs = context.getSharedPreferences(DEVICE_ID_PREFS, Context.MODE_PRIVATE);
        String encryptedDeviceId = prefs.getString(DEVICE_ID_KEY, null);
        String ivString = prefs.getString(IV_KEY, null);

        if (encryptedDeviceId == null || ivString == null) {
            return null;
        }

        // Get the encryption key from Keystore
        SecretKey key = getOrCreateKey();
        if (key == null) {
            return null;
        }

        // Decrypt the device ID
        byte[] encryptedBytes = android.util.Base64.decode(encryptedDeviceId, android.util.Base64.DEFAULT);
        byte[] iv = android.util.Base64.decode(ivString, android.util.Base64.DEFAULT);

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        GCMParameterSpec spec = new GCMParameterSpec(GCM_TAG_LENGTH, iv);
        cipher.init(Cipher.DECRYPT_MODE, key, spec);

        byte[] decryptedBytes = cipher.doFinal(encryptedBytes);
        return new String(decryptedBytes, StandardCharsets.UTF_8);
    }

    /**
     * Saves the device ID to Keystore-encrypted storage.
     *
     * The device ID is encrypted using AES/GCM with a key stored in Android Keystore.
     * The Keystore key persists across reinstalls on Android 6.0+ (API 23+).
     *
     * @param context Application context
     * @param deviceId The device ID to save
     */
    private static void saveDeviceIdToKeystore(Context context, String deviceId) throws Exception {
        // Get or create encryption key in Keystore
        SecretKey key = getOrCreateKey();
        if (key == null) {
            throw new Exception("Failed to get encryption key");
        }

        // Encrypt the device ID
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key);

        byte[] iv = cipher.getIV();
        byte[] encryptedBytes = cipher.doFinal(deviceId.getBytes(StandardCharsets.UTF_8));

        // Store encrypted device ID and IV in SharedPreferences
        SharedPreferences prefs = context.getSharedPreferences(DEVICE_ID_PREFS, Context.MODE_PRIVATE);
        prefs.edit()
            .putString(DEVICE_ID_KEY, android.util.Base64.encodeToString(encryptedBytes, android.util.Base64.DEFAULT))
            .putString(IV_KEY, android.util.Base64.encodeToString(iv, android.util.Base64.DEFAULT))
            .apply();
    }

    /**
     * Gets or creates the encryption key in Android Keystore.
     *
     * The key is configured to persist across reinstalls and not require user authentication.
     *
     * @return SecretKey from Keystore or null if failed
     */
    private static SecretKey getOrCreateKey() {
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEYSTORE);
            keyStore.load(null);

            // Check if key already exists
            if (keyStore.containsAlias(KEYSTORE_ALIAS)) {
                KeyStore.SecretKeyEntry entry = (KeyStore.SecretKeyEntry) keyStore.getEntry(KEYSTORE_ALIAS, null);
                return entry.getSecretKey();
            }

            // Create new key
            KeyGenerator keyGenerator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                ANDROID_KEYSTORE
            );

            KeyGenParameterSpec keySpec = new KeyGenParameterSpec.Builder(
                KEYSTORE_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build();

            keyGenerator.init(keySpec);
            return keyGenerator.generateKey();
        } catch (KeyStoreException | CertificateException | NoSuchAlgorithmException |
                 IOException | NoSuchProviderException | UnrecoverableEntryException e) {
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Fallback method using legacy SharedPreferences if Keystore fails or API < 23.
     *
     * @param legacyPrefs Legacy SharedPreferences
     * @return Device ID string
     */
    private static String getFallbackDeviceId(SharedPreferences legacyPrefs) {
        String deviceId = legacyPrefs.getString(LEGACY_PREFS_KEY, null);

        if (deviceId == null || deviceId.isEmpty()) {
            deviceId = UUID.randomUUID().toString();
            legacyPrefs.edit().putString(LEGACY_PREFS_KEY, deviceId).apply();
        }

        return deviceId.toLowerCase();
    }
}
