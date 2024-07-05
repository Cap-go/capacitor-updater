package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.content.Intent;
import java.io.*;
import java.net.URL;
import java.net.URLConnection;
import java.util.Objects;
import java.nio.channels.FileChannel;
import java.net.HttpURLConnection;

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
  private static final String PROGRESS_FILE = "progress.dat";

  public DownloadService() {
    super("Background DownloadService");
  }

  private int calcTotalPercent(long downloadedBytes, int contentLength) {
    if (contentLength <= 0)
      return 0;
    return (int) (((double) downloadedBytes / contentLength) * 100);
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

    File target = new File(documentsDir, dest);
    File progressFile = new File(documentsDir, PROGRESS_FILE); // The file where the download progress (how much byte
                                                               // downloaded) is stored
    File tempFile = new File(documentsDir, "temp" + ".tmp"); // Temp file, where the downloaded data is stored
    try {
      URL u = new URL(url);
      HttpURLConnection httpConn = (HttpURLConnection) u.openConnection();

      // Reading progress file (if exist)
      long downloadedBytes = 0;
      if (progressFile.exists() && tempFile.exists()) {
        try (BufferedReader reader = new BufferedReader(new FileReader(progressFile))) {
          downloadedBytes = Long.parseLong(reader.readLine());
        }
      } else {
        tempFile.delete();
        progressFile.delete();
        progressFile.createNewFile();
        tempFile.createNewFile();
        downloadedBytes = 0;
      }

      if (downloadedBytes > 0) {
        httpConn.setRequestProperty("Range", "bytes=" + downloadedBytes + "-");
      }

      int responseCode = httpConn.getResponseCode();

      if (responseCode == HttpURLConnection.HTTP_OK || responseCode == HttpURLConnection.HTTP_PARTIAL) {
        String contentType = httpConn.getContentType();
        int contentLength = httpConn.getContentLength() + (int) downloadedBytes;

        InputStream inputStream = httpConn.getInputStream();
        FileOutputStream outputStream = new FileOutputStream(tempFile, downloadedBytes > 0);

        // Writing initial progression into file
        if (downloadedBytes == 0) {
          try (BufferedWriter writer = new BufferedWriter(new FileWriter(progressFile))) {
            writer.write(String.valueOf(downloadedBytes));
          }
        }

        int bytesRead = -1;
        byte[] buffer = new byte[4096];
        int lastPercent = 0;
        while ((bytesRead = inputStream.read(buffer)) != -1) {

          outputStream.write(buffer, 0, bytesRead);
          downloadedBytes += bytesRead;

          // Updating the progress file
          try (BufferedWriter writer = new BufferedWriter(new FileWriter(progressFile))) {
            writer.write(String.valueOf(downloadedBytes));
          }

          // Saving progress (flushing every 100 Ko)
          if (downloadedBytes % 102400 == 0) {
            outputStream.flush();
          }

          // Computing percentage
          int percent = calcTotalPercent(downloadedBytes, contentLength);
          if (percent != lastPercent) {
            notifyDownload(id, percent);
            lastPercent = percent;
          }
        }

        outputStream.close();
        inputStream.close();

        // Rename the temp file with the final name (dest)
        tempFile.renameTo(new File(documentsDir, dest));
        progressFile.delete();
        publishResults(dest, id, version, checksum, sessionKey, "");
      } else {
        progressFile.delete();
      }
      httpConn.disconnect();
    } catch (IOException e) {
      e.printStackTrace();

    }
  }

  private void notifyDownload(String id, int percent) {
    Intent intent = new Intent(PERCENTDOWNLOAD);
    intent.setPackage(getPackageName());
    intent.putExtra(ID, id);
    intent.putExtra("percent", percent);
    sendBroadcast(intent);
  }

  private void publishResults(String dest, String id, String version, String checksum, String sessionKey,
      String error) {
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
