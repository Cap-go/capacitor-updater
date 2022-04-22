package ee.forgr.capacitor_updater;

import java.util.HashMap;
import java.util.Map;

public enum VersionStatus {
    SUCCESS("success"),
    ERROR("error"),
    PENDING("pending");

    public final String label;

    private static final Map<String, VersionStatus> BY_LABEL = new HashMap<>();
    static {
        for (VersionStatus e: values()) {
            BY_LABEL.put(e.label, e);
        }
    }

    private VersionStatus(String label) {
        this.label = label;
    }

    @Override
    public String toString() {
        return label;
    }

    public static VersionStatus fromString(String status) {
        if(status == null || status.isEmpty()) {
            return VersionStatus.PENDING;
        }
        return VersionStatus.BY_LABEL.get(status);
    }
}
