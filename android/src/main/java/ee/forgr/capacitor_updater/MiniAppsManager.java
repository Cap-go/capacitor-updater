package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Represents a mini-app entry in the registry
 */
class MiniAppEntry {

    public final String name;
    public final String bundleId;
    public final boolean isMain;

    public MiniAppEntry(String name, String bundleId, boolean isMain) {
        this.name = name;
        this.bundleId = bundleId;
        this.isMain = isMain;
    }
}

/**
 * Manages mini-apps registry and operations.
 * Handles storage, lookup, and lifecycle of mini-apps in a "super-app" architecture.
 */
public class MiniAppsManager {

    private static final String DEFAULT_REGISTRY_KEY = "CapacitorUpdater.miniApps";

    private final String registryKey;
    private final SharedPreferences prefs;
    private final SharedPreferences.Editor editor;
    private final Logger logger;

    public MiniAppsManager(SharedPreferences prefs, SharedPreferences.Editor editor, Logger logger) {
        this(prefs, editor, logger, DEFAULT_REGISTRY_KEY);
    }

    public MiniAppsManager(SharedPreferences prefs, SharedPreferences.Editor editor, Logger logger, String registryKey) {
        this.prefs = prefs;
        this.editor = editor;
        this.logger = logger;
        this.registryKey = registryKey;
    }

    // MARK: - Validation

    /**
     * Validates that a mini-app name contains only safe characters.
     * Names must contain only alphanumeric characters, hyphens, and underscores.
     * @param name The mini-app name to validate
     * @return true if the name is valid, false otherwise
     */
    public boolean isValidMiniAppName(String name) {
        if (name == null || name.isEmpty()) {
            return false;
        }
        return name.matches("^[a-zA-Z0-9_-]+$");
    }

    // MARK: - Registry Operations

