/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;
import org.json.JSONArray;

/**
 * Runs JavaScript engine methods in call order, like Capacitor's plugin thread ran every previous version.
 *
 * <p>Every method runs on one serial lane. Detached methods ({@code detachedPluginMethods}: network calls and
 * {@code set} / {@code reload} / {@code reset}, which wait for {@code notifyAppReady} from the new page) run on a
 * worker thread while the lane waits until the engine reports that the method waits ({@code releaseMethodLane}
 * hook) or the method returns. What a detached method changes before waiting is in call order (set then reset);
 * its wait never blocks the calls that follow.
 */
final class EngineMethodLanes {

    /**
     * Detached methods running at once; more wait for a free thread. The previous plugin started a thread per call;
     * the cap only matters for bursts of waiting calls (offline downloads, reloads waiting for notifyAppReady).
     */
    static final int MAX_DETACHED_THREADS = 32;
    /** Longest the lane waits for a detached method to start waiting (a full pool, a slow step). */
    static final long DEFAULT_LANE_HOLD_LIMIT_MS = 5000;

    /** Released when the detached method on this thread waits ({@link #releaseCurrentThread()}). */
    private static final ThreadLocal<CountDownLatch> LANE_HOLD = new ThreadLocal<>();

    private final ExecutorService lane = Executors.newSingleThreadExecutor((runnable) -> {
        final Thread thread = new Thread(runnable, "CapgoUpdater-methods");
        thread.setDaemon(true);
        return thread;
    });
    private final ThreadPoolExecutor detached;
    /** Detached methods submitted and not finished: below the cap, a submitted one starts at once. */
    private final AtomicInteger outstanding = new AtomicInteger();
    private final long laneHoldLimitMs;
    private volatile Set<String> detachedMethods = Collections.emptySet();

    EngineMethodLanes() {
        this(DEFAULT_LANE_HOLD_LIMIT_MS);
    }

    EngineMethodLanes(final long laneHoldLimitMs) {
        this.laneHoldLimitMs = laneHoldLimitMs;
        final AtomicInteger count = new AtomicInteger();
        this.detached = new ThreadPoolExecutor(
            MAX_DETACHED_THREADS,
            MAX_DETACHED_THREADS,
            30,
            TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(),
            (runnable) -> {
                final Thread thread = new Thread(runnable, "CapgoUpdater-detached-" + count.incrementAndGet());
                thread.setDaemon(true);
                return thread;
            }
        );
        this.detached.allowCoreThreadTimeOut(true);
    }

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

    /** {@code releaseMethodLane} hook: the detached method running on this thread waits; the lane goes on. */
    static void releaseCurrentThread() {
        final CountDownLatch hold = LANE_HOLD.get();
        if (hold != null) {
            LANE_HOLD.remove();
            hold.countDown();
        }
    }

    /** Queues {@code task}; {@code onRejected} runs instead once the lanes are shut down. */
    void submit(final String name, final Runnable task, final Runnable onRejected) {
        this.submit(name, task, onRejected, (error) -> {});
    }

    /**
     * Queues {@code task}; {@code onRejected} runs instead once the lanes are shut down, {@code onFailure} when the
     * task throws. A throw on these threads would reach the default handler, which kills the app on Android.
     */
    void submit(final String name, final Runnable task, final Runnable onRejected, final Consumer<Throwable> onFailure) {
        final Runnable guarded = () -> {
            try {
                task.run();
            } catch (final Throwable error) {
                runQuietly(() -> onFailure.accept(error));
            }
        };
        try {
            if (!this.isDetached(name)) {
                this.lane.execute(guarded);
                return;
            }
            this.lane.execute(() -> {
                final CountDownLatch hold = new CountDownLatch(1);
                // Every thread busy: the method queues for one and the lane does not wait for it.
                final boolean startsNow = this.outstanding.getAndIncrement() < MAX_DETACHED_THREADS;
                try {
                    this.detached.execute(() -> {
                        LANE_HOLD.set(hold);
                        try {
                            guarded.run();
                        } finally {
                            LANE_HOLD.remove();
                            this.outstanding.decrementAndGet();
                            hold.countDown();
                        }
                    });
                } catch (final RejectedExecutionException e) {
                    this.outstanding.decrementAndGet();
                    runQuietly(onRejected);
                    return;
                }
                if (!startsNow) {
                    return;
                }
                try {
                    hold.await(this.laneHoldLimitMs, TimeUnit.MILLISECONDS);
                } catch (final InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            });
        } catch (final RejectedExecutionException e) {
            runQuietly(onRejected);
        }
    }

    /** Runs a rejection / failure callback; it must not throw on the caller's thread either. */
    private static void runQuietly(final Runnable callback) {
        try {
            callback.run();
        } catch (final Throwable ignored) {
            // The call cannot be answered: nothing left to do.
        }
    }

    void shutdown() {
        this.lane.shutdown();
        this.detached.shutdown();
    }
}
