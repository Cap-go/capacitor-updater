/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;

/**
 * The engine scheduled downloads run on, process-wide. While the plugin is loaded its engine runs them (progress
 * events and the waiting JavaScript call live there). When WorkManager starts the process without the plugin (the app
 * was killed mid-download), a worker engine is created from the configuration the plugin persisted at load.
 */
final class CapgoEngineHolder {

    private static CapgoEngine pluginEngine;
    private static CapgoEngine workerEngine;

    private CapgoEngineHolder() {}

    static synchronized void setPluginEngine(final CapgoEngine engine) {
        pluginEngine = engine;
        if (engine != null && workerEngine != null) {
            // Jobs move to the plugin engine; running calls finish first.
            final CapgoEngine worker = workerEngine;
            workerEngine = null;
            try {
                new Thread(worker::close, "capgo-worker-engine-close").start();
            } catch (final Throwable e) {
                // No thread (out of memory): never close inline under this lock, the engine is freed when collected.
            }
        }
    }

    static synchronized void clearPluginEngine(final CapgoEngine engine) {
        if (pluginEngine == engine) {
            pluginEngine = null;
        }
    }

    /** The plugin engine, else the worker engine (created on first use); {@code null} without a persisted configuration. */
    static synchronized CapgoEngine acquire(final Context context) {
        if (pluginEngine != null) {
            return pluginEngine;
        }
        if (workerEngine == null) {
            workerEngine = CapgoUpdater.createWorkerEngine(context.getApplicationContext());
        }
        return workerEngine;
    }

    /** Tests: forget every engine. */
    static synchronized void reset() {
        pluginEngine = null;
        workerEngine = null;
    }
}
