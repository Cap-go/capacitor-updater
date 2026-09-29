package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/**
 * Runs the shared updater core contract (native-contract-tests/policy.json, security.json,
 * crypto.json) against the Android implementation through {@link CoreContractAdapter}.
 *
 * Success cases must match `expect` exactly (deep JSON equality). Error cases
 * (`expect: {"error": code}`) only require the operation to throw: the codes are the
 * canonical Rust core codes, which the current Java code does not produce.
 */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CoreContractTest {

    private static final String PLATFORM = "android";

    /** Contract groups with no Android implementation yet. Currently every group is covered. */
    private static final Set<String> GROUPS_WITHOUT_ANDROID_IMPLEMENTATION = Collections.emptySet();

    /**
     * Non-divergent cases where the current Android behavior differs from the fixture.
     * Every entry is a bug to fix (in the Rust core migration) or a fixture to revisit.
     */
    private static final Set<String> KNOWN_ANDROID_MISMATCHES = Collections.emptySet();

    @BeforeClass
    public static void setUpClass() {
        CryptoCipher.setLogger(new Logger("CoreContractTest", new Logger.Options(Logger.LogLevel.silent)));
    }

    @Test
    public void policyMatchesCoreContract() throws Exception {
        runFixture("policy");
    }

    @Test
    public void securityMatchesCoreContract() throws Exception {
        runFixture("security");
    }

    @Test
    public void cryptoMatchesCoreContract() throws Exception {
        runFixture("crypto");
    }

    private static void runFixture(String name) throws Exception {
        JSONObject fixture = loadFixture(name);
        String publicKeyPem = fixture.optString("publicKeyPem", null);
        List<String> failures = new ArrayList<>();
        int passed = 0;
        int skipped = 0;

        Iterator<String> groups = fixture.keys();
        while (groups.hasNext()) {
            String group = groups.next();
            JSONArray cases = fixture.optJSONArray(group);
            if (cases == null) {
                continue;
            }
            if (GROUPS_WITHOUT_ANDROID_IMPLEMENTATION.contains(group)) {
                System.out.println("[core-contract] SKIP group " + name + "." + group + ": no Android implementation");
                skipped += cases.length();
                continue;
            }
            for (int index = 0; index < cases.length(); index++) {
                JSONObject testCase = cases.getJSONObject(index);
                String id = testCase.getString("id");
                String label = name + "." + group + " " + id;

                if (divergesOnPlatform(testCase)) {
                    System.out.println("[core-contract] SKIP " + label + ": divergence " + PLATFORM);
                    skipped++;
                    continue;
                }
                if (KNOWN_ANDROID_MISMATCHES.contains(id)) {
                    System.out.println("[core-contract] SKIP " + label + ": known Android mismatch");
                    skipped++;
                    continue;
                }

                JSONObject input = resolveInput(testCase.getJSONObject("input"), publicKeyPem);
                JSONObject expect = testCase.getJSONObject("expect");
                boolean expectsError = isErrorExpectation(expect);

                JSONObject actual;
                try {
                    actual = CoreContractAdapter.run(group, input);
                } catch (CoreContractAdapter.UnsupportedCase unsupported) {
                    System.out.println("[core-contract] SKIP " + label + ": " + unsupported.getMessage());
                    skipped++;
                    continue;
                } catch (CoreContractAdapter.UnknownGroup unknown) {
                    failures.add(label + ": " + unknown.getMessage());
                    continue;
                } catch (Exception error) {
                    if (expectsError) {
                        passed++;
                    } else {
                        failures.add(label + ": expected " + expect + " but threw " + error);
                    }
                    continue;
                }

                if (expectsError) {
                    failures.add(label + ": expected error " + expect.get("error") + " but returned " + actual);
                } else if (!jsonEquals(expect, actual)) {
                    failures.add(label + ": expected " + expect + " but was " + actual);
                } else {
                    passed++;
                }
            }
        }

        System.out.println("[core-contract] " + name + ": " + passed + " passed, " + skipped + " skipped, " + failures.size() + " failed");
        if (!failures.isEmpty()) {
            fail(name + ".json core contract failures:\n  " + String.join("\n  ", failures));
        }
        assertTrue(name + ".json ran no cases", passed > 0);
    }

    private static boolean divergesOnPlatform(JSONObject testCase) throws Exception {
        JSONArray divergence = testCase.optJSONArray("divergence");
        if (divergence == null) {
            return false;
        }
        for (int i = 0; i < divergence.length(); i++) {
            if (PLATFORM.equals(divergence.getString(i))) {
                return true;
            }
        }
        return false;
    }

    /**
     * An error case is exactly {"error": "<code>"}. remoteError success outputs also carry an
     * "error" key, but always next to "message", so a lone key is the discriminator.
     */
    private static boolean isErrorExpectation(JSONObject expect) {
        return expect.length() == 1 && expect.has("error");
    }

    /** crypto.json: an input `publicKey: null` means "use the fixture key". */
    private static JSONObject resolveInput(JSONObject input, String publicKeyPem) throws Exception {
        if (publicKeyPem != null && input.has("publicKey") && input.isNull("publicKey")) {
            JSONObject copy = new JSONObject(input.toString());
            copy.put("publicKey", publicKeyPem);
            return copy;
        }
        return input;
    }

    /**
     * Deep JSON equality. Numbers compare numerically. A key whose expected value is an
     * explicit null also accepts a missing key; otherwise key sets must match exactly.
     */
    static boolean jsonEquals(Object expected, Object actual) throws Exception {
        if (expected == null || expected == JSONObject.NULL) {
            return actual == null || actual == JSONObject.NULL;
        }
        if (actual == null || actual == JSONObject.NULL) {
            return false;
        }
        if (expected instanceof Number && actual instanceof Number) {
            return new BigDecimal(expected.toString()).compareTo(new BigDecimal(actual.toString())) == 0;
        }
        if (expected instanceof JSONObject && actual instanceof JSONObject) {
            JSONObject expectedObject = (JSONObject) expected;
            JSONObject actualObject = (JSONObject) actual;
            Set<String> keys = new HashSet<>();
            expectedObject.keys().forEachRemaining(keys::add);
            actualObject.keys().forEachRemaining(keys::add);
            for (String key : keys) {
                if (!expectedObject.has(key)) {
                    return false;
                }
                Object expectedValue = expectedObject.get(key);
                Object actualValue = actualObject.has(key) ? actualObject.get(key) : null;
                if (!jsonEquals(expectedValue, actualValue)) {
                    return false;
                }
            }
            return true;
        }
        if (expected instanceof JSONArray && actual instanceof JSONArray) {
            JSONArray expectedArray = (JSONArray) expected;
            JSONArray actualArray = (JSONArray) actual;
            if (expectedArray.length() != actualArray.length()) {
                return false;
            }
            for (int i = 0; i < expectedArray.length(); i++) {
                if (!jsonEquals(expectedArray.get(i), actualArray.get(i))) {
                    return false;
                }
            }
            return true;
        }
        return expected.equals(actual);
    }

    private static JSONObject loadFixture(String name) {
        try {
            return new JSONObject(new String(Files.readAllBytes(fixtureFile(name + ".json")), StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new AssertionError("Unable to load core contract fixture " + name, error);
        }
    }

    private static Path fixtureFile(String fileName) throws IOException {
        Path current = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (current != null) {
            Path candidate = current.resolve("native-contract-tests").resolve(fileName);
            if (Files.exists(candidate)) {
                return candidate;
            }
            current = current.getParent();
        }
        throw new IOException("native-contract-tests/" + fileName + " not found");
    }
}
