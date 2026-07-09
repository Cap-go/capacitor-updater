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
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
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
import java.util.Iterator;
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
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import okhttp3.*;
import okhttp3.HttpUrl;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class CapgoUpdater {

    private final Logger logger;

    private static final String AB = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    private static final SecureRandom rnd = new SecureRandom();

    private static final String INFO_SUFFIX = "_info";

    private static final String FALLBACK_VERSION = "pastVersion";
    private static final String NEXT_VERSION = "nextVersion";
    private static final String PREVIEW_FALLBACK_VERSION = "previewFallbackVersion";
    private static final String bundleDirectory = "versions";
    private static final String TEMP_UNZIP_PREFIX = "capgo_unzip_";
    private static final String CAPACITOR_CONFIG_ASSET = "capacitor.config.json";
    private static final String BACKGROUND_RUNNER_CONFIG_KEY = "BackgroundRunner";
    private static final String BACKGROUND_RUNNER_WORKER_CLASS = "io.ionic.backgroundrunner.plugin.RunnerWorker";

    public static final String TAG = "Capacitor-updater";
    public SharedPreferences.Editor editor;
    public SharedPreferences prefs;

    public File documentsDir;
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

    // Flag to track if we received a 429 response - stops requests until app restart
    private static volatile boolean rateLimitExceeded = false;

    // Flag to track if we've already sent the rate limit statistic - prevents infinite loop
    private static volatile boolean rateLimitStatisticSent = false;

    // Stats batching - queue events and send max once per second
    private final List<QueuedStatsEvent> statsQueue = new CopyOnWriteArrayList<>();
    private final ScheduledExecutorService statsScheduler = Executors.newSingleThreadScheduledExecutor();
    private ScheduledFuture<?> statsFlushTask = null;
    private static final long STATS_FLUSH_INTERVAL_MS = 1000;

    private static final class QueuedStatsEvent {

        private final JSONObject event;
        private final Runnable onSent;

        private QueuedStatsEvent(final JSONObject event, final Runnable onSent) {
            this.event = event;
            this.onSent = onSent;
        }
    }

    private final Map<String, CompletableFuture<BundleInfo>> downloadFutures = new ConcurrentHashMap<>();
    private final ExecutorService io = Executors.newSingleThreadExecutor();

    public CapgoUpdater(Logger logger) {
        this.logger = logger;
    }

    private final FilenameFilter filter = (f, name) -> {
        // ignore directories generated by mac os x
        return (!name.startsWith("__MACOSX") && !name.startsWith(".") && !name.startsWith(".DS_Store"));
    };

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

    private int calcTotalPercent(final int percent, final int min, final int max) {
        return (percent * (max - min)) / 100 + min;
    }

    void notifyDownload(final String id, final int percent) {}

    void directUpdateFinish(final BundleInfo latest) {}

    void notifyListeners(final String id, final Map<String, Object> res) {}

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

    static File resolvePathInsideDirectory(final File baseDirectory, final String relativePath) throws IOException {
        if (relativePath == null || relativePath.isEmpty()) {
            throw new IOException("Invalid empty path");
        }
        if (relativePath.contains("\\") || relativePath.indexOf('\0') >= 0) {
            throw new IOException("Invalid path separator");
        }
        if (new File(relativePath).isAbsolute()) {
            throw new IOException("Absolute paths are not allowed");
        }

        final File canonicalBase = baseDirectory.getCanonicalFile();
        final File canonicalTarget = new File(canonicalBase, relativePath).getCanonicalFile();
        final String basePath = canonicalBase.getPath();
        final String targetPath = canonicalTarget.getPath();
        final String normalizedBasePath = basePath.endsWith(File.separator) ? basePath : basePath + File.separator;

        if (!targetPath.equals(basePath) && !targetPath.startsWith(normalizedBasePath)) {
            throw new IOException("Path escapes base directory: " + relativePath);
        }

        return canonicalTarget;
    }

    public String getKeyId() {
        return this.cachedKeyId;
    }

    private File unzip(final String id, final File zipFile, final String dest) throws IOException {
        final File targetDirectory = new File(this.documentsDir, dest);
        try (
            final BufferedInputStream bis = new BufferedInputStream(new FileInputStream(zipFile));
            final ZipInputStream zis = new ZipInputStream(bis)
        ) {
            int count;
            final int bufferSize = 8192;
            final byte[] buffer = new byte[bufferSize];
            final long lengthTotal = zipFile.length();
            long lengthRead = bufferSize;
            int percent = 0;
            this.notifyDownload(id, 75);

            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                final File file;
                try {
                    file = resolvePathInsideDirectory(targetDirectory, entry.getName());
                } catch (IOException e) {
                    if (entry.getName().contains("\\")) {
                        logger.error("Unzip failed: Windows path not supported");
                        logger.debug("Invalid path: " + entry.getName());
                        this.sendStats("windows_path_fail");
                    } else {
                        this.sendStats("canonical_path_fail");
                    }
                    throw e;
                }
                final File dir = entry.isDirectory() ? file : file.getParentFile();

                assert dir != null;
                if (!dir.isDirectory() && !dir.mkdirs()) {
                    this.sendStats("directory_path_fail");
                    throw new FileNotFoundException("Failed to ensure directory: " + dir.getAbsolutePath());
                }

                if (entry.isDirectory()) {
                    continue;
                }

                try (final FileOutputStream outputStream = new FileOutputStream(file)) {
                    while ((count = zis.read(buffer)) != -1) outputStream.write(buffer, 0, count);
                }

                final int newPercent = (int) ((lengthRead / (float) lengthTotal) * 100);
                if (lengthTotal > 1 && newPercent != percent) {
                    percent = newPercent;
                    this.notifyDownload(id, this.calcTotalPercent(percent, 75, 90));
                }

                lengthRead += entry.getCompressedSize();
            }
            return targetDirectory;
        } catch (IOException e) {
            this.sendStats("unzip_fail");
            throw new IOException("Failed to unzip: " + zipFile.getPath());
        }
    }

    private void flattenAssets(final File sourceFile, final String dest) throws IOException {
        if (!sourceFile.exists()) {
            throw new FileNotFoundException("Source file not found: " + sourceFile.getPath());
        }
        final File destinationFile = new File(this.documentsDir, dest);
        Objects.requireNonNull(destinationFile.getParentFile()).mkdirs();
        final String[] entries = sourceFile.list(this.filter);
        if (entries == null || entries.length == 0) {
            throw new IOException("Source file was not a directory or was empty: " + sourceFile.getPath());
        }
        if (entries.length == 1 && !"index.html".equals(entries[0])) {
            final File child = new File(sourceFile, entries[0]);
            if (!child.renameTo(destinationFile)) {
                throw new IOException("Failed to move bundle contents: " + child.getPath() + " -> " + destinationFile.getPath());
            }
        } else {
            if (!sourceFile.renameTo(destinationFile)) {
                throw new IOException("Failed to move bundle contents: " + sourceFile.getPath() + " -> " + destinationFile.getPath());
            }
        }
        sourceFile.delete();
    }

    private void cacheBundleFilesAsync(final String id) {
        io.execute(() -> cacheBundleFiles(id));
    }

    private void cacheBundleFiles(final String id) {
        if (this.activity == null) {
            logger.debug("Skip delta cache population: activity is null");
            return;
        }

        final File bundleDir = this.getBundleDirectory(id);
        if (!bundleDir.exists()) {
            logger.debug("Skip delta cache population: bundle dir missing");
            return;
        }

        final File cacheDir = new File(this.activity.getCacheDir(), "capgo_downloads");
        if (cacheDir.exists() && !cacheDir.isDirectory()) {
            logger.debug("Skip delta cache population: cache dir is not a directory");
            return;
        }
        if (!cacheDir.exists() && !cacheDir.mkdirs()) {
            logger.debug("Skip delta cache population: failed to create cache dir");
            return;
        }

        final List<File> files = new ArrayList<>();
        collectFiles(bundleDir, files);
        for (File file : files) {
            final String checksum = CryptoCipher.calcChecksum(file);
            if (checksum.isEmpty()) {
                continue;
            }
            final String cacheName = checksum + "_" + file.getName();
            final File cacheFile = new File(cacheDir, cacheName);
            if (cacheFile.exists()) {
                continue;
            }
            try {
                copyFile(file, cacheFile);
            } catch (IOException e) {
                logger.debug("Delta cache copy failed: " + file.getPath());
            }
        }
    }

    private void collectFiles(final File dir, final List<File> files) {
        final File[] entries = dir.listFiles();
        if (entries == null) {
            return;
        }
        for (File entry : entries) {
            if (!this.filter.accept(dir, entry.getName())) {
                continue;
            }
            if (entry.isDirectory()) {
                collectFiles(entry, files);
            } else if (entry.isFile()) {
                files.add(entry);
            }
        }
    }

    private void copyFile(final File source, final File dest) throws IOException {
        try (final FileInputStream input = new FileInputStream(source); final FileOutputStream output = new FileOutputStream(dest)) {
            final byte[] buffer = new byte[1024 * 1024];
            int length;
            while ((length = input.read(buffer)) != -1) {
                output.write(buffer, 0, length);
            }
        }
    }

    private boolean verifyChecksum(final File file, final String expectedHash) {
        if (expectedHash == null || expectedHash.isEmpty() || file == null || !file.exists()) {
            return false;
        }
        final String actualHash = CryptoCipher.calcChecksum(file);
        return expectedHash.equalsIgnoreCase(actualHash);
    }

    private String resolveManifestFileHash(final JSONObject entry, final String sessionKey) {
        String fileHash = entry.optString("file_hash", "");
        if (fileHash.isEmpty()) {
            return "";
        }
        if (this.publicKey != null && !this.publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty()) {
            try {
                fileHash = CryptoCipher.decryptChecksum(fileHash, this.publicKey);
            } catch (Exception e) {
                logger.error("Checksum decryption failed while checking missing manifest files");
                logger.debug("File: " + entry.optString("file_name", "unknown") + ", Error: " + e.getMessage());
                return "";
            }
        }
        return fileHash;
    }

    private boolean isManifestEntryAvailableLocally(final JSONObject entry, final String sessionKey) {
        final String fileName = entry.optString("file_name", "");
        final String fileHash = resolveManifestFileHash(entry, sessionKey);
        if (fileName.isEmpty() || fileHash.isEmpty() || this.activity == null) {
            return false;
        }

        final File builtinFile = new File(this.activity.getFilesDir(), "public/" + fileName);
        if (verifyChecksum(builtinFile, fileHash)) {
            return true;
        }

        final boolean isBrotli = fileName.endsWith(".br");
        final String fileNameWithoutPath = new File(fileName).getName();
        final String cacheBaseName = isBrotli ? fileNameWithoutPath.substring(0, fileNameWithoutPath.length() - 3) : fileNameWithoutPath;
        final File cacheFolder = new File(this.activity.getCacheDir(), "capgo_downloads");
        final File cacheFile = new File(cacheFolder, fileHash + "_" + cacheBaseName);
        if (verifyChecksum(cacheFile, fileHash)) {
            return true;
        }

        if (isBrotli) {
            final File legacyCacheFile = new File(cacheFolder, fileHash + "_" + fileNameWithoutPath);
            return verifyChecksum(legacyCacheFile, fileHash);
        }

        return false;
    }

    public JSONArray getMissingBundleFiles(final JSONArray manifest, final String sessionKey) throws JSONException {
        final JSONArray missing = new JSONArray();
        for (int i = 0; i < manifest.length(); i++) {
            final JSONObject entry = manifest.getJSONObject(i);
            if (!isManifestEntryAvailableLocally(entry, sessionKey)) {
                missing.put(entry);
            }
        }
        return missing;
    }

    public JSONObject missingBundleFilesResult(final JSONArray manifest, final String sessionKey) throws JSONException {
        final JSONArray missing = getMissingBundleFiles(manifest, sessionKey);
        final JSONObject ret = new JSONObject();
        ret.put("missing", missing);
        ret.put("total", manifest.length());
        ret.put("missingCount", missing.length());
        ret.put("reusableCount", manifest.length() - missing.length());
        return ret;
    }

    private String manifestSizeUrl(final String updateUrl) {
        HttpUrl parsed = HttpUrl.parse(updateUrl);
        if (parsed == null) {
            return updateUrl;
        }
        return parsed.newBuilder().addPathSegment("manifest_size").query(null).build().toString();
    }

    private JSONObject unavailableBundleSizeResult(final JSONArray manifest, final String error) throws JSONException {
        final JSONObject ret = new JSONObject();
        final JSONArray files = new JSONArray();
        for (int i = 0; i < manifest.length(); i++) {
            final JSONObject entry = new JSONObject(manifest.getJSONObject(i).toString());
            entry.put("error", error);
            files.put(entry);
        }
        ret.put("totalSize", 0);
        ret.put("knownFiles", 0);
        ret.put("unknownFiles", manifest.length());
        ret.put("files", files);
        return ret;
    }

    public JSONObject getBundleDownloadSize(final String updateUrl, final String version, final JSONArray manifest) throws JSONException {
        if (manifest.length() == 0) {
            final JSONObject ret = new JSONObject();
            ret.put("totalSize", 0);
            ret.put("knownFiles", 0);
            ret.put("unknownFiles", 0);
            ret.put("files", new JSONArray());
            return ret;
        }

        final JSONObject json = this.createInfoObject();
        json.put("version", version != null ? version : "");
        json.put("manifest", manifest);

        Request request = new Request.Builder()
            .url(manifestSizeUrl(updateUrl))
            .post(RequestBody.create(json.toString(), MediaType.get("application/json; charset=utf-8")))
            .build();

        try (Response response = DownloadService.sharedClient.newCall(request).execute()) {
            final ResponseBody responseBody = response.body();
            final String responseData = responseBody != null ? responseBody.string() : "";
            if (!response.isSuccessful() || responseData.isEmpty()) {
                return unavailableBundleSizeResult(manifest, "response_error");
            }
            return new JSONObject(responseData);
        } catch (IOException e) {
            logger.error("Error getting bundle download size");
            logger.debug("Error: " + e.getMessage());
            return unavailableBundleSizeResult(manifest, "response_error");
        }
    }

    private void observeWorkProgress(Context context, String id, boolean setNext) {
        if (!(context instanceof LifecycleOwner)) {
            logger.error("Context is not a LifecycleOwner, cannot observe work progress");
            return;
        }

        activity.runOnUiThread(() -> {
            WorkManager.getInstance(context)
                .getWorkInfosByTagLiveData(id)
                .observe((LifecycleOwner) context, (workInfos) -> {
                    if (workInfos == null || workInfos.isEmpty()) return;

                    WorkInfo workInfo = workInfos.get(0);
                    Data progress = workInfo.getProgress();

                    switch (workInfo.getState()) {
                        case RUNNING:
                            int percent = progress.getInt(DownloadService.PERCENT, 0);
                            notifyDownload(id, percent);
                            break;
                        case SUCCEEDED:
                            logger.info("Download succeeded: " + workInfo.getState());
                            Data outputData = workInfo.getOutputData();
                            String dest = outputData.getString(DownloadService.FILEDEST);
                            String version = outputData.getString(DownloadService.VERSION);
                            String sessionKey = outputData.getString(DownloadService.SESSIONKEY);
                            String checksum = outputData.getString(DownloadService.CHECKSUM);
                            boolean isManifest = outputData.getBoolean(DownloadService.IS_MANIFEST, false);

                            io.execute(() -> {
                                boolean success = finishDownload(id, dest, version, sessionKey, checksum, setNext, isManifest);
                                BundleInfo resultBundle;
                                if (!success) {
                                    logger.error("Finish download failed");
                                    logger.debug("Version: " + version);
                                    resultBundle = new BundleInfo(
                                        id,
                                        version,
                                        BundleStatus.ERROR,
                                        new Date(System.currentTimeMillis()),
                                        ""
                                    );
                                    saveBundleInfo(id, resultBundle);
                                    // Cleanup download tracking
                                    DownloadWorkerManager.cancelBundleDownload(activity, id, version);
                                    Map<String, Object> ret = new HashMap<>();
                                    ret.put("version", version);
                                    ret.put("error", "finish_download_fail");
                                    sendStats("finish_download_fail", version);
                                    notifyListeners("downloadFailed", ret);
                                } else {
                                    // Successful download - cleanup tracking
                                    DownloadWorkerManager.cancelBundleDownload(activity, id, version);
                                    resultBundle = getBundleInfo(id);
                                }

                                // Complete the future if it exists
                                CompletableFuture<BundleInfo> future = downloadFutures.remove(id);
                                if (future != null) {
                                    future.complete(resultBundle);
                                }
                            });
                            break;
                        case FAILED:
                            Data failedData = workInfo.getOutputData();
                            String error = failedData.getString(DownloadService.ERROR);
                            logger.error("Download failed");
                            logger.debug("Error: " + error + ", State: " + workInfo.getState());
                            String failedVersion = failedData.getString(DownloadService.VERSION);

                            io.execute(() -> {
                                BundleInfo failedBundle = new BundleInfo(
                                    id,
                                    failedVersion,
                                    BundleStatus.ERROR,
                                    new Date(System.currentTimeMillis()),
                                    ""
                                );
                                saveBundleInfo(id, failedBundle);
                                // Cleanup download tracking for failed downloads
                                DownloadWorkerManager.cancelBundleDownload(activity, id, failedVersion);
                                Map<String, Object> ret = new HashMap<>();
                                ret.put("version", failedVersion);
                                if ("low_mem_fail".equals(error)) {
                                    sendStats("low_mem_fail", failedVersion);
                                }
                                if ("insufficient_disk_space".equals(error)) {
                                    sendStats("insufficient_disk_space", failedVersion);
                                }
                                ret.put("error", error != null ? error : "download_fail");
                                sendStats("download_fail", failedVersion);
                                notifyListeners("downloadFailed", ret);

                                // Complete the future with error status
                                CompletableFuture<BundleInfo> failedFuture = downloadFutures.remove(id);
                                if (failedFuture != null) {
                                    failedFuture.complete(failedBundle);
                                }
                            });
                            break;
                    }
                });
        });
    }

    private void download(
        final String id,
        final String url,
        final String dest,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest,
        final boolean setNext
    ) {
        if (this.activity == null) {
            logger.error("Activity is null, cannot observe work progress");
            return;
        }
        observeWorkProgress(this.activity, id, setNext);

        DownloadWorkerManager.enqueueDownload(
            this.activity,
            url,
            id,
            this.documentsDir.getAbsolutePath(),
            dest,
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

        if (manifest != null) {
            DataManager.getInstance().setManifest(manifest);
        }
    }

    public Boolean finishDownload(
        String id,
        String dest,
        String version,
        String sessionKey,
        String checksumRes,
        Boolean setNext,
        Boolean isManifest
    ) {
        File downloaded = null;
        File extractedDir = null;
        String checksum = "";

        try {
            this.notifyDownload(id, 71);
            downloaded = new File(this.documentsDir, dest);

            if (!isManifest) {
                String checksumDecrypted = Objects.requireNonNullElse(checksumRes, "");

                // If public key is present but no checksum provided, refuse installation
                if (!this.publicKey.isEmpty() && checksumDecrypted.isEmpty()) {
                    logger.error("Public key present but no checksum provided");
                    this.sendStats("checksum_required");
                    throw new IOException("Checksum required when public key is present: " + id);
                }

                if (!sessionKey.isEmpty()) {
                    CryptoCipher.decryptFile(downloaded, publicKey, sessionKey);
                    checksumDecrypted = CryptoCipher.decryptChecksum(checksumRes, publicKey);
                    checksum = CryptoCipher.calcChecksum(downloaded);
                } else {
                    checksum = CryptoCipher.calcChecksum(downloaded);
                }
                CryptoCipher.logChecksumInfo("Calculated checksum", checksum);
                CryptoCipher.logChecksumInfo("Expected checksum", checksumDecrypted);
                if ((!checksumDecrypted.isEmpty() || !this.publicKey.isEmpty()) && !checksumDecrypted.equals(checksum)) {
                    logger.error("Checksum mismatch");
                    logger.debug("Expected: " + checksumDecrypted + ", Got: " + checksum);
                    this.sendStats("checksum_fail");
                    throw new IOException("Checksum failed: " + id);
                }
            }
            // Remove the decryption for manifest downloads
        } catch (Exception e) {
            if (!isManifest) {
                safeDelete(downloaded);
            }
            final Boolean res = this.delete(id);
            if (!res) {
                logger.info("Failed to cleanup after error");
                logger.debug("Version: " + version);
            }

            final Map<String, Object> ret = new HashMap<>();
            ret.put("version", version);

            CapgoUpdater.this.notifyListeners("downloadFailed", ret);
            CapgoUpdater.this.sendStats("download_fail");
            return false;
        }

        try {
            if (!isManifest) {
                extractedDir = this.unzip(id, downloaded, TEMP_UNZIP_PREFIX + this.randomString());
                this.notifyDownload(id, 91);
                final String idName = bundleDirectory + "/" + id;
                this.flattenAssets(extractedDir, idName);
                this.cacheBundleFilesAsync(id);
            } else {
                this.notifyDownload(id, 91);
                final String idName = bundleDirectory + "/" + id;
                this.flattenAssets(downloaded, idName);
                downloaded.delete();
            }
            // Remove old bundle info and set new one
            this.saveBundleInfo(id, null);
            BundleInfo next = new BundleInfo(id, version, BundleStatus.PENDING, new Date(System.currentTimeMillis()), checksum);
            this.saveBundleInfo(id, next);
            this.notifyDownload(id, 100);

            final Map<String, Object> ret = new HashMap<>();
            ret.put("bundle", InternalUtils.mapToJSObject(next.toJSONMap()));
            logger.info("updateAvailable: " + ret);
            CapgoUpdater.this.notifyListeners("updateAvailable", ret);
            logger.info("setNext: " + setNext);
            if (setNext) {
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
        } catch (IOException e) {
            if (!isManifest) {
                safeDelete(extractedDir);
                safeDelete(downloaded);
            }
            e.printStackTrace();
            final Map<String, Object> ret = new HashMap<>();
            ret.put("version", version);
            CapgoUpdater.this.notifyListeners("downloadFailed", ret);
            CapgoUpdater.this.sendStats("download_fail");
            return false;
        }
        if (!isManifest) {
            safeDelete(downloaded);
        }
        return true;
    }

    private void deleteDirectory(final File file) throws IOException {
        deleteDirectory(file, null);
    }

    private void deleteDirectory(final File file, final Thread threadToCheck) throws IOException {
        // Check if thread was interrupted (cancelled)
        if (threadToCheck != null && threadToCheck.isInterrupted()) {
            throw new IOException("Operation cancelled");
        }

        if (file.isDirectory()) {
            final File[] entries = file.listFiles();
            if (entries != null) {
                for (final File entry : entries) {
                    this.deleteDirectory(entry, threadToCheck);
                }
            }
        }
        if (!file.delete()) {
            throw new IOException("Failed to delete: " + file);
        }
    }

    public void cleanupDeltaCache() {
        cleanupDeltaCache(null);
    }

    public void cleanupDeltaCache(final Thread threadToCheck) {
        if (this.activity == null) {
            logger.warn("Activity is null, skipping delta cache cleanup");
            return;
        }
        final File cacheFolder = new File(this.activity.getCacheDir(), "capgo_downloads");
        if (!cacheFolder.exists()) {
            return;
        }
        try {
            this.deleteDirectory(cacheFolder, threadToCheck);
            logger.info("Cleaned up delta cache folder");
        } catch (IOException e) {
            logger.error("Failed to cleanup delta cache");
            logger.debug("Error: " + e.getMessage());
        }
    }

    public void cleanupDownloadDirectories(final Set<String> allowedIds) {
        cleanupDownloadDirectories(allowedIds, null);
    }

    public void cleanupDownloadDirectories(final Set<String> allowedIds, final Thread threadToCheck) {
        if (this.documentsDir == null) {
            logger.warn("Documents directory is null, skipping download cleanup");
            return;
        }

        final File bundleRoot = new File(this.documentsDir, bundleDirectory);
        if (!bundleRoot.exists() || !bundleRoot.isDirectory()) {
            return;
        }

        final File[] entries = bundleRoot.listFiles();
        if (entries != null) {
            for (final File entry : entries) {
                // Check if thread was interrupted (cancelled)
                if (threadToCheck != null && threadToCheck.isInterrupted()) {
                    logger.warn("cleanupDownloadDirectories was cancelled");
                    return;
                }

                if (!entry.isDirectory()) {
                    continue;
                }

                final String id = entry.getName();

                if (allowedIds != null && allowedIds.contains(id)) {
                    continue;
                }

                try {
                    this.deleteDirectory(entry, threadToCheck);
                    this.removeBundleInfo(id);
                    logger.info("Deleted orphan bundle directory");
                    logger.debug("Bundle ID: " + id);
                } catch (IOException e) {
                    logger.error("Failed to delete orphan bundle directory");
                    logger.debug("Bundle ID: " + id + ", Error: " + e.getMessage());
                }
            }
        }
    }

    public void cleanupOrphanedTempFolders(final Thread threadToCheck) {
        if (this.documentsDir == null) {
            logger.warn("Documents directory is null, skipping temp folder cleanup");
            return;
        }

        final File[] entries = this.documentsDir.listFiles();
        if (entries == null) {
            return;
        }

        for (final File entry : entries) {
            // Check if thread was interrupted (cancelled)
            if (threadToCheck != null && threadToCheck.isInterrupted()) {
                logger.warn("cleanupOrphanedTempFolders was cancelled");
                return;
            }

            if (!entry.isDirectory()) {
                continue;
            }

            final String folderName = entry.getName();

            // Only delete folders with the temp unzip prefix
            if (!folderName.startsWith(TEMP_UNZIP_PREFIX)) {
                continue;
            }

            try {
                this.deleteDirectory(entry, threadToCheck);
                logger.info("Deleted orphaned temp unzip folder");
                logger.debug("Folder: " + folderName);
            } catch (IOException e) {
                logger.error("Failed to delete orphaned temp folder");
                logger.debug("Folder: " + folderName + ", Error: " + e.getMessage());
            }
        }
    }

    private void safeDelete(final File target) {
        if (target == null || !target.exists()) {
            return;
        }
        try {
            if (target.isDirectory()) {
                this.deleteDirectory(target);
            } else if (!target.delete()) {
                logger.warn("Failed to delete file: " + target.getAbsolutePath());
            }
        } catch (IOException cleanupError) {
            logger.warn("Cleanup failed for " + target.getAbsolutePath() + ": " + cleanupError.getMessage());
        }
    }

    private void setCurrentBundle(final File bundle) {
        this.resetBackgroundRunnerWorkForBundleSwitch(bundle);
        this.editor.putString(this.CAP_SERVER_PATH, bundle.getPath());
        logger.info("Current bundle set to: " + bundle);
        this.editor.commit();
    }

    static boolean shouldResetForForeignBundle(final String bundlePath, final boolean isBuiltin, final boolean hasStoredBundleInfo) {
        return bundlePath != null && !bundlePath.trim().isEmpty() && !isBuiltin && !hasStoredBundleInfo;
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

        final File tempFile = new File(parent, dest.getName() + ".capgo_tmp");
        try (final FileInputStream input = new FileInputStream(source); final FileOutputStream output = new FileOutputStream(tempFile)) {
            final byte[] buffer = new byte[1024 * 1024];
            int length;
            while ((length = input.read(buffer)) != -1) {
                output.write(buffer, 0, length);
            }
        }

        if (!tempFile.renameTo(dest)) {
            if (!dest.delete() || !tempFile.renameTo(dest)) {
                tempFile.delete();
                throw new IOException("Failed to replace file: " + dest.getAbsolutePath());
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
        return (
            id != null &&
            !id.isEmpty() &&
            !BundleInfo.ID_BUILTIN.equals(id) &&
            !BundleInfo.VERSION_UNKNOWN.equals(id) &&
            this.prefs.contains(id + INFO_SUFFIX)
        );
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
        final String id = this.randomString();

        // Check if version is already downloading, but allow retry if previous download failed
        if (this.activity != null && DownloadWorkerManager.isVersionDownloading(this.activity, version)) {
            // Check if there's an existing bundle with error status that we can retry
            BundleInfo existingBundle = this.getBundleInfoByName(version);
            if (existingBundle != null && existingBundle.isErrorStatus()) {
                // Cancel the failed download and allow retry
                DownloadWorkerManager.cancelVersionDownload(this.activity, version);
                logger.info("Retrying failed download for version: " + version);
            } else {
                logger.info("Version already downloading: " + version);
                return;
            }
        }

        saveBundleInfo(id, new BundleInfo(id, version, BundleStatus.DOWNLOADING, new Date(System.currentTimeMillis()), ""));
        this.notifyDownload(id, 0);
        this.notifyDownload(id, 5);

        this.download(id, url, this.randomString(), version, sessionKey, checksum, manifest, setNext);
    }

    public BundleInfo download(final String url, final String version, final String sessionKey, final String checksum) throws IOException {
        // Check for existing bundle with same version and clean up if in error state
        BundleInfo existingBundle = this.getBundleInfoByName(version);
        if (existingBundle != null && (existingBundle.isErrorStatus() || existingBundle.isDeleted())) {
            logger.info("Found existing failed bundle for version " + version + ", deleting before retry");
            this.delete(existingBundle.getId(), true);
        }

        final String id = this.randomString();
        saveBundleInfo(id, new BundleInfo(id, version, BundleStatus.DOWNLOADING, new Date(System.currentTimeMillis()), ""));
        this.notifyDownload(id, 0);
        this.notifyDownload(id, 5);
        final String dest = this.randomString();

        // Create a CompletableFuture to track download completion
        CompletableFuture<BundleInfo> downloadFuture = new CompletableFuture<>();
        downloadFutures.put(id, downloadFuture);

        // Start the download
        this.download(id, url, dest, version, sessionKey, checksum, null, false);

        // Wait for completion without timeout
        try {
            BundleInfo result = downloadFuture.get();
            if (result.isErrorStatus()) {
                throw new IOException("Download failed with status: " + result.getStatus());
            }
            return result;
        } catch (Exception e) {
            // Clean up on failure
            downloadFutures.remove(id);
            logger.error("Error waiting for download");
            logger.debug("Error: " + e.getMessage());
            BundleInfo errorBundle = new BundleInfo(id, version, BundleStatus.ERROR, new Date(System.currentTimeMillis()), "");
            saveBundleInfo(id, errorBundle);
            if (e instanceof IOException) {
                throw (IOException) e;
            }
            throw new IOException("Error waiting for download: " + e.getMessage(), e);
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

        // Check for existing bundle with same version and clean up if in error state
        BundleInfo existingBundle = this.getBundleInfoByName(version);
        if (existingBundle != null && (existingBundle.isErrorStatus() || existingBundle.isDeleted())) {
            logger.info("Found existing failed bundle for version " + version + ", deleting before retry");
            this.delete(existingBundle.getId(), true);
        }

        final String id = this.randomString();
        saveBundleInfo(id, new BundleInfo(id, version, BundleStatus.DOWNLOADING, new Date(System.currentTimeMillis()), ""));
        this.notifyDownload(id, 0);
        this.notifyDownload(id, 5);
        final String dest = this.randomString();

        // Create a CompletableFuture to track download completion
        CompletableFuture<BundleInfo> downloadFuture = new CompletableFuture<>();
        downloadFutures.put(id, downloadFuture);

        // Start the download
        this.download(id, url, dest, version, sessionKey, checksum, manifest, false);

        // Wait for completion without timeout
        try {
            BundleInfo result = downloadFuture.get();
            if (result.isErrorStatus()) {
                throw new IOException("Download failed with status: " + result.getStatus());
            }
            return result;
        } catch (Exception e) {
            // Clean up on failure
            downloadFutures.remove(id);
            logger.error("Error waiting for download");
            logger.debug("Error: " + e.getMessage());
            BundleInfo errorBundle = new BundleInfo(id, version, BundleStatus.ERROR, new Date(System.currentTimeMillis()), "");
            saveBundleInfo(id, errorBundle);
            if (e instanceof IOException) {
                throw (IOException) e;
            }
            throw new IOException("Error waiting for download: " + e.getMessage(), e);
        }
    }

    public List<BundleInfo> list(boolean rawList) {
        if (!rawList) {
            final List<BundleInfo> res = new ArrayList<>();
            final File destHot = new File(this.documentsDir, bundleDirectory);
            logger.debug("list File : " + destHot.getPath());
            if (destHot.exists()) {
                for (final File i : Objects.requireNonNull(destHot.listFiles())) {
                    final String id = i.getName();
                    res.add(this.getBundleInfo(id));
                }
            } else {
                logger.info("No versions available to list" + destHot);
            }
            return res;
        } else {
            final List<BundleInfo> res = new ArrayList<>();
            for (String value : this.prefs.getAll().keySet()) {
                if (!value.matches("^[0-9A-Za-z]{10}_info$")) {
                    continue;
                }

                res.add(this.getBundleInfo(value.split("_")[0]));
            }
            return res;
        }
    }

    public Boolean delete(final String id, final Boolean removeInfo) throws IOException {
        final BundleInfo deleted = this.getBundleInfo(id);
        if (deleted.isBuiltin() || this.getCurrentBundleId().equals(id)) {
            logger.error("Cannot delete current or builtin bundle");
            logger.debug("Bundle ID: " + id);
            return false;
        }
        final BundleInfo previewFallback = this.getPreviewFallbackBundle();
        if (
            previewFallback != null &&
            !previewFallback.isDeleted() &&
            !previewFallback.isErrorStatus() &&
            previewFallback.getId().equals(id)
        ) {
            logger.error("Cannot delete the preview fallback bundle");
            logger.debug("Bundle ID: " + id);
            return false;
        }
        final BundleInfo next = this.getNextBundle();
        if (next != null && !next.isDeleted() && !next.isErrorStatus() && next.getId().equals(id)) {
            logger.error("Cannot delete the next bundle");
            logger.debug("Bundle ID: " + id);
            return false;
        }
        // Cancel download for this version if active
        if (this.activity != null) {
            DownloadWorkerManager.cancelVersionDownload(this.activity, deleted.getVersionName());
        }
        final File bundle = new File(this.documentsDir, bundleDirectory + "/" + id);
        if (bundle.exists()) {
            this.deleteDirectory(bundle);
            if (!removeInfo) {
                this.saveBundleInfo(id, deleted.setStatus(BundleStatus.DELETED));
            } else {
                this.removeBundleInfo(id);
            }
            return true;
        }
        logger.info("Bundle not found on disk");
        logger.debug("Version: " + deleted.getVersionName());
        // perhaps we did not find the bundle in the files, but if the user requested a delete, we delete
        if (removeInfo) {
            this.removeBundleInfo(id);
        }
        this.sendStats("delete", deleted.getVersionName());
        return false;
    }

    public Boolean delete(final String id) {
        try {
            return this.delete(id, true);
        } catch (IOException e) {
            e.printStackTrace();
            logger.info("Failed to delete bundle (" + id + ")" + "\nError:\n" + e.toString());
            return false;
        }
    }

    private File getBundleDirectory(final String id) {
        return new File(this.documentsDir, bundleDirectory + "/" + id);
    }

    private boolean bundleExists(final String id) {
        final File bundle = this.getBundleDirectory(id);
        final BundleInfo bundleInfo = this.getBundleInfo(id);
        return (bundle.isDirectory() && bundle.exists() && new File(bundle.getPath(), "/index.html").exists() && !bundleInfo.isDeleted());
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
        return new ResetState(
            this.getCurrentBundlePath(),
            this.prefs.getString(FALLBACK_VERSION, BundleInfo.ID_BUILTIN),
            this.prefs.getString(NEXT_VERSION, null)
        );
    }

    void restoreResetState(final ResetState state) {
        final String currentBundlePath =
            state.currentBundlePath == null || state.currentBundlePath.trim().isEmpty() ? "public" : state.currentBundlePath;
        final String fallbackBundleId =
            state.fallbackBundleId == null || state.fallbackBundleId.isEmpty() ? BundleInfo.ID_BUILTIN : state.fallbackBundleId;

        this.editor.putString(this.CAP_SERVER_PATH, currentBundlePath);
        this.editor.putString(FALLBACK_VERSION, fallbackBundleId);
        if (state.nextBundleId == null || state.nextBundleId.isEmpty()) {
            this.editor.remove(NEXT_VERSION);
        } else {
            this.editor.putString(NEXT_VERSION, state.nextBundleId);
        }
        this.editor.commit();
    }

    void prepareResetStateForTransition() {
        this.setCurrentBundle(new File("public"));
        this.setFallbackBundle(null);
        this.setNextBundle(null);
    }

    void finalizeResetTransition(final String previousBundleName, final boolean internal) {
        if (this.activity != null) {
            DownloadWorkerManager.cancelAllDownloads(this.activity);
        }
        if (!internal) {
            this.sendStats("reset", this.getCurrentBundle().getVersionName(), previousBundleName);
        }
    }

    boolean canSet(final BundleInfo bundle) {
        return bundle != null && (bundle.isBuiltin() || this.bundleExists(bundle.getId()));
    }

    public Boolean set(final BundleInfo bundle) {
        return this.set(bundle.getId());
    }

    public Boolean set(final String id) {
        final BundleInfo newBundle = this.getBundleInfo(id);
        if (newBundle.isBuiltin()) {
            this.reset();
            return true;
        }
        final File bundle = this.getBundleDirectory(id);
        logger.info("Setting next active bundle: " + id);
        if (this.bundleExists(id)) {
            var currentBundleName = this.getCurrentBundle().getVersionName();
            this.setCurrentBundle(bundle);
            this.setBundleStatus(id, BundleStatus.PENDING);
            this.sendStats("set", newBundle.getVersionName(), currentBundleName);
            return true;
        }
        this.setBundleStatus(id, BundleStatus.ERROR);
        this.sendStats("set_fail", newBundle.getVersionName());
        return false;
    }

    boolean stagePendingReload(final BundleInfo bundle) {
        if (bundle == null || bundle.isBuiltin() || !this.bundleExists(bundle.getId())) {
            return false;
        }
        this.setCurrentBundle(this.getBundleDirectory(bundle.getId()));
        return true;
    }

    boolean stagePreviewFallbackReload(final BundleInfo bundle) {
        if (bundle == null || bundle.isErrorStatus()) {
            return false;
        }
        if (bundle.isBuiltin()) {
            this.setCurrentBundle(new File("public"));
            return true;
        }
        if (!this.bundleExists(bundle.getId())) {
            return false;
        }
        this.setCurrentBundle(this.getBundleDirectory(bundle.getId()));
        return true;
    }

    void finalizePendingReload(final BundleInfo bundle, final String previousBundleName) {
        if (bundle == null || bundle.isBuiltin()) {
            return;
        }
        this.sendStats("set", bundle.getVersionName(), previousBundleName);
    }

    @Deprecated
    public void autoReset() {
        this.autoReset(this.versionCode == null ? "" : this.versionCode);
    }

    public void autoReset(final String currentNativeBuildVersion) {
        this.autoReset(currentNativeBuildVersion, true);
    }

    public void autoReset(final String currentNativeBuildVersion, final boolean resetWhenNativeVersionChanged) {
        final BundleInfo currentBundle = this.getCurrentBundle();
        if (!currentBundle.isBuiltin() && !this.bundleExists(currentBundle.getId())) {
            logger.info("Folder at bundle path does not exist. Triggering reset.");
            this.reset();
            return;
        }
        String bundlePath = this.prefs.getString(this.CAP_SERVER_PATH, null);
        if (shouldResetForForeignBundle(bundlePath, currentBundle.isBuiltin(), this.hasStoredBundleInfo(currentBundle.getId()))) {
            logger.info("Current bundle id is not one of the bundle ids stored by this plugin. Triggering reset.");
            this.reset();
            return;
        }
        final String previousNativeBuildVersion = this.getStoredNativeBuildVersion();
        if (
            resetWhenNativeVersionChanged &&
            !previousNativeBuildVersion.isEmpty() &&
            currentNativeBuildVersion != null &&
            !currentNativeBuildVersion.isEmpty() &&
            !Objects.equals(previousNativeBuildVersion, currentNativeBuildVersion)
        ) {
            logger.info(
                "Stored native build version " +
                    previousNativeBuildVersion +
                    " does not match current native build version " +
                    currentNativeBuildVersion +
                    ". Triggering reset."
            );
            this.reset();
        }
    }

    private String getStoredNativeBuildVersion() {
        if (this.prefs == null) {
            return "";
        }
        String previousNativeBuildVersion = this.prefs.getString("LatestNativeBuildVersion", "");
        if (previousNativeBuildVersion == null || previousNativeBuildVersion.isEmpty()) {
            previousNativeBuildVersion = this.prefs.getString("LatestVersionNative", "");
        }
        return previousNativeBuildVersion == null ? "" : previousNativeBuildVersion;
    }

    public void reset() {
        this.reset(false);
    }

    public void setSuccess(final BundleInfo bundle, Boolean autoDeletePrevious) {
        this.setBundleStatus(bundle.getId(), BundleStatus.SUCCESS);
        final BundleInfo fallback = this.getFallbackBundle();
        final BundleInfo previewFallback = this.getPreviewFallbackBundle();
        final boolean fallbackIsPreviewFallback = previewFallback != null && previewFallback.getId().equals(fallback.getId());
        logger.debug("Fallback bundle is: " + fallback);
        logger.info("Version successfully loaded: " + bundle.getVersionName());
        // Only attempt to delete when the fallback is a different bundle than the
        // currently loaded one. Otherwise we spam logs with "Cannot delete <id>"
        // because delete() protects the current bundle from removal.
        if (
            autoDeletePrevious &&
            !fallback.isBuiltin() &&
            fallback.getId() != null &&
            !fallback.getId().equals(bundle.getId()) &&
            !fallbackIsPreviewFallback
        ) {
            final Boolean res = this.delete(fallback.getId());
            if (res) {
                logger.info("Deleted previous bundle: " + fallback.getVersionName());
            } else {
                logger.debug("Skip deleting previous bundle (same as current or protected): " + fallback.getId());
            }
        }
        this.setFallbackBundle(bundle);
    }

    public void setError(final BundleInfo bundle) {
        this.setBundleStatus(bundle.getId(), BundleStatus.ERROR);
    }

    public void reset(final boolean internal) {
        logger.debug("reset: " + internal);
        final String currentBundleName = this.getCurrentBundle().getVersionName();
        this.prepareResetStateForTransition();
        this.finalizeResetTransition(currentBundleName, internal);
    }

    private JSONObject createInfoObject() throws JSONException {
        return this.createInfoObject(null);
    }

    private JSONObject createInfoObject(final String appIdOverride) throws JSONException {
        JSONObject json = new JSONObject();
        json.put("platform", "android");
        json.put("device_id", this.deviceID);
        json.put("app_id", appIdOverride == null || appIdOverride.trim().isEmpty() ? this.appId : appIdOverride);
        json.put("custom_id", this.customId);
        json.put("version_build", this.versionBuild);
        json.put("version_code", this.versionCode);
        json.put("version_os", this.versionOs);
        json.put("version_name", this.getCurrentBundle().getVersionName());
        json.put("plugin_version", this.pluginVersion);
        json.put("is_emulator", this.isEmulator());
        json.put("is_prod", this.isProd());
        json.put("install_source", this.getInstallSource());
        json.put("defaultChannel", this.defaultChannel);

        // Add encryption key ID if encryption is enabled (use cached value)
        if (!this.cachedKeyId.isEmpty()) {
            json.put("key_id", this.cachedKeyId);
        }

        return json;
    }

    /**
     * Check if a 429 (Too Many Requests) response was received and set the flag
     */
    private boolean checkAndHandleRateLimitResponse(Response response) {
        if (response.code() == 429) {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if (!this.previewSession && !rateLimitExceeded && !rateLimitStatisticSent) {
                rateLimitStatisticSent = true;
                sendRateLimitStatistic();
            }
            rateLimitExceeded = true;
            logger.warn("Rate limit exceeded (429). Stopping all stats and channel requests until app restart.");
            return true;
        }
        return false;
    }

    /**
     * Send a synchronous statistic about rate limiting
     */
    private void sendRateLimitStatistic() {
        String statsUrl = this.statsUrl;
        if (statsUrl == null || statsUrl.isEmpty()) {
            return;
        }

        try {
            BundleInfo current = this.getCurrentBundle();
            JSONObject json = this.createInfoObject();
            json.put("version_name", current.getVersionName());
            json.put("old_version_name", "");
            json.put("action", "rate_limit_reached");

            Request request = new Request.Builder()
                .url(statsUrl)
                .post(RequestBody.create(json.toString(), MediaType.get("application/json")))
                .build();

            // Send synchronously to ensure it goes out before the flag is set
            // User-Agent header is automatically added by DownloadService.sharedClient interceptor
            try (Response response = DownloadService.sharedClient.newCall(request).execute()) {
                if (response.isSuccessful()) {
                    logger.info("Rate limit statistic sent");
                } else {
                    logger.error("Error sending rate limit statistic");
                    logger.debug("Response code: " + response.code());
                }
            }
        } catch (final Exception e) {
            logger.error("Failed to send rate limit statistic");
            logger.debug("Error: " + e.getMessage());
        }
    }

    private void makeJsonRequest(String url, JSONObject jsonBody, Callback callback) {
        MediaType JSON = MediaType.get("application/json; charset=utf-8");
        RequestBody body = RequestBody.create(jsonBody.toString(), JSON);

        Request request = new Request.Builder().url(url).post(body).build();

        DownloadService.sharedClient.newCall(request).enqueue(
            new okhttp3.Callback() {
                @Override
                public void onFailure(@NonNull Call call, @NonNull IOException e) {
                    Map<String, Object> retError = new HashMap<>();
                    retError.put("message", "Request failed: " + e.getMessage());
                    retError.put("error", "network_error");
                    retError.put("kind", "failed");
                    callback.callback(retError);
                }

                @Override
                public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                    try (ResponseBody responseBody = response.body()) {
                        final int statusCode = response.code();
                        final String responseData = responseBody != null ? responseBody.string() : "";
                        JSONObject jsonResponse = null;
                        if (!responseData.isEmpty()) {
                            try {
                                jsonResponse = new JSONObject(responseData);
                            } catch (JSONException ignored) {
                                // Non-JSON responses are handled as response or parse errors below.
                            }
                        }

                        if (jsonResponse != null && (jsonResponse.has("error") || jsonResponse.has("kind"))) {
                            if (statusCode == 429) {
                                checkAndHandleRateLimitResponse(response);
                            }
                            Map<String, Object> retError = new HashMap<>();
                            if (jsonResponse.has("error") && !jsonResponse.isNull("error")) {
                                retError.put("error", jsonResponse.getString("error"));
                            }
                            if (jsonResponse.has("kind") && !jsonResponse.isNull("kind")) {
                                retError.put("kind", jsonResponse.getString("kind"));
                            }
                            if (jsonResponse.has("message") && !jsonResponse.isNull("message")) {
                                retError.put("message", jsonResponse.getString("message"));
                            } else {
                                retError.put("message", "server did not provide a message");
                            }
                            if (jsonResponse.has("version") && !jsonResponse.isNull("version")) {
                                retError.put("version", jsonResponse.getString("version"));
                            }
                            retError.put("statusCode", statusCode);
                            callback.callback(retError);
                            return;
                        }

                        // Check for 429 rate limit
                        if (checkAndHandleRateLimitResponse(response)) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Rate limit exceeded");
                            retError.put("error", "rate_limit_exceeded");
                            retError.put("kind", "failed");
                            retError.put("statusCode", statusCode);
                            callback.callback(retError);
                            return;
                        }

                        if (!response.isSuccessful()) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Server error: " + response.code());
                            retError.put("error", "response_error");
                            retError.put("kind", "failed");
                            retError.put("statusCode", statusCode);
                            callback.callback(retError);
                            return;
                        }

                        if (jsonResponse == null) {
                            throw new JSONException("Response is not a JSON object");
                        }

                        Map<String, Object> ret = new HashMap<>();
                        ret.put("statusCode", statusCode);

                        Iterator<String> keys = jsonResponse.keys();
                        while (keys.hasNext()) {
                            String key = keys.next();
                            if (jsonResponse.has(key)) {
                                if ("session_key".equals(key)) {
                                    ret.put("sessionKey", jsonResponse.get(key));
                                } else {
                                    ret.put(key, jsonResponse.get(key));
                                }
                            }
                        }
                        callback.callback(ret);
                    } catch (JSONException e) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "JSON parse error: " + e.getMessage());
                        retError.put("error", "parse_error");
                        retError.put("kind", "failed");
                        callback.callback(retError);
                    }
                }
            }
        );
    }

    public void getLatest(final String updateUrl, final String channel, final Callback callback) {
        this.getLatest(updateUrl, channel, null, callback);
    }

    public void getLatest(final String updateUrl, final String channel, final String appIdOverride, final Callback callback) {
        JSONObject json;
        try {
            json = this.createInfoObject(appIdOverride);
            if (channel != null && json != null) {
                json.put("defaultChannel", channel);
            }
        } catch (JSONException e) {
            logger.error("Error getting latest version");
            logger.debug("JSONException: " + e.getMessage());
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        if (logger != null) {
            logger.info("Auto-update parameters: " + json);
        }

        makeJsonRequest(updateUrl, json, callback);
    }

    public void unsetChannel(
        final SharedPreferences.Editor editor,
        final String defaultChannelKey,
        final String configDefaultChannel,
        final Callback callback
    ) {
        // Clear persisted defaultChannel and revert to config value
        editor.remove(defaultChannelKey);
        editor.apply();
        this.defaultChannel = configDefaultChannel;
        logger.info("Persisted defaultChannel cleared, reverted to config value: " + configDefaultChannel);

        Map<String, Object> ret = new HashMap<>();
        ret.put("status", "ok");
        ret.put("message", "Channel override removed");
        callback.callback(ret);
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
        // Check if setting defaultChannel is allowed
        if (!allowSetDefaultChannel) {
            logger.error("setChannel is disabled by allowSetDefaultChannel config");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "setChannel is disabled by configuration");
            retError.put("error", "disabled_by_config");
            callback.callback(retError);
            return;
        }

        // Check if rate limit was exceeded
        if (rateLimitExceeded) {
            logger.debug("Skipping setChannel due to rate limit (429). Requests will resume after app restart.");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        String channelUrl = this.channelUrl;
        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "channelUrl missing");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }
        JSONObject json;
        try {
            json = this.createInfoObject();
            json.put("channel", channel);
        } catch (JSONException e) {
            logger.error("Error setting channel");
            logger.debug("JSONException: " + e.getMessage());
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        makeJsonRequest(channelUrl, json, (res) -> {
            if (res.containsKey("error")) {
                callback.callback(res);
            } else if (Boolean.TRUE.equals(res.get("unset"))) {
                // Server requested to unset channel (public channel was requested)
                // Clear persisted defaultChannel and revert to config value
                editor.remove(defaultChannelKey);
                editor.apply();
                this.defaultChannel = configDefaultChannel;
                logger.info("Public channel requested, channel override removed");
                callback.callback(res);
            } else {
                this.defaultChannel = channel;
                editor.putString(defaultChannelKey, channel);
                editor.apply();
                logger.info("defaultChannel persisted locally: " + channel);
                callback.callback(res);
            }
        });
    }

    public void getChannel(final Callback callback) {
        this.getChannel(callback, null, null);
    }

    public void getChannel(final Callback callback, final SharedPreferences.Editor editor, final String defaultChannelKey) {
        // Check if rate limit was exceeded
        if (rateLimitExceeded) {
            logger.debug("Skipping getChannel due to rate limit (429). Requests will resume after app restart.");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        String channelUrl = this.channelUrl;
        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Channel URL is not set");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }
        JSONObject json;
        try {
            json = this.createInfoObject();
        } catch (JSONException e) {
            logger.error("Error getting channel");
            logger.debug("JSONException: " + e.getMessage());
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        Request request = new Request.Builder()
            .url(channelUrl)
            .put(RequestBody.create(json.toString(), MediaType.get("application/json")))
            .build();

        DownloadService.sharedClient.newCall(request).enqueue(
            new okhttp3.Callback() {
                @Override
                public void onFailure(@NonNull Call call, @NonNull IOException e) {
                    Map<String, Object> retError = new HashMap<>();
                    retError.put("message", "Request failed: " + e.getMessage());
                    retError.put("error", "network_error");
                    callback.callback(retError);
                }

                @Override
                public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                    try (ResponseBody responseBody = response.body()) {
                        // Check for 429 rate limit
                        if (checkAndHandleRateLimitResponse(response)) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Rate limit exceeded");
                            retError.put("error", "rate_limit_exceeded");
                            callback.callback(retError);
                            return;
                        }

                        if (response.code() == 400) {
                            if (responseBody == null) {
                                Map<String, Object> retError = new HashMap<>();
                                retError.put("message", "Empty response body");
                                retError.put("error", "no_response_body");
                                callback.callback(retError);
                                return;
                            }
                            String data = responseBody.string();
                            if (data.contains("channel_not_found") && !defaultChannel.isEmpty()) {
                                Map<String, Object> ret = new HashMap<>();
                                ret.put("channel", defaultChannel);
                                ret.put("status", "default");
                                logger.info("Channel get to \"" + ret);
                                callback.callback(ret);
                                return;
                            }
                        }

                        if (!response.isSuccessful()) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Server error: " + response.code());
                            retError.put("error", "response_error");
                            callback.callback(retError);
                            return;
                        }

                        if (responseBody == null) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Empty response body");
                            retError.put("error", "no_response_body");
                            callback.callback(retError);
                            return;
                        }
                        String responseData = responseBody.string();
                        JSONObject jsonResponse = new JSONObject(responseData);

                        // Check for server-side errors first
                        if (jsonResponse.has("error")) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("error", jsonResponse.getString("error"));
                            if (jsonResponse.has("message")) {
                                retError.put("message", jsonResponse.getString("message"));
                            } else {
                                retError.put("message", "server did not provide a message");
                            }
                            callback.callback(retError);
                            return;
                        }

                        Map<String, Object> ret = new HashMap<>();

                        Iterator<String> keys = jsonResponse.keys();
                        while (keys.hasNext()) {
                            String key = keys.next();
                            if (jsonResponse.has(key)) {
                                ret.put(key, jsonResponse.get(key));
                            }
                        }
                        persistDefaultChannelFromResponse(ret.get("channel"), editor, defaultChannelKey);
                        logger.info("Channel get to \"" + ret);
                        callback.callback(ret);
                    } catch (JSONException e) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "JSON parse error: " + e.getMessage());
                        retError.put("error", "parse_error");
                        callback.callback(retError);
                    }
                }
            }
        );
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
        // Check if rate limit was exceeded
        if (rateLimitExceeded) {
            logger.debug("Skipping listChannels due to rate limit (429). Requests will resume after app restart.");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        String channelUrl = this.channelUrl;
        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Channel URL is not set");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }

        JSONObject json;
        try {
            json = this.createInfoObject();
        } catch (JSONException e) {
            logger.error("Error creating info object");
            logger.debug("JSONException: " + e.getMessage());
            final Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        // Build URL with query parameters from JSON
        HttpUrl.Builder urlBuilder = HttpUrl.parse(channelUrl).newBuilder();
        try {
            Iterator<String> keys = json.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                Object value = json.get(key);
                if (value != null) {
                    urlBuilder.addQueryParameter(key, value.toString());
                }
            }
        } catch (JSONException e) {
            logger.error("Error adding query parameters");
            logger.debug("JSONException: " + e.getMessage());
        }

        Request request = new Request.Builder().url(urlBuilder.build()).get().build();

        DownloadService.sharedClient.newCall(request).enqueue(
            new okhttp3.Callback() {
                @Override
                public void onFailure(@NonNull Call call, @NonNull IOException e) {
                    Map<String, Object> retError = new HashMap<>();
                    retError.put("message", "Request failed: " + e.getMessage());
                    retError.put("error", "network_error");
                    callback.callback(retError);
                }

                @Override
                public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                    try (ResponseBody responseBody = response.body()) {
                        // Check for 429 rate limit
                        if (checkAndHandleRateLimitResponse(response)) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Rate limit exceeded");
                            retError.put("error", "rate_limit_exceeded");
                            callback.callback(retError);
                            return;
                        }

                        if (!response.isSuccessful()) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Server error: " + response.code());
                            retError.put("error", "response_error");
                            callback.callback(retError);
                            return;
                        }

                        if (responseBody == null) {
                            Map<String, Object> retError = new HashMap<>();
                            retError.put("message", "Empty response body");
                            retError.put("error", "no_response_body");
                            callback.callback(retError);
                            return;
                        }
                        String data = responseBody.string();

                        try {
                            Map<String, Object> ret = parseListChannelsResponse(data);

                            logger.info("Channels listed successfully");
                            callback.callback(ret);
                        } catch (JSONException arrayException) {
                            // If not an array, try to parse as error object
                            try {
                                JSONObject json = new JSONObject(data);
                                if (json.has("error")) {
                                    Map<String, Object> retError = new HashMap<>();
                                    retError.put("error", json.getString("error"));
                                    if (json.has("message")) {
                                        retError.put("message", json.getString("message"));
                                    } else {
                                        retError.put("message", "server did not provide a message");
                                    }
                                    callback.callback(retError);
                                    return;
                                }
                                Map<String, Object> retError = new HashMap<>();
                                retError.put("message", "Unexpected channels response format");
                                retError.put("error", "parse_error");
                                callback.callback(retError);
                                return;
                            } catch (JSONException objException) {
                                // If neither array nor object, throw parse error
                                arrayException.addSuppressed(objException);
                                Map<String, Object> retError = new HashMap<>();
                                retError.put("message", "JSON parse error: " + arrayException.getMessage());
                                retError.put("error", "parse_error");
                                callback.callback(retError);
                            }
                        }
                    }
                }
            }
        );
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
        if (this.previewSession) {
            if (logger != null) {
                logger.debug("Skipping sendStats during preview session.");
            }
            return;
        }

        // Check if rate limit was exceeded
        if (rateLimitExceeded) {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.");
            return;
        }

        String statsUrl = this.statsUrl;
        if (statsUrl == null || statsUrl.isEmpty()) {
            return;
        }

        JSONObject json;
        try {
            json = this.createInfoObject();
            json.put("version_name", versionName);
            json.put("old_version_name", oldVersionName);
            json.put("action", action);
            json.put("timestamp", System.currentTimeMillis());
            if (metadata != null && !metadata.isEmpty()) {
                json.put("metadata", new JSONObject(metadata));
            }
        } catch (JSONException e) {
            logger.error("Error preparing stats");
            logger.debug("JSONException: " + e.getMessage());
            return;
        }

        statsQueue.add(new QueuedStatsEvent(json, onSent));
        ensureStatsTimerStarted();
    }

    private synchronized void ensureStatsTimerStarted() {
        if (statsFlushTask == null || statsFlushTask.isCancelled() || statsFlushTask.isDone()) {
            statsFlushTask = statsScheduler.scheduleAtFixedRate(
                this::flushStatsQueue,
                STATS_FLUSH_INTERVAL_MS,
                STATS_FLUSH_INTERVAL_MS,
                TimeUnit.MILLISECONDS
            );
        }
    }

    private void flushStatsQueue() {
        if (statsQueue.isEmpty()) {
            return;
        }

        String statsUrl = this.statsUrl;
        if (statsUrl == null || statsUrl.isEmpty()) {
            statsQueue.clear();
            return;
        }

        // Copy and clear the queue atomically using synchronized block
        List<QueuedStatsEvent> eventsToSend;
        synchronized (statsQueue) {
            if (statsQueue.isEmpty()) {
                return;
            }
            eventsToSend = new ArrayList<>(statsQueue);
            statsQueue.clear();
        }

        JSONArray jsonArray = new JSONArray();
        for (QueuedStatsEvent queuedEvent : eventsToSend) {
            jsonArray.put(queuedEvent.event);
        }

        Request request = new Request.Builder()
            .url(statsUrl)
            .post(RequestBody.create(jsonArray.toString(), MediaType.get("application/json")))
            .build();

        final int eventCount = eventsToSend.size();
        DownloadService.sharedClient.newCall(request).enqueue(
            new okhttp3.Callback() {
                @Override
                public void onFailure(@NonNull Call call, @NonNull IOException e) {
                    logger.error("Failed to send stats batch");
                    logger.debug("Error: " + e.getMessage());
                }

                @Override
                public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                    try (ResponseBody responseBody = response.body()) {
                        // Check for 429 rate limit
                        if (checkAndHandleRateLimitResponse(response)) {
                            return;
                        }

                        if (response.isSuccessful()) {
                            logger.info("Stats batch sent successfully");
                            logger.debug("Sent " + eventCount + " events");
                            runStatsCallbacks(eventsToSend);
                        } else {
                            logger.error("Error sending stats batch");
                            logger.debug("Response code: " + response.code());
                        }
                    }
                }
            }
        );
    }

    private void runStatsCallbacks(final List<QueuedStatsEvent> sentEvents) {
        for (final QueuedStatsEvent sentEvent : sentEvents) {
            if (sentEvent.onSent == null) {
                continue;
            }

            try {
                sentEvent.onSent.run();
            } catch (Exception e) {
                if (logger != null) {
                    logger.error("Error running stats sent callback");
                    logger.debug("Error: " + e.getMessage());
                }
            }
        }
    }

    public BundleInfo getBundleInfo(final String id) {
        String trueId = BundleInfo.VERSION_UNKNOWN;
        if (id != null) {
            trueId = id;
        }
        BundleInfo result;
        if (BundleInfo.ID_BUILTIN.equals(trueId)) {
            result = new BundleInfo(
                trueId,
                this.versionBuild == null || this.versionBuild.isEmpty() ? null : this.versionBuild,
                BundleStatus.SUCCESS,
                "",
                ""
            );
        } else if (BundleInfo.VERSION_UNKNOWN.equals(trueId)) {
            result = new BundleInfo(trueId, null, BundleStatus.ERROR, "", "");
        } else {
            try {
                String stored = this.prefs.getString(trueId + INFO_SUFFIX, "");
                if (stored.isEmpty()) {
                    result = new BundleInfo(trueId, null, BundleStatus.PENDING, "", "");
                } else {
                    result = BundleInfo.fromJSON(stored);
                }
            } catch (JSONException e) {
                logger.error("Failed to parse bundle info");
                logger.debug("Bundle ID: " + trueId + ", Error: " + e.getMessage());
                // Clear corrupted data
                this.editor.remove(trueId + INFO_SUFFIX);
                this.editor.commit();
                result = new BundleInfo(trueId, null, BundleStatus.ERROR, "", "");
            }
        }
        return result;
    }

    public BundleInfo getBundleInfoByName(final String versionName) {
        final List<BundleInfo> installed = this.list(false);
        for (final BundleInfo i : installed) {
            if (i.getVersionName().equals(versionName)) {
                return i;
            }
        }
        return null;
    }

    private void removeBundleInfo(final String id) {
        this.saveBundleInfo(id, null);
    }

    public void saveBundleInfo(final String id, final BundleInfo info) {
        if (id == null || (info != null && (info.isBuiltin() || info.isUnknown()))) {
            logger.debug("Not saving info for bundle: [" + id + "] " + info);
            return;
        }

        if (info == null) {
            logger.debug("Removing info for bundle [" + id + "]");
            this.editor.remove(id + INFO_SUFFIX);
        } else {
            final BundleInfo update = info.setId(id);
            String jsonString = update.toString();
            logger.debug("Storing info for bundle [" + id + "] " + update.getClass().getName() + " -> " + jsonString);
            this.editor.putString(id + INFO_SUFFIX, jsonString);
        }
        this.editor.commit();
    }

    private void setBundleStatus(final String id, final BundleStatus status) {
        if (id != null && status != null) {
            BundleInfo info = this.getBundleInfo(id);
            logger.debug("Setting status for bundle [" + id + "] to " + status);
            this.saveBundleInfo(id, info.setStatus(status));
        }
    }

    private String getCurrentBundleId() {
        if (this.isUsingBuiltin()) {
            return BundleInfo.ID_BUILTIN;
        } else {
            final String path = this.getCurrentBundlePath();
            return path.substring(path.lastIndexOf('/') + 1);
        }
    }

    public BundleInfo getCurrentBundle() {
        return this.getBundleInfo(this.getCurrentBundleId());
    }

    public String getCurrentBundlePath() {
        String path = this.prefs.getString(this.CAP_SERVER_PATH, "public");
        if (path.trim().isEmpty()) {
            return "public";
        }
        return path;
    }

    public Boolean isUsingBuiltin() {
        return this.getCurrentBundlePath().equals("public");
    }

    public BundleInfo getFallbackBundle() {
        final String id = this.prefs.getString(FALLBACK_VERSION, BundleInfo.ID_BUILTIN);
        return this.getBundleInfo(id);
    }

    private void setFallbackBundle(final BundleInfo fallback) {
        this.editor.putString(FALLBACK_VERSION, fallback == null ? BundleInfo.ID_BUILTIN : fallback.getId());
        this.editor.commit();
    }

    public BundleInfo getNextBundle() {
        final String id = this.prefs.getString(NEXT_VERSION, null);
        if (id == null) return null;
        return this.getBundleInfo(id);
    }

    public BundleInfo getPreviewFallbackBundle() {
        final String id = this.prefs.getString(PREVIEW_FALLBACK_VERSION, null);
        if (id == null) return null;
        final BundleInfo bundle = this.getBundleInfo(id);
        if (bundle.isErrorStatus() || (!bundle.isBuiltin() && !this.bundleExists(id))) {
            this.setPreviewFallbackBundle(null);
            return null;
        }
        return bundle;
    }

    public boolean setPreviewFallbackBundle(final String fallback) {
        if (fallback == null) {
            this.editor.remove(PREVIEW_FALLBACK_VERSION);
        } else {
            final BundleInfo newBundle = this.getBundleInfo(fallback);
            if (newBundle.isErrorStatus() || (!newBundle.isBuiltin() && !this.bundleExists(fallback))) {
                return false;
            }
            this.editor.putString(PREVIEW_FALLBACK_VERSION, fallback);
        }
        this.editor.commit();
        return true;
    }

    public boolean setNextBundle(final String next) {
        BundleInfo bundleToNotify = null;
        if (next == null) {
            this.editor.remove(NEXT_VERSION);
        } else {
            final BundleInfo newBundle = this.getBundleInfo(next);
            if (!newBundle.isBuiltin() && !this.bundleExists(next)) {
                return false;
            }
            this.editor.putString(NEXT_VERSION, next);
            this.setBundleStatus(next, BundleStatus.PENDING);
            bundleToNotify = newBundle;
        }
        this.editor.commit();
        if (bundleToNotify != null) {
            this.sendStats("set_next", bundleToNotify.getVersionName(), this.getCurrentBundle().getVersionName());
            final Map<String, Object> payload = new HashMap<>();
            payload.put("bundle", bundleToNotify.toJSONMap());
            this.notifyListeners("setNext", payload);
        }
        return true;
    }

    /**
     * Shuts down the stats scheduler and flushes any pending stats.
     * Should be called when the plugin is destroyed to prevent resource leaks.
     */
    public void shutdown() {
        // Cancel the scheduled task
        if (statsFlushTask != null) {
            statsFlushTask.cancel(false);
            statsFlushTask = null;
        }

        // Flush any remaining stats before shutdown
        flushStatsQueue();

        // Shutdown the scheduler
        statsScheduler.shutdown();
        try {
            if (!statsScheduler.awaitTermination(2, TimeUnit.SECONDS)) {
                statsScheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            statsScheduler.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }
}
