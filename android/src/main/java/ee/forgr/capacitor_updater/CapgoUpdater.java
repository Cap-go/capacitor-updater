/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.lifecycle.LifecycleOwner;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.ListenableWorker;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FilenameFilter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class CapgoUpdater {

    private final Logger logger;

    private static final String AB = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    private static final SecureRandom rnd = new SecureRandom();

    private static final String bundleDirectory = "versions";
    private static final String CAPACITOR_CONFIG_ASSET = "capacitor.config.json";
    private static final String BACKGROUND_RUNNER_CONFIG_KEY = "BackgroundRunner";
    private static final String BACKGROUND_RUNNER_WORKER_CLASS = "io.ionic.backgroundrunner.plugin.RunnerWorker";

    public static final String TAG = "Capacitor-updater";
    public SharedPreferences.Editor editor;

    /** Optional gate run before any download touches disk (e.g. wait for launch cleanup). */
    public Runnable downloadGate = null;
    public SharedPreferences prefs;

    public File documentsDir;
    public File noBackupDir;
    public Boolean directUpdate = false;
    public Activity activity;
    public String pluginVersion = "";
    public String versionBuild = "";
    public String versionCode = "";
    public String versionOs = "";
    public String CAP_SERVER_PATH = "";

    public String customId = "";
    public String statsUrl = "";
    public String channelUrl = "";
    public String defaultChannel = "";
    public String appId = "";
    public volatile boolean previewSession = false;
    public String publicKey = "";
    public String deviceID = "";
    public int timeout = 20000;

    // Cached key ID calculated once from publicKey
    private String cachedKeyId = "";

    private final ExecutorService io = Executors.newSingleThreadExecutor();

    public CapgoUpdater(Logger logger) {
        this.logger = logger;
    }

    private boolean isProd() {
        try {
            if (activity == null) {
                return true; // Default to production if no activity context
            }
            return (activity.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0;
        } catch (Exception e) {
            return true; // Default to production if we can't determine
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
        if (activity == null) {
            return "";
        }

        try {
            PackageManager packageManager = activity.getPackageManager();
            String packageName = activity.getPackageName();
            String installerPackageName;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                android.content.pm.InstallSourceInfo installSourceInfo = packageManager.getInstallSourceInfo(packageName);
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

    private boolean isEmulator() {
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

    void notifyDownload(final String id, final int percent) {}

    void directUpdateFinish(final BundleInfo latest) {}

    /** Launch downloads have no waiter. The plugin emits appReady from here when WorkManager settles. */
    void backgroundDownloadSettled(final BundleInfo bundle, final String status) {}

    void notifyListeners(final String id, final Map<String, Object> res) {}

    static boolean shouldNotifyLaunchDownloadReady(
        final boolean awaitedByCaller,
        final boolean success,
        final boolean directInstall,
        final boolean previewSession
    ) {
        return CapgoCore.bool(
            "launchDownloadReady",
            launchDownloadReadyInput(awaitedByCaller, success, directInstall, previewSession, true),
            "notify",
            !awaitedByCaller
        );
    }

    static String launchDownloadReadyStatus(final boolean success, final boolean setNext) {
        return CapgoCore.string(
            "launchDownloadReady",
            launchDownloadReadyInput(true, success, false, false, setNext),
            "status",
            "Error downloading file"
        );
    }

    private static org.json.JSONObject launchDownloadReadyInput(
        final boolean awaitedByCaller,
        final boolean success,
        final boolean directInstall,
        final boolean previewSession,
        final boolean setNext
    ) {
        return CapgoCore.input(
            "awaitedByCaller",
            awaitedByCaller,
            "success",
            success,
            "directInstall",
            directInstall,
            "previewSession",
            previewSession,
            "setNext",
            setNext
        );
    }

    public String randomString() {
        final StringBuilder sb = new StringBuilder(10);
        for (int i = 0; i < 10; i++) sb.append(AB.charAt(rnd.nextInt(AB.length())));
        return sb.toString();
    }

    public void setPublicKey(String publicKey) {
        // Empty string means no encryption - proceed normally
        if (publicKey == null || publicKey.isEmpty()) {
            this.publicKey = "";
            this.cachedKeyId = "";
            return;
        }

        // Non-empty: must be a valid RSA key or crash
        try {
            CryptoCipher.stringToPublicKey(publicKey);
        } catch (Exception e) {
            throw new RuntimeException(
                "Invalid public key in capacitor.config.json: failed to parse RSA key. Remove the key or provide a valid PEM-formatted RSA public key.",
                e
            );
        }

        this.publicKey = publicKey;
        this.cachedKeyId = CryptoCipher.calcKeyId(publicKey);
    }

    static boolean containsPathTraversalSegment(final String relativePath) {
        return CapgoCore.bool("pathTraversalSegment", CapgoCore.input("path", relativePath), "traversal", true);
    }

    /**
     * Resolves an untrusted relative path (manifest file_name, zip entry, bundle id) strictly inside
     * {@code baseDirectory}. The lexical guard is the shared core rule; the canonical (symlink-resolving) check is
     * kept here as defense in depth.
     */
    static File resolvePathInsideDirectory(final File baseDirectory, final String relativePath) throws IOException {
        return resolveInsideDirectory("resolvePathInside", baseDirectory, "path", relativePath);
    }

    static File resolveInsideDirectory(final String operation, final File baseDirectory, final String key, final String relativePath)
        throws IOException {
        final File canonicalBase = baseDirectory.getCanonicalFile();
        final String resolved;
        try {
            resolved = CapgoCore.call(operation, CapgoCore.input("base", canonicalBase.getPath(), key, relativePath)).getString("path");
        } catch (CapgoCore.Failure | org.json.JSONException e) {
            throw new IOException("Invalid path: " + e.getMessage());
        }

        final File canonicalTarget = new File(resolved).getCanonicalFile();
        final String basePath = canonicalBase.getPath();
        final String normalizedBasePath = basePath.endsWith(File.separator) ? basePath : basePath + File.separator;
        if (!canonicalTarget.getPath().startsWith(normalizedBasePath)) {
            throw new IOException("Path escapes base directory: " + relativePath);
        }
        return canonicalTarget;
    }

    static File resolveBundleDirectory(final File documentsDir, final String bundleId) throws IOException {
        return resolvePathInsideDirectory(new File(documentsDir, bundleDirectory), bundleId);
    }

    public String getKeyId() {
        return this.cachedKeyId;
    }

    static final String EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    static boolean isSafeCacheHash(final String hash) {
        return CapgoCore.bool("safeCacheHash", CapgoCore.input("hash", hash), "safe", false);
    }

    // SHA-256 hash-named cache files were verified when written. Existence is
    // enough for non-empty files; empty files are reused only for the empty SHA-256.
    // CRC32 (8 hex) is too collision-prone to trust without a re-read.
    static boolean isReusableCacheFile(final File file, final String expectedHash) {
        final Long size = file != null && file.isFile() ? file.length() : null;
        return CapgoCore.bool("reusableCacheFile", CapgoCore.input("hash", expectedHash, "size", size), "reusable", false);
    }

    public JSONArray getMissingBundleFiles(final JSONArray manifest, final String sessionKey) throws JSONException {
        return this.missingBundleFilesResult(manifest, sessionKey).getJSONArray("missing");
    }

    public JSONObject missingBundleFilesResult(final JSONArray manifest, final String sessionKey) throws JSONException {
        return this.call("missingBundleFiles", "manifest", manifest, "sessionKey", sessionKey);
    }

    private void notifyLaunchDownloadReady(
        final boolean awaitedByCaller,
        final boolean success,
        final boolean directInstall,
        final boolean previewSession,
        final boolean setNext,
        final BundleInfo bundle
    ) {
        if (!shouldNotifyLaunchDownloadReady(awaitedByCaller, success, directInstall, previewSession)) {
            return;
        }
        final BundleInfo readyBundle = bundle != null ? bundle : this.getCurrentBundle();
        this.backgroundDownloadSettled(readyBundle, launchDownloadReadyStatus(success, setNext));
    }

    /** Applies a freshly installed bundle: preview sessions skip it, direct updates install now, else schedule it. */
    private void applyDownloadedBundle(final BundleInfo next) {
        if (this.previewSession) {
            logger.info("Preview session is active, skipping automatic install of downloaded bundle");
            this.directUpdate = false;
        } else if (this.directUpdate) {
            logger.info("directUpdate: " + this.directUpdate);
            CapgoUpdater.this.directUpdateFinish(next);
            this.directUpdate = false;
        } else {
            logger.info("directUpdate: " + this.directUpdate);
            this.setNextBundle(next.getId());
        }
    }

    private void observeWorkProgress(Context context, String id, boolean setNext) {
        if (!(context instanceof LifecycleOwner)) {
            logger.error("Context is not a LifecycleOwner, cannot observe work progress");
            return;
        }

        final AtomicBoolean terminalHandled = new AtomicBoolean(false);
        activity.runOnUiThread(() -> {
            WorkManager.getInstance(context)
                .getWorkInfosByTagLiveData(id)
                .observe((LifecycleOwner) context, (workInfos) -> {
                    if (workInfos == null || workInfos.isEmpty()) return;
                    final WorkInfo workInfo = workInfos.get(0);
                    switch (workInfo.getState()) {
                        case SUCCEEDED:
                            if (!terminalHandled.compareAndSet(false, true)) break;
                            io.execute(() -> {
                                // Read the install plan before applying it clears directUpdate.
                                final boolean directInstall =
                                    setNext && Boolean.TRUE.equals(CapgoUpdater.this.directUpdate) && !CapgoUpdater.this.previewSession;
                                final boolean previewSession = CapgoUpdater.this.previewSession;
                                final BundleInfo installed = getBundleInfo(id);
                                if (setNext) {
                                    this.applyDownloadedBundle(installed);
                                }
                                DownloadWorkerManager.cancelBundleDownload(activity, id, installed.getVersionName());
                                notifyLaunchDownloadReady(false, true, directInstall, previewSession, setNext, setNext ? installed : null);
                            });
                            break;
                        case FAILED:
                            if (!terminalHandled.compareAndSet(false, true)) break;
                            final Data failedData = workInfo.getOutputData();
                            final String error = failedData.getString(DownloadService.ERROR);
                            final String failedVersion = failedData.getString(DownloadService.VERSION);
                            logger.error("Download failed");
                            logger.debug("Error: " + error);
                            io.execute(() -> {
                                if (DownloadService.UPDATER_UNAVAILABLE.equals(error)) {
                                    // The engine never ran: record the failure here.
                                    final BundleInfo pending = getBundleInfo(id);
                                    saveBundleInfo(id, pending.setStatus(BundleStatus.ERROR));
                                    final Map<String, Object> ret = new HashMap<>();
                                    ret.put("version", failedVersion);
                                    ret.put("error", error);
                                    sendStats("download_fail", failedVersion);
                                    notifyListeners("downloadFailed", ret);
                                }
                                DownloadWorkerManager.cancelBundleDownload(activity, id, failedVersion);
                                notifyLaunchDownloadReady(false, false, false, false, false, null);
                            });
                            break;
                        case CANCELLED:
                            if (!terminalHandled.compareAndSet(false, true)) break;
                            DataManager.getInstance().clearManifest(id);
                            break;
                        default:
                            // Progress is emitted by the engine (downloadProgress events).
                            break;
                    }
                });
        });
    }

    /** Runs a download in the engine (WorkManager worker and JS paths). Blocking. */
    BundleInfo runEngineDownload(
        final String id,
        final String url,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest
    ) throws CapgoCore.Failure {
        final JSONObject result = this.engine().call(
            "download",
            CapgoCore.input(
                "id",
                id,
                "url",
                url == null ? "" : url,
                "version",
                version,
                "sessionKey",
                sessionKey == null ? "" : sessionKey,
                "checksum",
                checksum == null ? "" : checksum,
                "manifest",
                manifest
            )
        );
        return BundleInfo.fromRawJson(result);
    }

    /** GET a JSON object through the engine HTTP client (preview payloads). */
    JSONObject fetchJson(final String url) throws IOException {
        try {
            return this.engine().call("fetchJson", CapgoCore.input("url", url));
        } catch (CapgoCore.Failure e) {
            throw asIOException(e);
        }
    }

    void cancelEngineDownload(final String version) {
        this.call("cancelDownload", "version", version);
    }

    public void cleanupDeltaCache() {
        cleanupDeltaCache(null);
    }

    public void cleanupDeltaCache(final Thread threadToCheck) {
        if (this.activity == null) {
            logger.warn("Activity is null, skipping delta cache cleanup");
            return;
        }
        this.call("bundleCleanupDeltaCache");
    }

    public void cleanupDownloadDirectories(final Set<String> allowedIds) {
        cleanupDownloadDirectories(allowedIds, null);
    }

    public void cleanupDownloadDirectories(final Set<String> allowedIds, final Thread threadToCheck) {
        if (this.documentsDir == null) {
            logger.warn("Documents directory is null, skipping download cleanup");
            return;
        }
        if (threadToCheck != null && threadToCheck.isInterrupted()) {
            logger.warn("cleanupDownloadDirectories was cancelled");
            return;
        }
        this.call("bundleCleanupDownloadDirectories", "allowedIds", allowedIds == null ? new JSONArray() : new JSONArray(allowedIds));
    }

    public Set<String> allowedBundleIdsForCleanup() {
        final Object ids = this.engine().callValueUnchecked("bundleAllowedIdsForCleanup", new JSONObject());
        final Set<String> allowed = new HashSet<>();
        if (ids instanceof JSONArray) {
            for (int index = 0; index < ((JSONArray) ids).length(); index++) {
                allowed.add(((JSONArray) ids).optString(index));
            }
        }
        return allowed;
    }

    public void cleanupOrphanedTempFolders(final Thread threadToCheck) {
        if (this.documentsDir == null) {
            logger.warn("Documents directory is null, skipping temp folder cleanup");
            return;
        }
        if (threadToCheck != null && threadToCheck.isInterrupted()) {
            logger.warn("cleanupOrphanedTempFolders was cancelled");
            return;
        }
        this.call("bundleCleanupOrphanedTempFolders");
    }

    static boolean shouldResetForForeignBundle(final String bundlePath, final boolean isBuiltin, final boolean hasStoredBundleInfo) {
        return CapgoCore.bool(
            "foreignBundleReset",
            CapgoCore.input("bundlePath", bundlePath, "isBuiltin", isBuiltin, "hasStoredBundleInfo", hasStoredBundleInfo),
            "reset",
            false
        );
    }

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

            final String src = backgroundRunner.optString("src", "").trim();
            final String event = backgroundRunner.optString("event", "").trim();
            return new BackgroundRunnerWorkConfig(
                label,
                src,
                event,
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
                new InputStreamReader(this.activity.getAssets().open(assetPath), StandardCharsets.UTF_8)
            )
        ) {
            String line;
            while ((line = reader.readLine()) != null) {
                buffer.append(line).append('\n');
            }
        }
        return buffer.toString();
    }

    private void copyFileAtomically(final File source, final File dest) throws IOException {
        final File parent = dest.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("Failed to create parent directory: " + parent.getAbsolutePath());
        }

        final File tempFile = File.createTempFile("capgo-", ".tmp", parent);
        try {
            try (
                final FileInputStream input = new FileInputStream(source);
                final FileOutputStream output = new FileOutputStream(tempFile)
            ) {
                final byte[] buffer = new byte[CryptoCipher.copyBufferBytes()];
                int length;
                while ((length = input.read(buffer)) != -1) {
                    output.write(buffer, 0, length);
                }
            }
            CryptoCipher.replaceFile(tempFile, dest);
        } finally {
            if (tempFile.exists()) {
                tempFile.delete();
            }
        }
    }

    private void syncBackgroundRunnerScriptFromBundle(final File bundle, final BackgroundRunnerWorkConfig config) {
        if (this.activity == null || bundle == null || config == null || config.src == null || config.src.isEmpty()) {
            return;
        }

        if (bundle.getPath().endsWith("/public") || "public".equals(bundle.getName())) {
            return;
        }

        try {
            final File source = resolvePathInsideDirectory(bundle, config.src);
            if (!source.isFile()) {
                return;
            }

            final File publicDir = new File(this.activity.getFilesDir(), "public");
            final File dest = resolvePathInsideDirectory(publicDir, config.src);
            this.copyFileAtomically(source, dest);
            logger.info("Synced Background Runner script into native public storage before bundle switch.");
            logger.debug("Background Runner script path: " + dest.getAbsolutePath());
        } catch (Exception e) {
            logger.debug("Background Runner script sync skipped: " + e.getMessage());
        }
    }

    private void resetBackgroundRunnerWorkForBundleSwitch(final File bundle) {
        if (this.activity == null) {
            return;
        }

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
            final WorkManager workManager = WorkManager.getInstance(this.activity.getApplicationContext());
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
            final WorkManager workManager = WorkManager.getInstance(this.activity.getApplicationContext());

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

    private boolean hasStoredBundleInfo(final String id) {
        return id != null && this.call("bundleHasInfo", "id", id).optBoolean("stored", false);
    }

    /** Engine gate: runs {@link #downloadGate} (launch cleanup) before a download touches disk. */
    private String runDownloadGateForEngine() {
        if (this.downloadGate == null) {
            return null;
        }
        try {
            this.downloadGate.run();
            return null;
        } catch (final RuntimeException e) {
            return e.getMessage() == null ? "Download gate failed" : e.getMessage();
        }
    }

    private static IOException asIOException(final CapgoCore.Failure failure) {
        final String message = failure.getMessage() == null ? failure.code : failure.getMessage();
        return new IOException(message.startsWith(failure.code + ": ") ? message.substring(failure.code.length() + 2) : message, failure);
    }

    public void downloadBackground(
        final String url,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest
    ) {
        downloadBackground(url, version, sessionKey, checksum, manifest, true);
    }

    public void downloadBackground(
        final String url,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest,
        final boolean setNext
    ) {
        try {
            this.engine().call(
                "downloadPreflight",
                CapgoCore.input("version", version, "sessionKey", sessionKey, "checksum", checksum, "isManifest", manifest != null)
            );
        } catch (final CapgoCore.Failure e) {
            logger.error("Download blocked: " + e.getMessage());
            return;
        }
        final String gateError = this.runDownloadGateForEngine();
        if (gateError != null) {
            logger.error("Download blocked by cleanup gate: " + gateError);
            return;
        }
        if (this.activity == null) {
            logger.error("Activity is null, cannot schedule download");
            return;
        }

        // Check if version is already downloading, but allow retry if previous download failed
        if (DownloadWorkerManager.isVersionDownloading(this.activity, version)) {
            BundleInfo existingBundle = this.getBundleInfoByName(version);
            if (existingBundle != null && existingBundle.isErrorStatus()) {
                if (!DownloadWorkerManager.cancelVersionDownloadAndAwait(this.activity, version)) {
                    logger.error("Failed to cancel previous download before retry");
                    return;
                }
                logger.info("Retrying failed download for version: " + version);
            } else {
                logger.info("Version already downloading: " + version);
                return;
            }
        }

        final BundleInfo record = this.bundleCall("bundleNewDownloadRecord", "version", version);
        final String id = record.getId();
        this.notifyDownload(id, 0);
        this.notifyDownload(id, 5);
        observeWorkProgress(this.activity, id, setNext);
        if (manifest != null) {
            DataManager.getInstance().setManifest(id, manifest);
        }
        DownloadWorkerManager.enqueueDownload(
            this.activity,
            url,
            id,
            this.documentsDir.getAbsolutePath(),
            id,
            version,
            sessionKey,
            checksum,
            this.publicKey,
            manifest != null,
            this.isEmulator(),
            this.appId,
            this.pluginVersion,
            this.isProd(),
            this.getInstallSource(),
            this.statsUrl,
            this.deviceID,
            this.versionBuild,
            this.versionCode,
            this.versionOs,
            this.customId,
            this.defaultChannel
        );
    }

    public BundleInfo download(final String url, final String version, final String sessionKey, final String checksum) throws IOException {
        try {
            return this.runEngineDownload(null, url, version, sessionKey, checksum, null);
        } catch (CapgoCore.Failure e) {
            throw asIOException(e);
        }
    }

    public BundleInfo downloadManifest(
        final String url,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest
    ) throws IOException {
        if (manifest == null) {
            return download(url, version, sessionKey, checksum);
        }
        try {
            return this.runEngineDownload(null, url, version, sessionKey, checksum, manifest);
        } catch (CapgoCore.Failure e) {
            throw asIOException(e);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Engine (shared Rust core). Store, stats and backend logic live in core/src/engine; the
    // methods below keep the historical Java API and only marshal arguments.

    private CapgoEngine engine;
    /** Last updater whose engine was created; WorkManager download jobs run on it. */
    private static volatile CapgoUpdater RUNNING;
    private JSONObject engineConfigSnapshot;

    static CapgoUpdater running() {
        return RUNNING;
    }

    private String engineBundleRoot;
    private final Map<String, Runnable> statsCallbacks = new ConcurrentHashMap<>();
    private final ExecutorService network = Executors.newCachedThreadPool();

    private final CapgoEngineHost engineHost = new CapgoEngineHost() {
        @Override
        void log(final int level, final String message) {
            if (logger == null) {
                return;
            }
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
            if (prefs == null) {
                return defaultValue;
            }
            try {
                return prefs.getString(key, defaultValue);
            } catch (ClassCastException e) {
                return defaultValue;
            }
        }

        @Override
        boolean kvContains(final String key) {
            return prefs != null && prefs.contains(key);
        }

        @Override
        boolean sendStats(final String action, final String versionName, final String oldVersionName) {
            CapgoUpdater.this.sendStats(action, versionName, oldVersionName);
            return true;
        }

        @Override
        void kvSet(final String key, final String value) {
            if (editor == null) {
                return;
            }
            if (value == null) {
                editor.remove(key);
            } else {
                editor.putString(key, value);
            }
            editor.commit();
        }

        @Override
        String kvKeysJson() {
            final JSONArray keys = new JSONArray();
            if (prefs != null) {
                final Map<String, ?> all = prefs.getAll();
                if (all != null) {
                    for (final String key : all.keySet()) {
                        keys.put(key);
                    }
                }
            }
            return keys.toString();
        }

        @Override
        void emit(final String event, final String payloadJson) {
            onEngineEvent(event, payloadJson);
        }

        @Override
        String beforeDownload() {
            return runDownloadGateForEngine();
        }

        @Override
        void willSwitchBundle(final String path) {
            resetBackgroundRunnerWorkForBundleSwitch(new File(path));
        }

        @Override
        boolean cancelVersionDownload(final String version) {
            return activity == null || DownloadWorkerManager.cancelVersionDownloadAndAwait(activity, version);
        }

        @Override
        void cancelAllDownloads() {
            if (activity != null) {
                DownloadWorkerManager.cancelAllDownloads(activity);
            }
        }
    };

    private void onEngineEvent(final String event, final String payloadJson) {
        final Object parsed = CapgoEngine.parse(payloadJson);
        final JSONObject payload = parsed instanceof JSONObject ? (JSONObject) parsed : new JSONObject();
        if ("downloadProgress".equals(event)) {
            this.notifyDownload(payload.optString("id", ""), payload.optInt("percent", 0));
            return;
        }
        if ("statsSent".equals(event)) {
            final Runnable callback = this.statsCallbacks.remove(payload.optString("callbackId", ""));
            if (callback != null) {
                try {
                    callback.run();
                } catch (Exception e) {
                    if (logger != null) {
                        logger.error("Error running stats sent callback");
                        logger.debug("Error: " + e.getMessage());
                    }
                }
            }
            return;
        }
        this.notifyListeners(event, jsonToMap(payload));
    }

    static Map<String, Object> jsonToMap(final JSONObject json) {
        final Map<String, Object> map = new HashMap<>();
        final Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            final String key = keys.next();
            final Object value = json.opt(key);
            map.put(key, value instanceof JSONObject ? jsonToMap((JSONObject) value) : value);
        }
        return map;
    }

    private static void put(final JSONObject json, final String key, final Object value) {
        try {
            json.put(key, value == null ? JSONObject.NULL : value);
        } catch (JSONException ignored) {
            // Keys are constants.
        }
    }

    private JSONObject engineConfig() {
        final JSONObject config = new JSONObject();
        put(config, "platform", "android");
        put(config, "appId", this.appId);
        put(config, "pluginVersion", this.pluginVersion);
        put(config, "versionBuild", this.versionBuild);
        put(config, "versionCode", this.versionCode);
        put(config, "versionOs", this.versionOs);
        put(config, "deviceId", this.deviceID);
        put(config, "customId", this.customId);
        put(config, "defaultChannel", this.defaultChannel);
        put(config, "isEmulator", this.isEmulator());
        put(config, "isProd", this.isProd());
        put(config, "installSource", this.getInstallSource());
        put(config, "statsUrl", this.statsUrl == null ? "" : this.statsUrl);
        put(config, "channelUrl", this.channelUrl == null ? "" : this.channelUrl);
        put(config, "publicKey", this.publicKey == null ? "" : this.publicKey);
        put(config, "previewSession", this.previewSession);
        put(config, "timeoutMs", DownloadService.httpTimeoutMs());
        put(config, "allowHttpsToHttpRedirect", DownloadService.allowHttpsToHttpRedirect());
        return config;
    }

    /** The engine for the current fields; created lazily, re-created when storage moves, re-configured on change. */
    synchronized CapgoEngine engine() {
        final String bundleRoot = this.documentsDir == null ? "" : new File(this.documentsDir, bundleDirectory).getAbsolutePath();
        final JSONObject config = this.engineConfig();
        if (this.engine == null || !bundleRoot.equals(this.engineBundleRoot)) {
            final JSONObject full = this.engineConfig();
            put(full, "bundleRoot", bundleRoot.isEmpty() ? "/capgo-updater-uninitialized/versions" : bundleRoot);
            put(full, "storageRoot", this.documentsDir == null ? "" : this.documentsDir.getAbsolutePath());
            final File statsDir = this.noBackupDir != null ? this.noBackupDir : this.documentsDir;
            put(full, "statsDir", statsDir == null ? "" : statsDir.getAbsolutePath());
            put(full, "cacheDir", this.activity == null ? "" : new File(this.activity.getCacheDir(), "capgo_downloads").getAbsolutePath());
            put(full, "builtinServerPath", "public");
            final JSONObject keys = new JSONObject();
            put(
                keys,
                "serverPath",
                this.CAP_SERVER_PATH == null || this.CAP_SERVER_PATH.isEmpty() ? "serverBasePath" : this.CAP_SERVER_PATH
            );
            put(full, "keys", keys);
            put(full, "builtinDir", this.activity == null ? "" : new File(this.activity.getFilesDir(), "public").getAbsolutePath());
            final android.content.pm.ApplicationInfo applicationInfo = this.activity == null ? null : this.activity.getApplicationInfo();
            put(full, "builtinApk", applicationInfo == null || applicationInfo.sourceDir == null ? "" : applicationInfo.sourceDir);
            this.engine = new CapgoEngine(full, this.engineHost);
            RUNNING = this;
            this.engineBundleRoot = bundleRoot;
            this.engineConfigSnapshot = config;
            return this.engine;
        }
        if (!config.toString().equals(this.engineConfigSnapshot.toString())) {
            try {
                this.engine.call("configure", config);
            } catch (CapgoCore.Failure e) {
                if (logger != null) {
                    logger.error("Failed to configure updater engine: " + e.getMessage());
                }
            }
            this.engineConfigSnapshot = config;
        }
        return this.engine;
    }

    private JSONObject call(final String operation, final Object... keyValues) {
        return this.engine().callUnchecked(operation, CapgoCore.input(keyValues));
    }

    private static BundleInfo bundleOrNull(final Object value) {
        return value instanceof JSONObject ? BundleInfo.fromRawJson((JSONObject) value) : null;
    }

    private BundleInfo bundleCall(final String operation, final Object... keyValues) {
        return bundleOrNull(this.engine().callValueUnchecked(operation, CapgoCore.input(keyValues)));
    }

    private static Map<String, Object> toResultMap(final JSONObject json) {
        final Map<String, Object> map = new HashMap<>();
        final Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            final String key = keys.next();
            map.put(key, json.opt(key));
        }
        return map;
    }

    /** Runs a blocking backend call off the caller thread, like the previous async OkHttp calls. */
    private void backend(final Callback callback, final String operation, final Object... keyValues) {
        final CapgoEngine engine = this.engine();
        final JSONObject input = CapgoCore.input(keyValues);
        this.network.execute(() -> {
            Map<String, Object> result;
            try {
                result = toResultMap(engine.call(operation, input));
            } catch (CapgoCore.Failure e) {
                result = new HashMap<>();
                result.put("error", e.code);
                result.put("message", e.getMessage());
            }
            callback.callback(result);
        });
    }

    // ---- store -------------------------------------------------------------------------------

    public List<BundleInfo> list(boolean rawList) {
        final JSONArray bundles = this.engine().callValueUnchecked("bundleList", CapgoCore.input("raw", rawList)) instanceof JSONArray
            ? (JSONArray) this.engine().callValueUnchecked("bundleList", CapgoCore.input("raw", rawList))
            : new JSONArray();
        final List<BundleInfo> res = new ArrayList<>();
        for (int index = 0; index < bundles.length(); index++) {
            final BundleInfo bundle = bundleOrNull(bundles.opt(index));
            if (bundle != null) {
                res.add(bundle);
            }
        }
        return res;
    }

    public Boolean delete(final String id, final Boolean removeInfo) throws IOException {
        return this.delete(id, removeInfo, true);
    }

    public Boolean delete(final String id, final Boolean removeInfo, final boolean cancelActiveDownload) throws IOException {
        return this.call(
            "bundleDelete",
            "id",
            id,
            "removeInfo",
            !Boolean.FALSE.equals(removeInfo),
            "cancelActiveDownload",
            cancelActiveDownload
        ).optBoolean("deleted", false);
    }

    public Boolean delete(final String id) {
        try {
            return this.delete(id, true);
        } catch (IOException e) {
            logger.info("Failed to delete bundle (" + id + ")" + "\nError:\n" + e);
            return false;
        }
    }

    /** Resumes deletes interrupted by a kill / OOM (records left in DELETING). */
    public void drainPendingDeletes() {
        this.call("bundleDrainPendingDeletes");
    }

    private boolean bundleExists(final String id) {
        return this.call("bundleExists", "id", id).optBoolean("exists", false);
    }

    static final class ResetState {

        final String currentBundlePath;
        final String fallbackBundleId;
        final String nextBundleId;

        ResetState(final String currentBundlePath, final String fallbackBundleId, final String nextBundleId) {
            this.currentBundlePath = currentBundlePath;
            this.fallbackBundleId = fallbackBundleId;
            this.nextBundleId = nextBundleId;
        }
    }

    ResetState captureResetState() {
        final JSONObject state = this.call("bundleCaptureResetState");
        return new ResetState(
            state.optString("currentBundlePath", "public"),
            state.optString("fallbackBundleId", BundleInfo.ID_BUILTIN),
            state.isNull("nextBundleId") ? null : state.optString("nextBundleId", null)
        );
    }

    void restoreResetState(final ResetState state) {
        this.call(
            "bundleRestoreResetState",
            "currentBundlePath",
            state.currentBundlePath,
            "fallbackBundleId",
            state.fallbackBundleId,
            "nextBundleId",
            state.nextBundleId
        );
    }

    void prepareResetStateForTransition() {
        this.call("bundlePrepareResetTransition");
    }

    void finalizeResetTransition(final String previousBundleName, final boolean internal) {
        this.call("bundleFinalizeResetTransition", "previousBundleName", previousBundleName, "internal", internal);
    }

    boolean canSet(final BundleInfo bundle) {
        return bundle != null && this.call("bundleCanSet", "id", bundle.getId(), "bundle", bundle.toRawJson()).optBoolean("canSet", false);
    }

    public Boolean set(final BundleInfo bundle) {
        return this.set(bundle.getId());
    }

    public Boolean set(final String id) {
        return this.call("bundleSet", "id", id).optBoolean("set", false);
    }

    boolean stagePendingReload(final BundleInfo bundle) {
        return (
            bundle != null &&
            this.call("bundleStagePendingReload", "id", bundle.getId(), "bundle", bundle.toRawJson()).optBoolean("staged", false)
        );
    }

    boolean stagePreviewFallbackReload(final BundleInfo bundle) {
        return (
            bundle != null &&
            this.call("bundleStagePreviewFallbackReload", "id", bundle.getId(), "bundle", bundle.toRawJson()).optBoolean("staged", false)
        );
    }

    void finalizePendingReload(final BundleInfo bundle, final String previousBundleName) {
        if (bundle == null) {
            return;
        }
        this.call(
            "bundleFinalizePendingReload",
            "id",
            bundle.getId(),
            "bundle",
            bundle.toRawJson(),
            "previousBundleName",
            previousBundleName
        );
    }

    @Deprecated
    public void autoReset() {
        this.autoReset(this.versionCode == null ? "" : this.versionCode);
    }

    public void autoReset(final String currentNativeBuildVersion) {
        this.autoReset(currentNativeBuildVersion, true);
    }

    public void autoReset(final String currentNativeBuildVersion, final boolean resetWhenNativeVersionChanged) {
        this.call(
            "bundleAutoReset",
            "nativeBuildVersion",
            currentNativeBuildVersion == null ? "" : currentNativeBuildVersion,
            "resetWhenNativeVersionChanged",
            resetWhenNativeVersionChanged
        );
    }

    public void reset() {
        this.reset(false);
    }

    public void setSuccess(final BundleInfo bundle, Boolean autoDeletePrevious) {
        this.call("bundleSetSuccess", "id", bundle.getId(), "autoDeletePrevious", Boolean.TRUE.equals(autoDeletePrevious));
    }

    public void setError(final BundleInfo bundle) {
        this.call("bundleSetError", "id", bundle.getId());
    }

    public void reset(final boolean internal) {
        this.call("bundleReset", "internal", internal);
    }

    public BundleInfo getBundleInfo(final String id) {
        return this.bundleCall("bundleGet", "id", id);
    }

    public BundleInfo getBundleInfoByName(final String versionName) {
        return this.bundleCall("bundleGetByName", "version", versionName);
    }

    public boolean saveBundleInfo(final String id, final BundleInfo info) {
        if (id == null) {
            return false;
        }
        return this.call("bundleSave", "id", id, "bundle", info == null ? null : info.toRawJson()).optBoolean("saved", false);
    }

    private String getCurrentBundleId() {
        return this.call("bundleCurrent").optString("id", BundleInfo.ID_BUILTIN);
    }

    public BundleInfo getCurrentBundle() {
        return this.getBundleInfo(this.getCurrentBundleId());
    }

    public String getCurrentBundlePath() {
        final String path = this.call("bundleCurrent").optString("path", "public");
        return path.trim().isEmpty() ? "public" : path;
    }

    public Boolean isUsingBuiltin() {
        return this.call("bundleCurrent").optBoolean("isBuiltin", true);
    }

    public BundleInfo getFallbackBundle() {
        return this.bundleCall("bundleFallback");
    }

    public BundleInfo getNextBundle() {
        return this.bundleCall("bundleNext");
    }

    public BundleInfo getPreviewFallbackBundle() {
        return this.bundleCall("bundlePreviewFallback");
    }

    public boolean setPreviewFallbackBundle(final String fallback) {
        return this.call("bundleSetPreviewFallback", "id", fallback).optBoolean("set", false);
    }

    public boolean setNextBundle(final String next) {
        return this.call("bundleSetNext", "id", next).optBoolean("set", false);
    }

    // ---- backend -----------------------------------------------------------------------------

    public void getLatest(final String updateUrl, final String channel, final Callback callback) {
        this.getLatest(updateUrl, channel, null, callback);
    }

    public void getLatest(final String updateUrl, final String channel, final String appIdOverride, final Callback callback) {
        this.backend(callback, "getLatest", "updateUrl", updateUrl, "channel", channel, "appId", appIdOverride);
    }

    public JSONObject getBundleDownloadSize(final String updateUrl, final String version, final JSONArray manifest) throws JSONException {
        return this.call("bundleDownloadSize", "updateUrl", updateUrl, "version", version, "manifest", manifest);
    }

    public void unsetChannel(
        final SharedPreferences.Editor editor,
        final String defaultChannelKey,
        final String configDefaultChannel,
        final boolean allowSetDefaultChannel,
        final Callback callback
    ) {
        final JSONObject result = this.call(
            "unsetChannel",
            "configDefaultChannel",
            configDefaultChannel,
            "allowSetDefaultChannel",
            allowSetDefaultChannel
        );
        if (!result.has("error")) {
            this.defaultChannel = configDefaultChannel;
            editor.remove(defaultChannelKey);
            editor.apply();
        }
        callback.callback(toResultMap(result));
    }

    public void setChannel(
        final String channel,
        final SharedPreferences.Editor editor,
        final String defaultChannelKey,
        final boolean allowSetDefaultChannel,
        final Callback callback
    ) {
        this.setChannel(channel, editor, defaultChannelKey, allowSetDefaultChannel, "", callback);
    }

    public void setChannel(
        final String channel,
        final SharedPreferences.Editor editor,
        final String defaultChannelKey,
        final boolean allowSetDefaultChannel,
        final String configDefaultChannel,
        final Callback callback
    ) {
        this.backend(
            (res) -> {
                if (!res.containsKey("error")) {
                    if (Boolean.TRUE.equals(res.get("unset"))) {
                        this.defaultChannel = configDefaultChannel;
                        editor.remove(defaultChannelKey);
                    } else {
                        this.defaultChannel = channel;
                        editor.putString(defaultChannelKey, channel);
                    }
                    editor.apply();
                }
                callback.callback(res);
            },
            "setChannel",
            "channel",
            channel,
            "allowSetDefaultChannel",
            allowSetDefaultChannel,
            "configDefaultChannel",
            configDefaultChannel
        );
    }

    public void getChannel(final Callback callback) {
        this.getChannel(callback, null, null);
    }

    public void getChannel(final Callback callback, final SharedPreferences.Editor editor, final String defaultChannelKey) {
        this.backend((res) -> {
            if (!res.containsKey("error") && !"default".equals(res.get("status"))) {
                persistDefaultChannelFromResponse(res.get("channel"), editor, defaultChannelKey);
            }
            callback.callback(res);
        }, "getChannel");
    }

    void persistDefaultChannelFromResponse(final Object channel, final SharedPreferences.Editor editor, final String defaultChannelKey) {
        if (!(channel instanceof String)) {
            return;
        }
        final String channelName = ((String) channel).trim();
        if (channelName.isEmpty() || BundleInfo.ID_BUILTIN.equals(channelName)) {
            return;
        }
        this.defaultChannel = channelName;
        if (editor != null && defaultChannelKey != null && !defaultChannelKey.isEmpty()) {
            editor.putString(defaultChannelKey, channelName);
            editor.apply();
        }
        logger.info("defaultChannel synchronized from getChannel(): " + channelName);
    }

    public void listChannels(final Callback callback) {
        this.backend(callback, "listChannels");
    }

    static Map<String, Object> parseListChannelsResponse(final String data) throws JSONException {
        JSONArray channelsJson = new JSONArray(data);
        List<Map<String, Object>> channelsList = new ArrayList<>();
        for (int i = 0; i < channelsJson.length(); i++) {
            JSONObject channelJson = channelsJson.getJSONObject(i);
            Object channelId = channelJson.get("id");
            if (!(channelId instanceof Number)) {
                throw new JSONException("Channel id must be a number");
            }
            Map<String, Object> channel = new HashMap<>();
            channel.put("id", channelId);
            channel.put("name", channelJson.optString("name", ""));
            channel.put("public", channelJson.optBoolean("public", false));
            channel.put("allow_self_set", channelJson.optBoolean("allow_self_set", false));
            channelsList.add(channel);
        }
        Map<String, Object> ret = new HashMap<>();
        ret.put("channels", channelsList);
        return ret;
    }

    static String parseRemoteError(final String responseData) {
        return CapgoCore.string("remoteError", CapgoCore.input("body", responseData), "error", "");
    }

    static String parseRemoteMessage(final String responseData) {
        return CapgoCore.string("remoteError", CapgoCore.input("body", responseData), "message", "");
    }

    /**
     * Epoch ms until which requests stay blocked after a 429 (0 = no block). Honours Retry-After, then
     * retryAfterSeconds, then rateLimitResetAt, capped at one day (shared core rule).
     */
    static long resolveRateLimitBlockedUntilMs(final String retryAfterHeader, final String responseData, final long nowMs) {
        return CapgoCore.number(
            "rateLimitDeadline",
            CapgoCore.input("retryAfter", retryAfterHeader, "body", responseData, "nowMs", nowMs),
            "blockedUntilMs",
            0L
        );
    }

    // ---- stats -------------------------------------------------------------------------------

    public void sendStats(final String action) {
        this.sendStats(action, this.getCurrentBundle().getVersionName());
    }

    public void sendStats(final String action, final String versionName) {
        this.sendStats(action, versionName, "");
    }

    public void sendStats(final String action, final String versionName, final String oldVersionName) {
        this.sendStats(action, versionName, oldVersionName, null);
    }

    public void sendStats(final String action, final String versionName, final String oldVersionName, final Map<String, String> metadata) {
        this.sendStats(action, versionName, oldVersionName, metadata, null);
    }

    public void sendStats(
        final String action,
        final String versionName,
        final String oldVersionName,
        final Map<String, String> metadata,
        final Runnable onSent
    ) {
        String callbackId = null;
        if (onSent != null) {
            callbackId = this.randomString();
            this.statsCallbacks.put(callbackId, onSent);
        }
        this.call(
            "statsSend",
            "action",
            action,
            "versionName",
            versionName,
            "oldVersionName",
            oldVersionName,
            "metadata",
            metadata == null ? null : new JSONObject(metadata),
            "callbackId",
            callbackId
        );
    }

    public void restorePendingStats() {
        this.call("statsRestore");
    }

    int pendingStatsCount() {
        return this.call("statsPendingCount").optInt("count", 0);
    }

    public void persistPendingStats() {
        this.call("statsPersist");
    }

    /**
     * Stops stats batching and persists pending stats. Call when the plugin is destroyed.
     */
    public void shutdown() {
        if (this.engine != null) {
            this.call("statsShutdown");
        }
        this.network.shutdown();
    }
}
