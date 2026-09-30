/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.ListenableWorker;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;
import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Creates the Rust updater engine ({@code core/src/engine}) and answers its host callbacks: persistence
 * (SharedPreferences), logs, events, plugin hooks and the Android-only Background Runner rescheduling.
 */
public class CapgoUpdater {

    public static final String TAG = "Capacitor-updater";

    /** Receives engine events and hooks. Both can arrive on any thread. */
    interface Listener {
        void onEvent(String event, String payloadJson);

        /** Returns the JSON reply of a hook, or {@code null} when it is not handled. */
        String onHook(String name, String payloadJson);
    }

    static final String BUNDLE_DIRECTORY = "versions";
    private static final String CAPACITOR_CONFIG_ASSET = "capacitor.config.json";
    private static final String BACKGROUND_RUNNER_CONFIG_KEY = "BackgroundRunner";
    private static final String BACKGROUND_RUNNER_WORKER_CLASS = "io.ionic.backgroundrunner.plugin.RunnerWorker";

    private final Context context;
    private final SharedPreferences prefs;
    private final Logger logger;
    private final Listener listener;

    CapgoUpdater(final Context context, final SharedPreferences prefs, final Logger logger, final Listener listener) {
        this.context = context;
        this.prefs = prefs;
        this.logger = logger;
        this.listener = listener;
    }

    /**
     * Creates the engine. {@code identity} carries appId, pluginVersion, versionBuild, versionCode, versionOs and
     * deviceId; storage paths and device facts are added here.
     */
    CapgoEngine createEngine(final JSONObject identity, final String serverPathKey) {
        final JSONObject config;
        try {
            config = new JSONObject(identity.toString());
            final File filesDir = this.context.getFilesDir();
            config.put("platform", "android");
            config.put("isEmulator", isEmulator());
            config.put("isProd", this.isProd());
            config.put("installSource", this.getInstallSource());
            config.put("bundleRoot", new File(filesDir, BUNDLE_DIRECTORY).getAbsolutePath());
            config.put("storageRoot", filesDir.getAbsolutePath());
            config.put("statsDir", this.context.getNoBackupFilesDir().getAbsolutePath());
            config.put("cacheDir", new File(this.context.getCacheDir(), "capgo_downloads").getAbsolutePath());
            config.put("builtinServerPath", "public");
            config.put("builtinDir", new File(filesDir, "public").getAbsolutePath());
            final ApplicationInfo applicationInfo = this.context.getApplicationInfo();
            config.put("builtinApk", applicationInfo == null || applicationInfo.sourceDir == null ? "" : applicationInfo.sourceDir);
            config.put(
                "keys",
                new JSONObject().put("serverPath", serverPathKey == null || serverPathKey.isEmpty() ? "serverBasePath" : serverPathKey)
            );
        } catch (JSONException e) {
            throw new IllegalStateException("Invalid engine config", e);
        }
        return new CapgoEngine(config, this.host);
    }

    final CapgoEngineHost host = new CapgoEngineHost() {
        @Override
        void log(final int level, final String message) {
            switch (level) {
                case 0:
                    logger.debug(message);
                    break;
                case 1:
                    logger.info(message);
                    break;
                case 2:
                    logger.warn(message);
                    break;
                default:
                    logger.error(message);
                    break;
            }
        }

        @Override
        String kvGet(final String key, final String defaultValue) {
            return readPreference(prefs, key, defaultValue);
        }

        @Override
        boolean kvContains(final String key) {
            return prefs.contains(key);
        }

        @Override
        void kvSet(final String key, final String value) {
            final SharedPreferences.Editor editor = prefs.edit();
            if (value == null) {
                editor.remove(key);
            } else {
                editor.putString(key, value);
            }
            editor.commit();
        }

        @Override
        String kvKeysJson() {
            final Map<String, ?> all = prefs.getAll();
            return all == null ? "[]" : new JSONArray(all.keySet()).toString();
        }

        @Override
        void emit(final String event, final String payloadJson) {
            listener.onEvent(event, payloadJson);
        }

        @Override
        String hook(final String name, final String payloadJson) {
            try {
                return listener.onHook(name, payloadJson);
            } catch (RuntimeException e) {
                logger.error("Hook " + name + " failed: " + e.getMessage());
                return null;
            }
        }

        @Override
        void willSwitchBundle(final String path) {
            resetBackgroundRunnerWorkForBundleSwitch(new File(path));
        }
    };

    /**
     * Stored value as a string. Earlier plugin versions stored some keys as booleans or longs
     * (preview flags, last reported exit timestamp): those are returned in their string form.
     */
    static String readPreference(final SharedPreferences prefs, final String key, final String defaultValue) {
        try {
            return prefs.getString(key, defaultValue);
        } catch (ClassCastException e) {
            final Map<String, ?> all = prefs.getAll();
            final Object value = all == null ? null : all.get(key);
            return value == null ? defaultValue : String.valueOf(value);
        }
    }

    // ---- device facts --------------------------------------------------------------------------

