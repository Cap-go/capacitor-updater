/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.content.Intent;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.nio.channels.FileChannel;
import java.util.Objects;
import org.json.JSONArray;
import org.json.JSONException;
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
    String manifestString = intent.getStringExtra("MANIFEST");

    if (manifestString != null) {
      handleManifestDownload(id, documentsDir, version, sessionKey, manifestString);
    } else {
      handleSingleFileDownload(url, id, documentsDir, dest, version, sessionKey, checksum);
    }
  }

  private void handleManifestDownload(String id, String documentsDir, String version, String sessionKey, String manifestString) {
    try {
        JSONArray manifest = new JSONArray(manifestString);
        File destFolder = new File(documentsDir, id);
        File cacheFolder = new File(documentsDir, "capgo_downloads");
        destFolder.mkdirs();
        cacheFolder.mkdirs();

        long totalBytes = 0;
        long downloadedBytes = 0;

        // Calculate total bytes to download (only for files not in cache)
        for (int i = 0; i < manifest.length(); i++) {
            JSONObject entry = manifest.getJSONObject(i);
            String fileName = entry.getString("file_name");
            String fileHash = entry.getString("file_hash");
            String downloadUrl = entry.getString("download_url");

            File cacheFile = new File(cacheFolder, fileHash + "_" + new File(fileName).getName());
            if (!cacheFile.exists()) {
                URL url = new URL(downloadUrl);
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                totalBytes += connection.getContentLength();
                connection.disconnect();
            }
        }

        for (int i = 0; i < manifest.length(); i++) {
            JSONObject entry = manifest.getJSONObject(i);
            String fileName = entry.getString("file_name");
            String fileHash = entry.getString("file_hash");
            String downloadUrl = entry.getString("download_url");

            File targetFile = new File(destFolder, fileName);
            File cacheFile = new File(cacheFolder, fileHash + "_" + new File(fileName).getName());
            targetFile.getParentFile().mkdirs();

            if (cacheFile.exists()) {
                // File exists in cache, copy to destination
                FileInputStream inStream = new FileInputStream(cacheFile);
                FileOutputStream outStream = new FileOutputStream(targetFile);
                FileChannel inChannel = inStream.getChannel();
                FileChannel outChannel = outStream.getChannel();
                inChannel.transferTo(0, inChannel.size(), outChannel);
                inStream.close();
                outStream.close();
                
                downloadedBytes += cacheFile.length();
                int percent = calcTotalPercent(downloadedBytes, totalBytes);
                notifyDownload(id, percent);
            } else {
                // File not in cache, download it
                URL url = new URL(downloadUrl);
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                connection.connect();

                if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) {
                    throw new IOException("Server returned HTTP " + connection.getResponseCode() 
                        + " " + connection.getResponseMessage());
                }

                FileOutputStream fileOutput = new FileOutputStream(cacheFile);
                InputStream inputStream = connection.getInputStream();

                byte[] buffer = new byte[4096];
                int bytesRead;
                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    fileOutput.write(buffer, 0, bytesRead);
                    downloadedBytes += bytesRead;
                    int percent = calcTotalPercent(downloadedBytes, totalBytes);
                    notifyDownload(id, percent);
                }

                fileOutput.close();
                inputStream.close();
                connection.disconnect();

                // Copy from cache to destination
                FileInputStream inStream = new FileInputStream(cacheFile);
                FileOutputStream outStream = new FileOutputStream(targetFile);
                FileChannel inChannel = inStream.getChannel();
                FileChannel outChannel = outStream.getChannel();
                inChannel.transferTo(0, inChannel.size(), outChannel);
                inStream.close();
                outStream.close();
            }

            // Here you might want to verify the fileHash
        }

        publishResults(destFolder.getPath(), id, version, "", sessionKey, "");
    } catch (Exception e) {
        e.printStackTrace();
        publishResults("", id, version, "", sessionKey, e.getMessage());
    }
  }

  private void handleSingleFileDownload(String url, String id, String documentsDir, String dest, String version, String sessionKey, String checksum) {
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
        publishResults(dest, id, version, checksum, sessionKey, "");
      } else {
        infoFile.delete();
      }
      httpConn.disconnect();
    } catch (OutOfMemoryError e) {
      e.printStackTrace();
      publishResults("", id, version, checksum, sessionKey, "low_mem_fail");
    } catch (Exception e) {
      e.printStackTrace();
      publishResults(
        "",
        id,
        version,
        checksum,
        sessionKey,
        e.getLocalizedMessage()
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
    String error
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
    sendBroadcast(intent);
  }
}
