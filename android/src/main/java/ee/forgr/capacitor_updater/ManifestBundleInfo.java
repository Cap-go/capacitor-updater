package ee.forgr.capacitor_updater;

import com.getcapacitor.JSObject;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

public class ManifestBundleInfo {
  // If the committed = false this will indicate how much files there are left to download
  // We will ALWAYS decrease this, even if the file fails
  private AtomicInteger filesLeftToDownload;

  // It's the name of the bundle
  private String id;

  // This value will commit which actions are allowed + if we should save
  // If committed = false:
  //   - disallow toJson (prevent saving)
  //   - allow addFileHash
  //   - allow decreaseFilesLeft
  //   - allow commit
  // If committed = true
  //   - allow toJson (saving)
  //   - disallow addFileHash
  //   - disallow decreaseFilesLeft
  //   - disallow commit
  private boolean committed;

  // This value will tell us if the bundle has been successful
  // If error = true then toJson will be disallowed in order to prevent a failed bundle from saving
  private boolean error;

  public ManifestBundleInfo(
    String id,
    int filesLeft
  ) {
    this.id = id;
    this.filesLeftToDownload = new AtomicInteger(filesLeft);
    this.committed = false;
    this.error = false;
  }

  public boolean isCommitted() {
    return committed;
  }

  public int decreaseFilesLeftToDownload() {
    if (this.committed) {
      throw new IllegalStateException("Cannot decrease the number of files left to download after the bundle has been committed");
    }
    return this.filesLeftToDownload.decrementAndGet();
  }

  public void markError() {
    if (this.committed) {
      throw new IllegalStateException("Cannot mark with an error after the bundle has been committed");
    }
    this.error = true;
  }

  public void commit() {
    if (this.committed) {
      throw new IllegalStateException("Cannot recommit a bundle");
    }

    this.committed = true;
  }
}
