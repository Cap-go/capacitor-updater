package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.PublicKey;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class RsaContractTest {

    @BeforeClass
    public static void setUpClass() {
        CryptoCipher.setLogger(new Logger("RsaContractTest", new Logger.Options(Logger.LogLevel.silent)));
    }

    private static JSONObject contract() {
        try {
            return new JSONObject(new String(Files.readAllBytes(contractFile()), StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new AssertionError("Unable to load RSA contract fixture", error);
        }
    }

    private static Path contractFile() throws IOException {
        Path current = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (current != null) {
            Path candidate = current.resolve("native-contract-tests/crypto-rsa.json");
            if (Files.exists(candidate)) {
                return candidate;
            }
            current = current.getParent();
        }
        throw new IOException("native-contract-tests/crypto-rsa.json not found");
    }

    private static byte[] hexToBytes(String hex) {
        int len = hex.length();
        byte[] data = new byte[len / 2];
        for (int i = 0; i < len; i += 2) {
            data[i / 2] = (byte) ((Character.digit(hex.charAt(i), 16) << 4) + Character.digit(hex.charAt(i + 1), 16));
        }
        return data;
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder hexString = new StringBuilder();
        for (byte b : bytes) {
            String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) {
                hexString.append('0');
            }
            hexString.append(hex);
        }
        return hexString.toString();
    }

    private static String fixturePublicKey() throws Exception {
        return contract().getString("publicKeyPem");
    }

    @Test
    public void rsaPublicDecryptMatchesNativeContract() throws Exception {
        String publicKeyPem = fixturePublicKey();
        PublicKey publicKey = CryptoCipher.stringToPublicKey(publicKeyPem);
        JSONArray cases = contract().getJSONArray("rsaPublicDecrypt");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String ciphertextHex = testCase.getJSONObject("input").getString("ciphertextHex");
            String expectedPlaintextHex = testCase.getJSONObject("expect").getString("plaintextHex");

            byte[] decrypted = CryptoCipher.decryptRSA(hexToBytes(ciphertextHex), publicKey);
            assertNotNull(id, decrypted);
            assertEquals(id, expectedPlaintextHex, bytesToHex(decrypted));
        }
    }

    @Test
    public void decryptChecksumMatchesNativeContract() throws Exception {
        String publicKeyPem = fixturePublicKey();
        JSONArray cases = contract().getJSONArray("decryptChecksum");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String checksumHex = testCase.getJSONObject("input").getString("checksumHex");
            String expectedDecryptedHex = testCase.getJSONObject("expect").getString("decryptedHex");

            String result = CryptoCipher.decryptChecksum(checksumHex, publicKeyPem);
            assertEquals(id, expectedDecryptedHex, result);
        }
    }

    @Test
    public void decryptChecksumInvalidMatchesNativeContract() throws Exception {
        String publicKeyPem = fixturePublicKey();
        JSONArray cases = contract().getJSONArray("decryptChecksumInvalid");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String checksumHex = testCase.getJSONObject("input").getString("checksumHex");
            boolean shouldThrow = testCase.getJSONObject("expect").getBoolean("throws");

            if (shouldThrow) {
                try {
                    CryptoCipher.decryptChecksum(checksumHex, publicKeyPem);
                    fail(id + ": expected decryptChecksum to throw");
                } catch (IOException ignored) {
                    // expected
                }
            }
        }
    }

    @Test
    public void calcKeyIdMatchesNativeContract() throws Exception {
        JSONArray cases = contract().getJSONArray("calcKeyId");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String publicKeyPem = testCase.getJSONObject("input").getString("publicKeyPem");
            String expectedKeyId = testCase.getJSONObject("expect").getString("keyId");

            assertEquals(id, expectedKeyId, CryptoCipher.calcKeyId(publicKeyPem));
        }
    }

    @Test
    public void rsaPublicKeyLoadMatchesNativeContract() throws Exception {
        JSONArray cases = contract().getJSONArray("rsaPublicKeyLoad");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String publicKeyPem = testCase.getJSONObject("input").getString("publicKeyPem");
            boolean shouldLoad = testCase.getJSONObject("expect").getBoolean("loads");

            PublicKey loaded = null;
            try {
                loaded = CryptoCipher.stringToPublicKey(publicKeyPem);
            } catch (Exception ignored) {
                loaded = null;
            }

            if (shouldLoad) {
                assertNotNull(id, loaded);
            } else {
                assertNull(id, loaded);
            }
        }
    }
}
