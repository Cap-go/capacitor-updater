/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.Map;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Java binding for the shared Rust updater core ({@code core/}).
 *
 * <p>Every call is "operation name + JSON object in, JSON object out", the same surface the iOS plugin uses
 * through the C ABI. Operation names and payloads are pinned by {@code native-contract-tests/}.
 */
final class CapgoCore {

    /** A failed core operation. {@link #code} is a stable, cross-platform error code. */
    static final class Failure extends Exception {

        final String code;

        Failure(final String code, final String message) {
            super(code + ": " + message);
            this.code = code;
        }
    }

    private CapgoCore() {}

    /** Builds an input object; {@code null} values are sent as JSON null. */
    static JSONObject input(final Object... keyValues) {
        final JSONObject input = new JSONObject();
        try {
            for (int index = 0; index + 1 < keyValues.length; index += 2) {
                final Object value = keyValues[index + 1];
                input.put((String) keyValues[index], value == null ? JSONObject.NULL : value);
            }
        } catch (JSONException e) {
            throw new IllegalArgumentException("Invalid core input", e);
        }
        return input;
    }

    static JSONObject call(final String operation, final JSONObject input) throws Failure {
        final String output = CapgoCoreNative.call(operation, input == null ? "{}" : input.toString());
        if (output == null) {
            throw new Failure("internal", "Core returned no result");
        }
        try {
            final JSONObject envelope = new JSONObject(output);
            if (envelope.optBoolean("ok", false)) {
                final JSONObject value = envelope.optJSONObject("value");
                return value != null ? value : new JSONObject();
            }
            final JSONObject error = envelope.optJSONObject("error");
            throw new Failure(
                error != null ? error.optString("code", "internal") : "internal",
                error != null ? error.optString("message", "") : "Unknown core error"
            );
        } catch (JSONException e) {
            throw new Failure("internal", "Core returned invalid JSON: " + e.getMessage());
        }
    }

    static JSONObject call(final String operation, final Map<String, ?> input) throws Failure {
        return call(operation, new JSONObject(input));
    }

    /**
     * For operations that cannot fail on well-formed input. A failure is a binding bug: it throws in tests
     * (assertions enabled) and returns {@code fallback} in production.
     */
    private static Object value(final String operation, final JSONObject input, final String key) {
        try {
            final JSONObject result = call(operation, input);
            if (result.has(key)) {
                return result.get(key);
            }
            throw new AssertionError("Capgo core " + operation + " returned no `" + key + "`");
        } catch (Failure | JSONException e) {
            throw new AssertionError("Capgo core " + operation + " failed: " + e.getMessage(), e);
        }
    }

    static boolean bool(final String operation, final JSONObject input, final String key, final boolean fallback) {
        try {
            final Object value = value(operation, input, key);
            return value instanceof Boolean ? (Boolean) value : fallback;
        } catch (AssertionError e) {
            reportBindingBug(e);
            return fallback;
        }
    }

    static String string(final String operation, final JSONObject input, final String key, final String fallback) {
        try {
            final Object value = value(operation, input, key);
            return value instanceof String ? (String) value : fallback;
        } catch (AssertionError e) {
            reportBindingBug(e);
            return fallback;
        }
    }

    /** Nullable string result ({@code null} when the core returns JSON null). */
    static String optString(final String operation, final JSONObject input, final String key) {
        try {
            final Object value = value(operation, input, key);
            return value instanceof String ? (String) value : null;
        } catch (AssertionError e) {
            reportBindingBug(e);
            return null;
        }
    }

    static long number(final String operation, final JSONObject input, final String key, final long fallback) {
        try {
            final Object value = value(operation, input, key);
            return value instanceof Number ? ((Number) value).longValue() : fallback;
        } catch (AssertionError e) {
            reportBindingBug(e);
            return fallback;
        }
    }

    private static void reportBindingBug(final AssertionError error) {
        // Surfaces in unit tests (-ea); production keeps the fail-closed fallback.
        boolean assertionsEnabled = false;
        assert assertionsEnabled = true;
        if (assertionsEnabled) {
            throw error;
        }
    }

    static String hex(final byte[] bytes) {
        final StringBuilder out = new StringBuilder(bytes.length * 2);
        for (final byte b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        }
        return out.toString();
    }

    static byte[] bytes(final String hex) {
        final byte[] out = new byte[hex.length() / 2];
        for (int index = 0; index < out.length; index++) {
            out[index] = (byte) Integer.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
        }
        return out;
    }
}
