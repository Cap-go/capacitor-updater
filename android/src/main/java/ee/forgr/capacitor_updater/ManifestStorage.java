package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import android.content.res.AssetManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

public class ManifestStorage {
    private ConcurrentHashMap<String, ManifestEntry> manifestHashMap;

    // This hashmap will store a bundle_id -> ManifestBundleInfo (object)
    // This will allow us to figure out which manifest entries belong to what bundle
    // This will be VERY important during the bundle deletion
    private ConcurrentHashMap<String, ManifestBundleInfo> bundleIdToBundleInfoHashmap;

    private  SharedPreferences.Editor editor;
    private SharedPreferences prefs;

    private final String SAVED_MANIFEST_PREFIX = "CAPGO_SAVED_MANIFEST";


    private ManifestStorage(ConcurrentHashMap<String, ManifestEntry> manifestHashMap, SharedPreferences.Editor editor, SharedPreferences prefs) {
        this.manifestHashMap = manifestHashMap;
        this.editor = editor;
        this.prefs = prefs;
        // TODO: load
        this.bundleIdToBundleInfoHashmap = new ConcurrentHashMap<>();
    }

    public synchronized void saveToDeviceStorage() {
        Log.i(CapacitorUpdater.TAG, "Saving the manifest storage to device storage");
        try {
            JSONArray jsonArray = new JSONArray();

            for (ManifestEntry entry: manifestHashMap.values()) {
                // We are going to build the builtin from scratch every time, there is no need to save it
                if (entry.getType() == ManifestEntry.ManifestEntryType.BUILTIN) {
                    continue;
                }

                jsonArray.put(entry.toJSON());
            }

            JSONArray bundleIdToManifestInfo = new JSONArray();
            for (Map.Entry<String, ManifestBundleInfo> bundleIdBundleInfoSet: bundleIdToBundleInfoHashmap.entrySet()) {
                ManifestBundleInfo value = bundleIdBundleInfoSet.getValue();
                if (!value.isCommitted()) {
                    Log.e(
                      CapacitorUpdater.TAG,
                      "Bundle " + bundleIdBundleInfoSet.getKey() + " not commited, not saving. This means that there very likely is a different update in parallel"
                    );
                    return;
                }
                JSONObject hashmapObj = new JSONObject();
                hashmapObj.put("key", bundleIdBundleInfoSet.getKey());
                hashmapObj.put("val", value.toJSON());
                bundleIdToManifestInfo.put(hashmapObj);
            }

            JSONObject finalJson = new JSONObject();
            finalJson.put("saved_manifest", jsonArray);
            finalJson.put("bundle_to_manifest", bundleIdToManifestInfo);

            this.editor.putString(SAVED_MANIFEST_PREFIX, finalJson.toString());
            this.editor.commit();
        } catch (Exception e) {
            Log.e(
              CapacitorUpdater.TAG,
              "Cannot save manifest storage into device storage",
              e
            );
        }
    }

    public ManifestBundleInfo getBundleById(String id) {
        return bundleIdToBundleInfoHashmap.get(id);
    }

    public void addBundleToDownload(String id, ManifestBundleInfo bundleInfo) {
        bundleIdToBundleInfoHashmap.put(id, bundleInfo);
    }

    public static ManifestStorage init(AssetManager manager, SharedPreferences.Editor editor, SharedPreferences prefs) {
        ArrayList<ManifestEntry> buildIn = loadBuiltinManifest(manager);
        ConcurrentHashMap<String, ManifestEntry> manifestHashMap = new ConcurrentHashMap<>();


        for (int i = 0; i < (buildIn != null ? buildIn.size() : 0); i++) {
            ManifestEntry manifestEntry = buildIn.get(i);
            manifestHashMap.put(manifestEntry.getHash(), manifestEntry);
        }

        ManifestStorage manifestStorage = new ManifestStorage(manifestHashMap, editor, prefs);
        manifestStorage.loadFromStorageDevice();
        return manifestStorage;
    }

    public ManifestEntry getEntryByHash(String hash) {
        return this.manifestHashMap.get(hash);
    }

    public void insertDownloadManifestEntry(String hash, String diskPath) {
        ManifestEntry manifestEntry = new ManifestEntry(hash, ManifestEntry.ManifestEntryType.URL, List.of(diskPath));
        manifestHashMap.put(hash, manifestEntry);
    }

