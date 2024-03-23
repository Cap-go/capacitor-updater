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

  // This will be the list with ALL file hashes
  // It will be used in ManifestStorage to map with ManifestEntry
  // It will only be added AFTER the file has downloaded successfully
  private List<String> allFilesHashList;

  // It's the name of the bundle
  private String name;

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
    String name,
    int filesLeft
  ) {
    this.name = name;
    this.filesLeftToDownload = new AtomicInteger(filesLeft);
    this.allFilesHashList = Collections.synchronizedList(new ArrayList<>());
    this.committed = false;
    this.error = false;
  }

  private ManifestBundleInfo(
    String name,
    ArrayList<String> fileHashes
  ) {
    this.allFilesHashList = Collections.synchronizedList(fileHashes);
    this.committed = true;
    this.error = false;
    this.name = name;
  }

  public void addFieHash(String fileHash) {
    if (this.committed) {
      throw new IllegalStateException("Cannot add a new file hash after the bundle has been committed");
    }
    this.allFilesHashList.add(fileHash);
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

  public JSObject toJSON() {
    final JSObject result = new JSObject();
    result.put("name", this.name);

    JSONArray jsonArray = new JSONArray();
    for (String filehash: allFilesHashList) {
      jsonArray.put(filehash);
    }

    result.put("file_hash", jsonArray);

    return result;
  }

  public static ManifestBundleInfo fromJson(JSONObject json) throws JSONException {
    JSONArray jsonArray = json.getJSONArray("file_hash");

    ArrayList<String> fileHashes = new ArrayList<>(jsonArray.length());
    for (int i = 0; i < jsonArray.length(); i++) {
      String string = jsonArray.getString(i);
      fileHashes.add(string);
    }

    String name = json.getString("name");

    return new ManifestBundleInfo(name, fileHashes);
  }
}
