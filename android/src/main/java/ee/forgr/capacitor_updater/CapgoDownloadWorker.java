/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;
import android.os.Build;
import android.os.Looper;
import androidx.annotation.NonNull;
import androidx.work.BackoffPolicy;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/**
 * One bundle download as a WorkManager job, like every Android plugin before the Rust engine: it waits for the
 * network, retries with backoff until it succeeds and survives the app process. The download itself stays in the
 * engine: the engine asks for the job ({@code scheduleDownload} hook) and each run calls its
 * {@code runScheduledDownload} operation, which answers {@code success}, {@code retry} or {@code failure}.
 */
public final class CapgoDownloadWorker extends Worker {

    /** Every job of this worker (the previous plugin's {@code capacitor_updater_download} jobs are legacy). */
    static final String TAG = "capgo_engine_download";
    static final String KEY_ID = "id";
    static final String KEY_VERSION = "version";
    private static final String VERSION_TAG_PREFIX = "capgo_engine_download_version:";
    private static final long CANCEL_WAIT_MS = 10_000;

    private volatile CapgoEngine engine;

    public CapgoDownloadWorker(@NonNull final Context context, @NonNull final WorkerParameters params) {
        super(context, params);
    }

    static String uniqueWorkName(final String id) {
        return "capgo_engine_download_" + id;
    }

    static String versionTag(final String version) {
        return VERSION_TAG_PREFIX + version;
    }

    /** The job of download {@code id} (manifest and request stay in the engine's job file: Data holds 10 KB). */
    static OneTimeWorkRequest request(final String id, final String version, final boolean isEmulator) {
        final Data input = new Data.Builder().putString(KEY_ID, id).putString(KEY_VERSION, version).build();
        // Emulators often report no validated network for background jobs: do not wait for one there.
        final Constraints constraints = new Constraints.Builder()
            .setRequiredNetworkType(isEmulator ? NetworkType.NOT_REQUIRED : NetworkType.CONNECTED)
            .build();
        final OneTimeWorkRequest.Builder builder = new OneTimeWorkRequest.Builder(CapgoDownloadWorker.class)
            .setConstraints(constraints)
            .setInputData(input)
            .addTag(TAG)
            .addTag(id)
            .addTag(versionTag(version));
        // Android 12+ expedited jobs skip the WorkManager delay without a foreground service.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST);
        }
        if (isEmulator) {
            builder.setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS);
        } else {
            builder.setBackoffCriteria(BackoffPolicy.LINEAR, WorkRequest.MIN_BACKOFF_MILLIS, TimeUnit.MILLISECONDS);
        }
        return builder.build();
    }

    static void enqueue(final Context context, final String id, final String version, final boolean isEmulator) {
        WorkManager.getInstance(context.getApplicationContext()).enqueueUniqueWork(
            uniqueWorkName(id),
            ExistingWorkPolicy.KEEP,
            request(id, version, isEmulator)
        );
    }

    /**
     * Cancels the jobs of {@code version} and waits (bounded) until none runs, so the caller can delete the bundle.
     * Returns {@code false} when they did not stop in time, or when called on the main thread, which cannot wait:
     * the caller keeps the files a job may still use.
     */
    static boolean cancelVersion(final Context context, final String version, final Logger logger) {
        final WorkManager workManager;
        try {
            workManager = WorkManager.getInstance(context.getApplicationContext());
        } catch (final IllegalStateException e) {
            return true; // WorkManager not initialized: no job can exist.
        }
        final String tag = versionTag(version);
        workManager.cancelAllWorkByTag(tag);
        if (Looper.myLooper() == Looper.getMainLooper()) {
            logger.warn("Cannot wait on the main thread for the scheduled download of " + version + " to stop");
            return false;
        }
        final long deadline = System.currentTimeMillis() + CANCEL_WAIT_MS;
        while (System.currentTimeMillis() < deadline) {
            try {
                final List<WorkInfo> infos = workManager.getWorkInfosByTag(tag).get(CANCEL_WAIT_MS, TimeUnit.MILLISECONDS);
                boolean active = false;
                for (final WorkInfo info : infos) {
                    active |= !info.getState().isFinished();
                }
                if (!active) {
                    return true;
                }
                Thread.sleep(100);
            } catch (final InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            } catch (final Exception e) {
                logger.error("Cannot check scheduled download state: " + e.getMessage());
                return false;
            }
        }
        logger.error("Timed out waiting for the scheduled download of " + version + " to stop");
        return false;
    }

    static void cancelAll(final Context context) {
        try {
            WorkManager.getInstance(context.getApplicationContext()).cancelAllWorkByTag(TAG);
        } catch (final IllegalStateException ignored) {
            // WorkManager not initialized: no job can exist.
        }
    }

    @NonNull
    @Override
    public Result doWork() {
        final String id = this.getInputData().getString(KEY_ID);
        if (id == null || id.isEmpty()) {
            return Result.failure();
        }
        final CapgoEngine engine = CapgoEngineHolder.acquire(this.getApplicationContext());
        if (engine == null) {
            // The plugin never ran on this install: there is no engine configuration to run it with.
            return Result.failure();
        }
        this.engine = engine;
        try {
            final JSONObject reply = engine.call("runScheduledDownload", CapgoCore.input(KEY_ID, id));
            switch (reply.optString("result")) {
                case "success":
                    return Result.success();
                case "retry":
                    return Result.retry();
                default:
                    return Result.failure();
            }
        } catch (final CapgoCore.Failure e) {
            // The engine was released mid-run (plugin destroyed): run again on the next engine.
            return Result.retry();
        } finally {
            this.engine = null;
        }
    }

    @Override
    public void onStopped() {
        super.onStopped();
        final CapgoEngine engine = this.engine;
        final String id = this.getInputData().getString(KEY_ID);
        if (engine == null || id == null) {
            return;
        }
        try {
            engine.call("stopScheduledDownload", CapgoCore.input(KEY_ID, id));
        } catch (final CapgoCore.Failure ignored) {
            // Engine released: its run is already over.
        }
    }
}
