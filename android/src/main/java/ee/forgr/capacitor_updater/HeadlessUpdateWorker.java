/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.core.content.pm.PackageInfoCompat;
import androidx.work.Constraints;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.WorkManager;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import com.getcapacitor.CapConfig;
import com.getcapacitor.PluginConfig;
import com.getcapacitor.plugin.WebView;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONException;

/**
 * Runs a live update check with no Activity and no Capacitor bridge, for example when an
 * update-check push wakes a killed app. The bundle is downloaded and, when the app has no UI,
 * applied as the current bundle so the next launch opens the new version (it still has to call
 * notifyAppReady). Enqueued as unique expedited work so the process stays alive until the bundle
 * is unzipped and stored.
 *
 * When a plugin instance is running in the process, use its native trigger instead
 * (CapacitorUpdaterPlugin#triggerBackgroundUpdateCheck); this worker then only stores the bundle as
 * next and lets that instance install it.
 */
public class HeadlessUpdateWorker extends Worker {

    static final String UNIQUE_WORK_NAME = "capacitor_updater_headless_update_check";
    private static final long FINISH_TIMEOUT_MINUTES = 9;

    public HeadlessUpdateWorker(@NonNull final Context context, @NonNull final WorkerParameters params) {
        super(context, params);
    }

    /** Queue a headless update check. Safe to call from any thread, including an FCM service. */
    public static void enqueue(@NonNull final Context context) {
        final OneTimeWorkRequest.Builder builder = new OneTimeWorkRequest.Builder(HeadlessUpdateWorker.class)
            .setConstraints(new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .addTag(UNIQUE_WORK_NAME);
        // Same as downloads: expedited work starts right away on Android 12+ without a foreground service.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST);
        }
        WorkManager.getInstance(context.getApplicationContext()).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            builder.build()
        );
    }

    @NonNull
    @Override
    public Result doWork() {
        final Logger logger = new Logger("CapgoUpdater");
        try {
            final String status = run(getApplicationContext(), logger);
            logger.info("Headless update check finished: " + status);
        } catch (final Exception e) {
            logger.error("Headless update check failed: " + e.getMessage());
        }
        // Never retry: the next launch or push runs a fresh check.
        return Result.success();
    }

    static String run(final Context context, final Logger logger) throws PackageManager.NameNotFoundException {
        if (CapacitorUpdaterPlugin.instanceLoaded) {
            // The running plugin instance owns downloads and installs in this process.
            return "handed_over";
        }
        final CapConfig capConfig = CapConfig.loadDefault(context);
        final PluginConfig config = capConfig.getPluginConfiguration("CapacitorUpdater");
        final String serverUrl = capConfig.getServerUrl();
        if (serverUrl != null && !serverUrl.isEmpty()) {
            return "unavailable";
        }
        final String autoUpdateMode = CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config, logger);
        if (!CapacitorUpdaterPlugin.isAutoUpdateModeEnabled(autoUpdateMode)) {
            return "unavailable";
        }

        final SharedPreferences prefs = context.getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Activity.MODE_PRIVATE);
        final boolean allowPreview = config.getBoolean("allowPreview", false);
        if (allowPreview && prefs.getBoolean(CapacitorUpdaterPlugin.PREVIEW_SESSION_PREF_KEY, false)) {
            return "preview_session";
        }

        final PackageInfo packageInfo = getPackageInfo(context);
        final String versionCode = Long.toString(PackageInfoCompat.getLongVersionCode(packageInfo));
        // After a native update the launch resets bundles first (resetWhenUpdate): leave it to the launch.
        if (nativeBuildChanged(prefs, versionCode)) {
            return "native_update_pending";
        }

        final boolean setNext = CapacitorUpdaterPlugin.shouldAutoUpdateModeSetNextBundle(autoUpdateMode);
        final CountDownLatch finished = new CountDownLatch(1);
        final AtomicReference<String> result = new AtomicReference<>("no_update");
        final CapgoUpdater updater = new CapgoUpdater(logger) {
            @Override
            void nextBundleReady(final BundleInfo bundle) {
                result.set(applyIfNoUi(this, bundle, logger) ? "installed" : "queued");
                finished.countDown();
            }

            @Override
            void notifyListeners(final String id, final Map<String, Object> res) {
                if ("downloadFailed".equals(id)) {
                    result.set("failed");
                    finished.countDown();
                } else if ("updateAvailable".equals(id) && !setNext) {
                    result.set("downloaded");
                    finished.countDown();
                }
            }
        };
        configure(updater, context, capConfig, config, prefs, packageInfo, versionCode);
        try {
            String updateUrl = config.getString("updateUrl", CapacitorUpdaterPlugin.updateUrlDefault);
            if (config.getBoolean("persistModifyUrl", false) && prefs.contains(CapacitorUpdaterPlugin.UPDATE_URL_PREF_KEY)) {
                updateUrl = prefs.getString(CapacitorUpdaterPlugin.UPDATE_URL_PREF_KEY, updateUrl);
            }
            if (updateUrl == null || updateUrl.isEmpty()) {
                return "unavailable";
            }

            final AtomicReference<Map<String, Object>> latestRef = new AtomicReference<>();
            final CountDownLatch latestDone = new CountDownLatch(1);
            updater.getLatest(updateUrl, null, (res) -> {
                latestRef.set(res);
                latestDone.countDown();
            });
            try {
                if (!latestDone.await(updater.timeout + 5000L, TimeUnit.MILLISECONDS)) {
                    return "failed";
                }
            } catch (final InterruptedException e) {
                Thread.currentThread().interrupt();
                return "failed";
            }
            final Map<String, Object> latest = latestRef.get();
            if (latest == null || latest.containsKey("error") || latest.containsKey("kind")) {
                return "no_update";
            }
            final String version = String.valueOf(latest.get("version"));
            final Object url = latest.get("url");
            final BundleInfo current = updater.getCurrentBundle();
            if ("builtin".equals(version) || version.isEmpty() || version.equals(current.getVersionName()) || !(url instanceof String)) {
                return "no_update";
            }
            final String sessionKey = latest.get("sessionKey") instanceof String ? (String) latest.get("sessionKey") : "";
            final String checksum = latest.get("checksum") instanceof String ? (String) latest.get("checksum") : "";

            final BundleInfo existing = updater.getBundleInfoByName(version);
            if (existing != null && existing.isErrorStatus()) {
                return "failed";
            }
            if (existing != null && existing.isDownloaded() && BundleStatus.DOWNLOADING != existing.getStatus()) {
                if (setNext && updater.setNextBundle(existing.getId())) {
                    return applyIfNoUi(updater, existing, logger) ? "installed" : "queued";
                }
                return "downloaded";
            }

            // downloadBackground returns null when it refuses the download (blocked encryption, gate,
            // version already downloading): only wait for a download it started.
            final String startedId = updater.downloadBackground((String) url, version, sessionKey, checksum, manifestOf(latest), setNext);
            if (startedId == null) {
                return "skipped";
            }
            final long deadline = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(FINISH_TIMEOUT_MINUTES);
            try {
                // Keep the worker (and so the process) alive until the bundle is stored. If the user opens
                // the app meanwhile, its plugin instance takes over the download (it restarts downloads it
                // does not observe), so stop waiting.
                while (!finished.await(1, TimeUnit.SECONDS)) {
                    if (CapacitorUpdaterPlugin.instanceLoaded) {
                        return "handed_over";
                    }
                    if (System.currentTimeMillis() > deadline) {
                        return "timeout";
                    }
                }
            } catch (final InterruptedException e) {
                Thread.currentThread().interrupt();
                return "interrupted";
            }
            return result.get();
        } finally {
            updater.shutdown();
        }
    }

    /**
     * With no plugin instance (no bridge, no WebView) nothing shows the current bundle, so switching
     * it is the same as installing on a background transition. Delay conditions keep it as next.
     */
    static boolean applyIfNoUi(final CapgoUpdater updater, final BundleInfo bundle, final Logger logger) {
        if (CapacitorUpdaterPlugin.instanceLoaded) {
            return false;
        }
        final String delays = updater.prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]");
        if (delays != null && !"[]".equals(delays.trim())) {
            logger.info("Update delayed until delay conditions met");
            return false;
        }
        if (updater.set(bundle)) {
            updater.setNextBundle(null);
            logger.info("Installed bundle " + bundle.getVersionName() + " for the next launch");
            return true;
        }
        return false;
    }

    static JSONArray manifestOf(final Map<String, Object> latest) {
        final Object manifest = latest.get("manifest");
        if (manifest instanceof JSONArray) {
            return (JSONArray) manifest;
        }
        if (manifest instanceof String) {
            try {
                return new JSONArray((String) manifest);
            } catch (final JSONException e) {
                return null;
            }
        }
        return null;
    }

    static boolean nativeBuildChanged(final SharedPreferences prefs, final String versionCode) {
        String previous = prefs.getString("LatestNativeBuildVersion", "");
        if (previous == null || previous.isEmpty()) {
            previous = prefs.getString("LatestVersionNative", "");
        }
        return previous != null && !previous.isEmpty() && !previous.equals(versionCode);
    }

    private static PackageInfo getPackageInfo(final Context context) throws PackageManager.NameNotFoundException {
        final PackageManager packageManager = context.getPackageManager();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return packageManager.getPackageInfo(context.getPackageName(), PackageManager.PackageInfoFlags.of(0));
        }
        return packageManager.getPackageInfo(context.getPackageName(), 0);
    }

    /** Mirrors the identity and URL setup of CapacitorUpdaterPlugin#load. */
    private static void configure(
        final CapgoUpdater updater,
        final Context context,
        final CapConfig capConfig,
        final PluginConfig config,
        final SharedPreferences prefs,
        final PackageInfo packageInfo,
        final String versionCode
    ) {
        updater.appContext = context;
        updater.prefs = prefs;
        updater.editor = prefs.edit();
        updater.documentsDir = context.getFilesDir();
        updater.noBackupDir = context.getNoBackupFilesDir();
        // Shares the plugin's pending-stats file: load it first so a flush does not overwrite it.
        updater.restorePendingStats();
        updater.CAP_SERVER_PATH = WebView.CAP_SERVER_PATH;
        updater.pluginVersion = CapacitorUpdaterPlugin.PLUGIN_VERSION;
        updater.versionBuild = config.getString("version", packageInfo.versionName);
        updater.versionCode = versionCode;
        updater.versionOs = Build.VERSION.RELEASE;

        String appId = InternalUtils.getPackageName(context.getPackageManager(), context.getPackageName());
        appId = capConfig.getString("appId", appId);
        updater.appId = config.getString("appId", appId);
        updater.setPublicKey(config.getString("publicKey", ""));

        final boolean persistModifyUrl = config.getBoolean("persistModifyUrl", false);
        updater.statsUrl = config.getString("statsUrl", CapacitorUpdaterPlugin.statsUrlDefault);
        updater.channelUrl = config.getString("channelUrl", CapacitorUpdaterPlugin.channelUrlDefault);
        if (persistModifyUrl) {
            updater.statsUrl = prefs.getString(CapacitorUpdaterPlugin.STATS_URL_PREF_KEY, updater.statsUrl);
            updater.channelUrl = prefs.getString(CapacitorUpdaterPlugin.CHANNEL_URL_PREF_KEY, updater.channelUrl);
        }

        final String storedDefaultChannel = prefs.getString(CapacitorUpdaterPlugin.DEFAULT_CHANNEL_PREF_KEY, "");
        updater.defaultChannel =
            storedDefaultChannel != null && !storedDefaultChannel.isEmpty() ? storedDefaultChannel : config.getString("defaultChannel", "");

        if (config.getBoolean("persistCustomId", false)) {
            final String storedCustomId = prefs.getString(CapacitorUpdaterPlugin.CUSTOM_ID_PREF_KEY, "");
            if (storedCustomId != null && !storedCustomId.isEmpty()) {
                updater.customId = storedCustomId;
            }
        }
        updater.deviceID = DeviceIdHelper.getOrCreateDeviceId(context, prefs);

        final int responseTimeoutSeconds = config.getInt("responseTimeout", 20);
        final long responseTimeoutMillis = responseTimeoutSeconds > 0 ? (long) responseTimeoutSeconds * 1000L : 20_000L;
        updater.timeout = (int) Math.min(Integer.MAX_VALUE, responseTimeoutMillis);
        DownloadService.applyHttpTimeouts(updater.timeout);
        DownloadService.updateUserAgent(updater.appId, updater.pluginVersion, updater.versionOs);
    }
}
