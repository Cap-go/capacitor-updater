/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.IntentService;
import android.content.Intent;
import android.os.Parcel;
import android.os.Parcelable;
import android.util.Base64;
import android.util.Log;

import androidx.annotation.NonNull;

import java.io.BufferedReader;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.security.GeneralSecurityException;
import java.security.PublicKey;
import java.util.zip.GZIPInputStream;

import javax.crypto.Cipher;
import javax.crypto.CipherInputStream;
import javax.crypto.SecretKey;

public class DownloadServiceV2 extends IntentService {

  // Unzip = unzip from builtin bundle
  // Download = download from an arbitrary URL
  public enum DownloadJobType implements Parcelable {
    DOWNLOAD,
    UNZIP;

    @Override
    public int describeContents() {
      return 0;
    }

    @Override
    public void writeToParcel(@NonNull Parcel dest, int flags) {
      dest.writeString(this.name());
    }

    public static final Parcelable.Creator<DownloadJobType> CREATOR
      = new Parcelable.Creator<DownloadJobType>() {
      public DownloadJobType createFromParcel(Parcel in) {
        return DownloadJobType.valueOf(in.readString());
      }

      public DownloadJobType[] newArray(int size) {
        return new DownloadJobType[size];
      }
    };
  }

  public static final String URL = "URL";
  public static final String ID = "id";
  public static final String PERCENT = "percent";
  public static final String FILEDEST = "filendest";
  public static final String FILENAME = "filename";
  public static final String SHAFILEHASH = "FILEHASH";
  public static final String DOCDIR = "docdir";
  public static final String ERROR = "error";
  public static final String VERSION = "version";
  public static final String JOBTYPE = "jobtype";
  public static final String MANIFEST = "manifest";
  public static final String FULLFILEPATH = "fullfilepath";
  public static final String FINALFILEPATH = "finalfilepath";

  public static final String NOTIFICATION = "service receiver";
  public static final String SESSION_KEY = "sessionkey";
  public static final String IV = "ivkey";
  public static final String PUBLICKEY = "publickey";
  public static final String PERCENTDOWNLOAD = "percent receiver";

