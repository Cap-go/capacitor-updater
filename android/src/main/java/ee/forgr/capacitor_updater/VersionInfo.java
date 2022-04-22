package ee.forgr.capacitor_updater;

import com.getcapacitor.JSObject;

import java.util.Objects;

public class VersionInfo {
    private String downloaded;
    private String name;
    private String version;
    private VersionStatus status;

    public VersionInfo(String version, VersionStatus status, String downloaded, String name) {
        this.downloaded = downloaded;
        this.name = name;
        this.version = version;
        this.status = status;
    }

    public Boolean isBuiltin() {
        return "".equals(this.version);
    }

    public Boolean isErrorStatus() {
        return VersionStatus.ERROR == this.status;
    }

    public String getDownloaded() {
        return this.isBuiltin() ? "1970-01-01T00:00:00.000Z" : downloaded;
    }

    public String getName() {
        return this.isBuiltin() ? "builtin" : name;
    }

    public String getVersion() {
        return version;
    }

    public VersionStatus getStatus() {
        return status;
    }

    public JSObject toJSON() {
        JSObject result = new JSObject();
        result.put("downloaded", this.getDownloaded());
        result.put("name", this.getName());
        result.put("version", this.getVersion());
        result.put("status", this.getStatus());
        return result;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof VersionInfo)) return false;
        VersionInfo that = (VersionInfo) o;
        return version.equals(that.version) && status == that.status;
    }

    @Override
    public int hashCode() {
        return Objects.hash(version, status);
    }

    @Override
    public String toString() {
        return "{" +
                "downloaded: '" + downloaded + "'" +
                ", name: '" + name + "'" +
                ", version: '" + version + "'" +
                ", status: '" + status +
                "'}";
    }
}
