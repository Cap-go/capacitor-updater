/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.content.Context;
import android.util.Log;
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
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.brotli.dec.BrotliInputStream;
import org.json.JSONArray;
import org.json.JSONObject;

public class DownloadService extends Worker {

    public static final String TAG = "Capacitor-updater";
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
    private static final String UPDATE_FILE = "update.dat";

    private final OkHttpClient client = new OkHttpClient.Builder().protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1)).build();

    public DownloadService(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
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

            Log.d(TAG, "doWork isManifest: " + isManifest);

            if (isManifest) {
                JSONArray manifest = DataManager.getInstance().getAndClearManifest();
                if (manifest != null) {
                    handleManifestDownload(id, documentsDir, dest, version, sessionKey, publicKey, manifest.toString());
                    return createSuccessResult(dest, version, sessionKey, checksum, true);
                } else {
                    Log.e(TAG, "Manifest is null");
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
            Log.d(TAG, "handleManifestDownload");
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
                        fileHash = CryptoCipherV2.decryptChecksum(fileHash, publicKey);
                    } catch (Exception e) {
                        Log.e(TAG, "Error decrypting checksum for " + fileName + "fileHash: " + fileHash);
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
                    Log.e(TAG, "Failed to create parent directory for: " + targetFile.getAbsolutePath());
                    hasError.set(true);
                    continue;
                }

                Future<?> future = executor.submit(() -> {
                    try {
                        if (builtinFile.exists() && verifyChecksum(builtinFile, finalFileHash)) {
                            copyFile(builtinFile, targetFile);
                            Log.d(TAG, "using builtin file " + fileName);
                        } else if (cacheFile.exists() && verifyChecksum(cacheFile, finalFileHash)) {
                            copyFile(cacheFile, targetFile);
                            Log.d(TAG, "already cached " + fileName);
                        } else {
                            downloadAndVerify(downloadUrl, targetFile, cacheFile, finalFileHash, sessionKey, publicKey);
                        }

                        long completed = completedFiles.incrementAndGet();
                        int percent = calcTotalPercent(completed, totalFiles);
                        setProgress(percent);
                    } catch (Exception e) {
                        Log.e(TAG, "Error processing file: " + fileName, e);
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
                    Log.e(TAG, "Error waiting for download", e);
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
                Log.e(TAG, "One or more files failed to download");
                throw new IOException("One or more files failed to download");
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in handleManifestDownload", e);
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
        File target = new File(documentsDir, dest);
        File infoFile = new File(documentsDir, UPDATE_FILE); // The file where the download progress (how much byte
        // downloaded) is stored
        File tempFile = new File(documentsDir, "temp" + ".tmp"); // Temp file, where the downloaded data is stored
        try {
            URL u = new URL(url);
            HttpURLConnection httpConn = null;
            try {
                httpConn = (HttpURLConnection) u.openConnection();

                // Reading progress file (if exist)
                long downloadedBytes = 0;

                if (infoFile.exists() && tempFile.exists()) {
                    try (BufferedReader reader = new BufferedReader(new FileReader(infoFile))) {
                        String updateVersion = reader.readLine();
                        if (updateVersion != null && !updateVersion.equals(version)) {
                            clearDownloadData(documentsDir);
                        } else {
                            downloadedBytes = tempFile.length();
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

                    try (
                        InputStream inputStream = httpConn.getInputStream();
                        FileOutputStream outputStream = new FileOutputStream(tempFile, downloadedBytes > 0)
                    ) {
                        if (downloadedBytes == 0) {
                            try (BufferedWriter writer = new BufferedWriter(new FileWriter(infoFile))) {
                                writer.write(String.valueOf(version));
                            }
                        }
                        // Updating the info file
                        try (BufferedWriter writer = new BufferedWriter(new FileWriter(infoFile))) {
                            writer.write(String.valueOf(version));
                        }

                        int bytesRead = -1;
                        byte[] buffer = new byte[4096];
                        int lastNotifiedPercent = 0;
                        while ((bytesRead = inputStream.read(buffer)) != -1) {
                            outputStream.write(buffer, 0, bytesRead);
                            downloadedBytes += bytesRead;
                            // Saving progress (flushing every 100 Ko)
                            if (downloadedBytes % 102400 == 0) {
                                outputStream.flush();
                            }
                            // Computing percentage
                            int percent = calcTotalPercent(downloadedBytes, contentLength);
                            while (lastNotifiedPercent + 10 <= percent) {
                                lastNotifiedPercent += 10;
                                // Artificial delay using CPU-bound calculation to take ~5 seconds
                                double result = 0;
                                setProgress(lastNotifiedPercent);
                            }
                        }

                        outputStream.close();
                        inputStream.close();

                        // Rename the temp file with the final name (dest)
                        tempFile.renameTo(new File(documentsDir, dest));
                        infoFile.delete();
                    }
                } else {
                    infoFile.delete();
                }
            } finally {
                if (httpConn != null) {
                    httpConn.disconnect();
                }
            }
        } catch (OutOfMemoryError e) {
            throw new RuntimeException("low_mem_fail");
        } catch (Exception e) {
            throw new RuntimeException(e.getLocalizedMessage());
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
            Log.e(TAG, "Error in clearDownloadData", e);
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
        Log.d(TAG, "downloadAndVerify " + downloadUrl);

        Request request = new Request.Builder().url(downloadUrl).build();

        // Check if file is a Brotli file
        boolean isBrotli = targetFile.getName().endsWith(".br");

        // Create final target file with .br extension removed if it's a Brotli file
        File finalTargetFile = isBrotli
            ? new File(targetFile.getParentFile(), targetFile.getName().substring(0, targetFile.getName().length() - 3))
            : targetFile;

        // Create a temporary file for the compressed data
        File compressedFile = new File(getApplicationContext().getCacheDir(), "temp_" + targetFile.getName() + ".tmp");

        try (Response response = client.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                throw new IOException("Unexpected response code: " + response.code());
            }

            // Download compressed file
            try (ResponseBody responseBody = response.body(); FileOutputStream compressedFos = new FileOutputStream(compressedFile)) {
                if (responseBody == null) {
                    throw new IOException("Response body is null");
                }

                byte[] buffer = new byte[8192];
                int bytesRead;
                try (InputStream inputStream = responseBody.byteStream()) {
                    while ((bytesRead = inputStream.read(buffer)) != -1) {
                        compressedFos.write(buffer, 0, bytesRead);
                    }
                }
            }

            if (!publicKey.isEmpty() && sessionKey != null && !sessionKey.isEmpty()) {
                Log.d(CapacitorUpdater.TAG + " DLSrv", "Decrypting file " + targetFile.getName());
                CryptoCipherV2.decryptFile(compressedFile, publicKey, sessionKey);
            }

            // Only decompress if file has .br extension
            if (isBrotli) {
                // Use new decompression method
                byte[] compressedData = Files.readAllBytes(compressedFile.toPath());
                byte[] decompressedData = decompressBrotli(compressedData, targetFile.getName());
                Files.write(finalTargetFile.toPath(), decompressedData);
            } else {
                // Just copy the file without decompression
                Files.copy(compressedFile.toPath(), finalTargetFile.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            }

            // Delete the compressed file
            compressedFile.delete();
            String calculatedHash = CryptoCipherV2.calcChecksum(finalTargetFile);

            // Verify checksum
            if (calculatedHash.equals(expectedHash)) {
                // Only cache if checksum is correct
                copyFile(finalTargetFile, cacheFile);
            } else {
                finalTargetFile.delete();
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
        FileInputStream fis = new FileInputStream(file);
        byte[] byteArray = new byte[1024];
        int bytesCount = 0;

        while ((bytesCount = fis.read(byteArray)) != -1) {
            digest.update(byteArray, 0, bytesCount);
        }
        fis.close();

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
            Log.e(TAG, "Error: Null data received for " + fileName);
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
                Log.e(TAG, "Error: Malformed data for " + fileName);
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
            Log.e(TAG, "Error: Brotli process failed for " + fileName + ". Status: " + e.getMessage());
            // Add hex dump for debugging
            StringBuilder hexDump = new StringBuilder();
            for (int i = 0; i < Math.min(32, data.length); i++) {
                hexDump.append(String.format("%02x ", data[i]));
            }
            Log.e(TAG, "Error: Raw data (" + fileName + "): " + hexDump.toString());
            throw e;
        }
    }
}