  public DownloadServiceV2() {
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
    String id = intent.getStringExtra(ID);
    String documentsDir = intent.getStringExtra(DOCDIR);
    String dest = intent.getStringExtra(FILEDEST);
    String version = intent.getStringExtra(VERSION);
    DownloadJobType jobType = intent.getParcelableExtra(JOBTYPE);

    if (jobType == DownloadJobType.UNZIP) {
      ManifestEntry downloadManifestEntry = intent.getParcelableExtra(MANIFEST);
      if (downloadManifestEntry == null) {
        Log.e(CapacitorUpdater.TAG, "Cannot get the manifest from intent (unzip)");
        return;
      }

      String copyPath = downloadManifestEntry.getCopyPath();
      if (downloadManifestEntry.getType() == ManifestEntry.ManifestEntryType.URL && copyPath == null) {
        Log.e(CapacitorUpdater.TAG, "The current manifest type !== builtin, quiting");
        return;
      }

      // FINALFILEPATH is here because one might rename the asset
      // If a rename happens then the ManifestEntry will keep the old file name
      // This is normal, but it HAS to be accounted for
      // As such, we should pass the entire DownloadManifest.Entry but since we  only need the path this FINALFILEPATH was created
      String finalFilePath = intent.getStringExtra(FINALFILEPATH);
      String finalDest = dest + "/" + finalFilePath;

      try {
        final File target = new File(documentsDir, finalDest);
        String fullPath = target.getAbsolutePath();
        target.getParentFile().mkdirs();
        target.createNewFile();

        // There are 2 possibilities
        // A) Open file from android resources - the file has to be builtin - most likely an asset like a video or img
        // B) Copy the file as it has already been downloaded and as such it is in device storage - cheaper then re-downloading
        // This is required as there is no easy way to symlink resources
        try (InputStream in = downloadManifestEntry.getType() == ManifestEntry.ManifestEntryType.BUILTIN ? this.getAssets().open("public/" + downloadManifestEntry.getBuiltinAssetPath()) : new FileInputStream(copyPath)) {
          try (final FileOutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[4 * 1024];
            int len;
            while ((len = in.read(buffer)) > 0) {
              out.write(buffer, 0, len);
            }
          }
        }

        // Send the resource to the main thread
        // Filename = null as it;s never going to get used in a case where jobtype = unzip
        // This is because a lot of stupid reasons, don't worry to much about it ;-)
        publishResults(dest, id, version, "", downloadManifestEntry.getHash(), fullPath, DownloadJobType.UNZIP, "");
      } catch (java.io.IOException e) {
        Log.e(CapacitorUpdater.TAG, "error creating the file", e);
        publishResults("", id, version, "", downloadManifestEntry.getHash(), "", DownloadJobType.UNZIP, e.getLocalizedMessage());
      }
    } else if (jobType == DownloadJobType.DOWNLOAD) {
      DownloadManifest.DownloadManifestEntry manifestEntry = intent.getParcelableExtra(MANIFEST);

      if (manifestEntry == null) {
        Log.e(CapacitorUpdater.TAG, "Cannot get the manifest from intent (download)");
        return;
      }

      String sessionKeyStr = intent.getStringExtra(SESSION_KEY);
      String ivStr = intent.getStringExtra(IV);
      String publicKeyStr = intent.getStringExtra(PUBLICKEY);

      Cipher cipher = null;

      if (
        sessionKeyStr != null && ivStr != null && publicKeyStr != null &&
          !sessionKeyStr.isEmpty() && !ivStr.isEmpty() && !publicKeyStr.isEmpty()
      ) {
        byte[] iv = Base64.decode(ivStr.getBytes(), Base64.DEFAULT);
        byte[] sessionKey = Base64.decode(
          sessionKeyStr.getBytes(),
          Base64.DEFAULT
        );

        PublicKey pKey;
        byte[] decryptedSessionKey;
        SecretKey sKey;

        try {
          pKey = CryptoCipher.stringToPublicKey(publicKeyStr);
          decryptedSessionKey = CryptoCipher.decryptRSA(sessionKey, pKey);
          sKey = CryptoCipher.byteToSessionKey(decryptedSessionKey);
          cipher = CryptoCipher.decryptAESCipher(sKey, iv);
          if (cipher == null) {
            // at this stage getting a null from decryptAESCipher is a deadly error ;-)
            return;
          }
        } catch (GeneralSecurityException e) {
          Log.e(CapacitorUpdater.TAG, "Cannot gen the public key - cannot download file", e);
          return;
        }
      }

      String finalDest = dest + "/" + manifestEntry.getFileName();
      String fullPath;

      InputStream is;

      try {
        final URL u = manifestEntry.getDownloadUrl();
        final URLConnection connection = u.openConnection();

        if (connection instanceof HttpURLConnection) {

          HttpURLConnection urlConnection = ((HttpURLConnection) connection);
          urlConnection.setInstanceFollowRedirects(true);
          urlConnection.setConnectTimeout(10_000);
          urlConnection.setReadTimeout(10_000);
          urlConnection.connect();

          int responseCode = urlConnection.getResponseCode();
          if (!(responseCode >= 200 && responseCode < 300)) {
            // Here we know sth went really wrong
            throw new RuntimeException("Could not open output stream for download url. Error code: " + responseCode);
          }

          is = urlConnection.getInputStream();

        } else {
          // Illegal url?? How did we get here????
          throw new RuntimeException("URL " + u.toString() + " is not a valid http url????");
        }

        try (
          InputStream dis = (cipher != null) ? new GZIPInputStream(new CipherInputStream(new DataInputStream(is), cipher)) : new GZIPInputStream(new DataInputStream(is));
        ) {
          final File target = new File(documentsDir, finalDest);
          fullPath = target.getAbsolutePath();
          target.getParentFile().mkdirs();
          target.createNewFile();
          try (final FileOutputStream fos = new FileOutputStream(target)) {
            final long totalLength = connection.getContentLength();
            final int bufferSize = 1024;
            final byte[] buffer = new byte[bufferSize];
            int length;

            int bytesRead = bufferSize;
            int percent = 0;
            //this.notifyDownload(id, 10);
            while ((length = dis.read(buffer)) > 0) {
              // The entire buffer could be encrypted so...

              fos.write(buffer, 0, length);

              final int newPercent = (int) ((bytesRead * 100) / totalLength);
              if (totalLength > 1 && newPercent != percent) {
                percent = newPercent;
                // this.notifyDownload(id, this.calcTotalPercent(percent, 10, 70));
              }
              bytesRead += length;
            }
            //publishResults(dest, id, version, checksum, sessionKey, "");
          }
        }
        publishResults(dest, id, version, manifestEntry.getFileName(), manifestEntry.getFileHash(), fullPath, DownloadJobType.DOWNLOAD, "");
      } catch (Exception e) {
        Log.e(CapacitorUpdater.TAG, "Cannot download the file within the download service", e);
        publishResults("", id, version, manifestEntry.getFileName(), manifestEntry.getFileHash(), "", DownloadJobType.DOWNLOAD, e.getLocalizedMessage());
      }
    }
  }

//    try {
//      final URL u = new URL(url);
//      final URLConnection connection = u.openConnection();
//
//      try (
//        final InputStream is = u.openStream();
//        final DataInputStream dis = new DataInputStream(is)
//      ) {
//        final File target = new File(documentsDir, dest);
//        target.getParentFile().mkdirs();
//        target.createNewFile();
//        try (final FileOutputStream fos = new FileOutputStream(target)) {
//          final long totalLength = connection.getContentLength();
//          final int bufferSize = 1024;
//          final byte[] buffer = new byte[bufferSize];
//          int length;
//
//          int bytesRead = bufferSize;
//          int percent = 0;
//          this.notifyDownload(id, 10);
//          while ((length = dis.read(buffer)) > 0) {
//            fos.write(buffer, 0, length);
//            final int newPercent = (int) ((bytesRead * 100) / totalLength);
//            if (totalLength > 1 && newPercent != percent) {
//              percent = newPercent;
//              this.notifyDownload(id, this.calcTotalPercent(percent, 10, 70));
//            }
//            bytesRead += length;
//          }
//          publishResults(dest, id, version, checksum, sessionKey, "");
//        }
//      }
//    } catch (Exception e) {
//      e.printStackTrace();
//      publishResults(
//        "",
//        id,
//        version,
//        checksum,
//        sessionKey,
//        e.getLocalizedMessage()
//      );
//    }
//}

  private void notifyDownload(String id, int percent) {
    // TODO
//    Intent intent = new Intent(PERCENTDOWNLOAD);
//    intent.putExtra(ID, id);
//    intent.putExtra(PERCENT, percent);
//    sendBroadcast(intent);
  }

  private void publishResults(
    String dest,
    String id,
    String version,
    String filename,
    String hash,
    String fullFilePath,
    DownloadJobType jobType,
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
    intent.putExtra(FILENAME, filename);
    intent.putExtra(FULLFILEPATH, fullFilePath);
    intent.putExtra(SHAFILEHASH, hash);
    intent.putExtra(JOBTYPE, (Parcelable) jobType);
    sendBroadcast(intent);
  }
}