    private boolean isProd() {
        try {
            return (this.context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0;
        } catch (Exception e) {
            return true;
        }
    }

    static String installSourceForInstallerPackage(final String installerPackageName) {
        if (installerPackageName == null || installerPackageName.trim().isEmpty()) {
            return "";
        }
        switch (installerPackageName) {
            case "com.android.vending":
                // Android exposes the Google Play installer package, but not whether the app came from production, alpha, beta, or internal testing.
                return "google_play";
            case "com.amazon.venezia":
                return "amazon_appstore";
            case "com.sec.android.app.samsungapps":
                return "samsung_galaxy_store";
            case "com.huawei.appmarket":
                return "huawei_appgallery";
            default:
                return "";
        }
    }

    @SuppressWarnings("deprecation")
    private String getInstallSource() {
        try {
            final PackageManager packageManager = this.context.getPackageManager();
            final String packageName = this.context.getPackageName();
            String installerPackageName;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                final android.content.pm.InstallSourceInfo installSourceInfo = packageManager.getInstallSourceInfo(packageName);
                installerPackageName = installSourceInfo.getInstallingPackageName();
                if (installerPackageName == null || installerPackageName.trim().isEmpty()) {
                    installerPackageName = installSourceInfo.getInitiatingPackageName();
                }
            } else {
                installerPackageName = packageManager.getInstallerPackageName(packageName);
            }
            return installSourceForInstallerPackage(installerPackageName);
        } catch (Exception e) {
            return "";
        }
    }

    private static boolean isEmulator() {
        final String brand = String.valueOf(Build.BRAND);
        final String device = String.valueOf(Build.DEVICE);
        final String fingerprint = String.valueOf(Build.FINGERPRINT);
        final String hardware = String.valueOf(Build.HARDWARE);
        final String model = String.valueOf(Build.MODEL);
        final String manufacturer = String.valueOf(Build.MANUFACTURER);
        final String product = String.valueOf(Build.PRODUCT);

        return (
            (brand.startsWith("generic") && device.startsWith("generic")) ||
            fingerprint.startsWith("generic") ||
            fingerprint.startsWith("unknown") ||
            hardware.contains("goldfish") ||
            hardware.contains("ranchu") ||
            model.contains("google_sdk") ||
            model.contains("Emulator") ||
            model.contains("Android SDK built for x86") ||
            manufacturer.contains("Genymotion") ||
            product.contains("sdk_google") ||
            product.contains("google_sdk") ||
            product.contains("sdk") ||
            product.contains("sdk_x86") ||
            product.contains("sdk_gphone64_arm64") ||
            product.contains("vbox86p") ||
            product.contains("emulator") ||
            product.contains("simulator")
        );
    }

    // ---- Background Runner -----------------------------------------------------------------------
    // @capacitor/background-runner runs a script from native public storage through WorkManager: before
    // the live bundle changes, cancel its work, copy the new bundle's script and reschedule it.

    static final class BackgroundRunnerWorkConfig {

        final String label;
        final String src;
        final String event;
        final boolean autoStart;
        final boolean repeat;
        final int interval;

        BackgroundRunnerWorkConfig(
            final String label,
            final String src,
            final String event,
            final boolean autoStart,
            final boolean repeat,
            final int interval
        ) {
            this.label = label;
            this.src = src;
            this.event = event;
            this.autoStart = autoStart;
            this.repeat = repeat;
            this.interval = interval;
        }
    }

    static BackgroundRunnerWorkConfig getBackgroundRunnerWorkConfigFromConfig(final String configJson) {
        if (configJson == null || configJson.trim().isEmpty()) {
            return null;
        }
        try {
            final JSONObject config = new JSONObject(configJson);
            final JSONObject plugins = config.optJSONObject("plugins");
            if (plugins == null) {
                return null;
            }
            final JSONObject backgroundRunner = plugins.optJSONObject(BACKGROUND_RUNNER_CONFIG_KEY);
            if (backgroundRunner == null) {
                return null;
            }
            final String label = backgroundRunner.optString("label", "").trim();
            if (label.isEmpty()) {
                return null;
            }
            return new BackgroundRunnerWorkConfig(
                label,
                backgroundRunner.optString("src", "").trim(),
                backgroundRunner.optString("event", "").trim(),
                backgroundRunner.optBoolean("autoStart", false),
                backgroundRunner.optBoolean("repeat", false),
                backgroundRunner.optInt("interval", 0)
            );
        } catch (JSONException ignored) {
            return null;
        }
    }

    static String getBackgroundRunnerLabelFromConfig(final String configJson) {
        final BackgroundRunnerWorkConfig config = getBackgroundRunnerWorkConfigFromConfig(configJson);
        return config == null ? null : config.label;
    }

    private String readAssetAsString(final String assetPath) throws IOException {
        final StringBuilder buffer = new StringBuilder();
        try (
            final BufferedReader reader = new BufferedReader(
                new InputStreamReader(this.context.getAssets().open(assetPath), StandardCharsets.UTF_8)
            )
        ) {
            String line;
            while ((line = reader.readLine()) != null) {
                buffer.append(line).append('\n');
            }
        }
        return buffer.toString();
    }

