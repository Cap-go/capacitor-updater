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
import android.util.Log;
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
import java.security.NoSuchAlgorithmException;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.zip.CRC32;
import javax.crypto.BadPaddingException;
import javax.crypto.Cipher;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import javax.crypto.spec.SecretKeySpec;

public class CryptoCipher {

    public static byte[] decryptRSA(byte[] source, PrivateKey privateKey)
        throws NoSuchPaddingException, NoSuchAlgorithmException, InvalidAlgorithmParameterException, InvalidKeyException, IllegalBlockSizeException, BadPaddingException {
        Cipher cipher = Cipher.getInstance("RSA/ECB/OAEPPadding");
        OAEPParameterSpec oaepParams = new OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            new MGF1ParameterSpec("SHA-256"),
            PSource.PSpecified.DEFAULT
        );
        cipher.init(Cipher.DECRYPT_MODE, privateKey, oaepParams);
        return cipher.doFinal(source);
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

    private static PrivateKey readPkcs8PrivateKey(byte[] pkcs8Bytes) throws GeneralSecurityException {
        KeyFactory keyFactory = KeyFactory.getInstance("RSA");
        PKCS8EncodedKeySpec keySpec = new PKCS8EncodedKeySpec(pkcs8Bytes);
        try {
            return keyFactory.generatePrivate(keySpec);
        } catch (InvalidKeySpecException e) {
            throw new IllegalArgumentException("Unexpected key format!", e);
        }
    }

    private static byte[] join(byte[] byteArray1, byte[] byteArray2) {
        byte[] bytes = new byte[byteArray1.length + byteArray2.length];
        System.arraycopy(byteArray1, 0, bytes, 0, byteArray1.length);
        System.arraycopy(byteArray2, 0, bytes, byteArray1.length, byteArray2.length);
        return bytes;
    }

    private static PrivateKey readPkcs1PrivateKey(byte[] pkcs1Bytes) throws GeneralSecurityException {
        // We can't use Java internal APIs to parse ASN.1 structures, so we build a PKCS#8 key Java can understand
        int pkcs1Length = pkcs1Bytes.length;
        int totalLength = pkcs1Length + 22;
        byte[] pkcs8Header = new byte[] {
            0x30,
            (byte) 0x82,
            (byte) ((totalLength >> 8) & 0xff),
            (byte) (totalLength & 0xff), // Sequence + total length
            0x2,
            0x1,
            0x0, // Integer (0)
            0x30,
            0xD,
            0x6,
            0x9,
            0x2A,
            (byte) 0x86,
            0x48,
            (byte) 0x86,
            (byte) 0xF7,
            0xD,
            0x1,
            0x1,
            0x1,
            0x5,
            0x0, // Sequence: 1.2.840.113549.1.1.1, NULL
            0x4,
            (byte) 0x82,
            (byte) ((pkcs1Length >> 8) & 0xff),
            (byte) (pkcs1Length & 0xff) // Octet string + length
        };
        byte[] pkcs8bytes = join(pkcs8Header, pkcs1Bytes);
        return readPkcs8PrivateKey(pkcs8bytes);
    }

    public static PrivateKey stringToPrivateKey(String private_key) throws GeneralSecurityException {
        // Base64 decode the result

        String pkcs1Pem = private_key;
        pkcs1Pem = pkcs1Pem.replace("-----BEGIN RSA PRIVATE KEY-----", "");
        pkcs1Pem = pkcs1Pem.replace("-----END RSA PRIVATE KEY-----", "");
        pkcs1Pem = pkcs1Pem.replace("\\n", "");
        pkcs1Pem = pkcs1Pem.replace(" ", "");

        byte[] pkcs1EncodedBytes = Base64.decode(pkcs1Pem.getBytes(), Base64.DEFAULT);
        // extract the private key
        return readPkcs1PrivateKey(pkcs1EncodedBytes);
    }

    public static void decryptFile(final File file, final String privateKey, final String ivSessionKey, final String version)
        throws IOException {
        // (str != null && !str.isEmpty())
        if (privateKey == null || privateKey.isEmpty()) {
            Log.i(CapacitorUpdater.TAG, "Cannot found privateKey");
            return;
        } else if (ivSessionKey == null || ivSessionKey.isEmpty() || ivSessionKey.split(":").length != 2) {
            Log.i(CapacitorUpdater.TAG, "Cannot found sessionKey");
            return;
        }
        try {
            String ivB64 = ivSessionKey.split(":")[0];
            String sessionKeyB64 = ivSessionKey.split(":")[1];
            byte[] iv = Base64.decode(ivB64.getBytes(), Base64.DEFAULT);
            byte[] sessionKey = Base64.decode(sessionKeyB64.getBytes(), Base64.DEFAULT);
            PrivateKey pKey = CryptoCipher.stringToPrivateKey(privateKey);
            byte[] decryptedSessionKey = CryptoCipher.decryptRSA(sessionKey, pKey);
            SecretKey sKey = CryptoCipher.byteToSessionKey(decryptedSessionKey);
            byte[] content = new byte[(int) file.length()];

            try (
                final FileInputStream fis = new FileInputStream(file);
                final BufferedInputStream bis = new BufferedInputStream(fis);
                final DataInputStream dis = new DataInputStream(bis)
            ) {
                dis.readFully(content);
                dis.close();
                byte[] decrypted = CryptoCipher.decryptAES(content, sKey, iv);
                // write the decrypted string to the file
                try (final FileOutputStream fos = new FileOutputStream(file.getAbsolutePath())) {
                    fos.write(decrypted);
                }
            }
        } catch (GeneralSecurityException e) {
            Log.i(CapacitorUpdater.TAG, "decryptFile fail");
            e.printStackTrace();
            throw new IOException("GeneralSecurityException");
        }
    }

    public static String calcChecksum(File file) {
        final int BUFFER_SIZE = 1024 * 1024 * 5; // 5 MB buffer size
        CRC32 crc = new CRC32();

        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] buffer = new byte[BUFFER_SIZE];
            int length;
            while ((length = fis.read(buffer)) != -1) {
                crc.update(buffer, 0, length);
            }
            return String.format("%08x", crc.getValue());
        } catch (IOException e) {
            System.err.println(CapacitorUpdater.TAG + " Cannot calc checksum: " + file.getPath() + " " + e.getMessage());
            return "";
        }
    }

    public static PublicKey stringToPublicKey(String publicKey) {
        byte[] encoded = Base64.decode(publicKey, Base64.DEFAULT);

        KeyFactory keyFactory = null;
        try {
            keyFactory = KeyFactory.getInstance("RSA");
            X509EncodedKeySpec keySpec = new X509EncodedKeySpec(encoded);
            return keyFactory.generatePublic(keySpec);
        } catch (NoSuchAlgorithmException | InvalidKeySpecException e) {
            Log.i("Capacitor-updater", "stringToPublicKey fail\nError:\n" + e.toString());
            return null;
        }
    }
}
