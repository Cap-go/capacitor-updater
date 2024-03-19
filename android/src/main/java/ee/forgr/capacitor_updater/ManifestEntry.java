package ee.forgr.capacitor_updater;

import android.os.Parcel;
import android.os.Parcelable;
import android.util.Log;

import com.getcapacitor.JSObject;

import org.jetbrains.annotations.NotNull;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

public class ManifestEntry implements Parcelable {
    private String hash;

    @NotNull
    private ManifestEntryType type;

    private final List<String> storagePathList = Collections.synchronizedList(new ArrayList<>());

    public ManifestEntry(String filePath, String hash, ManifestEntryType type) {
        this.storagePathList.add(filePath);
        this.hash = hash;
        this.type = type;
    }

    public ManifestEntry(String hash, ManifestEntryType type, List<String> storagePathList) {
        this.storagePathList.addAll(storagePathList);
        this.hash = hash;
        this.type = type;
    }

    public String getHash() {
        return hash;
    }

    public void addPath(String path) {
        storagePathList.add(path);
    }

    public String getBuiltinAssetPath() {
        if (this.type != ManifestEntryType.BUILTIN) {
            return null;
        }

        // It will throw but given the constructor there SHOULD not be a way for the path not to be the first item
        return storagePathList.get(0);
    }

    // This fn will check if all storagePathList actually exist
    // If not then it will remove them and retun true
    // If true returned ManifestStorage.saveToDeviceStorage should be called
    public synchronized boolean cleanupFilePaths() {
        if (this.type == ManifestEntryType.BUILTIN) {
            return false;
        }

        boolean shouldSave = false;

        final List<String> finalStoragePathList = new ArrayList<>();
        for (int i = 0; i < storagePathList.size(); i++) {
            String filepath = storagePathList.get(i);

            File file = new File(filepath);
            if (!file.exists()) {
                shouldSave = true;
                Log.i(CapacitorUpdater.TAG, "Filepath " + filepath + " does not exist. Removing from storagePathList");
                continue;
            }

            finalStoragePathList.add(filepath);
        }

        if (shouldSave) {
            this.storagePathList.clear();
            this.storagePathList.addAll(finalStoragePathList);
        }
        return shouldSave;
    }

    public String formattedStoragePathList() {
        return "[ " + String.join(", ", this.storagePathList) + " ]";
    }

    public List<String> getStoragePathList() {
        return storagePathList;
    }

    public String getCopyPath() {
        if (type != ManifestEntryType.URL || storagePathList.size() == 0) {
            return null;
        }

        // TODO: a bit smarter fetch
        return storagePathList.get(0);
    }

    public JSObject toJSON() {
        final JSObject result = new JSObject();
        result.put("storagePaths", new JSONArray(this.storagePathList));
        result.put("hash", this.hash);
        result.put("type", this.type.toString());
        return result;
    }

    public static ManifestEntry fromJson(JSONObject json) throws JSONException {
        JSONArray jsonArray = json.getJSONArray("storagePaths");

        ArrayList<String> pathArray = new ArrayList<>(jsonArray.length());
        for (int i = 0; i < jsonArray.length(); i++) {
            String string = jsonArray.getString(i);
            pathArray.add(string);
        }

        String hash = json.getString("hash");
        ManifestEntryType type = ManifestEntry.ManifestEntryType.valueOf(json.getString("type"));

        return new ManifestEntry(hash, type, pathArray);
    }

    @NotNull
    public ManifestEntryType getType() {
        return this.type;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(@NotNull Parcel dest, int flags) {
        dest.writeString(this.hash);
        dest.writeString(this.type.name());
        String[] pathListArray = this.storagePathList.toArray(new String[0]);
        dest.writeStringArray(pathListArray);
    }
    public static final Parcelable.Creator<ManifestEntry> CREATOR
      = new Parcelable.Creator<ManifestEntry>() {
        public ManifestEntry createFromParcel(Parcel in) {
            return new ManifestEntry(in);
        }

        public ManifestEntry[] newArray(int size) {
            return new ManifestEntry[size];
        }
    };

    private ManifestEntry(Parcel in) {
        this.hash = in.readString();
        this.type =  ManifestEntryType.valueOf(in.readString());
        this.storagePathList.addAll(Arrays.asList(in.createStringArray()));
    }


    public enum ManifestEntryType {
        BUILTIN, URL
    }
}
