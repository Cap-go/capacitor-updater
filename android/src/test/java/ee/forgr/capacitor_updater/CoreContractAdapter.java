package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Runs the shared core contract (native-contract-tests/*.json) through the Android JNI binding
 * ({@link CapgoCore}), like core/tests/contract.rs does for Rust: every fixture group is a core operation.
 * File-backed groups get their content written to a temporary file first.
 */
final class CoreContractAdapter {

    private CoreContractAdapter() {}

    static JSONObject run(final String group, final JSONObject input) throws Exception {
        switch (group) {
            case "checksumFile": {
                final File file = File.createTempFile("capgo-core-contract", ".bin");
                try {
                    final byte[] chunk = CapgoCore.bytes(input.getString("contentHex"));
                    try (OutputStream output = Files.newOutputStream(file.toPath())) {
                        for (int i = 0; i < input.optInt("repeat", 1); i++) {
                            output.write(chunk);
                        }
                    }
                    return CapgoCore.call(group, CapgoCore.input("path", file.getAbsolutePath()));
                } finally {
                    deleteQuietly(file);
                }
            }
            case "decryptFile": {
                final File dir = Files.createTempDirectory("capgo-core-contract").toFile();
                final File file = new File(dir, "bundle.zip");
                try {
                    Files.write(file.toPath(), CapgoCore.bytes(input.getString("ciphertextHex")));
                    final JSONObject callInput = new JSONObject(input.toString());
                    callInput.remove("ciphertextHex");
                    callInput.put("path", file.getAbsolutePath());
                    CapgoCore.call(group, callInput);
                    return new JSONObject().put("plaintextHex", CapgoCore.hex(Files.readAllBytes(file.toPath())));
                } finally {
                    final File[] leftovers = dir.listFiles();
                    if (leftovers != null) {
                        for (final File leftover : leftovers) {
                            deleteQuietly(leftover);
                        }
                    }
                    deleteQuietly(dir);
                }
            }
            default:
                return CapgoCore.call(group, input);
        }
    }

    /** Runs every group of {@code native-contract-tests/<name>.json}. */
    static void runFixture(final String name) throws Exception {
        final JSONObject fixture = loadFixture(name + ".json");
        final String publicKeyPem = fixture.optString("publicKeyPem", null);
        final List<String> failures = new ArrayList<>();
        int passed = 0;

        final Iterator<String> groups = fixture.keys();
        while (groups.hasNext()) {
            final String group = groups.next();
            final JSONArray cases = fixture.optJSONArray(group);
            if (cases == null) {
                continue;
            }
            for (int index = 0; index < cases.length(); index++) {
                final JSONObject testCase = cases.getJSONObject(index);
                final String label = name + "." + group + " " + testCase.getString("id");
                final JSONObject input = resolveInput(testCase.getJSONObject("input"), publicKeyPem);
                final JSONObject expect = testCase.optJSONObject("expect");
                final String expectedError = expectedError(testCase);

                final JSONObject actual;
                try {
                    actual = run(group, input);
                } catch (CapgoCore.Failure failure) {
                    if (expectedError != null && expectedError.equals(failure.code)) {
                        passed++;
                    } else {
                        failures.add(
                            label + ": expected " + (expectedError != null ? "error " + expectedError : expect) + " but threw " + failure
                        );
                    }
                    continue;
                }
                if (expectedError != null) {
                    failures.add(label + ": expected error " + expectedError + " but returned " + actual);
                } else if (!jsonEquals(expect, actual)) {
                    failures.add(label + ": expected " + expect + " but was " + actual);
                } else {
                    passed++;
                }
            }
        }

        System.out.println("[core-contract] " + name + ": " + passed + " passed, " + failures.size() + " failed");
        if (!failures.isEmpty()) {
            fail(name + ".json core contract failures:\n  " + String.join("\n  ", failures));
        }
        assertTrue(name + ".json ran no cases", passed > 0);
    }

    /** Case-level {@code error}, or an {@code expect} that is exactly {@code {"error": code}}. */
    private static String expectedError(final JSONObject testCase) {
        if (testCase.has("error")) {
            return testCase.optString("error");
        }
        final JSONObject expect = testCase.optJSONObject("expect");
        if (expect != null && expect.length() == 1 && expect.has("error")) {
            return expect.optString("error");
        }
        return null;
    }

    /** crypto fixtures: an input `publicKey: null` means "use the fixture key". */
    private static JSONObject resolveInput(final JSONObject input, final String publicKeyPem) throws Exception {
        if (publicKeyPem != null && input.has("publicKey") && input.isNull("publicKey")) {
            final JSONObject copy = new JSONObject(input.toString());
            copy.put("publicKey", publicKeyPem);
            return copy;
        }
        return input;
    }

    /** Deep JSON equality; numbers compare numerically, an expected null also accepts a missing key. */
    static boolean jsonEquals(final Object expected, final Object actual) throws Exception {
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
            final JSONObject expectedObject = (JSONObject) expected;
            final JSONObject actualObject = (JSONObject) actual;
            final Set<String> keys = new HashSet<>();
            expectedObject.keys().forEachRemaining(keys::add);
            actualObject.keys().forEachRemaining(keys::add);
            for (final String key : keys) {
                if (!expectedObject.has(key)) {
                    return false;
                }
                if (!jsonEquals(expectedObject.get(key), actualObject.has(key) ? actualObject.get(key) : null)) {
                    return false;
                }
            }
            return true;
        }
        if (expected instanceof JSONArray && actual instanceof JSONArray) {
            final JSONArray expectedArray = (JSONArray) expected;
            final JSONArray actualArray = (JSONArray) actual;
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

    static JSONObject loadFixture(final String fileName) {
        try {
            return new JSONObject(new String(Files.readAllBytes(fixtureFile(fileName)), StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new AssertionError("Unable to load core contract fixture " + fileName, error);
        }
    }

    private static Path fixtureFile(final String fileName) throws IOException {
        Path current = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (current != null) {
            final Path candidate = current.resolve("native-contract-tests").resolve(fileName);
            if (Files.exists(candidate)) {
                return candidate;
            }
            current = current.getParent();
        }
        throw new IOException("native-contract-tests/" + fileName + " not found");
    }

    private static void deleteQuietly(final File file) {
        if (file.exists() && !file.delete()) {
            file.deleteOnExit();
        }
    }
}
