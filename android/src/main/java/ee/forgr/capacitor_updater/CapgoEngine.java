/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.concurrent.locks.ReentrantReadWriteLock;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Java handle on a Rust updater engine ({@code core/src/engine}). Thread-safe. */
final class CapgoEngine {

    // Native calls hold the read lock; close() takes the write lock, so the Rust engine is
    // never freed while a call still uses it.
    private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
    private long handle;

    CapgoEngine(final JSONObject config, final CapgoEngineHost host) {
        if (!CapgoCoreNative.isAvailable()) {
            throw new IllegalStateException("Capgo native core is not available: " + CapgoCoreNative.loadError());
        }
        this.handle = CapgoCoreNative.engineCreate(config.toString(), host);
        if (this.handle == 0) {
            throw new IllegalStateException("Capgo engine could not be created (see logs)");
        }
    }

    /** Returns the operation value: a JSONObject, JSONArray or {@link JSONObject#NULL}. */
    Object callValue(final String operation, final JSONObject input) throws CapgoCore.Failure {
        return this.callValue(operation, input, true);
    }

    /**
     * Like {@link #call} but never queues behind a pending {@link #close()}: the read-write lock makes new readers
     * wait once close() waits, and close() waits for the running calls. A call that ends a running one (stop a
     * download) must not wait for that call to end, else both stall until it ends on its own. Fails as closed while
     * close() frees the engine.
     */
    JSONObject callWithoutWaitingForClose(final String operation, final JSONObject input) throws CapgoCore.Failure {
        final Object value = this.callValue(operation, input, false);
        return value instanceof JSONObject ? (JSONObject) value : new JSONObject();
    }

    private Object callValue(final String operation, final JSONObject input, final boolean waitForClose) throws CapgoCore.Failure {
        final String output;
        if (waitForClose) {
            this.lock.readLock().lock();
        } else if (!this.lock.readLock().tryLock()) {
            // tryLock() barges past a waiting close(); it fails only while close() frees the engine.
            throw new CapgoCore.Failure("internal", "Capgo engine is closed");
        }
        try {
            if (this.handle == 0) {
                throw new CapgoCore.Failure("internal", "Capgo engine is closed");
            }
            output = CapgoCoreNative.engineCall(this.handle, operation, input == null ? "{}" : input.toString());
        } finally {
            this.lock.readLock().unlock();
        }
        if (output == null) {
            throw new CapgoCore.Failure("internal", "Engine returned no result");
        }
        try {
            final JSONObject envelope = new JSONObject(output);
            if (envelope.optBoolean("ok", false)) {
                final Object value = envelope.opt("value");
                return value == null ? JSONObject.NULL : value;
            }
            final JSONObject error = envelope.optJSONObject("error");
            throw new CapgoCore.Failure(
                error != null ? error.optString("code", "internal") : "internal",
                error != null ? error.optString("message", "") : "Unknown engine error"
            );
        } catch (JSONException e) {
            throw new CapgoCore.Failure("internal", "Engine returned invalid JSON: " + e.getMessage());
        }
    }

    JSONObject call(final String operation, final JSONObject input) throws CapgoCore.Failure {
        final Object value = this.callValue(operation, input);
        return value instanceof JSONObject ? (JSONObject) value : new JSONObject();
    }

    JSONArray callArray(final String operation, final JSONObject input) throws CapgoCore.Failure {
        final Object value = this.callValue(operation, input);
        return value instanceof JSONArray ? (JSONArray) value : new JSONArray();
    }

    /** Frees the Rust engine once no call is running. Later calls fail with a {@link CapgoCore.Failure}. */
    void close() {
        this.lock.writeLock().lock();
        try {
            if (this.handle != 0) {
                CapgoCoreNative.engineDestroy(this.handle);
                this.handle = 0;
            }
        } finally {
            this.lock.writeLock().unlock();
        }
    }

    @Override
    protected void finalize() throws Throwable {
        try {
            this.close();
        } finally {
            super.finalize();
        }
    }
}