    /** Resolves {@code relativePath} inside {@code base} with the shared core path guard, then canonically. */
    private static File resolveInside(final File base, final String relativePath) throws IOException {
        final File canonicalBase = base.getCanonicalFile();
        final String resolved;
        try {
            resolved = CapgoCore.call(
                "resolvePathInside",
                CapgoCore.input("base", canonicalBase.getPath(), "path", relativePath)
            ).getString("path");
        } catch (CapgoCore.Failure | JSONException e) {
            throw new IOException("Invalid path: " + e.getMessage());
        }
        final File target = new File(resolved).getCanonicalFile();
        final String basePath = canonicalBase.getPath().endsWith(File.separator)
            ? canonicalBase.getPath()
            : canonicalBase.getPath() + File.separator;
        if (!target.getPath().startsWith(basePath)) {
            throw new IOException("Path escapes base directory: " + relativePath);
        }
        return target;
    }

    private void syncBackgroundRunnerScriptFromBundle(final File bundle, final BackgroundRunnerWorkConfig config) {
        if (bundle == null || config == null || config.src == null || config.src.isEmpty()) {
            return;
        }
        if (bundle.getPath().endsWith("/public") || "public".equals(bundle.getName())) {
            return;
        }
        try {
            final File source = resolveInside(bundle, config.src);
            if (!source.isFile()) {
                return;
            }
            final File dest = resolveInside(new File(this.context.getFilesDir(), "public"), config.src);
            final File parent = dest.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                throw new IOException("Failed to create parent directory: " + parent.getAbsolutePath());
            }
            final File temp = File.createTempFile("capgo-", ".tmp", parent);
            try {
                Files.copy(source.toPath(), temp.toPath(), StandardCopyOption.REPLACE_EXISTING);
                Files.move(temp.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING);
            } finally {
                if (temp.exists()) {
                    temp.delete();
                }
            }
            logger.info("Synced Background Runner script into native public storage before bundle switch.");
            logger.debug("Background Runner script path: " + dest.getAbsolutePath());
        } catch (Exception e) {
            logger.debug("Background Runner script sync skipped: " + e.getMessage());
        }
    }

    private void resetBackgroundRunnerWorkForBundleSwitch(final File bundle) {
        final BackgroundRunnerWorkConfig config;
        try {
            config = getBackgroundRunnerWorkConfigFromConfig(this.readAssetAsString(CAPACITOR_CONFIG_ASSET));
        } catch (IOException ignored) {
            return;
        }
        if (config == null) {
            return;
        }
        try {
            final WorkManager workManager = WorkManager.getInstance(this.context.getApplicationContext());
            workManager.cancelUniqueWork(config.label);
            workManager.cancelAllWorkByTag(config.label);
            logger.info("Cancelled Background Runner work before bundle switch.");
            logger.debug("Background Runner label: " + config.label);
        } catch (Exception e) {
            logger.warn("Failed to cancel Background Runner work before bundle switch.");
            logger.debug("Background Runner cancellation error: " + e.getMessage());
        }
        this.syncBackgroundRunnerScriptFromBundle(bundle, config);
        this.rescheduleBackgroundRunnerWork(config);
    }

    private void rescheduleBackgroundRunnerWork(final BackgroundRunnerWorkConfig config) {
        if (!config.autoStart || config.interval <= 0 || config.src.isEmpty()) {
            return;
        }
        try {
            @SuppressWarnings("unchecked")
            final Class<? extends ListenableWorker> workerClass = (Class<? extends ListenableWorker>) Class.forName(
                BACKGROUND_RUNNER_WORKER_CLASS
            );
            final Data data = new Data.Builder()
                .putString("label", config.label)
                .putString("src", config.src)
                .putString("event", config.event)
                .build();
            final Constraints constraints = new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build();
            final WorkManager workManager = WorkManager.getInstance(this.context.getApplicationContext());
            if (!config.repeat) {
                final OneTimeWorkRequest work = new OneTimeWorkRequest.Builder(workerClass)
                    .setInitialDelay(config.interval, TimeUnit.MINUTES)
                    .setInputData(data)
                    .addTag(config.label)
                    .setConstraints(constraints)
                    .build();
                workManager.enqueueUniqueWork(config.label, ExistingWorkPolicy.REPLACE, work);
            } else {
                final PeriodicWorkRequest work = new PeriodicWorkRequest.Builder(workerClass, config.interval, TimeUnit.MINUTES)
                    .setInitialDelay(config.interval, TimeUnit.MINUTES)
                    .setInputData(data)
                    .addTag(config.label)
                    .setConstraints(constraints)
                    .build();
                workManager.enqueueUniquePeriodicWork(config.label, ExistingPeriodicWorkPolicy.UPDATE, work);
            }
            logger.info("Rescheduled Background Runner work after bundle switch.");
        } catch (ClassNotFoundException ignored) {
            logger.debug("Background Runner plugin not installed, skipping reschedule.");
        } catch (Exception e) {
            logger.warn("Failed to reschedule Background Runner work after bundle switch.");
            logger.debug("Background Runner reschedule error: " + e.getMessage());
        }
    }
}
