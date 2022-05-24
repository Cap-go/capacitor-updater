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
    private final String name;
    private final String version;
    private final VersionStatus status;

    static {
        sdf.setTimeZone(TimeZone.getTimeZone("GMT"));
    }

    public VersionInfo(final VersionInfo source) {
        this(source.version, source.status, source.downloaded, source.name);
    }

    public VersionInfo(final String version, final VersionStatus status, final Date downloaded, final String name) {
        this(version, status, sdf.format(downloaded), name);
    }

    public VersionInfo(final String version, final VersionStatus status, final String downloaded, final String name) {
        this.downloaded = downloaded;
        this.name = name;
        this.version = version;
        this.status = status;
    }

    public Boolean isBuiltin() {
        return VERSION_BUILTIN.equals(this.getVersion());
    }
    public Boolean isUnknown() {
        return VERSION_UNKNOWN.equals(this.getVersion());
    }
    public Boolean isErrorStatus() {
        return VersionStatus.ERROR == this.status;
    }
    public boolean isDownloaded() {
        return !this.isBuiltin() && this.downloaded != null && this.downloaded.trim().length() == DOWNLOADED_BUILTIN.length();
    }

    public String getDownloaded() {
        return this.isBuiltin() ? DOWNLOADED_BUILTIN : this.downloaded;
    }

    public VersionInfo setDownloaded(Date downloaded) {
        return new VersionInfo(this.version, this.status, downloaded, this.name);
    }

    public String getName() {
        return this.isBuiltin() ? VERSION_BUILTIN : this.name;
    }

    public VersionInfo setName(String name) {
        return new VersionInfo(this.version, this.status, this.downloaded, name);
    }

    public String getVersion() {
        return this.version == null ? VERSION_BUILTIN : this.version;
    }

    public VersionInfo setVersion(String version) {
        return new VersionInfo(version, this.status, this.downloaded, this.name);
    }

    public VersionStatus getStatus() {
        return this.isBuiltin() ? VersionStatus.SUCCESS : this.status;
    }

    public VersionInfo setStatus(VersionStatus status) {
        return new VersionInfo(this.version, status, this.downloaded, this.name);
    }

    public static VersionInfo fromJSON(final JSObject json) throws JSONException {
        return VersionInfo.fromJSON(json.toString());
    }

    public static VersionInfo fromJSON(final String jsonString) throws JSONException {
        JSONObject json = new JSONObject(new JSONTokener(jsonString));
        return new VersionInfo(
                json.has("version") ? json.getString("version") : VersionInfo.VERSION_UNKNOWN,
                json.has("status") ? VersionStatus.fromString(json.getString("status")) : VersionStatus.PENDING,
                json.has("downloaded") ? json.getString("downloaded") : "",
                json.has("name") ? json.getString("name") : ""
        );
    }

    public JSObject toJSON() {
        final JSObject result = new JSObject();
        result.put("downloaded", this.getDownloaded());
        result.put("name", this.getName());
        result.put("version", this.getVersion());
        result.put("status", this.getStatus());
        return result;
    }
    


    @Override
    public boolean equals(final Object o) {
        if (this == o) return true;
        if (!(o instanceof VersionInfo)) return false;
        final VersionInfo that = (VersionInfo) o;
        return this.getVersion().equals(that.getVersion());
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