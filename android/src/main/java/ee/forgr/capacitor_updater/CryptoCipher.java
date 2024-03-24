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

import java.security.GeneralSecurityException;
import java.security.InvalidAlgorithmParameterException;
import java.security.InvalidKeyException;
import java.security.KeyFactory;
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
import javax.crypto.spec.PSource;
import javax.crypto.spec.SecretKeySpec;

public class CryptoCipher {

  public static byte[] decryptRSA(byte[] source, PublicKey publicKey)
    throws NoSuchPaddingException, NoSuchAlgorithmException, InvalidAlgorithmParameterException, InvalidKeyException, IllegalBlockSizeException, BadPaddingException {
    Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
    cipher.init(Cipher.DECRYPT_MODE, publicKey);
    byte[] decryptedBytes = cipher.doFinal(source);
    return decryptedBytes;
  }

  public static Cipher decryptAESCipher(SecretKey key, byte[] iv) {
    try {
      IvParameterSpec ivParameterSpec = new IvParameterSpec(iv);
      Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
      SecretKeySpec keySpec = new SecretKeySpec(key.getEncoded(), "AES");
      cipher.init(Cipher.DECRYPT_MODE, keySpec, ivParameterSpec);
      return cipher;
    } catch (Exception e) {
      Log.e(CapacitorUpdater.TAG, "Cannot gen the aes cipher - cannot download file", e);
      e.printStackTrace();
    }
    return null;
  }

  public static SecretKey byteToSessionKey(byte[] sessionKey) {
    // rebuild key using SecretKeySpec
    return new SecretKeySpec(sessionKey, 0, sessionKey.length, "AES");
  }

  private static PublicKey readX509PublicKey(byte[] x509Bytes)
    throws GeneralSecurityException {
    KeyFactory keyFactory = KeyFactory.getInstance("RSA");
    X509EncodedKeySpec keySpec = new X509EncodedKeySpec(x509Bytes);
    try {
      return keyFactory.generatePublic(keySpec);
    } catch (InvalidKeySpecException e) {
      throw new IllegalArgumentException("Unexpected key format!", e);
    }
  }

  public static PublicKey stringToPublicKey(String public_key)
    throws GeneralSecurityException {
    // Base64 decode the result

    String pkcs1Pem = public_key.toString();
    pkcs1Pem = pkcs1Pem.replace("-----BEGIN RSA PUBLIC KEY-----", "");
    pkcs1Pem = pkcs1Pem.replace("-----END RSA PUBLIC KEY-----", "");
    pkcs1Pem = pkcs1Pem.replace("\\n", "");
    pkcs1Pem = pkcs1Pem.replace(" ", "");

    byte[] pkcs1EncodedBytes = Base64.decode(pkcs1Pem, Base64.DEFAULT);

    // extract the public key
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
    (byte) 0x00,
  };

  private static PublicKey readPkcs1PublicKey(byte[] pkcs1Bytes)
    throws NoSuchAlgorithmException, InvalidKeySpecException, GeneralSecurityException {
    // convert the pkcs1 public key to an x509 favorable format
    byte[] keyBitString = createDEREncoding(
      BIT_STRING_TAG,
      joinPublic(NO_UNUSED_BITS, pkcs1Bytes)
    );
    byte[] keyInfoValue = joinPublic(
      RSA_ALGORITHM_IDENTIFIER_SEQUENCE,
      keyBitString
    );
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

  private static byte[] createDEREncoding(int tag, byte[] value) {
    if (tag < 0 || tag >= 0xFF) {
      throw new IllegalArgumentException(
        "Currently only single byte tags supported"
      );
    }

    byte[] lengthEncoding = createDERLengthEncoding(value.length);

    int size = 1 + lengthEncoding.length + value.length;
    byte[] derEncodingBuf = new byte[size];

    int off = 0;
    derEncodingBuf[off++] = (byte) tag;
    System.arraycopy(
      lengthEncoding,
      0,
      derEncodingBuf,
      off,
      lengthEncoding.length
    );
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
      return new byte[] {
        (byte) 0x82,
        (byte) (size >> Byte.SIZE),
        (byte) size,
      };
    }

    throw new IllegalArgumentException(
      "size too large, only up to 64KiB length encoding supported: " + size
    );
  }
}
