/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.util.Base64;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.security.GeneralSecurityException;
import java.security.InvalidAlgorithmParameterException;
import java.security.InvalidKeyException;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.PublicKey;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.X509EncodedKeySpec;
import javax.crypto.BadPaddingException;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONObject;

/**
 * Bundle crypto entry points. RSA recovery (PKCS#1 v1.5 type 1, as produced by the Capgo CLI with
 * {@code privateEncrypt}), AES-128-CBC decryption and file SHA-256 run in the shared Rust core; this class keeps the
 * plugin's Java API, logging and exception types.
 */
public class CryptoCipher {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    /** Recovers data signed with the private key matching {@code publicKey}. */
    public static byte[] decryptRSA(byte[] source, PublicKey publicKey)
        throws NoSuchPaddingException, NoSuchAlgorithmException, InvalidAlgorithmParameterException, InvalidKeyException, IllegalBlockSizeException, BadPaddingException {
        if (publicKey == null || publicKey.getEncoded() == null) {
            throw new InvalidKeyException("Missing RSA public key");
        }
        try {
            final JSONObject result = CapgoCore.call(
                "rsaPublicDecrypt",
                CapgoCore.input(
                    "publicKey",
                    Base64.encodeToString(publicKey.getEncoded(), Base64.NO_WRAP),
                    "ciphertextHex",
                    CapgoCore.hex(source)
                )
            );
            return CapgoCore.bytes(result.optString("plaintextHex", ""));
        } catch (CapgoCore.Failure e) {
            if ("invalid_public_key".equals(e.code)) {
                throw new InvalidKeyException(e.getMessage());
            }
            throw new BadPaddingException(e.getMessage());
        }
    }

    public static byte[] decryptAES(byte[] cipherText, SecretKey key, byte[] iv) throws GeneralSecurityException {
        if (key == null || iv == null) {
            throw new IllegalArgumentException("AES key and IV must not be null");
        }
        try {
            final JSONObject result = CapgoCore.call(
                "aesDecrypt",
                CapgoCore.input(
                    "ciphertextHex",
                    CapgoCore.hex(cipherText),
                    "keyHex",
                    CapgoCore.hex(key.getEncoded()),
                    "ivHex",
                    CapgoCore.hex(iv)
                )
            );
            return CapgoCore.bytes(result.optString("plaintextHex", ""));
        } catch (CapgoCore.Failure e) {
            throw new GeneralSecurityException(e.getMessage());
        }
    }

    public static SecretKey byteToSessionKey(byte[] sessionKey) {
        // rebuild key using SecretKeySpec
        return new SecretKeySpec(sessionKey, 0, sessionKey.length, "AES");
    }

