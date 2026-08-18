/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.content.Context;
import android.content.res.AssetManager;
import androidx.annotation.NonNull;
import androidx.work.Data;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import java.io.*;
import java.io.FileInputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.Dispatcher;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.brotli.dec.BrotliInputStream;
import org.json.JSONArray;
import org.json.JSONObject;

public class DownloadService extends Worker {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    public static final String URL = "URL";
    public static final String ID = "id";
    public static final String PERCENT = "percent";
    public static final String FILEDEST = "filendest";
    public static final String DOCDIR = "docdir";
    public static final String ERROR = "error";
    public static final String VERSION = "version";
    public static final String SESSIONKEY = "sessionkey";
    public static final String CHECKSUM = "checksum";
    public static final String PUBLIC_KEY = "publickey";
    public static final String IS_MANIFEST = "is_manifest";
    public static final String APP_ID = "app_id";
    public static final String pluginVersion = "plugin_version";
    public static final String INSTALL_SOURCE = "install_source";
    public static final String STATS_URL = "stats_url";
    public static final String DEVICE_ID = "device_id";
    public static final String CUSTOM_ID = "custom_id";
    public static final String VERSION_BUILD = "version_build";
    public static final String VERSION_CODE = "version_code";
    public static final String VERSION_OS = "version_os";
    public static final String DEFAULT_CHANNEL = "default_channel";
    public static final String IS_PROD = "is_prod";
    public static final String IS_EMULATOR = "is_emulator";
    // HTTP + decode share one pool. Cap by CPU: 8 on 4 cores, 16 on 8 cores, 64 max.
    private static final int MANIFEST_MAX_CONCURRENT_FILES = manifestMaxConcurrentFiles();
    private static final String UPDATE_FILE = "update.dat";

    // Shared OkHttpClient to prevent resource leaks
    protected static OkHttpClient sharedClient;
    private static String currentAppId = "unknown";
    private static String currentPluginVersion = "unknown";
    private static String currentVersionOs = "unknown";

