package ee.forgr.capacitor_updater;

import org.json.JSONArray;

public class DataManager {
    private static DataManager instance;
    private JSONArray currentManifest;
    
    private DataManager() {}
    
    public static synchronized DataManager getInstance() {
        if (instance == null) {
            instance = new DataManager();
        }
        return instance;
    }
    
    public void setManifest(JSONArray manifest) {
        this.currentManifest = manifest;
    }
    
    public JSONArray getAndClearManifest() {
        JSONArray manifest = this.currentManifest;
        this.currentManifest = null;
        return manifest;
    }
} 
