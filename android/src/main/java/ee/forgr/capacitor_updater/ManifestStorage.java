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
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

public class ManifestStorage {
    private ConcurrentHashMap<String, ManifestEntry> manifestHashMap;

    // This hashmap is used to save how many files have to still get downloaded before we can say that we got all.
    // Essentially it will be used to map version_id -> files_left_to_download
    // Once the number reaches zero two things have to happen
    // A) The entry gets removed from this hashmap
    // B) The bundle gets marked as done
    private ConcurrentHashMap<String, AtomicInteger> downloadingManifestFilesLeftHashMap;
    private  SharedPreferences.Editor editor;
    private SharedPreferences prefs;

    private final String SAVED_MANIFEST_PREFIX = "CAPGO_SAVED_MANIFEST";


    private ManifestStorage(ConcurrentHashMap<String, ManifestEntry> manifestHashMap, SharedPreferences.Editor editor, SharedPreferences prefs) {
        this.manifestHashMap = manifestHashMap;
        this.downloadingManifestFilesLeftHashMap = new ConcurrentHashMap<>();
        this.editor = editor;
        this.prefs = prefs;
    }

    public synchronized void saveToDeviceStorage() {
        try {
            JSONArray jsonArray = new JSONArray();

            for (ManifestEntry entry: manifestHashMap.values()) {
                // We are going to build the builtin from scratch every time, there is no need to save it
                if (entry.getType() == ManifestEntry.ManifestEntryType.BUILTIN) {
                    continue;
                }

                jsonArray.put(entry.toJSON());
            }

            this.editor.putString(SAVED_MANIFEST_PREFIX, jsonArray.toString());
            this.editor.commit();
        } catch (Exception e) {
            Log.e(
              CapacitorUpdater.TAG,
              "Cannot save manifest storage into device storage",
              e
            );
        }
    }

    public int decreaseFilesToDownloadForBundle(String id) {
        AtomicInteger integer = downloadingManifestFilesLeftHashMap.get(id);
        if (integer == null) {
            return -1;
        }

        return integer.decrementAndGet();
    }

    public void addBundleToDownload(String id, int filesToDownload) {
        downloadingManifestFilesLeftHashMap.put(id, new AtomicInteger(filesToDownload));
    }

    public static ManifestStorage init(AssetManager manager, SharedPreferences.Editor editor, SharedPreferences prefs) {
        ArrayList<ManifestEntry> buildIn = loadBuiltinManifest(manager);
        ConcurrentHashMap<String, ManifestEntry> manifestHashMap = new ConcurrentHashMap<>();


        for (int i = 0; i < (buildIn != null ? buildIn.size() : 0); i++) {
            ManifestEntry manifestEntry = buildIn.get(i);
            manifestHashMap.put(manifestEntry.getHash(), manifestEntry);
        }

        return new ManifestStorage(manifestHashMap, editor, prefs);
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
            JSONArray jsonArray = new JSONArray(new JSONTokener(savedManifestStr));

            for (int i = 0; i < jsonArray.length(); i++) {
                JSONObject jsonObject = jsonArray.getJSONObject(i);
                ManifestEntry manifestEntry = ManifestEntry.fromJson(jsonObject);
                // TODO: verify that each ManifestEntry.storagePath is an actual file existing on the file system
                this.manifestHashMap.put(manifestEntry.getHash(), manifestEntry);
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
