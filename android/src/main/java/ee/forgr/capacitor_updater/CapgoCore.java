/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Java binding for the shared Rust updater core ({@code core/}).
 *
 * <p>Every call is "operation name + JSON object in, JSON object out", the same surface the iOS plugin uses
 * through the C ABI ({@code resolvePathInside}).
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
}
