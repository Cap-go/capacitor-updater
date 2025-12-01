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
 *
 * V2 Encryption - uses publicKey (modern encryption from main branch)
 */
import android.util.Base64;
import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
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
import javax.crypto.Cipher;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public class CryptoCipherV2 {

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

    public static byte[] decryptAES(byte[] cipherText, SecretKey key, byte[] iv) {
        try {
            IvParameterSpec ivParameterSpec = new IvParameterSpec(iv);
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            SecretKeySpec keySpec = new SecretKeySpec(key.getEncoded(), "AES");
            cipher.init(Cipher.DECRYPT_MODE, keySpec, ivParameterSpec);
            return cipher.doFinal(cipherText);
        } catch (Exception e) {
            e.printStackTrace();
        }
        return null;
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

    public static void decryptFile(final File file, final String publicKey, final String ivSessionKey) throws IOException {
        if (publicKey.isEmpty() || ivSessionKey == null || ivSessionKey.isEmpty() || ivSessionKey.split(":").length != 2) {
            logger.info("Encryption not set, no public key or session, ignored");
            return;
        }
        if (!publicKey.startsWith("-----BEGIN RSA PUBLIC KEY-----")) {
            logger.error("The public key is not a valid RSA Public key");
            return;
        }

        try {
            String ivB64 = ivSessionKey.split(":")[0];
            String sessionKeyB64 = ivSessionKey.split(":")[1];
            byte[] iv = Base64.decode(ivB64.getBytes(), Base64.DEFAULT);
            byte[] sessionKey = Base64.decode(sessionKeyB64.getBytes(), Base64.DEFAULT);
            PublicKey pKey = CryptoCipherV2.stringToPublicKey(publicKey);
            byte[] decryptedSessionKey = CryptoCipherV2.decryptRSA(sessionKey, pKey);

            SecretKey sKey = CryptoCipherV2.byteToSessionKey(decryptedSessionKey);
            byte[] content = new byte[(int) file.length()];

            try (
                final FileInputStream fis = new FileInputStream(file);
                final BufferedInputStream bis = new BufferedInputStream(fis);
                final DataInputStream dis = new DataInputStream(bis)
            ) {
                dis.readFully(content);
                dis.close();
                byte[] decrypted = CryptoCipherV2.decryptAES(content, sKey, iv);
                // write the decrypted string to the file
                try (final FileOutputStream fos = new FileOutputStream(file.getAbsolutePath())) {
                    fos.write(decrypted);
                }
            }
        } catch (GeneralSecurityException e) {
            logger.info("decryptFile fail");
            e.printStackTrace();
            throw new IOException("GeneralSecurityException");
        }
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
            // Determine if input is hex or base64 encoded
            // Hex strings only contain 0-9 and a-f, while base64 contains other characters
            byte[] checksumBytes;
            if (checksum.matches("^[0-9a-fA-F]+$")) {
                // Hex encoded (new format from CLI for plugin versions >= 5.30.0, 6.30.0, 7.30.0)
                checksumBytes = hexStringToByteArray(checksum);
            } else {
                // TODO: remove backwards compatibility
                // Base64 encoded (old format for backwards compatibility)
                checksumBytes = Base64.decode(checksum, Base64.DEFAULT);
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
            return hexString.toString();
        } catch (GeneralSecurityException e) {
            logger.error("decryptChecksum fail: " + e.getMessage());
            throw new IOException("Decryption failed: " + e.getMessage());
        }
    }

    public static String calcChecksum(File file) {
        final int BUFFER_SIZE = 1024 * 1024 * 5; // 5 MB buffer size
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (java.security.NoSuchAlgorithmException e) {
            logger.error("SHA-256 algorithm not available");
            return "";
        }

        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] buffer = new byte[BUFFER_SIZE];
            int length;
            while ((length = fis.read(buffer)) != -1) {
                digest.update(buffer, 0, length);
            }
            byte[] hash = digest.digest();
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            return hexString.toString();
        } catch (IOException e) {
            logger.error("Cannot calc checksum v2: " + file.getPath() + " " + e.getMessage());
            return "";
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
}