    private synchronized void loadFromStorageDevice() {
        String savedManifestStr = this.prefs.getString(SAVED_MANIFEST_PREFIX, "");
        if (savedManifestStr.isEmpty()) {
            Log.e(CapacitorUpdater.TAG, "Cannot read the downloaded manifest entries from device storage!");
            return;
        }

        try {
            JSONObject savedJson = new JSONObject(new JSONTokener(savedManifestStr));
            JSONArray savedManifestArray = savedJson.getJSONArray("saved_manifest");
            JSONArray bundleIdToManifestInfo = savedJson.getJSONArray("bundle_to_manifest");
            boolean shouldSave = false;
            boolean removedFromManifest = false;

            for (int i = 0; i < savedManifestArray.length(); i++) {
                JSONObject jsonObject = savedManifestArray.getJSONObject(i);
                ManifestEntry manifestEntry = ManifestEntry.fromJson(jsonObject);

                if (manifestEntry.cleanupFilePaths() && !shouldSave) {
                    shouldSave = true;
                }


                if (manifestEntry.getStoragePathList().size() > 0) {
                    this.manifestHashMap.put(manifestEntry.getHash(), manifestEntry);
                } else {
                    removedFromManifest = true;
                }
            }

            for (int i = 0; i < bundleIdToManifestInfo.length(); i++) {
                JSONObject object = bundleIdToManifestInfo.getJSONObject(i);
                String key = object.getString("key");
                ManifestBundleInfo bundleInfo = ManifestBundleInfo.fromJson(object.getJSONObject("val"));

                for (String filehash: bundleInfo.getAllFilesHashList()) {
                    if (this.manifestHashMap.get(filehash) == null) {
                        Log.e(CapacitorUpdater.TAG, "Bundle " + key + " was stored with an invalid file hashes. Hash " + filehash + " does not exist. This bundle will not be marked as downloaded. This situation should never happen. Illegal state reached");
                        return;
                    }
                }

                this.bundleIdToBundleInfoHashmap.put(key, bundleInfo);
            }

            if (removedFromManifest) {
                Log.i(CapacitorUpdater.TAG, "Some manifest entries had to be removed as the underlying file does not exist on the filesystem");
            }
            if (shouldSave) {
                this.saveToDeviceStorage();
            }

        } catch (JSONException e) {
            Log.e(CapacitorUpdater.TAG, "Cannot read the downloaded manifest entries from device storage (json error)!", e);
        }
    }

    private static ArrayList<String> recusiveAssetFolderLoad(AssetManager assetManager, String folder) throws IOException {
        String[] files = assetManager.list(folder);
        ArrayList<String> finalFiles = new ArrayList<>();
        Log.e(CapacitorUpdater.TAG, String.valueOf(finalFiles));

        for (int i = 0; i < files.length; i++) {
            String file = files[i];
            if (file.split("\\.").length == 1) {
                finalFiles.addAll(recusiveAssetFolderLoad(assetManager, folder + "/" + file));
            } else {
                finalFiles.add(folder + "/" + file);
            }
        }

        return finalFiles;
    }

    // Stolen from https://www.baeldung.com/java-byte-arrays-hex-strings
    private static String byteToHex(byte num) {
        char[] hexDigits = new char[2];
        hexDigits[0] = Character.forDigit((num >> 4) & 0xF, 16);
        hexDigits[1] = Character.forDigit((num & 0xF), 16);
        return new String(hexDigits);
    }

    private static String encodeHexString(byte[] byteArray) {
        StringBuffer hexStringBuffer = new StringBuffer();
        for (int i = 0; i < byteArray.length; i++) {
            hexStringBuffer.append(byteToHex(byteArray[i]));
        }
        return hexStringBuffer.toString();
    }

    private static ArrayList<ManifestEntry> loadBuiltinManifest(AssetManager assetManager) {
        try {
            ArrayList<String> allFiles = recusiveAssetFolderLoad(assetManager, "public");
            ArrayList<ManifestEntry> manifestEntries = new ArrayList<>(allFiles.size());


            for (int i = 0; i < allFiles.size(); i++) {
                String file = allFiles.get(i);
                InputStream dataStream = assetManager.open(file);
                MessageDigest digest = MessageDigest.getInstance("SHA-256");

                byte[] buffer = new byte[dataStream.available()];
                if (dataStream.read(buffer) == -1) {
                    Log.e(CapacitorUpdater.TAG, "Cannot read file " + file + ". Cannot generate manifest!");
                    return null;
                }

                digest.update(buffer);

                byte[] hash = digest.digest();
                String finalHash = encodeHexString(hash);

                if (file.startsWith("public/")) {
                    file = file.substring("public/".length());
                }
                manifestEntries.add(new ManifestEntry(file, finalHash, ManifestEntry.ManifestEntryType.BUILTIN));
            }

            return manifestEntries;
        } catch (IOException e) {
            Log.e(CapacitorUpdater.TAG, "IOException when generating the manifest", e);
            return null;
        } catch (NoSuchAlgorithmException e) {
            Log.e(CapacitorUpdater.TAG, "The device does not support sha256??", e);
            return null;
        }
    }
}
