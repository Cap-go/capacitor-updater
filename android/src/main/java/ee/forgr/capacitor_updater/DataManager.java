package ee.forgr.capacitor_updater;

import java.util.HashMap;
import java.util.Map;
import org.json.JSONArray;

public class DataManager {

    private static DataManager instance;
    private final Map<String, JSONArray> manifestsById = new HashMap<>();

    private DataManager() {}

    public static synchronized DataManager getInstance() {
        if (instance == null) {
            instance = new DataManager();
        }
        return instance;
    }

    public synchronized void setManifest(String downloadId, JSONArray manifest) {
        if (downloadId == null || manifest == null) {
            return;
        }
        this.manifestsById.put(downloadId, manifest);
    }

    public synchronized JSONArray getAndClearManifest(String downloadId) {
        if (downloadId == null) {
            return null;
        }
        return this.manifestsById.remove(downloadId);
    }

    public synchronized void clearManifest(String downloadId) {
        if (downloadId != null) {
            this.manifestsById.remove(downloadId);
        }
    }

    public synchronized void clearAllManifests() {
        this.manifestsById.clear();
    }
}
