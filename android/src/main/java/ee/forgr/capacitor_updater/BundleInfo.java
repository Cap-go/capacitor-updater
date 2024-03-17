/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import com.getcapacitor.JSObject;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Objects;
import java.util.TimeZone;
import java.util.concurrent.atomic.AtomicInteger;

import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

public class BundleInfo {

  private static final SimpleDateFormat sdf = new SimpleDateFormat(
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
  );

  public static final String ID_BUILTIN = "builtin";
  public static final String VERSION_UNKNOWN = "unknown";
  public static final String DOWNLOADED_BUILTIN = "1970-01-01T00:00:00.000Z";

  private final String downloaded;
  private final String id;
  private final String version;
  private final String checksum;
  private final BundleStatus status;
  private AtomicInteger filesToDownload;

  static {
    sdf.setTimeZone(TimeZone.getTimeZone("GMT"));
  }

  public BundleInfo(final BundleInfo source) {
    this(
      source.id,
      source.version,
      source.status,
      source.downloaded,
      source.checksum
    );
  }

  public BundleInfo(
    final String id,
    final String version,
    final BundleStatus status,
    final Date downloaded,
    final String checksum
  ) {
    this(id, version, status, sdf.format(downloaded), checksum);
  }

  public BundleInfo(
    final String id,
    final String version,
    final BundleStatus status,
    final Date downloaded,
    final int filesToDownload,
    final String checksum
  ) {
    this(id, version, status, sdf.format(downloaded), checksum);
    this.filesToDownload = new AtomicInteger(filesToDownload);
  }

  public BundleInfo(
    final String id,
    final String version,
    final BundleStatus status,
    final String downloaded,
    final String checksum
  ) {
    this.downloaded = downloaded.trim();
    this.id = id;
    this.version = version;
    this.checksum = checksum;
    this.status = status;
  }

  public Boolean isBuiltin() {
    return ID_BUILTIN.equals(this.id);
  }

  public Boolean isUnknown() {
    return VERSION_UNKNOWN.equals(this.id);
  }

  public Boolean isErrorStatus() {
    return BundleStatus.ERROR == this.status;
  }

  public Boolean isDeleted() {
    return BundleStatus.DELETED == this.status;
  }

  public boolean isDownloaded() {
    return (
      !this.isBuiltin() &&
      this.downloaded != null &&
      !this.downloaded.isEmpty() &&
      !this.isDeleted()
    );
  }

  public int decreaseFilesToDownload() {
    return this.filesToDownload.decrementAndGet();
  }

  public String getDownloaded() {
    return this.isBuiltin() ? DOWNLOADED_BUILTIN : this.downloaded;
  }

  public BundleInfo setDownloaded(Date downloaded) {
    return new BundleInfo(
      this.id,
      this.version,
      this.status,
      downloaded,
      this.checksum
    );
  }

  public String getChecksum() {
    return this.isBuiltin() ? "" : this.checksum;
  }

  public BundleInfo setChecksum(String checksum) {
    return new BundleInfo(
      this.id,
      this.version,
      this.status,
      this.downloaded,
      checksum
    );
  }

  public String getId() {
    return this.isBuiltin() ? ID_BUILTIN : this.id;
  }

  public BundleInfo setId(String id) {
    return new BundleInfo(
      id,
      this.version,
      this.status,
      this.downloaded,
      this.checksum
    );
  }

  public String getVersionName() {
    return this.version == null ? ID_BUILTIN : this.version;
  }

  public BundleInfo setVersionName(String version) {
    return new BundleInfo(
      this.id,
      version,
      this.status,
      this.downloaded,
      this.checksum
    );
  }

  public BundleStatus getStatus() {
    return this.isBuiltin() ? BundleStatus.SUCCESS : this.status;
  }

  public BundleInfo setStatus(BundleStatus status) {
    return new BundleInfo(
      this.id,
      this.version,
      status,
      this.downloaded,
      this.checksum
    );
  }

  public static BundleInfo fromJSON(final JSObject json) throws JSONException {
    return BundleInfo.fromJSON(json.toString());
  }

  public static BundleInfo fromJSON(final String jsonString)
    throws JSONException {
    JSONObject json = new JSONObject(new JSONTokener(jsonString));
    return new BundleInfo(
      json.has("id") ? json.getString("id") : "",
      json.has("version")
        ? json.getString("version")
        : BundleInfo.VERSION_UNKNOWN,
      json.has("status")
        ? BundleStatus.fromString(json.getString("status"))
        : BundleStatus.PENDING,
      json.has("downloaded") ? json.getString("downloaded") : "",
      json.has("checksum") ? json.getString("checksum") : ""
    );
  }

  public JSObject toJSON() {
    final JSObject result = new JSObject();
    result.put("id", this.getId());
    result.put("version", this.getVersionName());
    result.put("downloaded", this.getDownloaded());
    result.put("checksum", this.getChecksum());
    result.put("status", this.getStatus());
    return result;
  }

  @Override
  public boolean equals(final Object o) {
    if (this == o) return true;
    if (!(o instanceof BundleInfo)) return false;
    final BundleInfo that = (BundleInfo) o;
    return this.getId().equals(that.getId());
  }

  @Override
  public int hashCode() {
    return Objects.hash(this.version);
  }

  @Override
  public String toString() {
    return this.toJSON().toString();
  }
}
