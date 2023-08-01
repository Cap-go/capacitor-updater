/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.content.Intent;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.net.URLConnection;

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

  public DownloadService() {
    super("Background DownloadService");
  }

  private int calcTotalPercent(
    final int percent,
    final int min,
    final int max
  ) {
    return (percent * (max - min)) / 100 + min;
  }

  // Will be called asynchronously by OS.
  @Override
  protected void onHandleIntent(Intent intent) {
    String url = intent.getStringExtra(URL);
    String id = intent.getStringExtra(ID);
    String documentsDir = intent.getStringExtra(DOCDIR);
    String dest = intent.getStringExtra(FILEDEST);
    String version = intent.getStringExtra(VERSION);
    String sessionKey = intent.getStringExtra(SESSIONKEY);
    String checksum = intent.getStringExtra(CHECKSUM);

    try {
      final URL u = new URL(url);
      final URLConnection connection = u.openConnection();

      try (final InputStream is = u.openStream();
           final DataInputStream dis = new DataInputStream(is)) {

        final File target = new File(documentsDir, dest);
        target.getParentFile().mkdirs();
        target.createNewFile();
        try (final FileOutputStream fos = new FileOutputStream(target)) {

          final long totalLength = connection.getContentLength();
          final int bufferSize = 1024;
          final byte[] buffer = new byte[bufferSize];
          int length;

          int bytesRead = bufferSize;
          int percent = 0;
          this.notifyDownload(id, 10);
          while ((length = dis.read(buffer)) > 0) {
            fos.write(buffer, 0, length);
            final int newPercent = (int) ((bytesRead * 100) / totalLength);
            if (totalLength > 1 && newPercent != percent) {
              percent = newPercent;
              this.notifyDownload(id, this.calcTotalPercent(percent, 10, 70));
            }
            bytesRead += length;
          }
          publishResults(dest, id, version, checksum, sessionKey, "");
        }
      }
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

  private void notifyDownload(String id, int percent) {
    Intent intent = new Intent(PERCENTDOWNLOAD);
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
    if (dest != null && !dest.isEmpty()) {
      intent.putExtra(FILEDEST, dest);
    }
    if (error != null && !error.isEmpty()) {
      intent.putExtra(ERROR, error);
    }
    intent.putExtra(ID, id);
    intent.putExtra(VERSION, version);
    intent.putExtra(SESSIONKEY, sessionKey);
    intent.putExtra(CHECKSUM, checksum);
    intent.putExtra(ERROR, error);
    sendBroadcast(intent);
  }
}
