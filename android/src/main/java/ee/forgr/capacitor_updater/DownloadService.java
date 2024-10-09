/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.content.Intent;
import android.util.Log;
import com.android.volley.DefaultRetryPolicy;
import com.android.volley.NetworkResponse;
import com.android.volley.Request;
import com.android.volley.Response;
import com.android.volley.toolbox.HttpHeaderParser;
import com.android.volley.toolbox.Volley;
import java.io.*;
import java.io.FileInputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import org.brotli.dec.BrotliInputStream;
import org.json.JSONArray;
import org.json.JSONObject;

public class DownloadService extends IntentService {

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

  public DownloadService() {
    super("Background DownloadService");
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
    String manifestString = intent.getStringExtra(MANIFEST);

    Log.d("DownloadService", "onHandleIntent" + manifestString);
    if (manifestString != null) {
      handleManifestDownload(
        id,
        documentsDir,
        dest,
        version,
        sessionKey,
        manifestString
      );
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
      Log.d("DownloadService", "handleManifestDownload");
      JSONArray manifest = new JSONArray(manifestString);
      File destFolder = new File(documentsDir, dest);
      File cacheFolder = new File(
        getApplicationContext().getCacheDir(),
        "capgo_downloads"
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
      int threadCount = Math.min(
        Runtime.getRuntime().availableProcessors() * 2,
        32
      );
      ExecutorService executor = Executors.newFixedThreadPool(threadCount);
      CompletableFuture<Void>[] futures = new CompletableFuture[totalFiles];

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

        futures[i] = CompletableFuture.runAsync(
          () -> {
            try {
              if (cacheFile.exists()) {
                if (verifyChecksum(cacheFile, fileHash)) {
                  copyFile(cacheFile, targetFile);
                  Log.d("DownloadService", "already cached " + fileName);
                } else {
                  cacheFile.delete();
                  downloadAndVerify(
                    downloadUrl,
                    targetFile,
                    cacheFile,
                    fileHash,
                    id
                  );
                }
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
              Log.e("DownloadService", "Error processing file: " + fileName, e);
              hasError.set(true);
            }
          },
          executor
        );
      }

      // Wait for all downloads to complete
      CompletableFuture.allOf(futures).join();

      executor.shutdown();

      if (hasError.get()) {
        throw new IOException("One or more files failed to download");
      }

      publishResults(dest, id, version, "", sessionKey, "", true);
    } catch (Exception e) {
      Log.e("DownloadService", "Error in handleManifestDownload", e);
      publishResults("", id, version, "", sessionKey, e.getMessage(), true);
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
    Log.d("DownloadService", "downloadAndVerify " + downloadUrl);
    URL url = new URL(downloadUrl);
    HttpURLConnection connection = (HttpURLConnection) url.openConnection();
    connection.setRequestMethod("GET");

    // Create a temporary file for the compressed data
    File compressedFile = new File(
      getApplicationContext().getCacheDir(),
      "temp_" + targetFile.getName() + ".br"
    );

    try (
      InputStream inputStream = connection.getInputStream();
      FileOutputStream compressedFos = new FileOutputStream(compressedFile)
    ) {
      byte[] buffer = new byte[8192];
      int bytesRead;
      while ((bytesRead = inputStream.read(buffer)) != -1) {
        compressedFos.write(buffer, 0, bytesRead);
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
      // Copy the downloaded file to cache if checksum is correct
      copyFile(targetFile, cacheFile);
      Log.d("DownloadService", "copied to cache " + targetFile.getName());
    } else {
      targetFile.delete();
      throw new IOException(
        "Checksum verification failed for " +
        targetFile.getName() +
        " " +
        expectedHash +
        " " +
        actualHash
      );
    }
  }

  // Custom request for handling input stream
  private class InputStreamVolleyRequest extends Request<byte[]> {

    private final Response.Listener<byte[]> mListener;

    public InputStreamVolleyRequest(
      int method,
      String mUrl,
      Response.Listener<byte[]> listener,
      Response.ErrorListener errorListener
    ) {
      super(method, mUrl, errorListener);
      mListener = listener;
    }

    @Override
    protected void deliverResponse(byte[] response) {
      mListener.onResponse(response);
    }

    @Override
    protected Response<byte[]> parseNetworkResponse(NetworkResponse response) {
      byte[] responseData = response.data;
      return Response.success(
        responseData,
        HttpHeaderParser.parseCacheHeaders(response)
      );
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
}