    /**
     * Get all mini-apps from registry
     */
    public JSONObject getRegistry() {
        String data = prefs.getString(registryKey, "{}");
        try {
            return new JSONObject(data);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    /**
     * Save registry to storage
     */
    public void saveRegistry(JSONObject registry) {
        editor.putString(registryKey, registry.toString());
        editor.apply();
    }

    /**
     * Get all protected bundle IDs (bundles that should not be cleaned up)
     */
    public Set<String> getProtectedBundleIds() {
        Set<String> ids = new HashSet<>();
        JSONObject registry = getRegistry();
        Iterator<String> keys = registry.keys();
        while (keys.hasNext()) {
            String name = keys.next();
            try {
                JSONObject entry = registry.getJSONObject(name);
                String bundleId = entry.optString("id", "");
                if (!bundleId.isEmpty()) {
                    ids.add(bundleId);
                }
            } catch (JSONException e) {
                // Skip invalid entries
            }
        }
        return ids;
    }

    /**
     * Find mini-app info by bundle ID
     * @return array of [name, isMainAsString] or null if not found
     */
    public String[] getMiniAppForBundleId(String bundleId) {
        JSONObject registry = getRegistry();
        Iterator<String> keys = registry.keys();
        while (keys.hasNext()) {
            String name = keys.next();
            try {
                JSONObject entry = registry.getJSONObject(name);
                String id = entry.optString("id", "");
                if (id.equals(bundleId)) {
                    boolean isMain = entry.optBoolean("isMain", false);
                    return new String[] { name, String.valueOf(isMain) };
                }
            } catch (JSONException e) {
                // Skip invalid entries
            }
        }
        return null;
    }

    /**
     * Get mini-app entry by name
     */
    public MiniAppEntry getMiniApp(String name) {
        JSONObject registry = getRegistry();
        try {
            if (!registry.has(name)) {
                return null;
            }
            JSONObject entry = registry.getJSONObject(name);
            String bundleId = entry.optString("id", "");
            if (bundleId.isEmpty()) {
                return null;
            }
            boolean isMain = entry.optBoolean("isMain", false);
            return new MiniAppEntry(name, bundleId, isMain);
        } catch (JSONException e) {
            return null;
        }
    }

    /**
     * Get bundle ID for mini-app name
     */
    public String getBundleId(String name) {
        JSONObject registry = getRegistry();
        try {
            if (!registry.has(name)) {
                return null;
            }
            JSONObject entry = registry.getJSONObject(name);
            return entry.optString("id", null);
        } catch (JSONException e) {
            return null;
        }
    }

    // MARK: - Registration

    /**
     * Register a bundle as a mini-app
     * @param name Mini-app name (also used as channel name)
     * @param bundleId Bundle ID to register
     * @param isMain Whether this is the main app (receives auto-updates)
     */
    public void register(String name, String bundleId, boolean isMain) {
        // Validate mini-app name
        if (!isValidMiniAppName(name)) {
            logger.error("Invalid mini-app name '" + name + "'. Names must contain only alphanumeric characters, hyphens, and underscores.");
            return;
        }

        try {
            JSONObject registry = getRegistry();

            // If isMain is true, clear isMain from all other entries
            if (isMain) {
                Iterator<String> keys = registry.keys();
                while (keys.hasNext()) {
                    String existingName = keys.next();
                    JSONObject entry = registry.getJSONObject(existingName);
                    if (entry.optBoolean("isMain", false)) {
                        entry.put("isMain", false);
                        registry.put(existingName, entry);
                    }
                }
            }

            // Add or update the mini-app entry
            JSONObject newEntry = new JSONObject();
            newEntry.put("id", bundleId);
            newEntry.put("isMain", isMain);
            registry.put(name, newEntry);

            saveRegistry(registry);
            logger.info("Registered mini-app '" + name + "' with bundle " + bundleId + ", isMain: " + isMain);
        } catch (JSONException e) {
            logger.error("Failed to register mini-app: " + e.getMessage());
        }
    }

    /**
     * Atomically update the bundle ID for an existing mini-app.
     * Thread-safe: uses synchronization to prevent race conditions.
     * @param name Mini-app name to update
     * @param newBundleId New bundle ID to set
     * @return true if the update succeeded, false if the mini-app was not found
     */
    public synchronized boolean updateBundleId(String name, String newBundleId) {
        if (!isValidMiniAppName(name)) {
            logger.error("Invalid mini-app name '" + name + "' in updateBundleId");
            return false;
        }

        try {
            JSONObject registry = getRegistry();
            if (!registry.has(name)) {
                logger.error("updateBundleId: mini-app '" + name + "' not found");
                return false;
            }

            JSONObject entry = registry.getJSONObject(name);
            boolean isMain = entry.optBoolean("isMain", false);

            JSONObject newEntry = new JSONObject();
            newEntry.put("id", newBundleId);
            newEntry.put("isMain", isMain);
            registry.put(name, newEntry);

            saveRegistry(registry);
            logger.info("Updated bundle ID for mini-app '" + name + "' to " + newBundleId);
            return true;
        } catch (JSONException e) {
            logger.error("Failed to update bundle ID: " + e.getMessage());
            return false;
        }
    }

    /**
     * Unregister a mini-app from the registry
     * @param name Mini-app name to unregister
     * @return The bundle ID that was unregistered, or null if not found
     */
    public String unregister(String name) {
        JSONObject registry = getRegistry();
        try {
            if (!registry.has(name)) {
                return null;
            }
            JSONObject entry = registry.getJSONObject(name);
            String bundleId = entry.optString("id", "");
            registry.remove(name);
            saveRegistry(registry);
            logger.info("Unregistered mini-app '" + name + "', bundle: " + bundleId);
            return bundleId.isEmpty() ? null : bundleId;
        } catch (JSONException e) {
            return null;
        }
    }

    // MARK: - Main App

    /**
     * Get the main app entry (the one that receives auto-updates)
     */
    public MiniAppEntry getMainApp() {
        JSONObject registry = getRegistry();
        Iterator<String> keys = registry.keys();
        while (keys.hasNext()) {
            String name = keys.next();
            try {
                JSONObject entry = registry.getJSONObject(name);
                if (entry.optBoolean("isMain", false)) {
                    String bundleId = entry.optString("id", "");
                    if (!bundleId.isEmpty()) {
                        return new MiniAppEntry(name, bundleId, true);
                    }
                }
            } catch (JSONException e) {
                // Skip invalid entries
            }
        }
        return null;
    }

    /**
     * Check if a mini-app is the main app
     */
    public boolean isMainApp(String name) {
        JSONObject registry = getRegistry();
        try {
            if (!registry.has(name)) {
                return false;
            }
            JSONObject entry = registry.getJSONObject(name);
            return entry.optBoolean("isMain", false);
        } catch (JSONException e) {
            return false;
        }
    }

    // MARK: - App State (Inter-app Communication)

    private String stateKey(String miniApp) {
        return "CapacitorUpdater.miniAppState." + miniApp;
    }

    /**
     * Write state data for a mini-app
     * @param miniApp The mini-app name
     * @param state The state object to save (must be JSON-serializable), or null to clear
     */
    public void writeState(String miniApp, JSONObject state) {
        if (!isValidMiniAppName(miniApp)) {
            logger.error("Invalid mini-app name '" + miniApp + "' in writeState");
            return;
        }

        String key = stateKey(miniApp);

        if (state != null) {
            editor.putString(key, state.toString());
            editor.apply();
            logger.info("Wrote state for mini-app '" + miniApp + "'");
        } else {
            // Clear state
            editor.remove(key);
            editor.apply();
            logger.info("Cleared state for mini-app '" + miniApp + "'");
        }
    }

    /**
     * Read state data for a mini-app
     * @param miniApp The mini-app name
     * @return The saved state, or null if no state exists
     */
    public JSONObject readState(String miniApp) {
        if (!isValidMiniAppName(miniApp)) {
            logger.error("Invalid mini-app name '" + miniApp + "' in readState");
            return null;
        }

        String key = stateKey(miniApp);
        String data = prefs.getString(key, null);

        if (data == null || data.isEmpty()) {
            return null;
        }

        try {
            return new JSONObject(data);
        } catch (JSONException e) {
            logger.error("Failed to parse state for mini-app '" + miniApp + "': " + e.getMessage());
            return null;
        }
    }

    /**
     * Clear state data for a mini-app
     * @param miniApp The mini-app name
     */
    public void clearState(String miniApp) {
        if (!isValidMiniAppName(miniApp)) {
            logger.error("Invalid mini-app name '" + miniApp + "' in clearState");
            return;
        }

        String key = stateKey(miniApp);
        editor.remove(key);
        editor.apply();
        logger.info("Cleared state for mini-app '" + miniApp + "'");
    }
}