    // Initialize shared client with User-Agent interceptor
    static {
        Dispatcher dispatcher = new Dispatcher();
        dispatcher.setMaxRequests(MANIFEST_MAX_CONCURRENT_FILES);
        dispatcher.setMaxRequestsPerHost(MANIFEST_MAX_CONCURRENT_FILES);
        sharedClient = new OkHttpClient.Builder()
            .dispatcher(dispatcher)
            .protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1))
            .addInterceptor((chain) -> {
                Request originalRequest = chain.request();
                String userAgent = buildUserAgent(currentAppId, currentPluginVersion, currentVersionOs);
                Request requestWithUserAgent = originalRequest.newBuilder().header("User-Agent", userAgent).build();
                return chain.proceed(requestWithUserAgent);
            })
            .build();
    }

    static int manifestMaxConcurrentFiles() {
        return manifestMaxConcurrentFiles(Runtime.getRuntime().availableProcessors());
    }

    static int manifestMaxConcurrentFiles(int processors) {
        int cores = Math.max(1, processors);
        return Math.min(64, Math.max(8, cores * 2));
    }

    static String buildUserAgent(String appId, String pluginVersion, String versionOs) {
        return (
            "CapacitorUpdater/" +
            sanitizeUserAgentValue(pluginVersion) +
            " (" +
            sanitizeUserAgentValue(appId) +
            ") android/" +
            sanitizeUserAgentValue(versionOs)
        );
    }

    private static String sanitizeUserAgentValue(String value) {
        if (value == null || value.isEmpty()) {
            return "unknown";
        }

        StringBuilder sanitized = new StringBuilder();
        value.codePoints().forEach((cp) -> {
            boolean isVisibleAscii = cp >= 0x20 && cp <= 0x7E;
            boolean isIso88591 = cp >= 0xA0 && cp <= 0xFF;
            if (isVisibleAscii || isIso88591) {
                sanitized.appendCodePoint(cp);
            }
        });

        String result = sanitized.toString().trim();
        return result.isEmpty() ? "unknown" : result;
    }

    // Method to update User-Agent values
    public static void updateUserAgent(String appId, String pluginVersion, String versionOs) {
        currentAppId = sanitizeUserAgentValue(appId);
        currentPluginVersion = sanitizeUserAgentValue(pluginVersion);
        currentVersionOs = sanitizeUserAgentValue(versionOs);
        if (logger != null) {
            logger.debug("Updated User-Agent: " + buildUserAgent(currentAppId, currentPluginVersion, currentVersionOs));
        }
    }

    public DownloadService(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
        // Use shared client - no need to create new instances

        // Clean up old temporary files on service initialization
        cleanupOldTempFiles(getApplicationContext().getCacheDir());
        cleanupOldTempFiles(new File(getApplicationContext().getCacheDir(), "capgo_downloads"));
    }

    private void setProgress(int percent) {
        Data progress = new Data.Builder().putInt(PERCENT, percent).build();
        setProgressAsync(progress);
    }

    private Result createFailureResult(String error) {
        Data output = new Data.Builder().putString(ERROR, error).build();
        return Result.failure(output);
    }

    private Result createSuccessResult(String dest, String version, String sessionKey, String checksum, boolean isManifest) {
        Data output = new Data.Builder()
            .putString(FILEDEST, dest)
            .putString(VERSION, version)
            .putString(SESSIONKEY, sessionKey)
            .putString(CHECKSUM, checksum)
            .putBoolean(IS_MANIFEST, isManifest)
            .build();
        return Result.success(output);
    }

    static File resolveManifestTargetFile(final File destFolder, final String fileName) throws IOException {
        final boolean isBrotli = fileName.endsWith(".br");
        final String targetFileName = isBrotli ? fileName.substring(0, fileName.length() - 3) : fileName;
        return CapgoUpdater.resolvePathInsideDirectory(destFolder, targetFileName);
    }

    static File resolveManifestBuiltinFile(final File builtinFolder, final String fileName) throws IOException {
        final boolean isBrotli = fileName.endsWith(".br");
        final String resolvedName = isBrotli ? fileName.substring(0, fileName.length() - 3) : fileName;
        return CapgoUpdater.resolvePathInsideDirectory(builtinFolder, resolvedName);
    }

    /** APK web assets live in assets/public/; strip .br so store files match. */
    static String resolveBuiltinAssetPath(final String fileName) throws IOException {
        final File base = new File("/capgo-builtin-assets");
        final File resolved = resolveManifestBuiltinFile(base, fileName);
        final String basePath = base.getCanonicalPath();
        final String resolvedPath = resolved.getCanonicalPath();
        final String normalizedBasePath = basePath.endsWith(File.separator) ? basePath : basePath + File.separator;
        if (!resolvedPath.startsWith(normalizedBasePath)) {
            throw new IOException("Invalid manifest file path: " + fileName);
        }
        return "public/" + resolvedPath.substring(normalizedBasePath.length()).replace(File.separatorChar, '/');
    }

    static boolean copyStreamIfChecksumMatches(final InputStream input, final File dest, final String expectedHash) throws IOException {
        if (expectedHash == null || expectedHash.isEmpty()) {
            return false;
        }
        final File parent = dest.getParentFile();
        if (parent == null) {
            throw new IOException("Destination has no parent: " + dest.getAbsolutePath());
        }
        if (!parent.exists() && !parent.mkdirs()) {
            throw new IOException("Failed to create parent directory: " + parent.getAbsolutePath());
        }

        final MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException("SHA-256 algorithm not available", e);
        }

        final File tempFile = File.createTempFile("capgo_asset_", ".tmp", parent);
        try {
            try (FileOutputStream outStream = new FileOutputStream(tempFile)) {
                final byte[] buffer = new byte[CryptoCipher.ioBufferBytes()];
                int length;
                while ((length = input.read(buffer)) != -1) {
                    digest.update(buffer, 0, length);
                    outStream.write(buffer, 0, length);
                }
            }
            if (!expectedHash.equalsIgnoreCase(sha256Hex(digest))) {
                return false;
            }
            return replaceFile(tempFile, dest);
        } finally {
            deleteQuietly(tempFile);
        }
    }

    private static String sha256Hex(final MessageDigest digest) {
        final byte[] hash = digest.digest();
        final StringBuilder hexString = new StringBuilder(hash.length * 2);
        for (final byte b : hash) {
            final String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) {
                hexString.append('0');
            }
            hexString.append(hex);
        }
        return hexString.toString();
    }

    private static void deleteQuietly(final File file) {
        if (file.exists() && !file.delete()) {
            file.deleteOnExit();
        }
    }

    static boolean replaceFile(final File tempFile, final File dest) {
        if (tempFile.renameTo(dest)) {
            return true;
        }
        final File parent = dest.getParentFile();
        if (parent == null) {
            return false;
        }
        final File backup = new File(parent, ".capgo_bak_" + UUID.randomUUID());
        deleteQuietly(backup);
        if (dest.exists() && !dest.renameTo(backup)) {
            return false;
        }
        if (!tempFile.renameTo(dest)) {
            if (backup.exists()) {
                backup.renameTo(dest);
            }
            return false;
        }
        deleteQuietly(backup);
        return true;
    }

    static boolean rememberManifestTarget(final Set<String> seenTargets, final File targetFile) throws IOException {
        return seenTargets.add(targetFile.getCanonicalPath());
    }

    static boolean tryCopyBuiltinAsset(final AssetManager assets, final String fileName, final File dest, final String expectedHash) {
        if (assets == null || fileName == null || dest == null) {
            return false;
        }
        try {
            final String assetPath = resolveBuiltinAssetPath(fileName);
            try (InputStream in = assets.open(assetPath)) {
                return copyStreamIfChecksumMatches(in, dest, expectedHash);
            }
        } catch (IOException e) {
            return false;
        }
    }

    static boolean builtinAssetMatches(final AssetManager assets, final String fileName, final String expectedHash) {
        if (assets == null || fileName == null || expectedHash == null || expectedHash.isEmpty()) {
            return false;
        }
        try {
            final String assetPath = resolveBuiltinAssetPath(fileName);
            try (InputStream in = assets.open(assetPath)) {
                return expectedHash.equalsIgnoreCase(CryptoCipher.calcChecksum(in));
            }
        } catch (IOException e) {
            return false;
        }
    }

    private String getInputString(String key, String fallback) {
        String value = getInputData().getString(key);
        return value != null ? value : fallback;
    }

    @NonNull
    @Override
    public Result doWork() {
        try {
            String url = getInputData().getString(URL);
            String id = getInputData().getString(ID);
            String documentsDir = getInputData().getString(DOCDIR);
            String dest = getInputData().getString(FILEDEST);
            String version = getInputData().getString(VERSION);
            String sessionKey = getInputData().getString(SESSIONKEY);
            String checksum = getInputData().getString(CHECKSUM);
            String publicKey = getInputData().getString(PUBLIC_KEY);
            boolean isManifest = getInputData().getBoolean(IS_MANIFEST, false);

            logger.debug("doWork isManifest: " + isManifest);

            if (isManifest) {
                JSONArray manifest = DataManager.getInstance().getAndClearManifest();
                if (manifest != null) {
                    handleManifestDownload(id, documentsDir, dest, version, sessionKey, publicKey, manifest);
                    return createSuccessResult(dest, version, sessionKey, checksum, true);
                } else {
                    logger.error("Manifest is null");
                    return createFailureResult("Manifest is null");
                }
            } else {
                handleSingleFileDownload(url, id, documentsDir, dest, version, sessionKey, checksum);
                return createSuccessResult(dest, version, sessionKey, checksum, false);
            }
        } catch (Exception e) {
            return createFailureResult(e.getMessage());
        }
    }

    private int calcTotalPercent(long downloadedBytes, long contentLength) {
        if (contentLength <= 0) {
            return 0;
        }
        int percent = (int) (((double) downloadedBytes / contentLength) * 100);
        percent = Math.max(10, percent);
        percent = Math.min(70, percent);
        return percent;
    }

    private void sendStatsAsync(String action, String version) {
        try {
            String statsUrl = getInputData().getString(STATS_URL);
            if (statsUrl == null || statsUrl.isEmpty()) {
                return;
            }

            JSONObject json = new JSONObject();
            json.put("platform", "android");
            json.put("app_id", getInputString(APP_ID, "unknown"));
            json.put("plugin_version", getInputString(pluginVersion, "unknown"));
            json.put("install_source", getInputString(INSTALL_SOURCE, ""));
            json.put("version_name", version != null ? version : "");
            json.put("old_version_name", "");
            json.put("action", action);
            json.put("device_id", getInputString(DEVICE_ID, ""));
            json.put("custom_id", getInputString(CUSTOM_ID, ""));
            json.put("version_build", getInputString(VERSION_BUILD, ""));
            json.put("version_code", getInputString(VERSION_CODE, ""));
            json.put("version_os", getInputString(VERSION_OS, currentVersionOs));
            json.put("defaultChannel", getInputString(DEFAULT_CHANNEL, ""));
            json.put("is_prod", getInputData().getBoolean(IS_PROD, true));
            json.put("is_emulator", getInputData().getBoolean(IS_EMULATOR, false));

            Request request = new Request.Builder()
                .url(statsUrl)
                .post(RequestBody.create(json.toString(), MediaType.get("application/json")))
                .build();

            sharedClient.newCall(request).enqueue(
                new Callback() {
                    @Override
                    public void onFailure(@NonNull Call call, @NonNull IOException e) {
                        if (logger != null) {
                            logger.error("Failed to send stats: " + e.getMessage());
                        }
                    }

                    @Override
                    public void onResponse(@NonNull Call call, @NonNull Response response) {
                        try (ResponseBody body = response.body()) {
                            // nothing else to do, just closing body
                        } catch (Exception ignored) {
                        } finally {
                            response.close();
                        }
                    }
                }
            );
        } catch (Exception e) {
            if (logger != null) {
                logger.error("sendStatsAsync error: " + e.getMessage());
            }
        }
    }

    private void handleManifestDownload(
        String id,
        String documentsDir,
        String dest,
        String version,
        String sessionKey,
        String publicKey,
        JSONArray manifest
    ) {
        try {
            logger.debug("handleManifestDownload");

            // Send stats for manifest download start
            sendStatsAsync("download_manifest_start", version);

            File destFolder = new File(documentsDir, dest);
            File cacheFolder = new File(getApplicationContext().getCacheDir(), "capgo_downloads");
            File builtinFolder = new File(getApplicationContext().getFilesDir(), "public");
            AssetManager assets = getApplicationContext().getAssets();

            // Ensure directories are created
            if (!destFolder.exists() && !destFolder.mkdirs()) {
                throw new IOException("Failed to create destination directory: " + destFolder.getAbsolutePath());
            }
            cleanupOrphanedAssetTemps(destFolder);
            if (!cacheFolder.exists() && !cacheFolder.mkdirs()) {
                throw new IOException("Failed to create cache directory: " + cacheFolder.getAbsolutePath());
            }

            int totalFiles = manifest.length();
            final AtomicLong completedFiles = new AtomicLong(0);
            final AtomicBoolean hasError = new AtomicBoolean(false);

            ExecutorService executor = Executors.newFixedThreadPool(Math.min(MANIFEST_MAX_CONCURRENT_FILES, Math.max(1, totalFiles)));
            List<Future<?>> futures = new ArrayList<>();
            final Set<String> seenTargets = new HashSet<>();

            for (int i = 0; i < totalFiles; i++) {
                JSONObject entry = manifest.getJSONObject(i);
                String fileName = entry.getString("file_name");
                String fileHash = entry.optString("file_hash", "");
                String downloadUrl = entry.getString("download_url");

                if (fileHash.isEmpty()) {
                    logger.error("Missing file_hash for manifest entry: " + fileName);
                    hasError.set(true);
                    continue;
                }

                if (publicKey != null && !publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty()) {
                    try {
                        fileHash = CryptoCipher.decryptChecksum(fileHash, publicKey);
                    } catch (Exception e) {
                        logger.error("Error decrypting checksum for " + fileName + "fileHash: " + fileHash);
                        hasError.set(true);
                        continue;
                    }
                }

                final String finalFileHash = fileHash;

                // Check if file is a Brotli file and remove .br extension from target
                boolean isBrotli = fileName.endsWith(".br");
                String targetFileName = isBrotli ? fileName.substring(0, fileName.length() - 3) : fileName;

                File targetFile;
                File builtinFile;
                try {
                    targetFile = resolveManifestTargetFile(destFolder, fileName);
                    builtinFile = resolveManifestBuiltinFile(builtinFolder, fileName);
                    if (!rememberManifestTarget(seenTargets, targetFile)) {
                        logger.error("Duplicate manifest target path: " + fileName);
                        sendStatsAsync("manifest_path_fail", version + ":" + fileName);
                        hasError.set(true);
                        continue;
                    }
                } catch (IOException e) {
                    logger.error("Invalid manifest file path: " + fileName);
                    sendStatsAsync("manifest_path_fail", version + ":" + fileName);
                    hasError.set(true);
                    continue;
                }
                String cacheBaseName = new File(isBrotli ? targetFileName : fileName).getName();
                final File cacheFile = CapgoUpdater.isSafeCacheHash(finalFileHash)
                    ? new File(cacheFolder, finalFileHash + "_" + cacheBaseName)
                    : null;
                final File legacyCacheFile =
                    isBrotli && cacheFile != null ? new File(cacheFolder, finalFileHash + "_" + new File(fileName).getName()) : null;

                // Ensure parent directories of the target file exist
                if (!Objects.requireNonNull(targetFile.getParentFile()).exists() && !targetFile.getParentFile().mkdirs()) {
                    logger.error("Failed to create parent directory for: " + targetFile.getAbsolutePath());
                    hasError.set(true);
                    continue;
                }

                final boolean finalIsBrotli = isBrotli;
                Future<?> future = executor.submit(() -> {
                    try {
                        if (tryCopyBuiltinAsset(assets, fileName, targetFile, finalFileHash)) {
                            logger.debug("using builtin asset " + fileName);
                        } else if (builtinFile.exists() && verifyChecksum(builtinFile, finalFileHash)) {
                            copyFile(builtinFile, targetFile);
                            logger.debug("using builtin file " + fileName);
                        } else if (
                            tryCopyFromCache(cacheFile, targetFile, finalFileHash) ||
                            (legacyCacheFile != null && tryCopyFromCache(legacyCacheFile, targetFile, finalFileHash))
                        ) {
                            logger.debug("already cached " + fileName);
                        } else {
                            downloadAndVerify(
                                downloadUrl,
                                targetFile,
                                cacheFile,
                                finalFileHash,
                                sessionKey,
                                publicKey,
                                finalIsBrotli,
                                fileName
                            );
                        }

                        long completed = completedFiles.incrementAndGet();
                        int percent = calcTotalPercent(completed, totalFiles);
                        setProgress(percent);
                    } catch (Exception e) {
                        logger.error("Error processing file: " + fileName + " " + e.getMessage());
                        sendStatsAsync("download_manifest_file_fail", version + ":" + fileName);
                        hasError.set(true);
                    }
                });
                futures.add(future);
            }

            // Wait for all downloads to complete
            for (Future<?> future : futures) {
                try {
                    future.get();
                } catch (Exception e) {
                    logger.error("Error waiting for download " + e.getMessage());
                    hasError.set(true);
                }
            }

            executor.shutdown();
            try {
                if (!executor.awaitTermination(60, TimeUnit.SECONDS)) {
                    executor.shutdownNow();
                }
            } catch (InterruptedException e) {
                executor.shutdownNow();
                Thread.currentThread().interrupt();
            }

            if (hasError.get()) {
                logger.error("One or more files failed to download");
                throw new IOException("One or more files failed to download");
            }

            // Send stats for manifest download complete
            sendStatsAsync("download_manifest_complete", version);
        } catch (Exception e) {
            logger.error("Error in handleManifestDownload " + e.getMessage());
            throw new RuntimeException(e.getLocalizedMessage());
        }
    }

    private void handleSingleFileDownload(
        String url,
        String id,
        String documentsDir,
        String dest,
        String version,
        String sessionKey,
        String checksum
    ) {
        // Send stats for zip download start
        sendStatsAsync("download_zip_start", version);

        File target = new File(documentsDir, dest);
        // Use bundle ID in temp file names to prevent collisions when multiple downloads run concurrently
        File infoFile = new File(documentsDir, "update_" + id + ".dat");
        File tempFile = new File(documentsDir, "temp_" + id + ".tmp");

        // Check available disk space before starting
        long availableSpace = target.getParentFile().getUsableSpace();
        long estimatedSize = 50 * 1024 * 1024; // 50MB default estimate
        if (availableSpace < estimatedSize * 2) {
            throw new RuntimeException("insufficient_disk_space");
        }

        HttpURLConnection httpConn = null;
        InputStream inputStream = null;
        FileOutputStream outputStream = null;
        BufferedReader reader = null;
        BufferedWriter writer = null;

        try {
            URL u = new URL(url);
            httpConn = (HttpURLConnection) u.openConnection();

            // Set reasonable timeouts
            httpConn.setConnectTimeout(30000); // 30 seconds
            httpConn.setReadTimeout(60000); // 60 seconds

            // Reading progress file (if exist)
            long downloadedBytes = 0;

            if (infoFile.exists() && tempFile.exists()) {
                try {
                    reader = new BufferedReader(new FileReader(infoFile));
                    String updateVersion = reader.readLine();
                    if (updateVersion != null && !updateVersion.equals(version)) {
                        clearDownloadData(documentsDir, id);
                    } else {
                        downloadedBytes = tempFile.length();
                    }
                } finally {
                    if (reader != null) {
                        try {
                            reader.close();
                        } catch (Exception ignored) {}
                    }
                }
            } else {
                clearDownloadData(documentsDir, id);
            }

            if (downloadedBytes > 0) {
                httpConn.setRequestProperty("Range", "bytes=" + downloadedBytes + "-");
            }

            int responseCode = httpConn.getResponseCode();

            if (responseCode == HttpURLConnection.HTTP_OK || responseCode == HttpURLConnection.HTTP_PARTIAL) {
                long contentLength = httpConn.getContentLength() + downloadedBytes;

                // Check if we have enough space for the actual file
                if (contentLength > 0 && availableSpace < contentLength * 2) {
                    throw new RuntimeException("insufficient_disk_space");
                }

                try {
                    inputStream = httpConn.getInputStream();
                    outputStream = new FileOutputStream(tempFile, downloadedBytes > 0);

                    if (downloadedBytes == 0) {
                        writer = new BufferedWriter(new FileWriter(infoFile));
                        writer.write(String.valueOf(version));
                        writer.close();
                        writer = null;
                    }

                    byte[] buffer = new byte[8192]; // Larger buffer for better performance
                    int lastNotifiedPercent = 0;
                    int bytesRead;

                    while ((bytesRead = inputStream.read(buffer)) != -1) {
                        outputStream.write(buffer, 0, bytesRead);
                        downloadedBytes += bytesRead;

                        // Flush every 1MB to ensure progress is saved
                        if (downloadedBytes % (1024 * 1024) == 0) {
                            outputStream.flush();
                        }

                        // Computing percentage
                        int percent = calcTotalPercent(downloadedBytes, contentLength);
                        if (percent >= lastNotifiedPercent + 10) {
                            lastNotifiedPercent = (percent / 10) * 10;
                            setProgress(lastNotifiedPercent);
                        }
                    }

                    // Final flush
                    outputStream.flush();
                    outputStream.close();
                    outputStream = null;

                    inputStream.close();
                    inputStream = null;

                    // Rename the temp file with the final name (dest)
                    if (!tempFile.renameTo(new File(documentsDir, dest))) {
                        throw new RuntimeException("Failed to rename temp file to final destination");
                    }
                    infoFile.delete();

                    // Send stats for zip download complete
                    sendStatsAsync("download_zip_complete", version);
                } catch (OutOfMemoryError e) {
                    logger.error("Out of memory during download: " + e.getMessage());
                    // Try to free some memory
                    System.gc();
                    throw new RuntimeException("low_mem_fail");
                } finally {
                    // Ensure all resources are closed
                    if (outputStream != null) {
                        try {
                            outputStream.close();
                        } catch (Exception ignored) {}
                    }
                    if (inputStream != null) {
                        try {
                            inputStream.close();
                        } catch (Exception ignored) {}
                    }
                    if (writer != null) {
                        try {
                            writer.close();
                        } catch (Exception ignored) {}
                    }
                }
            } else {
                infoFile.delete();
                throw new RuntimeException("HTTP error: " + responseCode);
            }
        } catch (OutOfMemoryError e) {
            logger.error("Critical memory error: " + e.getMessage());
            System.gc(); // Suggest garbage collection
            throw new RuntimeException("low_mem_fail");
        } catch (SecurityException e) {
            logger.error("Security error during download: " + e.getMessage());
            throw new RuntimeException("security_error: " + e.getMessage());
        } catch (Exception e) {
            logger.error("Download error: " + e.getMessage());
            throw new RuntimeException(e.getMessage());
        } finally {
            // Ensure connection is closed
            if (httpConn != null) {
                try {
                    httpConn.disconnect();
                } catch (Exception ignored) {}
            }
        }
    }

    private void clearDownloadData(String docDir, String id) {
        File tempFile = new File(docDir, "temp_" + id + ".tmp");
        File infoFile = new File(docDir, "update_" + id + ".dat");
        try {
            tempFile.delete();
            infoFile.delete();
            infoFile.createNewFile();
            tempFile.createNewFile();
        } catch (IOException e) {
            logger.error("Error in clearDownloadData " + e.getMessage());
            // not a fatal error, so we don't throw an exception
        }
    }

    // Helper methods

    /**
     * Atomically try to copy a file from cache - returns true if successful, false if file doesn't exist or copy failed.
     * This handles the race condition where OS can delete cache files between exists() check and copy.
     */
    private boolean tryCopyFromCache(File source, File dest, String expectedHash) {
        // First quick check - if file doesn't exist or was truncated, don't bother
        if (!CapgoUpdater.isReusableCacheFile(source, expectedHash)) {
            return false;
        }

        // Hash is in the cache file name and was verified when written.
        // Re-hashing here would re-read every reused file on low-RAM devices.
        try {
            copyFile(source, dest);
            return true;
        } catch (IOException e) {
            // File was deleted between check and copy, or other IO error - caller should download instead
            logger.debug("Cache copy failed (likely OS eviction): " + e.getMessage());
            return false;
        }
    }

    private void copyFile(File source, File dest) throws IOException {
        final File parent = dest.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("Failed to create parent directory: " + parent.getAbsolutePath());
        }

        final File tempFile = File.createTempFile("capgo-", ".tmp", parent);
        try {
            try (
                FileInputStream inStream = new FileInputStream(source);
                FileOutputStream outStream = new FileOutputStream(tempFile);
                FileChannel inChannel = inStream.getChannel();
                FileChannel outChannel = outStream.getChannel()
            ) {
                long size = inChannel.size();
                long pos = 0;
                while (pos < size) {
                    long transferred = inChannel.transferTo(pos, size - pos, outChannel);
                    if (transferred <= 0) {
                        throw new IOException("Failed to copy file: " + source.getAbsolutePath());
                    }
                    pos += transferred;
                }
            }
            CryptoCipher.replaceFile(tempFile, dest);
        } finally {
            if (tempFile.exists()) {
                tempFile.delete();
            }
        }
    }

    private void downloadAndVerify(
        String downloadUrl,
        File targetFile,
        File cacheFile,
        String expectedHash,
        String sessionKey,
        String publicKey,
        boolean isBrotli,
        String relativeName
    ) throws Exception {
        logger.debug("downloadAndVerify " + downloadUrl);

        File finalTargetFile = targetFile;
        File cacheFolder = new File(getApplicationContext().getCacheDir(), "capgo_downloads");
        if (!cacheFolder.exists() && !cacheFolder.mkdirs()) {
            throw new IOException("Failed to create cache directory: " + cacheFolder.getAbsolutePath());
        }
        File partial = manifestPartialFile(cacheFolder, expectedHash, relativeName);
        File workFile = null;
        boolean keepPartial = partial.isFile();
        try {
            long existing = partial.isFile() ? partial.length() : 0;
            Request.Builder builder = new Request.Builder().url(downloadUrl);
            if (existing > 0) {
                builder.header("Range", "bytes=" + existing + "-");
            }
            try (Response response = sharedClient.newCall(builder.build()).execute()) {
                int code = response.code();
                if (code == 416 && existing > 0) {
                    logger.debug("Range not satisfiable, using existing partial " + partial.getName());
                    keepPartial = true;
                } else if (code != HttpURLConnection.HTTP_OK && code != HttpURLConnection.HTTP_PARTIAL) {
                    sendStatsAsync("download_manifest_file_fail", getInputData().getString(VERSION) + ":" + finalTargetFile.getName());
                    throw new IOException("Unexpected response code: " + code);
                } else {
                    ResponseBody responseBody = response.body();
                    if (responseBody == null) {
                        throw new IOException("Response body is null");
                    }
                    try {
                        writeHttpBody(partial, responseBody.byteStream(), code, existing);
                        keepPartial = true;
                    } catch (Exception e) {
                        keepPartial = true;
                        throw e;
                    }
                }
            }

            boolean needDecrypt = publicKey != null && !publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty();
            File source = partial;
            if (needDecrypt) {
                workFile = new File(cacheFolder, "work_" + UUID.randomUUID() + "_" + targetFile.getName() + ".tmp");
                copyFile(partial, workFile);
                try {
                    logger.debug("Decrypting file " + targetFile.getName());
                    CryptoCipher.decryptFile(workFile, publicKey, sessionKey);
                    source = workFile;
                } catch (Exception e) {
                    keepPartial = false;
                    throw e;
                }
            }

            try {
                if (isBrotli) {
                    decompressBrotli(source, finalTargetFile, targetFile.getName(), expectedHash);
                } else {
                    try (FileInputStream fis = new FileInputStream(source)) {
                        writeFileAtomic(finalTargetFile, fis, expectedHash);
                    }
                }
            } catch (IOException e) {
                String msg = e.getMessage();
                if (msg != null && msg.contains("Checksum verification failed")) {
                    if (finalTargetFile.exists() && !finalTargetFile.delete()) {
                        logger.debug("Failed to delete dest after checksum mismatch");
                    }
                    sendStatsAsync("download_manifest_checksum_fail", getInputData().getString(VERSION) + ":" + finalTargetFile.getName());
                    keepPartial = false;
                } else if (isBrotli) {
                    sendStatsAsync("download_manifest_brotli_fail", getInputData().getString(VERSION) + ":" + finalTargetFile.getName());
                    keepPartial = false;
                }
                throw e;
            }

            CryptoCipher.logChecksumInfo("Calculated checksum", expectedHash);
            CryptoCipher.logChecksumInfo("Expected checksum", expectedHash);

            if (cacheFile != null) {
                try (FileInputStream fis = new FileInputStream(finalTargetFile)) {
                    writeFileAtomic(cacheFile, fis, null);
                }
            }
            keepPartial = false;
        } catch (Exception e) {
            throw new IOException("Error in downloadAndVerify: " + e.getMessage(), e);
        } finally {
            if (workFile != null && workFile.exists() && !workFile.delete()) {
                logger.debug("Failed to delete decrypt work file");
            }
            if (!keepPartial && partial.exists() && !partial.delete()) {
                logger.debug("Failed to delete manifest partial " + partial.getName());
            }
        }
    }

    static String safePartialToken(String fileName) {
        return CryptoCipher.shortPathKey(fileName);
    }

    static File manifestPartialFile(File cacheDir, String hash, String fileName) {
        String token = safePartialToken(fileName);
        if (CapgoUpdater.isSafeCacheHash(hash) && hash.length() == 64) {
            return new File(cacheDir, "partial_" + hash + "_" + token + ".tmp");
        }
        return new File(cacheDir, "temp_" + UUID.randomUUID() + "_" + token + ".tmp");
    }

    static boolean shouldAppendHttpBody(int statusCode, long existingBytes) {
        return existingBytes > 0 && statusCode == HttpURLConnection.HTTP_PARTIAL;
    }

    static void writeHttpBody(File dest, InputStream body, int statusCode, long existingBytes) throws IOException {
        boolean append = shouldAppendHttpBody(statusCode, existingBytes);
        byte[] buffer = new byte[CryptoCipher.ioBufferBytes()];
        try (FileOutputStream fos = new FileOutputStream(dest, append)) {
            int n;
            long written = append ? existingBytes : 0;
            while ((n = body.read(buffer)) != -1) {
                fos.write(buffer, 0, n);
                written += n;
                if (written % (1024 * 1024) == 0) {
                    fos.flush();
                }
            }
            fos.flush();
        }
    }

    private boolean verifyChecksum(File file, String expectedHash) {
        try {
            String actualHash = calculateFileHash(file);
            return actualHash.equalsIgnoreCase(expectedHash);
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    private String calculateFileHash(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] byteArray = new byte[1024];
        int bytesCount = 0;

        try (FileInputStream fis = new FileInputStream(file)) {
            while ((bytesCount = fis.read(byteArray)) != -1) {
                digest.update(byteArray, 0, bytesCount);
            }
        }

        byte[] bytes = digest.digest();
        StringBuilder sb = new StringBuilder();
        for (byte aByte : bytes) {
            sb.append(Integer.toString((aByte & 0xff) + 0x100, 16).substring(1));
        }
        return sb.toString();
    }

    static void decompressBrotli(File input, File output, String fileName) throws IOException {
        decompressBrotli(input, output, fileName, null);
    }

    static void decompressBrotli(File input, File output, String fileName, String expectedChecksum) throws IOException {
        File parent = output.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        long length = input.length();
        if (length == 0) {
            writeFileAtomic(output, new ByteArrayInputStream(new byte[0]), expectedChecksum);
            return;
        }

        byte[] head = new byte[(int) Math.min(3, length)];
        byte last = 0;
        try (RandomAccessFile raf = new RandomAccessFile(input, "r")) {
            raf.readFully(head);
            if (length >= 1) {
                raf.seek(length - 1);
                last = raf.readByte();
            }
        }

        if (length == 3 && head[0] == 0x1B && head[1] == 0x00 && head[2] == 0x06) {
            writeFileAtomic(output, new ByteArrayInputStream(new byte[0]), expectedChecksum);
            return;
        }

        if (length > 3 && last == 0x03) {
            boolean emptyWrapper = head[0] == 0x1B && head[1] == 0x00 && head[2] == 0x06;
            boolean qualityZeroWrapper = head[0] == 0x0b && head[1] == 0x02 && head[2] == (byte) 0x80;
            if (emptyWrapper || qualityZeroWrapper) {
                try (FileInputStream fis = new FileInputStream(input)) {
                    long skipped = 0;
                    while (skipped < 3) {
                        long n = fis.skip(3 - skipped);
                        if (n <= 0) {
                            break;
                        }
                        skipped += n;
                    }
                    writeFileAtomic(output, new BoundedInputStream(fis, length - 4), expectedChecksum);
                }
                return;
            }
        }

        try (FileInputStream fis = new FileInputStream(input); BrotliInputStream brotliInputStream = new BrotliInputStream(fis)) {
            writeFileAtomic(output, brotliInputStream, expectedChecksum);
        } catch (IOException e) {
            logger.error("Error: Brotli process failed for " + fileName + ". Status: " + e.getMessage());
            StringBuilder hexDump = new StringBuilder();
            try (FileInputStream peek = new FileInputStream(input)) {
                byte[] prefix = new byte[(int) Math.min(32, length)];
                int n = peek.read(prefix);
                for (int i = 0; i < n; i++) {
                    hexDump.append(String.format("%02x ", prefix[i]));
                }
            }
            logger.error("Error: Raw data (" + fileName + "): " + hexDump);
            throw e;
        }
    }

    private static final class BoundedInputStream extends FilterInputStream {

        private long remaining;

        BoundedInputStream(InputStream in, long remaining) {
            super(in);
            this.remaining = remaining;
        }

        @Override
        public int read() throws IOException {
            if (remaining <= 0) {
                return -1;
            }
            int value = super.read();
            if (value >= 0) {
                remaining--;
            }
            return value;
        }

        @Override
        public int read(byte[] b, int off, int len) throws IOException {
            if (remaining <= 0) {
                return -1;
            }
            int capped = (int) Math.min(len, remaining);
            int n = super.read(b, off, capped);
            if (n > 0) {
                remaining -= n;
            }
            return n;
        }
    }

    /**
     * Atomically write a stream to a file using the 256 KiB IO buffer.
     * When expectedChecksum is set, SHA-256 is hashed during the write.
     */
    static void writeFileAtomic(File targetFile, InputStream inputStream, String expectedChecksum) throws IOException {
        File tempFile = File.createTempFile("capgo-", ".tmp", targetFile.getParentFile());

        try {
            // Okio's default segment is 8 KiB. Copy with 256 KiB so 8 MiB wrapper unwraps
            // are not 1000 tiny writes.
            byte[] buffer = new byte[CryptoCipher.ioBufferBytes()];
            MessageDigest digest = null;
            if (expectedChecksum != null && !expectedChecksum.isEmpty()) {
                try {
                    digest = MessageDigest.getInstance("SHA-256");
                } catch (java.security.NoSuchAlgorithmException e) {
                    throw new IOException("SHA-256 algorithm not available", e);
                }
            }
            try (FileOutputStream fos = new FileOutputStream(tempFile)) {
                int n;
                while ((n = inputStream.read(buffer)) != -1) {
                    if (digest != null) {
                        digest.update(buffer, 0, n);
                    }
                    fos.write(buffer, 0, n);
                }
            }

            if (digest != null) {
                String actualChecksum = CryptoCipher.digestToHex(digest);
                if (!expectedChecksum.equalsIgnoreCase(actualChecksum)) {
                    throw new IOException("Checksum verification failed expected: " + expectedChecksum + " calculated: " + actualChecksum);
                }
            }

            // Atomic rename (on same filesystem). renameTo works on API 24; Files.move does not.
            CryptoCipher.replaceFile(tempFile, targetFile);
        } catch (IOException e) {
            if (tempFile.exists()) {
                tempFile.delete();
            }
            throw e;
        } catch (Exception e) {
            if (tempFile.exists()) {
                tempFile.delete();
            }
            throw new IOException("Failed to write file atomically: " + e.getMessage(), e);
        }
    }

    /**
     * Clean up old temporary files (both .tmp and update_*.dat files)
     */
    private void cleanupOldTempFiles(File directory) {
        if (directory == null || !directory.exists()) return;

        File[] tempFiles = directory.listFiles(
            (dir, name) -> name.endsWith(".tmp") || (name.startsWith("update_") && name.endsWith(".dat"))
        );
        if (tempFiles != null) {
            long oneHourAgo = System.currentTimeMillis() - 3600000;
            for (File tempFile : tempFiles) {
                if (tempFile.lastModified() < oneHourAgo) {
                    tempFile.delete();
                }
            }
        }
    }

    private void cleanupOrphanedAssetTemps(final File directory) {
        if (directory == null || !directory.isDirectory()) {
            return;
        }
        final File[] children = directory.listFiles();
        if (children == null) {
            return;
        }
        final long oneHourAgo = System.currentTimeMillis() - 3600000;
        for (final File child : children) {
            if (child.isDirectory()) {
                cleanupOrphanedAssetTemps(child);
                continue;
            }
            final String name = child.getName();
            final boolean orphanedAssetTemp = name.startsWith("capgo_asset_") && name.endsWith(".tmp");
            final boolean orphanedBackup = name.startsWith(".capgo_bak_");
            if ((orphanedAssetTemp || orphanedBackup) && child.lastModified() < oneHourAgo) {
                child.delete();
            }
        }
    }
}
