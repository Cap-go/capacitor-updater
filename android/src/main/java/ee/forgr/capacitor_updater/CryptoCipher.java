/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

/**
 * Created by Awesometic
 * It's encrypt returns Base64 encoded, and also decrypt for Base64 encoded cipher
 * references: http://stackoverflow.com/questions/12471999/rsa-encryption-decryption-in-android
 */
import android.util.Base64;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
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
import java.util.ArrayList;
import java.util.List;
import javax.crypto.BadPaddingException;
import javax.crypto.Cipher;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public class CryptoCipher {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    public static byte[] decryptRSA(byte[] source, PublicKey publicKey)
        throws NoSuchPaddingException, NoSuchAlgorithmException, InvalidAlgorithmParameterException, InvalidKeyException, IllegalBlockSizeException, BadPaddingException {
        Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
        cipher.init(Cipher.DECRYPT_MODE, publicKey);
        byte[] decryptedBytes = cipher.doFinal(source);
        return decryptedBytes;
    }

    public static byte[] decryptAES(byte[] cipherText, SecretKey key, byte[] iv) throws GeneralSecurityException {
        if (key == null || iv == null) {
            throw new IllegalArgumentException("AES key and IV must not be null");
        }
        IvParameterSpec ivParameterSpec = new IvParameterSpec(iv);
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        SecretKeySpec keySpec = new SecretKeySpec(key.getEncoded(), "AES");
        cipher.init(Cipher.DECRYPT_MODE, keySpec, ivParameterSpec);
        return cipher.doFinal(cipherText);
    }

    public static SecretKey byteToSessionKey(byte[] sessionKey) {
        // rebuild key using SecretKeySpec
        return new SecretKeySpec(sessionKey, 0, sessionKey.length, "AES");
    }

    private static PublicKey readX509PublicKey(byte[] x509Bytes) throws GeneralSecurityException {
        KeyFactory keyFactory = KeyFactory.getInstance("RSA");
        X509EncodedKeySpec keySpec = new X509EncodedKeySpec(x509Bytes);
        try {
            return keyFactory.generatePublic(keySpec);
        } catch (InvalidKeySpecException e) {
            throw new IllegalArgumentException("Unexpected key format!", e);
        }
    }

    public static PublicKey stringToPublicKey(String public_key) throws GeneralSecurityException {
        String pkcs1Pem = public_key
            .replaceAll("\\s+", "")
            .replace("-----BEGINRSAPUBLICKEY-----", "")
            .replace("-----ENDRSAPUBLICKEY-----", "");

        byte[] pkcs1EncodedBytes = Base64.decode(pkcs1Pem, Base64.DEFAULT);
        return readPkcs1PublicKey(pkcs1EncodedBytes);
    }

    // since the public key is in pkcs1 format, we have to convert it to x509 format similar
    // to what needs done with the private key converting to pkcs8 format
    // so, the rest of the code below here is adapted from here https://stackoverflow.com/a/54246646
    private static final int SEQUENCE_TAG = 0x30;
    private static final int BIT_STRING_TAG = 0x03;
    private static final byte[] NO_UNUSED_BITS = new byte[] { 0x00 };
    private static final byte[] RSA_ALGORITHM_IDENTIFIER_SEQUENCE = {
        (byte) 0x30,
        (byte) 0x0d,
        (byte) 0x06,
        (byte) 0x09,
        (byte) 0x2a,
        (byte) 0x86,
        (byte) 0x48,
        (byte) 0x86,
        (byte) 0xf7,
        (byte) 0x0d,
        (byte) 0x01,
        (byte) 0x01,
        (byte) 0x01,
        (byte) 0x05,
        (byte) 0x00
    };

    private static PublicKey readPkcs1PublicKey(byte[] pkcs1Bytes)
        throws NoSuchAlgorithmException, InvalidKeySpecException, GeneralSecurityException {
        // convert the pkcs1 public key to an x509 favorable format
        byte[] keyBitString = createDEREncoding(BIT_STRING_TAG, joinPublic(NO_UNUSED_BITS, pkcs1Bytes));
        byte[] keyInfoValue = joinPublic(RSA_ALGORITHM_IDENTIFIER_SEQUENCE, keyBitString);
        byte[] keyInfoSequence = createDEREncoding(SEQUENCE_TAG, keyInfoValue);
        return readX509PublicKey(keyInfoSequence);
    }

    private static byte[] joinPublic(byte[]... bas) {
        int len = 0;
        for (int i = 0; i < bas.length; i++) {
            len += bas[i].length;
        }

        byte[] buf = new byte[len];
        int off = 0;
        for (int i = 0; i < bas.length; i++) {
            System.arraycopy(bas[i], 0, buf, off, bas[i].length);
            off += bas[i].length;
        }

        return buf;
    }

    public static boolean isValidSessionKey(final String sessionKey) {
        if (sessionKey == null || sessionKey.isEmpty()) {
            return false;
        }
        String[] sessionKeyParts = sessionKey.split(":", -1);
        return sessionKeyParts.length == 2 && !sessionKeyParts[0].isEmpty() && !sessionKeyParts[1].isEmpty();
    }

    public static void decryptFile(final File file, final String publicKey, final String ivSessionKey) throws IOException {
        if (publicKey.isEmpty() || !isValidSessionKey(ivSessionKey)) {
            if (logger != null) {
                logger.info("Encryption not set, no public key or session, ignored");
            }
            return;
        }
        // The bundle is encrypted from here on: an unusable key must fail, never leave it encrypted.
        if (!publicKey.startsWith("-----BEGIN RSA PUBLIC KEY-----")) {
            if (logger != null) {
                logger.error("The public key is not a valid RSA Public key");
            }
            throw new IOException("AES file decryption failed: the public key is not a valid RSA public key");
        }

        try {
            String ivB64 = ivSessionKey.split(":")[0];
            String sessionKeyB64 = ivSessionKey.split(":")[1];
            byte[] iv = Base64.decode(ivB64.getBytes(), Base64.DEFAULT);
            byte[] sessionKey = Base64.decode(sessionKeyB64.getBytes(), Base64.DEFAULT);
            if (iv.length != 16) {
                throw new IOException("AES file decryption failed: IV must be 16 bytes");
            }
            PublicKey pKey = CryptoCipher.stringToPublicKey(publicKey);
            byte[] decryptedSessionKey = CryptoCipher.decryptRSA(sessionKey, pKey);
            if (decryptedSessionKey == null || decryptedSessionKey.length != 16) {
                throw new IOException("AES file decryption failed: decrypted session key must be 16 bytes");
            }

            SecretKey sKey = CryptoCipher.byteToSessionKey(decryptedSessionKey);
            decryptAesFile(file, sKey, iv);
        } catch (GeneralSecurityException e) {
            if (logger != null) {
                logger.info("decryptFile fail");
            }
            throw new IOException("AES file decryption failed: " + e.getMessage(), e);
        }
    }

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
        File parent = file.getAbsoluteFile().getParentFile();
        if (parent == null) {
            throw new IOException("Cannot create temp file for " + file.getAbsolutePath());
        }
        File tempFile = File.createTempFile("capgo-aes-", ".tmp", parent);
        try {
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(keyBytes, "AES"), new IvParameterSpec(iv));
            byte[] inBuf = new byte[ioBufferBytes()];
            // Reuse one output buffer. cipher.update(in) allocates a new byte[] per chunk.
            byte[] outBuf = new byte[inBuf.length + 16];
            try (FileInputStream fis = new FileInputStream(file); FileOutputStream fos = new FileOutputStream(tempFile)) {
                int n;
                while ((n = fis.read(inBuf)) != -1) {
                    int outLen = cipher.update(inBuf, 0, n, outBuf, 0);
                    if (outLen > 0) {
                        fos.write(outBuf, 0, outLen);
                    }
                }
                int last = cipher.doFinal(outBuf, 0);
                if (last > 0) {
                    fos.write(outBuf, 0, last);
                }
            }
            if (tempFile.length() == 0) {
                throw new IOException("Empty decrypted data");
            }
            replaceFile(tempFile, file);
            tempFile = null;
        } catch (GeneralSecurityException e) {
            throw new IOException("AES file decryption failed: " + e.getMessage(), e);
        } finally {
            if (tempFile != null && tempFile.exists()) {
                tempFile.delete();
            }
        }
    }

    static void replaceFile(File from, File to) throws IOException {
        if (from.renameTo(to)) {
            return;
        }
        throw new IOException("Failed to replace file: " + to.getAbsolutePath());
    }

    private static byte[] hexStringToByteArray(String s) {
        int len = s.length();
        byte[] data = new byte[len / 2];
        for (int i = 0; i < len; i += 2) {
            data[i / 2] = (byte) ((Character.digit(s.charAt(i), 16) << 4) + Character.digit(s.charAt(i + 1), 16));
        }
        return data;
    }

    public static String decryptChecksum(String checksum, String publicKey) throws IOException {
        if (publicKey.isEmpty()) {
            logger.error("No encryption set (public key) ignored");
            return checksum;
        }
        try {
            // TODO: remove this in a month or two
            // Determine if input is hex or base64 encoded
            // Hex strings only contain 0-9 and a-f, while base64 contains other characters
            byte[] checksumBytes;
            String detectedFormat;
            if (checksum.matches("^[0-9a-fA-F]+$")) {
                // Hex encoded (new format from CLI for plugin versions >= 5.30.0, 6.30.0, 7.30.0)
                checksumBytes = hexStringToByteArray(checksum);
                detectedFormat = "hex";
            } else {
                // TODO: remove backwards compatibility
                // Base64 encoded (old format for backwards compatibility)
                checksumBytes = Base64.decode(checksum, Base64.DEFAULT);
                detectedFormat = "base64";
            }
            logger.debug(
                "Received checksum format: " +
                    detectedFormat +
                    " (length: " +
                    checksum.length() +
                    " chars, " +
                    checksumBytes.length +
                    " bytes)"
            );

            // RSA-2048 encrypted data must be exactly 256 bytes
            // If the checksum is not 256 bytes, the bundle was not encrypted properly
            if (checksumBytes.length != 256) {
                logger.error(
                    "Checksum is not RSA encrypted (size: " +
                        checksumBytes.length +
                        " bytes, expected 256 for RSA-2048). Bundle must be uploaded with encryption when public key is configured."
                );
                throw new IOException("Bundle checksum is not encrypted. Upload bundle with --key flag when encryption is configured.");
            }

            PublicKey pKey = CryptoCipher.stringToPublicKey(publicKey);
            byte[] decryptedChecksum = CryptoCipher.decryptRSA(checksumBytes, pKey);
            // Return as hex string to match calcChecksum output format
            StringBuilder hexString = new StringBuilder();
            for (byte b : decryptedChecksum) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            String result = hexString.toString();

            // Detect checksum algorithm based on length
            String detectedAlgorithm;
            if (decryptedChecksum.length == 32) {
                detectedAlgorithm = "SHA-256";
            } else if (decryptedChecksum.length == 4) {
                detectedAlgorithm = "CRC32 (deprecated)";
                logger.error("CRC32 checksum detected - deprecated algorithm");
            } else {
                detectedAlgorithm = "unknown (" + decryptedChecksum.length + " bytes)";
                logger.error("Unknown checksum algorithm detected");
                logger.debug("Byte count: " + decryptedChecksum.length + ", Expected: 32 (SHA-256)");
            }
            logger.debug(
                "Decrypted checksum: " +
                    detectedAlgorithm +
                    " hex format (length: " +
                    result.length() +
                    " chars, " +
                    decryptedChecksum.length +
                    " bytes)"
            );
            return result;
        } catch (GeneralSecurityException e) {
            logger.error("Checksum decryption failed");
            logger.debug("Error: " + e.getMessage());
            throw new IOException("Decryption failed: " + e.getMessage());
        }
    }

    /** Line 1 of the signed zip metadata payload (spec: capgo-bundle-v1). */
    static final String BUNDLE_SIGNATURE_HEADER = "capgo-bundle-v1";
    /** Line 1 of the signed manifest metadata payload (spec: capgo-manifest-v1). */
    static final String MANIFEST_SIGNATURE_HEADER = "capgo-manifest-v1";
    /** RSA-2048 PKCS#1 signature length, in bytes. */
    static final int SIGNATURE_BYTES = 256;

    /** One manifest entry as it enters the signed payload: exact file_name + plain (decrypted) sha256 hex. */
    public static final class ManifestSignatureEntry {

        public final String fileName;
        public final String plainHash;

        public ManifestSignatureEntry(final String fileName, final String plainHash) {
            this.fileName = fileName == null ? "" : fileName;
            this.plainHash = plainHash == null ? "" : plainHash;
        }
    }

    /**
     * Builds the exact UTF-8 string signed by the Capgo CLI for a zip bundle:
     * {@code "capgo-bundle-v1\nversion:<version>\nchecksum:<plain sha256 hex, lowercase>\n"}.
     */
    public static String buildBundleSignaturePayload(final String version, final String checksumHex) {
        return (
            BUNDLE_SIGNATURE_HEADER +
            "\n" +
            "version:" +
            (version == null ? "" : version) +
            "\n" +
            "checksum:" +
            (checksumHex == null ? "" : checksumHex.toLowerCase(java.util.Locale.ROOT)) +
            "\n"
        );
    }

    /** Unsigned lexicographic comparison of the UTF-8 bytes (matches Node Buffer.compare / Swift Array(utf8)). */
    static int compareUtf8Bytes(final String a, final String b) {
        final byte[] x = a.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        final byte[] y = b.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        final int n = Math.min(x.length, y.length);
        for (int i = 0; i < n; i++) {
            final int cx = x[i] & 0xff;
            final int cy = y[i] & 0xff;
            if (cx != cy) {
                return cx - cy;
            }
        }
        return x.length - y.length;
    }

    /**
     * Builds the exact UTF-8 string signed by the Capgo CLI for a manifest:
     * {@code "capgo-manifest-v1\nversion:<version>\n<file_name>:<plain sha256 hex>\n"...}, entries sorted by
     * file_name compared as unsigned UTF-8 bytes. Every entry must be present: the signature binds the whole set.
     */
    public static String buildManifestSignaturePayload(final String version, final List<ManifestSignatureEntry> entries) {
        final List<ManifestSignatureEntry> sorted = new ArrayList<>(entries == null ? java.util.Collections.emptyList() : entries);
        sorted.sort((l, r) -> compareUtf8Bytes(l.fileName, r.fileName));
        final StringBuilder sb = new StringBuilder();
        sb.append(MANIFEST_SIGNATURE_HEADER).append("\n");
        sb.append("version:")
            .append(version == null ? "" : version)
            .append("\n");
        for (final ManifestSignatureEntry entry : sorted) {
            sb.append(entry.fileName).append(':').append(entry.plainHash.toLowerCase(java.util.Locale.ROOT)).append("\n");
        }
        return sb.toString();
    }

    /** Lowercase hex SHA-256 of the UTF-8 bytes of {@code utf8}. */
    public static String sha256Hex(final String utf8) {
        try {
            final MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update((utf8 == null ? "" : utf8).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return digestToHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }

    /**
     * Verifies a Capgo metadata signature: {@code signatureHex} must be 256 bytes of hex (RSA-2048, PKCS#1 v1.5
     * privateEncrypt of sha256(payload)); it is public-recovered with {@code publicKey} and compared to
     * {@code sha256Hex(payload)} in constant time. Returns false on any malformed input or mismatch.
     */
    public static boolean verifySignature(final String signatureHex, final String payload, final String publicKey) {
        if (signatureHex == null || publicKey == null || publicKey.isEmpty()) {
            return false;
        }
        final String trimmed = signatureHex.trim();
        if (trimmed.length() != SIGNATURE_BYTES * 2 || !trimmed.matches("^[0-9a-fA-F]+$")) {
            if (logger != null) {
                logger.error("Signature is not " + SIGNATURE_BYTES + " bytes of hex (length: " + trimmed.length() + " chars)");
            }
            return false;
        }
        try {
            // Same public-recover path as the encrypted checksum: it yields the hex of the recovered bytes.
            final String recoveredHex = decryptChecksum(trimmed, publicKey);
            final byte[] recovered = hexStringToByteArray(recoveredHex);
            final byte[] expected = hexStringToByteArray(sha256Hex(payload));
            return MessageDigest.isEqual(recovered, expected);
        } catch (IOException | RuntimeException e) {
            if (logger != null) {
                logger.error("Signature verification failed");
                logger.debug("Error: " + e.getMessage());
            }
            return false;
        }
    }

    /**
     * Detect checksum algorithm based on hex string length.
     * SHA-256 = 64 hex chars (32 bytes)
     * CRC32 = 8 hex chars (4 bytes)
     */
    public static String detectChecksumAlgorithm(String hexChecksum) {
        if (hexChecksum == null || hexChecksum.isEmpty()) {
            return "empty";
        }
        int len = hexChecksum.length();
        if (len == 64) {
            return "SHA-256";
        } else if (len == 8) {
            return "CRC32 (deprecated)";
        } else {
            return "unknown (" + len + " hex chars)";
        }
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

    public static String calcChecksum(File file) {
        try (FileInputStream fis = new FileInputStream(file)) {
            return calcChecksum(fis);
        } catch (IOException e) {
            logger.error("Cannot calculate checksum");
            logger.debug("Path: " + file.getPath() + ", Error: " + e.getMessage());
            return "";
        }
    }

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
        byte[] hash = digest.digest();
        StringBuilder hexString = new StringBuilder(hash.length * 2);
        for (byte b : hash) {
            String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) hexString.append('0');
            hexString.append(hex);
        }
        return hexString.toString();
    }

    static String shortPathKey(String fileName) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update((fileName == null ? "" : fileName).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return digestToHex(digest).substring(0, 16);
        } catch (java.security.NoSuchAlgorithmException e) {
            return Integer.toHexString((fileName == null ? "" : fileName).hashCode());
        }
    }

    private static byte[] createDEREncoding(int tag, byte[] value) {
        if (tag < 0 || tag >= 0xFF) {
            throw new IllegalArgumentException("Currently only single byte tags supported");
        }

        byte[] lengthEncoding = createDERLengthEncoding(value.length);

        int size = 1 + lengthEncoding.length + value.length;
        byte[] derEncodingBuf = new byte[size];

        int off = 0;
        derEncodingBuf[off++] = (byte) tag;
        System.arraycopy(lengthEncoding, 0, derEncodingBuf, off, lengthEncoding.length);
        off += lengthEncoding.length;
        System.arraycopy(value, 0, derEncodingBuf, off, value.length);

        return derEncodingBuf;
    }

    private static byte[] createDERLengthEncoding(int size) {
        if (size <= 0x7F) {
            // single byte length encoding
            return new byte[] { (byte) size };
        } else if (size <= 0xFF) {
            // double byte length encoding
            return new byte[] { (byte) 0x81, (byte) size };
        } else if (size <= 0xFFFF) {
            // triple byte length encoding
            return new byte[] { (byte) 0x82, (byte) (size >> Byte.SIZE), (byte) size };
        }

        throw new IllegalArgumentException("size too large, only up to 64KiB length encoding supported: " + size);
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

        // Remove PEM headers and whitespace to get the raw key data
        String cleanedKey = publicKey
            .replaceAll("\\s+", "")
            .replace("-----BEGINRSAPUBLICKEY-----", "")
            .replace("-----ENDRSAPUBLICKEY-----", "");

        // Return first 20 characters of the base64-encoded key
        return cleanedKey.length() >= 20 ? cleanedKey.substring(0, 20) : cleanedKey;
    }
}
