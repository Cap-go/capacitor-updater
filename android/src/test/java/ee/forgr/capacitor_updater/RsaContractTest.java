package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;
import static org.mockito.Mockito.mock;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.PublicKey;
import java.util.ArrayList;
import java.util.List;
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
            } else {
                CryptoCipher.decryptChecksum(checksumHex, publicKeyPem);
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

    /** CapgoUpdater with a fixture key whose stats are captured instead of sent. */
    private static final class StatsCapturingUpdater extends CapgoUpdater {

        final List<String> stats = new ArrayList<>();

        StatsCapturingUpdater(final String publicKeyPem) {
            super(mock(Logger.class));
            this.publicKey = publicKeyPem;
        }

        @Override
        public void sendStats(final String action, final String versionName) {
            this.stats.add(action);
        }
    }

    @Test
    public void bundleSignatureMatchesNativeContract() throws Exception {
        String publicKeyPem = fixturePublicKey();
        JSONArray cases = contract().getJSONArray("bundleSignature");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            JSONObject input = testCase.getJSONObject("input");
            JSONObject expect = testCase.getJSONObject("expect");

            String payload = CryptoCipher.buildBundleSignaturePayload(input.getString("version"), input.getString("checksumHex"));
            assertEquals(id, expect.getString("payload"), payload);
            assertArrayEquals(id, expect.getString("payload").getBytes(StandardCharsets.UTF_8), payload.getBytes(StandardCharsets.UTF_8));
            assertEquals(
                id,
                expect.getBoolean("valid"),
                CryptoCipher.verifySignature(input.getString("signatureHex"), payload, publicKeyPem)
            );

            // Full gate: the server sends the RSA-encrypted checksum, the plugin decrypts it before building the payload.
            StatsCapturingUpdater updater = new StatsCapturingUpdater(publicKeyPem);
            try {
                updater.verifyBundleSignature(
                    input.getString("version"),
                    input.getString("encryptedChecksumHex"),
                    input.getString("signatureHex")
                );
                assertTrue(id + ": expected the gate to reject", expect.getBoolean("valid"));
                assertTrue(id, updater.stats.isEmpty());
            } catch (IOException error) {
                assertFalse(id + ": expected the gate to accept", expect.getBoolean("valid"));
                assertEquals(id, "Bundle signature verification failed", error.getMessage());
                assertEquals(id, List.of("signature_fail"), updater.stats);
            }
        }
    }

    @Test
    public void manifestSignatureMatchesNativeContract() throws Exception {
        String publicKeyPem = fixturePublicKey();
        JSONArray cases = contract().getJSONArray("manifestSignature");

        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            JSONObject input = testCase.getJSONObject("input");
            JSONObject expect = testCase.getJSONObject("expect");

            List<CryptoCipher.ManifestSignatureEntry> entries = new ArrayList<>();
            JSONArray plainEntries = input.getJSONArray("entries");
            for (int i = 0; i < plainEntries.length(); i++) {
                JSONObject entry = plainEntries.getJSONObject(i);
                entries.add(new CryptoCipher.ManifestSignatureEntry(entry.getString("file_name"), entry.getString("hashHex")));
            }
            String payload = CryptoCipher.buildManifestSignaturePayload(input.getString("version"), entries);
            assertEquals(id, expect.getString("payload"), payload);
            assertArrayEquals(id, expect.getString("payload").getBytes(StandardCharsets.UTF_8), payload.getBytes(StandardCharsets.UTF_8));
            assertEquals(
                id,
                expect.getBoolean("valid"),
                CryptoCipher.verifySignature(input.getString("signatureHex"), payload, publicKeyPem)
            );

            // Full gate with the manifest as the server sends it (encrypted file_hash values).
            StatsCapturingUpdater updater = new StatsCapturingUpdater(publicKeyPem);
            try {
                updater.verifyManifestSignature(
                    input.getString("version"),
                    input.getJSONArray("encryptedEntries"),
                    input.getString("signatureHex")
                );
                assertTrue(id + ": expected the gate to reject", expect.getBoolean("valid"));
                assertTrue(id, updater.stats.isEmpty());
            } catch (IOException error) {
                assertFalse(id + ": expected the gate to accept", expect.getBoolean("valid"));
                assertEquals(id, "Bundle signature verification failed", error.getMessage());
                assertEquals(id, List.of("signature_fail"), updater.stats);
            }
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
