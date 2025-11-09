/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.work.Data;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import java.io.*;
import java.io.FileInputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.Buffer;
import okio.BufferedSink;
import okio.BufferedSource;
import okio.Okio;
import okio.Source;
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
    public static final String STATS_URL = "stats_url";
    public static final String DEVICE_ID = "device_id";
    public static final String CUSTOM_ID = "custom_id";
    public static final String VERSION_BUILD = "version_build";
    public static final String VERSION_CODE = "version_code";
    public static final String VERSION_OS = "version_os";
    public static final String DEFAULT_CHANNEL = "default_channel";
    public static final String IS_PROD = "is_prod";
    public static final String IS_EMULATOR = "is_emulator";
    private static final String UPDATE_FILE = "update.dat";

    // Shared OkHttpClient to prevent resource leaks
    protected static OkHttpClient sharedClient;
    private static String currentAppId = "unknown";
    private static String currentPluginVersion = "unknown";
    private static String currentVersionOs = "unknown";

    // Initialize shared client with User-Agent interceptor
    static {
        sharedClient = new OkHttpClient.Builder()
            .protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1))
            .addInterceptor(chain -> {
                Request originalRequest = chain.request();
                String userAgent =
                    "CapacitorUpdater/" +
                    (currentPluginVersion != null ? currentPluginVersion : "unknown") +
                    " (" +
                    (currentAppId != null ? currentAppId : "unknown") +
                    ") android/" +
                    (currentVersionOs != null ? currentVersionOs : "unknown");
                Request requestWithUserAgent = originalRequest.newBuilder().header("User-Agent", userAgent).build();
                return chain.proceed(requestWithUserAgent);
            })
            .build();
    }

    // Method to update User-Agent values
    public static void updateUserAgent(String appId, String pluginVersion, String versionOs) {
        currentAppId = appId != null ? appId : "unknown";
        currentPluginVersion = pluginVersion != null ? pluginVersion : "unknown";
        currentVersionOs = versionOs != null ? versionOs : "unknown";
        logger.debug(
            "Updated User-Agent: CapacitorUpdater/" + currentPluginVersion + " (" + currentAppId + ") android/" + currentVersionOs
        );
    }

    public DownloadService(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
        // Use shared client - no need to create new instances

        // Clean up old temporary files on service initialization
        cleanupOldTempFiles(getApplicationContext().getCacheDir());
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
                    handleManifestDownload(id, documentsDir, dest, version, sessionKey, publicKey, manifest.toString());
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

            sharedClient
                .newCall(request)
                .enqueue(
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
                            } catch (Exception ignored) {} finally {
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
        String manifestString
    ) {
        try {
            logger.debug("handleManifestDownload");

            // Send stats for manifest download start
            sendStatsAsync("download_manifest_start", version);

            JSONArray manifest = new JSONArray(manifestString);
            File destFolder = new File(documentsDir, dest);
            File cacheFolder = new File(getApplicationContext().getCacheDir(), "capgo_downloads");
            File builtinFolder = new File(getApplicationContext().getFilesDir(), "public");

            // Ensure directories are created
            if (!destFolder.exists() && !destFolder.mkdirs()) {
                throw new IOException("Failed to create destination directory: " + destFolder.getAbsolutePath());
            }
            if (!cacheFolder.exists() && !cacheFolder.mkdirs()) {
                throw new IOException("Failed to create cache directory: " + cacheFolder.getAbsolutePath());
            }

            int totalFiles = manifest.length();
            final AtomicLong completedFiles = new AtomicLong(0);
            final AtomicBoolean hasError = new AtomicBoolean(false);

            // Use more threads for I/O-bound operations
            int threadCount = Math.min(64, Math.max(32, totalFiles));
            ExecutorService executor = Executors.newFixedThreadPool(threadCount);
            List<Future<?>> futures = new ArrayList<>();

            for (int i = 0; i < totalFiles; i++) {
                JSONObject entry = manifest.getJSONObject(i);
                String fileName = entry.getString("file_name");
                String fileHash = entry.getString("file_hash");
                String downloadUrl = entry.getString("download_url");

                if (!publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty()) {
                    try {
                        fileHash = CryptoCipher.decryptChecksum(fileHash, publicKey);
                    } catch (Exception e) {
                        logger.error("Error decrypting checksum for " + fileName + "fileHash: " + fileHash);
                        hasError.set(true);
                        continue;
                    }
                }

                final String finalFileHash = fileHash;
                File targetFile = new File(destFolder, fileName);
                File cacheFile = new File(cacheFolder, finalFileHash + "_" + new File(fileName).getName());
                File builtinFile = new File(builtinFolder, fileName);

                // Ensure parent directories of the target file exist
                if (!Objects.requireNonNull(targetFile.getParentFile()).exists() && !targetFile.getParentFile().mkdirs()) {
                    logger.error("Failed to create parent directory for: " + targetFile.getAbsolutePath());
                    hasError.set(true);
                    continue;
                }

                Future<?> future = executor.submit(() -> {
                    try {
                        if (builtinFile.exists() && verifyChecksum(builtinFile, finalFileHash)) {
                            copyFile(builtinFile, targetFile);
                            logger.debug("using builtin file " + fileName);
                        } else if (cacheFile.exists() && verifyChecksum(cacheFile, finalFileHash)) {
                            copyFile(cacheFile, targetFile);
                            logger.debug("already cached " + fileName);
                        } else {
                            downloadAndVerify(downloadUrl, targetFile, cacheFile, finalFileHash, sessionKey, publicKey);
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
        File infoFile = new File(documentsDir, UPDATE_FILE);
        File tempFile = new File(documentsDir, "temp" + ".tmp");

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
                        clearDownloadData(documentsDir);
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
                clearDownloadData(documentsDir);
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

    private void clearDownloadData(String docDir) {
        File tempFile = new File(docDir, "temp" + ".tmp");
        File infoFile = new File(docDir, UPDATE_FILE);
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

    private void copyFile(File source, File dest) throws IOException {
        try (
            FileInputStream inStream = new FileInputStream(source);
            FileOutputStream outStream = new FileOutputStream(dest);
            FileChannel inChannel = inStream.getChannel();
            FileChannel outChannel = outStream.getChannel()
        ) {
            inChannel.transferTo(0, inChannel.size(), outChannel);
        }
    }

    private void downloadAndVerify(
        String downloadUrl,
        File targetFile,
        File cacheFile,
        String expectedHash,
        String sessionKey,
        String publicKey
    ) throws Exception {
        logger.debug("downloadAndVerify " + downloadUrl);

        Request request = new Request.Builder().url(downloadUrl).build();

        // Check if file is a Brotli file
        boolean isBrotli = targetFile.getName().endsWith(".br");

        // Create final target file with .br extension removed if it's a Brotli file
        File finalTargetFile = isBrotli
            ? new File(targetFile.getParentFile(), targetFile.getName().substring(0, targetFile.getName().length() - 3))
            : targetFile;

        // Create a temporary file for the compressed data
        File compressedFile = new File(getApplicationContext().getCacheDir(), "temp_" + targetFile.getName() + ".tmp");

        try (Response response = sharedClient.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                sendStatsAsync("download_manifest_file_fail", getInputData().getString(VERSION) + ":" + finalTargetFile.getName());
                throw new IOException("Unexpected response code: " + response.code());
            }

            // Download compressed file atomically
            ResponseBody responseBody = response.body();
            if (responseBody == null) {
                throw new IOException("Response body is null");
            }

            // Use OkIO for atomic write
            writeFileAtomic(compressedFile, responseBody.byteStream(), null);

            if (!publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty()) {
                logger.debug("Decrypting file " + targetFile.getName());
                CryptoCipher.decryptFile(compressedFile, publicKey, sessionKey);
            }

            // Only decompress if file has .br extension
            if (isBrotli) {
                // Use new decompression method with atomic write
                try (FileInputStream fis = new FileInputStream(compressedFile)) {
                    byte[] compressedData = new byte[(int) compressedFile.length()];
                    fis.read(compressedData);
                    byte[] decompressedData;
                    try {
                        decompressedData = decompressBrotli(compressedData, targetFile.getName());
                    } catch (IOException e) {
                        sendStatsAsync(
                            "download_manifest_brotli_fail",
                            getInputData().getString(VERSION) + ":" + finalTargetFile.getName()
                        );
                        throw e;
                    }

                    // Write decompressed data atomically
                    try (java.io.ByteArrayInputStream bais = new java.io.ByteArrayInputStream(decompressedData)) {
                        writeFileAtomic(finalTargetFile, bais, null);
                    }
                }
            } else {
                // Just copy the file without decompression using atomic operation
                try (FileInputStream fis = new FileInputStream(compressedFile)) {
                    writeFileAtomic(finalTargetFile, fis, null);
                }
            }

            // Delete the compressed file
            compressedFile.delete();
            String calculatedHash = CryptoCipher.calcChecksum(finalTargetFile);

            // Verify checksum
            if (calculatedHash.equals(expectedHash)) {
                // Only cache if checksum is correct - use atomic copy
                try (FileInputStream fis = new FileInputStream(finalTargetFile)) {
                    writeFileAtomic(cacheFile, fis, expectedHash);
                }
            } else {
                finalTargetFile.delete();
                sendStatsAsync("download_manifest_checksum_fail", getInputData().getString(VERSION) + ":" + finalTargetFile.getName());
                throw new IOException(
                    "Checksum verification failed for: " +
                    downloadUrl +
                    " " +
                    targetFile.getName() +
                    " expected: " +
                    expectedHash +
                    " calculated: " +
                    calculatedHash
                );
            }
        } catch (Exception e) {
            throw new IOException("Error in downloadAndVerify: " + e.getMessage());
        }
    }

    private boolean verifyChecksum(File file, String expectedHash) {
        try {
            String actualHash = calculateFileHash(file);
            return actualHash.equals(expectedHash);
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

    private byte[] decompressBrotli(byte[] data, String fileName) throws IOException {
        // Validate input
        if (data == null) {
            logger.error("Error: Null data received for " + fileName);
            throw new IOException("Null data received");
        }

        // Handle empty files
        if (data.length == 0) {
            return new byte[0];
        }

        // Handle the special EMPTY_BROTLI_STREAM case
        if (data.length == 3 && data[0] == 0x1B && data[1] == 0x00 && data[2] == 0x06) {
            return new byte[0];
        }

        // For small files, check if it's a minimal Brotli wrapper
        if (data.length > 3) {
            try {
                // Handle our minimal wrapper pattern
                if (data[0] == 0x1B && data[1] == 0x00 && data[2] == 0x06 && data[data.length - 1] == 0x03) {
                    return Arrays.copyOfRange(data, 3, data.length - 1);
                }

                // Handle brotli.compress minimal wrapper (quality 0)
                if (data[0] == 0x0b && data[1] == 0x02 && data[2] == (byte) 0x80 && data[data.length - 1] == 0x03) {
                    return Arrays.copyOfRange(data, 3, data.length - 1);
                }
            } catch (ArrayIndexOutOfBoundsException e) {
                logger.error("Error: Malformed data for " + fileName);
                throw new IOException("Malformed data structure");
            }
        }

        // For all other cases, try standard decompression
        try (
            ByteArrayInputStream bis = new ByteArrayInputStream(data);
            BrotliInputStream brotliInputStream = new BrotliInputStream(bis);
            ByteArrayOutputStream bos = new ByteArrayOutputStream()
        ) {
            byte[] buffer = new byte[8192];
            int len;
            while ((len = brotliInputStream.read(buffer)) != -1) {
                bos.write(buffer, 0, len);
            }
            return bos.toByteArray();
        } catch (IOException e) {
            logger.error("Error: Brotli process failed for " + fileName + ". Status: " + e.getMessage());
            // Add hex dump for debugging
            StringBuilder hexDump = new StringBuilder();
            for (int i = 0; i < Math.min(32, data.length); i++) {
                hexDump.append(String.format("%02x ", data[i]));
            }
            logger.error("Error: Raw data (" + fileName + "): " + hexDump.toString());
            throw e;
        }
    }

    /**
     * Atomically write data to a file using OkIO
     */
    private void writeFileAtomic(File targetFile, InputStream inputStream, String expectedChecksum) throws IOException {
        File tempFile = new File(targetFile.getParent(), targetFile.getName() + ".tmp");

        try {
            // Write to temp file first using OkIO
            try (BufferedSink sink = Okio.buffer(Okio.sink(tempFile)); BufferedSource source = Okio.buffer(Okio.source(inputStream))) {
                sink.writeAll(source);
            }

            // Verify checksum if provided
            if (expectedChecksum != null && !expectedChecksum.isEmpty()) {
                String actualChecksum = CryptoCipher.calcChecksum(tempFile);
                if (!expectedChecksum.equalsIgnoreCase(actualChecksum)) {
                    tempFile.delete();
                    throw new IOException("Checksum verification failed");
                }
            }

            // Atomic rename (on same filesystem)
            Files.move(tempFile.toPath(), targetFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception e) {
            // Clean up temp file on error
            if (tempFile.exists()) {
                tempFile.delete();
            }
            throw new IOException("Failed to write file atomically: " + e.getMessage(), e);
        }
    }

    /**
     * Clean up old temporary files
     */
    private void cleanupOldTempFiles(File directory) {
        if (directory == null || !directory.exists()) return;

        File[] tempFiles = directory.listFiles((dir, name) -> name.endsWith(".tmp"));
        if (tempFiles != null) {
            long oneHourAgo = System.currentTimeMillis() - 3600000;
            for (File tempFile : tempFiles) {
                if (tempFile.lastModified() < oneHourAgo) {
                    tempFile.delete();
                }
            }
        }
    }
}
