/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.TimeZone;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

public class BundleInfo {

    private static final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ");

    public static final String ID_BUILTIN = "builtin";
    public static final String VERSION_UNKNOWN = "unknown";
    public static final String DOWNLOADED_BUILTIN = "1970-01-01T00:00:00.000Z";

    private final String downloaded;
    private final String id;
    private final String version;
    private final String checksum;
    private final BundleStatus status;
    private final String link;
    private final String comment;

    static {
        sdf.setTimeZone(TimeZone.getTimeZone("GMT"));
    }

    public BundleInfo(final BundleInfo source) {
        this(source.id, source.version, source.status, source.downloaded, source.checksum, source.link, source.comment);
    }

    public BundleInfo(final String id, final String version, final BundleStatus status, final Date downloaded, final String checksum) {
        this(id, version, status, sdf.format(downloaded), checksum, null, null);
    }

    public BundleInfo(final String id, final String version, final BundleStatus status, final Date downloaded, final String checksum, final String link, final String comment) {
        this(id, version, status, sdf.format(downloaded), checksum, link, comment);
    }

    public BundleInfo(final String id, final String version, final BundleStatus status, final String downloaded, final String checksum) {
        this(id, version, status, downloaded, checksum, null, null);
    }

    public BundleInfo(final String id, final String version, final BundleStatus status, final String downloaded, final String checksum, final String link, final String comment) {
        this.downloaded = downloaded != null ? downloaded.trim() : "";
        this.id = id != null ? id : "";
        this.version = version;
        this.checksum = checksum != null ? checksum : "";
        this.status = status != null ? status : BundleStatus.ERROR;
        this.link = link;
        this.comment = comment;
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
        return (!this.isBuiltin() && this.downloaded != null && !this.downloaded.isEmpty() && !this.isDeleted());
    }

    public String getDownloaded() {
        return this.isBuiltin() ? DOWNLOADED_BUILTIN : (this.downloaded != null ? this.downloaded : "");
    }

    public BundleInfo setDownloaded(Date downloaded) {
        return new BundleInfo(this.id, this.version, this.status, downloaded, this.checksum, this.link, this.comment);
    }

    public String getChecksum() {
        return this.isBuiltin() ? "" : (this.checksum != null ? this.checksum : "");
    }

    public BundleInfo setChecksum(String checksum) {
        return new BundleInfo(this.id, this.version, this.status, this.downloaded, checksum, this.link, this.comment);
    }

    public String getId() {
        return this.isBuiltin() ? ID_BUILTIN : this.id;
    }

    public BundleInfo setId(String id) {
        return new BundleInfo(id, this.version, this.status, this.downloaded, this.checksum, this.link, this.comment);
    }

    public String getVersionName() {
        return this.version == null ? ID_BUILTIN : this.version;
    }

    public BundleInfo setVersionName(String version) {
        return new BundleInfo(this.id, version, this.status, this.downloaded, this.checksum, this.link, this.comment);
    }

    public BundleStatus getStatus() {
        if (this.isBuiltin()) {
            return BundleStatus.SUCCESS;
        }
        return this.status != null ? this.status : BundleStatus.ERROR;
    }

    public BundleInfo setStatus(BundleStatus status) {
        return new BundleInfo(this.id, this.version, status, this.downloaded, this.checksum, this.link, this.comment);
    }

    public String getLink() {
        return this.link;
    }

    public BundleInfo setLink(String link) {
        return new BundleInfo(this.id, this.version, this.status, this.downloaded, this.checksum, link, this.comment);
    }

    public String getComment() {
        return this.comment;
    }

    public BundleInfo setComment(String comment) {
        return new BundleInfo(this.id, this.version, this.status, this.downloaded, this.checksum, this.link, comment);
    }

    public static BundleInfo fromJSON(final String jsonString) throws JSONException {
        JSONObject json = new JSONObject(new JSONTokener(jsonString));
        return new BundleInfo(
            json.has("id") ? json.getString("id") : "",
            json.has("version") ? json.getString("version") : BundleInfo.VERSION_UNKNOWN,
            json.has("status") ? BundleStatus.fromString(json.getString("status")) : BundleStatus.PENDING,
            json.has("downloaded") ? json.getString("downloaded") : "",
            json.has("checksum") ? json.getString("checksum") : "",
            json.has("link") ? json.getString("link") : null,
            json.has("comment") ? json.getString("comment") : null
        );
    }

    public Map<String, Object> toJSONMap() {
        final Map<String, Object> result = new HashMap<>();
        result.put("id", this.getId());
        result.put("version", this.getVersionName());
        result.put("downloaded", this.getDownloaded());
        result.put("checksum", this.getChecksum());
        result.put("status", this.getStatus().toString());
        if (this.link != null && !this.link.isEmpty()) {
            result.put("link", this.link);
        }
        if (this.comment != null && !this.comment.isEmpty()) {
            result.put("comment", this.comment);
        }
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
        try {
            // Build JSON manually with extra safety checks
            StringBuilder json = new StringBuilder();
            json.append("{");

            // Safe ID access
            String safeId = this.id != null ? this.id : "";
            if (this.isBuiltin()) safeId = ID_BUILTIN;
            json.append("\"id\":\"").append(safeId).append("\",");

            // Safe version access
            String safeVersion = this.version != null ? this.version : ID_BUILTIN;
            json.append("\"version\":\"").append(safeVersion).append("\",");

            // Safe downloaded access
            String safeDownloaded = this.downloaded != null ? this.downloaded : "";
            if (this.isBuiltin()) safeDownloaded = DOWNLOADED_BUILTIN;
            json.append("\"downloaded\":\"").append(safeDownloaded).append("\",");

            // Safe checksum access
            String safeChecksum = this.checksum != null ? this.checksum : "";
            json.append("\"checksum\":\"").append(safeChecksum).append("\",");

            // Safe status access
            BundleStatus safeStatus = this.status != null ? this.status : BundleStatus.ERROR;
            if (this.isBuiltin()) safeStatus = BundleStatus.SUCCESS;
            json.append("\"status\":\"").append(safeStatus.toString()).append("\"");

            json.append("}");
            return json.toString();
        } catch (Exception e) {
            // Log the error for debugging but still return valid JSON
            System.err.println("BundleInfo toString() error: " + e.getMessage());
            e.printStackTrace();
            // Return absolute minimal JSON
            return "{\"id\":\"" + (this.id != null ? this.id : "unknown") + "\",\"status\":\"error\"}";
        }
    }
}
