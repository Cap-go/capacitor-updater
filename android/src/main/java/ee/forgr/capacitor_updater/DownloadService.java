/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import java.io.*;
import java.io.FileInputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
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

public class DownloadService extends IntentService {

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
  public static final String NOTIFICATION = "service receiver";
  public static final String PERCENTDOWNLOAD = "percent receiver";
  public static final String IS_MANIFEST = "is_manifest";
  public static final String MANIFEST = "manifest";
  private static final String UPDATE_FILE = "update.dat";
  private static final int NOTIFICATION_ID = 1;
  private static final long NOTIFICATION_DELAY_MS = 4000; // 4 seconds
  private static final String CHANNEL_ID = "CapacitorUpdaterChannel";
  private static final String CHANNEL_NAME = "Capacitor Updater";
  private static final String CHANNEL_DESCRIPTION =
    "Notifications for app updates";

  private final OkHttpClient client = new OkHttpClient.Builder()
    .protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1))
    .build();
  private Handler handler = new Handler(Looper.getMainLooper());
  private Runnable notificationRunnable;
  private boolean isNotificationShown = false;
  private PowerManager.WakeLock wakeLock;

  public DownloadService() {
    super("Background DownloadService");
  }

  @Override
  public void onCreate() {
    super.onCreate();
    this.startForegroundService();
  }

  @Override
  public void onDestroy() {
    super.onDestroy();
    handler.removeCallbacks(notificationRunnable);
    Log.w(TAG + " DownloadService", "DownloadService killed/destroyed");
  }

  private void startForegroundService() {
    isNotificationShown = true;
    String channelId = createNotificationChannelForDownload();

    Notification.Builder builder = new Notification.Builder(this, channelId)
      .setContentTitle("Downloading Update")
      .setContentText("Download in progress")
      .setSmallIcon(android.R.drawable.stat_sys_download)
      .setOngoing(true)
      .setPriority(Notification.PRIORITY_MIN)
      .setCategory(Notification.CATEGORY_SERVICE)
      .setAutoCancel(false);

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      startForeground(
        NOTIFICATION_ID,
        builder.build(),
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
      );
    } else {
      startForeground(NOTIFICATION_ID, builder.build());
    }
  }

  private String createNotificationChannelForDownload() {
    String channelId = "capacitor_updater_channel";
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
        channelId,
        "Capacitor Updater Downloads",
        NotificationManager.IMPORTANCE_MIN // // High importance to keep service alive
      );
      NotificationManager manager = getSystemService(NotificationManager.class);
      manager.createNotificationChannel(channel);
    }
    return channelId;
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

  @Override
  protected void onHandleIntent(Intent intent) {
    assert intent != null;
    String url = intent.getStringExtra(URL);
    String id = intent.getStringExtra(ID);
    String documentsDir = intent.getStringExtra(DOCDIR);
    String dest = intent.getStringExtra(FILEDEST);
    String version = intent.getStringExtra(VERSION);
    String sessionKey = intent.getStringExtra(SESSIONKEY);
    String checksum = intent.getStringExtra(CHECKSUM);
    boolean isManifest = intent.getBooleanExtra(IS_MANIFEST, false);

    Log.d(TAG + " DownloadService", "onHandleIntent isManifest: " + isManifest);
    if (isManifest) {
      JSONArray manifest = DataManager.getInstance().getAndClearManifest();
      if (manifest != null) {
        handleManifestDownload(
          id,
          documentsDir,
          dest,
          version,
          sessionKey,
          manifest.toString()
        );
      } else {
        Log.e(TAG + " DownloadService", "Manifest is null");
        publishResults(
          "",
          id,
          version,
          checksum,
          sessionKey,
          "Manifest is null",
          false
        );
      }
    } else {
      handleSingleFileDownload(
        url,
        id,
        documentsDir,
        dest,
        version,
        sessionKey,
        checksum
      );
    }
  }

  private void handleManifestDownload(
    String id,
    String documentsDir,
    String dest,
    String version,
    String sessionKey,
    String manifestString
  ) {
    try {
      Log.d(TAG + " DownloadService", "handleManifestDownload");
      JSONArray manifest = new JSONArray(manifestString);
      File destFolder = new File(documentsDir, dest);
      File cacheFolder = new File(
        getApplicationContext().getCacheDir(),
        "capgo_downloads"
      );
      File builtinFolder = new File(
        getApplicationContext().getFilesDir(),
        "public"
      );

      // Ensure directories are created
      if (!destFolder.exists() && !destFolder.mkdirs()) {
        throw new IOException(
          "Failed to create destination directory: " +
          destFolder.getAbsolutePath()
        );
      }
      if (!cacheFolder.exists() && !cacheFolder.mkdirs()) {
        throw new IOException(
          "Failed to create cache directory: " + cacheFolder.getAbsolutePath()
        );
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

        File targetFile = new File(destFolder, fileName);
        File cacheFile = new File(
          cacheFolder,
          fileHash + "_" + new File(fileName).getName()
        );
        File builtinFile = new File(builtinFolder, fileName);

        // Ensure parent directories of the target file exist
        if (
          !targetFile.getParentFile().exists() &&
          !targetFile.getParentFile().mkdirs()
        ) {
          throw new IOException(
            "Failed to create parent directory for: " +
            targetFile.getAbsolutePath()
          );
        }

        Future<?> future = executor.submit(() -> {
          try {
            if (builtinFile.exists() && verifyChecksum(builtinFile, fileHash)) {
              copyFile(builtinFile, targetFile);
              Log.d(TAG + " DownloadService", "using builtin file " + fileName);
            } else if (
              cacheFile.exists() && verifyChecksum(cacheFile, fileHash)
            ) {
              copyFile(cacheFile, targetFile);
              Log.d(TAG + " DownloadService", "already cached " + fileName);
            } else {
              downloadAndVerify(
                downloadUrl,
                targetFile,
                cacheFile,
                fileHash,
                id
              );
            }

            long completed = completedFiles.incrementAndGet();
            int percent = calcTotalPercent(completed, totalFiles);
            notifyDownload(id, percent);
          } catch (Exception e) {
            Log.e(
              TAG + " DownloadService",
              "Error processing file: " + fileName,
              e
            );
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
          Log.e(TAG + " DownloadService", "Error waiting for download", e);
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
        throw new IOException("One or more files failed to download");
      }

      publishResults(dest, id, version, "", sessionKey, "", true);
    } catch (Exception e) {
      Log.e(TAG + " DownloadService", "Error in handleManifestDownload", e);
      publishResults("", id, version, "", sessionKey, e.getMessage(), true);
    }
    stopForegroundIfNeeded();
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
      HttpURLConnection httpConn = (HttpURLConnection) u.openConnection();

      // Reading progress file (if exist)
      long downloadedBytes = 0;

      if (infoFile.exists() && tempFile.exists()) {
        try (
          BufferedReader reader = new BufferedReader(new FileReader(infoFile))
        ) {
          String updateVersion = reader.readLine();
          if (!updateVersion.equals(version)) {
            clearDownloadData(documentsDir);
            downloadedBytes = 0;
          } else {
            downloadedBytes = tempFile.length();
          }
        }
      } else {
        clearDownloadData(documentsDir);
        downloadedBytes = 0;
      }

      if (downloadedBytes > 0) {
        httpConn.setRequestProperty("Range", "bytes=" + downloadedBytes + "-");
      }

      int responseCode = httpConn.getResponseCode();

      if (
        responseCode == HttpURLConnection.HTTP_OK ||
        responseCode == HttpURLConnection.HTTP_PARTIAL
      ) {
        String contentType = httpConn.getContentType();
        long contentLength = httpConn.getContentLength() + downloadedBytes;

        InputStream inputStream = httpConn.getInputStream();
        FileOutputStream outputStream = new FileOutputStream(
          tempFile,
          downloadedBytes > 0
        );
        if (downloadedBytes == 0) {
          try (
            BufferedWriter writer = new BufferedWriter(new FileWriter(infoFile))
          ) {
            writer.write(String.valueOf(version));
          }
        }
        // Updating the info file
        try (
          BufferedWriter writer = new BufferedWriter(new FileWriter(infoFile))
        ) {
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
            notifyDownload(id, lastNotifiedPercent);
          }
        }

        outputStream.close();
        inputStream.close();

        // Rename the temp file with the final name (dest)
        tempFile.renameTo(new File(documentsDir, dest));
        infoFile.delete();
        publishResults(dest, id, version, checksum, sessionKey, "", false);
      } else {
        infoFile.delete();
      }
      httpConn.disconnect();
    } catch (OutOfMemoryError e) {
      e.printStackTrace();
      publishResults(
        "",
        id,
        version,
        checksum,
        sessionKey,
        "low_mem_fail",
        false
      );
    } catch (Exception e) {
      e.printStackTrace();
      publishResults(
        "",
        id,
        version,
        checksum,
        sessionKey,
        e.getLocalizedMessage(),
        false
      );
    }
    stopForegroundIfNeeded();
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
      e.printStackTrace();
    }
  }

  private void notifyDownload(String id, int percent) {
    Intent intent = new Intent(PERCENTDOWNLOAD);
    intent.setPackage(getPackageName());
    intent.putExtra(ID, id);
    intent.putExtra(PERCENT, percent);
    sendBroadcast(intent);
  }

  private void publishResults(
    String dest,
    String id,
    String version,
    String checksum,
    String sessionKey,
    String error,
    boolean isManifest
  ) {
    Intent intent = new Intent(NOTIFICATION);
    intent.setPackage(getPackageName());
    if (dest != null && !dest.isEmpty()) {
      intent.putExtra(FILEDEST, dest);
    }
    intent.putExtra(ERROR, error);
    intent.putExtra(ID, id);
    intent.putExtra(VERSION, version);
    intent.putExtra(SESSIONKEY, sessionKey);
    intent.putExtra(CHECKSUM, checksum);
    intent.putExtra(IS_MANIFEST, isManifest);
    sendBroadcast(intent);
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
    String id
  ) throws Exception {
    Log.d(TAG + " DownloadService", "downloadAndVerify " + downloadUrl);

    Request request = new Request.Builder().url(downloadUrl).build();

    // Create a temporary file for the compressed data
    File compressedFile = new File(
      getApplicationContext().getCacheDir(),
      "temp_" + targetFile.getName() + ".br"
    );

    try (Response response = client.newCall(request).execute()) {
      if (!response.isSuccessful()) {
        throw new IOException("Unexpected response code: " + response.code());
      }

      // Download compressed file
      try (
        ResponseBody responseBody = response.body();
        FileOutputStream compressedFos = new FileOutputStream(compressedFile)
      ) {
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

      // Decompress the file
      try (
        FileInputStream fis = new FileInputStream(compressedFile);
        BrotliInputStream brotliInputStream = new BrotliInputStream(fis);
        FileOutputStream fos = new FileOutputStream(targetFile)
      ) {
        byte[] buffer = new byte[8192];
        int len;
        while ((len = brotliInputStream.read(buffer)) != -1) {
          fos.write(buffer, 0, len);
        }
      }

      // Delete the compressed file
      compressedFile.delete();

      // Verify checksum
      String actualHash = calculateFileHash(targetFile);
      if (actualHash.equals(expectedHash)) {
        // Only cache if checksum is correct
        copyFile(targetFile, cacheFile);
      } else {
        targetFile.delete();
        throw new IOException(
          "Checksum verification failed for " + targetFile.getName()
        );
      }
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

  private void stopForegroundIfNeeded() {
    handler.removeCallbacks(notificationRunnable);
    if (isNotificationShown) {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        stopForeground(STOP_FOREGROUND_REMOVE);
      } else {
        stopForeground(true);
      }
    }
  }

  private void createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
        CHANNEL_ID,
        CHANNEL_NAME,
        NotificationManager.IMPORTANCE_MAX
      );
      channel.setDescription(CHANNEL_DESCRIPTION);
      NotificationManager notificationManager = getSystemService(
        NotificationManager.class
      );
      notificationManager.createNotificationChannel(channel);
    }
  }

  private void showNotification(String text, int progress) {
    Notification.Builder builder = new Notification.Builder(this, CHANNEL_ID)
      .setSmallIcon(android.R.drawable.stat_sys_download)
      .setContentTitle("App Update")
      .setContentText(text)
      // .setPriority(Notification.PRIORITY_LOW)
      .setOngoing(true);

    if (progress > 0) {
      builder.setProgress(100, progress, false);
    }

    startForeground(NOTIFICATION_ID, builder.build());
  }

  // Update the notification progress
  private void updateNotificationProgress(int progress) {
    showNotification("Downloading OTA update... " + progress + "%", progress);
  }

  // When download completes or fails
  private void stopForegroundService() {
    stopForeground(true);
    stopSelf();
  }
}