    /** Parses a PKCS#1 ({@code RSA PUBLIC KEY}) or SPKI ({@code PUBLIC KEY}) PEM with the shared core rules. */
    public static PublicKey stringToPublicKey(String public_key) throws GeneralSecurityException {
        final JSONObject info;
        try {
            info = CapgoCore.call("publicKeyInfo", CapgoCore.input("publicKey", public_key == null ? "" : public_key));
        } catch (CapgoCore.Failure e) {
            throw new InvalidKeySpecException(e.getMessage());
        }
        final byte[] spki = Base64.decode(info.optString("spkiDerBase64", ""), Base64.NO_WRAP);
        return KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(spki));
    }

    public static boolean isValidSessionKey(final String sessionKey) {
        return CapgoCore.bool("sessionKeyValid", CapgoCore.input("sessionKey", sessionKey), "valid", false);
    }

    /** Decrypts an encrypted bundle in place. No-op when the bundle is not encrypted. */
    public static void decryptFile(final File file, final String publicKey, final String ivSessionKey) throws IOException {
        final String outcome;
        try {
            final JSONObject result = CapgoCore.call(
                "decryptFile",
                CapgoCore.input("path", file.getAbsolutePath(), "publicKey", publicKey, "sessionKey", ivSessionKey)
            );
            outcome = result.optString("outcome", "");
        } catch (CapgoCore.Failure e) {
            if (logger != null) {
                logger.info("decryptFile fail");
            }
            throw new IOException("AES file decryption failed: " + e.getMessage(), e);
        }
        if (logger != null && "notEncrypted".equals(outcome)) {
            logger.info("Encryption not set, no public key or session, ignored");
        }
    }

    /** AES-128-CBC decrypts {@code file} in place (streamed; the file is untouched on failure). */
    static void decryptAesFile(File file, SecretKey key, byte[] iv) throws IOException {
        if (key == null) {
            throw new IOException("AES file decryption failed: missing session key");
        }
        if (iv == null) {
            throw new IOException("AES file decryption failed: missing IV");
        }
        if (iv.length != 16) {
            throw new IOException("AES file decryption failed: IV must be 16 bytes");
        }
        byte[] keyBytes = key.getEncoded();
        if (keyBytes == null || keyBytes.length != 16) {
            throw new IOException("AES file decryption failed: session key must be 16 bytes");
        }
        if (file.length() == 0) {
            throw new IOException("Empty encrypted data");
        }
        try {
            CapgoCore.call(
                "aesDecryptFile",
                CapgoCore.input("path", file.getAbsolutePath(), "keyHex", CapgoCore.hex(keyBytes), "ivHex", CapgoCore.hex(iv))
            );
        } catch (CapgoCore.Failure e) {
            throw new IOException("AES file decryption failed: " + e.getMessage(), e);
        }
    }

    static void replaceFile(File from, File to) throws IOException {
        if (from.renameTo(to)) {
            return;
        }
        throw new IOException("Failed to replace file: " + to.getAbsolutePath());
    }

    /**
     * Decrypts a bundle checksum signed with the private key (hex, or legacy base64). Returns the checksum unchanged
     * when no public key is configured.
     */
    public static String decryptChecksum(String checksum, String publicKey) throws IOException {
        if (publicKey.isEmpty()) {
            logger.error("No encryption set (public key) ignored");
            return checksum;
        }
        try {
            final JSONObject result = CapgoCore.call("decryptChecksum", CapgoCore.input("checksum", checksum, "publicKey", publicKey));
            final String decrypted = result.optString("checksum", "");
            logChecksumInfo("Decrypted checksum", decrypted);
            return decrypted;
        } catch (CapgoCore.Failure e) {
            logger.error("Checksum decryption failed");
            logger.debug("Error: " + e.getMessage());
            if ("checksum_not_encrypted".equals(e.code)) {
                throw new IOException("Bundle checksum is not encrypted. Upload bundle with --key flag when encryption is configured.");
            }
            throw new IOException("Decryption failed: " + e.getMessage());
        }
    }

    /**
     * Detect checksum algorithm based on hex string length.
     * SHA-256 = 64 hex chars (32 bytes)
     * CRC32 = 8 hex chars (4 bytes)
     */
    public static String detectChecksumAlgorithm(String hexChecksum) {
        return CapgoCore.string("checksumAlgorithm", CapgoCore.input("checksum", hexChecksum), "algorithm", "empty");
    }

    /**
     * Log checksum info and warn if deprecated algorithm detected.
     */
    public static void logChecksumInfo(String label, String hexChecksum) {
        String algorithm = detectChecksumAlgorithm(hexChecksum);
        logger.debug(label + ": " + algorithm + " hex format (length: " + hexChecksum.length() + " chars)");
        if (algorithm.contains("CRC32")) {
            logger.error("CRC32 checksum detected - deprecated algorithm");
        } else if (algorithm.contains("unknown")) {
            logger.error("Unknown checksum algorithm detected");
            logger.debug("Char count: " + hexChecksum.length() + ", Expected: 64 (SHA-256)");
        }
    }

    // 256 KiB: one size for checksum, copy, and decode.
    // 64 workers * 256 KiB = 16 MiB for one buffer; AES/Brotli hold two (~32 MiB).
    static final int IO_BUFFER_BYTES = 256 * 1024;

    static int ioBufferBytes() {
        return IO_BUFFER_BYTES;
    }

    static int checksumBufferBytes() {
        return IO_BUFFER_BYTES;
    }

    static int copyBufferBytes() {
        return IO_BUFFER_BYTES;
    }

    /** Lowercase hex SHA-256 of a file (computed by the core), or "" when it cannot be read. */
    public static String calcChecksum(File file) {
        try {
            return CapgoCore.call("checksumFile", CapgoCore.input("path", file.getAbsolutePath())).optString("checksum", "");
        } catch (CapgoCore.Failure e) {
            logger.error("Cannot calculate checksum");
            logger.debug("Path: " + file.getPath() + ", Error: " + e.getMessage());
            return "";
        }
    }

    /** SHA-256 of a stream (APK assets have no file path, so they are hashed in Java). */
    public static String calcChecksum(InputStream inputStream) {
        final int BUFFER_SIZE = checksumBufferBytes();
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (java.security.NoSuchAlgorithmException e) {
            logger.error("SHA-256 algorithm not available");
            return "";
        }

        try {
            byte[] buffer = new byte[BUFFER_SIZE];
            int length;
            while ((length = inputStream.read(buffer)) != -1) {
                digest.update(buffer, 0, length);
            }
            return digestToHex(digest);
        } catch (IOException e) {
            logger.error("Cannot calculate checksum");
            logger.debug("Error: " + e.getMessage());
            return "";
        }
    }

    static String digestToHex(MessageDigest digest) {
        return CapgoCore.hex(digest.digest());
    }

    static String shortPathKey(String fileName) {
        return CapgoCore.string("shortPathKey", CapgoCore.input("value", fileName == null ? "" : fileName), "key", "");
    }

    /**
     * Get first 20 characters of the public key for identification.
     * Returns 20-character string or empty string if key is invalid/empty.
     * The first 12 chars are always "MIIBCgKCAQEA" for RSA 2048-bit keys,
     * so the unique part starts at character 13.
     */
    public static String calcKeyId(String publicKey) {
        if (publicKey == null || publicKey.isEmpty()) {
            return "";
        }
        return CapgoCore.string("keyId", CapgoCore.input("publicKey", publicKey), "keyId", "");
    }
}
