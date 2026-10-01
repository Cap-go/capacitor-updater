/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import org.json.JSONArray;

/**
 * Runs JavaScript engine methods in call order, like Capacitor's plugin thread ran every previous version.
 *
 * <p>Every method runs on one serial lane. Detached methods ({@code detachedPluginMethods}: network calls and
 * {@code set} / {@code reload} / {@code reset}, which wait for {@code notifyAppReady} from the new page) start in
 * call order, then run on their own thread so they never block the calls that follow.
 */
final class EngineMethodLanes {

    private final ExecutorService lane = Executors.newSingleThreadExecutor((runnable) -> {
        final Thread thread = new Thread(runnable, "CapgoUpdater-methods");
        thread.setDaemon(true);
        return thread;
    });
    private final ExecutorService detached = Executors.newCachedThreadPool();
    private volatile Set<String> detachedMethods = Collections.emptySet();

    void setDetachedMethods(final JSONArray names) {
        final Set<String> methods = new HashSet<>();
        for (int index = 0; index < names.length(); index++) {
            methods.add(names.optString(index));
        }
        this.detachedMethods = Collections.unmodifiableSet(methods);
    }

    boolean isDetached(final String name) {
        return this.detachedMethods.contains(name);
    }

    /** Queues {@code task}; {@code onRejected} runs instead once the lanes are shut down. */
    void submit(final String name, final Runnable task, final Runnable onRejected) {
        try {
            if (!this.isDetached(name)) {
                this.lane.execute(task);
                return;
            }
            this.lane.execute(() -> {
                try {
                    this.detached.execute(task);
                } catch (final RejectedExecutionException e) {
                    onRejected.run();
                }
            });
        } catch (final RejectedExecutionException e) {
            onRejected.run();
        }
    }

    void shutdown() {
        this.lane.shutdown();
        this.detached.shutdown();
    }
}
