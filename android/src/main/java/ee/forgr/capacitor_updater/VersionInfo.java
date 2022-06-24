package ee.forgr.capacitor_updater;

import com.getcapacitor.JSObject;

import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Objects;
import java.util.TimeZone;

public class VersionInfo {
    private static final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ");

    public static final String VERSION_BUILTIN = "builtin";
    public static final String VERSION_UNKNOWN = "unknown";
    public static final String DOWNLOADED_BUILTIN = "1970-01-01T00:00:00.000Z";

    private final String downloaded;
    private final String folder;
    private final String versionName;
    private final VersionStatus status;

    static {
        sdf.setTimeZone(TimeZone.getTimeZone("GMT"));
    }

    public VersionInfo(final VersionInfo source) {
        this(source.folder, source.version, source.status, source.downloaded);
    }

    public VersionInfo(final String folder, final String version, final VersionStatus status, final Date downloaded) {
        this(folder, version, status, sdf.format(downloaded));
    }

    public VersionInfo(final String folder, final String version, final VersionStatus status, final String downloaded) {
        this.downloaded = downloaded.trim();
        this.folder = folder;
        this.version = version;
        this.status = status;
    }

    public Boolean isBuiltin() {
        return VERSION_BUILTIN.equals(this.folder);
    }
    public Boolean isUnknown() {
        return VERSION_UNKNOWN.equals(this.folder);
    }
    public Boolean isErrorStatus() {
        return VersionStatus.ERROR == this.status;
    }
    public boolean isDownloaded() {
        return !this.isBuiltin() && this.downloaded != null && !this.downloaded.equals("");
    }

    public String getDownloaded() {
        return this.isBuiltin() ? DOWNLOADED_BUILTIN : this.downloaded;
    }

    public VersionInfo setDownloaded(Date downloaded) {
        return new VersionInfo(this.folder, this.version, this.status, downloaded);
    }

    public String getFolder() {
        return this.isBuiltin() ? VERSION_BUILTIN : this.folder;
    }

    public VersionInfo setFolder(String folder) {
        return new VersionInfo(folder, this.version, this.status, this.downloaded);
    }

    public String getVersionName() {
        return this.version == null ? VERSION_BUILTIN : this.version;
    }

    public VersionInfo setVersionName(String version) {
        return new VersionInfo(this.folder, version, this.status, this.downloaded);
    }

    public VersionStatus getStatus() {
        return this.isBuiltin() ? VersionStatus.SUCCESS : this.status;
    }

    public VersionInfo setStatus(VersionStatus status) {
        return new VersionInfo(this.folder, this.version, status, this.downloaded);
    }

    public static VersionInfo fromJSON(final JSObject json) throws JSONException {
        return VersionInfo.fromJSON(json.toString());
    }

    public static VersionInfo fromJSON(final String jsonString) throws JSONException {
        JSONObject json = new JSONObject(new JSONTokener(jsonString));
        return new VersionInfo(
                json.has("folder") ? json.getString("name") : "",
                json.has("versionName") ? json.getString("version") : VersionInfo.VERSION_UNKNOWN,
                json.has("status") ? VersionStatus.fromString(json.getString("status")) : VersionStatus.PENDING,
                json.has("downloaded") ? json.getString("downloaded") : ""
        );
    }

    public JSObject toJSON() {
        final JSObject result = new JSObject();
        result.put("folder", this.getFolder());
        result.put("versionName", this.getVersionName());
        result.put("downloaded", this.getDownloaded());
        result.put("status", this.getStatus());
        return result;
    }

    @Override
    public boolean equals(final Object o) {
        if (this == o) return true;
        if (!(o instanceof VersionInfo)) return false;
        final VersionInfo that = (VersionInfo) o;
        return this.getFolder().equals(that.getFolder());
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