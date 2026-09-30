package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** native-contract-tests/crypto-rsa.json through the JNI binding (same mapping as core/tests/contract.rs). */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class RsaContractTest {

    private static JSONObject contract() {
        return CoreContractAdapter.loadFixture("crypto-rsa.json");
    }

    private static JSONArray cases(final String group) throws Exception {
        return contract().getJSONArray(group);
    }

    private static String fixturePublicKey() throws Exception {
        return contract().getString("publicKeyPem");
    }

    @Test
    public void rsaPublicDecryptMatchesNativeContract() throws Exception {
        final JSONArray cases = cases("rsaPublicDecrypt");
        for (int index = 0; index < cases.length(); index++) {
            final JSONObject testCase = cases.getJSONObject(index);
            final JSONObject result = CapgoCore.call(
                "rsaPublicDecrypt",
                CapgoCore.input(
                    "publicKey",
                    fixturePublicKey(),
                    "ciphertextHex",
                    testCase.getJSONObject("input").getString("ciphertextHex")
                )
            );
            assertEquals(
                testCase.getString("id"),
                testCase.getJSONObject("expect").getString("plaintextHex"),
                result.getString("plaintextHex")
            );
        }
    }

    @Test
    public void decryptChecksumMatchesNativeContract() throws Exception {
        final JSONArray cases = cases("decryptChecksum");
        for (int index = 0; index < cases.length(); index++) {
            final JSONObject testCase = cases.getJSONObject(index);
            final JSONObject result = CapgoCore.call(
                "decryptChecksum",
                CapgoCore.input("publicKey", fixturePublicKey(), "checksum", testCase.getJSONObject("input").getString("checksumHex"))
            );
            assertEquals(
                testCase.getString("id"),
                testCase.getJSONObject("expect").getString("decryptedHex"),
                result.getString("checksum")
            );
        }
    }

    @Test
    public void decryptChecksumInvalidMatchesNativeContract() throws Exception {
        final JSONArray cases = cases("decryptChecksumInvalid");
        for (int index = 0; index < cases.length(); index++) {
            final JSONObject testCase = cases.getJSONObject(index);
            final String id = testCase.getString("id");
            final boolean shouldThrow = testCase.getJSONObject("expect").getBoolean("throws");
            try {
                CapgoCore.call(
                    "decryptChecksum",
                    CapgoCore.input("publicKey", fixturePublicKey(), "checksum", testCase.getJSONObject("input").getString("checksumHex"))
                );
                if (shouldThrow) {
                    fail(id + ": expected decryptChecksum to fail");
                }
            } catch (CapgoCore.Failure failure) {
                if (!shouldThrow) {
                    fail(id + ": unexpected failure " + failure);
                }
            }
        }
    }

    @Test
    public void calcKeyIdMatchesNativeContract() throws Exception {
        final JSONArray cases = cases("calcKeyId");
        for (int index = 0; index < cases.length(); index++) {
            final JSONObject testCase = cases.getJSONObject(index);
            final JSONObject result = CapgoCore.call(
                "keyId",
                CapgoCore.input("publicKey", testCase.getJSONObject("input").getString("publicKeyPem"))
            );
            assertEquals(testCase.getString("id"), testCase.getJSONObject("expect").getString("keyId"), result.getString("keyId"));
        }
    }

    @Test
    public void rsaPublicKeyLoadMatchesNativeContract() throws Exception {
        final JSONArray cases = cases("rsaPublicKeyLoad");
        for (int index = 0; index < cases.length(); index++) {
            final JSONObject testCase = cases.getJSONObject(index);
            final JSONObject result = CapgoCore.call(
                "publicKeyValid",
                CapgoCore.input("publicKey", testCase.getJSONObject("input").getString("publicKeyPem"))
            );
            assertEquals(testCase.getString("id"), testCase.getJSONObject("expect").getBoolean("loads"), result.getBoolean("valid"));
        }
    }
}
