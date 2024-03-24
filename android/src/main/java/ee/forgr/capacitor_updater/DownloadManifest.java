package ee.forgr.capacitor_updater;

import static ee.forgr.capacitor_updater.CapacitorUpdaterPlugin.isValidURL;

import android.os.Parcel;
import android.os.Parcelable;
import android.util.Log;

import androidx.annotation.NonNull;

import com.getcapacitor.JSObject;
import com.google.gson.JsonObject;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.net.MalformedURLException;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class DownloadManifest implements Parcelable {

    public interface DownloadManifestCallback {
        public void manifestErrorCallback(String error);
    }

    public static class DownloadManifestEntry implements Parcelable {
        private String fileName;
        private String fileHash;
        private URL downloadUrl;

        public String getFileName() {
            return fileName;
        }

        public String getFileHash() {
            return fileHash;
        }

        public URL getDownloadUrl() {
            return downloadUrl;
        }

        @Override
        public String toString() {
            return "DownloadManifestEntry{" +
              "fileName='" + fileName + '\'' +
              ", fileHash='" + fileHash + '\'' +
              ", downloadUrl=" + downloadUrl +
              '}';
        }

        private DownloadManifestEntry(String fileName, String fileHash, URL downloadUrl) {
            this.fileName = fileName;
            this.fileHash = fileHash;
            this.downloadUrl = downloadUrl;
        }

        public static DownloadManifestEntry parseJson(JSONObject jsObject, DownloadManifestCallback errorCallback) {
            if (!jsObject.has("file_name")) {
                errorCallback.manifestErrorCallback("DownloadManifestEntry parsing failed (no \"file_name\") for " + jsObject);
                // Log.e(CapacitorUpdater.TAG, "DownloadManifestEntry parsing failed (no \"file_name\") for " + jsObject);
                return null;
            }
            if (!jsObject.has("file_hash")) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (no \"file_hash\") for " + jsObject);
                return null;
            }
            if (!jsObject.has("download_url")) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (no \"download_url\") for " + jsObject);
                return null;
            }

            String fileName;
            String fileHash;
            String downloadUrlStr;
            String sessionKey;

            try {
                fileName = jsObject.getString("file_name");
                fileHash = jsObject.getString("file_hash");
                downloadUrlStr = jsObject.getString("download_url");
            } catch (JSONException e) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (Unreachable exception reached) for " + jsObject);
                return null;
            }

            if (fileName.length() == 0) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (\"file_name\" len === 0) for " + jsObject);
                return null;
            }

            if (fileHash.length() == 0) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (\"file_hash\" len === 0) for " + jsObject);
                return null;
            }

            if (downloadUrlStr.length() == 0) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (\"download_url\" len === 0) for " + jsObject);
                return null;
            }

            if (!isValidURL(downloadUrlStr)) {
                errorCallback.manifestErrorCallback( "DownloadManifestEntry parsing failed (\"download_url\" -> \"" + downloadUrlStr +  "\" is not a valid url) for " + jsObject);
                return null;
            }

            try {
                URL downloadURl = new URL(downloadUrlStr);
                return new DownloadManifestEntry(fileName, fileHash, downloadURl);
            } catch (MalformedURLException e) {
                // Unreachable, we know because we checked
                errorCallback.manifestErrorCallback( "Unreachable url wrong format reached for url: " + downloadUrlStr);
                return null;
            }
        }

        @Override
        public int describeContents() {
            return 0;
        }

        @Override
        public void writeToParcel(@NonNull Parcel dest, int flags) {
            dest.writeString(this.fileHash);
            dest.writeString(this.fileName);
            dest.writeString(this.downloadUrl.toString());
        }

        public static final Parcelable.Creator<DownloadManifestEntry> CREATOR
                = new Parcelable.Creator<DownloadManifestEntry>() {
            public DownloadManifestEntry createFromParcel(Parcel in) {
                return new DownloadManifestEntry(in);
            }

            public DownloadManifestEntry[] newArray(int size) {
                return new DownloadManifestEntry[size];
            }
        };

        private DownloadManifestEntry(Parcel in) {
            this.fileHash = in.readString();
            this.fileName = in.readString();
            try {
                this.downloadUrl = new URL(in.readString());
            } catch (MalformedURLException e) {
                // unreachable
                Log.e(CapacitorUpdater.TAG, "Unreachable reached", e);
            }
        }
    }

    private String versionName;
    private ArrayList<DownloadManifestEntry> downloadManifestEntries;
    private String iv64B;
    private String sessionKeyB64;

    private DownloadManifest(String versionName, ArrayList<DownloadManifestEntry> downloadManifestEntries, String iv64B, String sessionKeyB64) {
        this.versionName = versionName;
        this.downloadManifestEntries = downloadManifestEntries;
        this.iv64B = iv64B;
        this.sessionKeyB64 = sessionKeyB64;
    }

    private static boolean checkForBase64(String string) {
        String pattern = "^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$";
        Pattern r = Pattern.compile(pattern);
        Matcher m = r.matcher(string);
        return m.find();
    }

    public static DownloadManifest parseJson(JSObject jsObject, DownloadManifestCallback errorCallback) throws RuntimeException {
        if (!jsObject.has("version")) {
            errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (no \"version\") for " + jsObject);
            return null;
        }

        if (!jsObject.has("manifest")) {
            errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (no \"version\") for " + jsObject);
            return null;
        }

        String version = jsObject.getString("version");
        if (version == null) {
            errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"version\" is null) for " + jsObject);
            return null;
        }

        if (version.length() == 0) {
            errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"version\" len === 0) for " + jsObject);
            return null;
        }

        JSONArray manifestArray;
        String iv64B;
        String sessionKeyB64;
        try {
            manifestArray = jsObject.getJSONArray("manifest");

            if (jsObject.has("sessionKey")) {
                String sessionKey = jsObject.getString("sessionKey");
                String[] split = sessionKey.split(":");
                if (split.length != 2) {
                    errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"session_key\" split for \":\" returned length " + split.length + " instead of 2) for " + jsObject);
                    return null;
                }
                if (!checkForBase64(split[0])) {
                    errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"session_key\" split for \":\" at 0 (" + split[0] + ") is not base64) for " + jsObject);
                    return null;
                }
                if (!checkForBase64(split[1])) {
                    errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"session_key\" split for \":\" at 0 (" + split[1] + ") is not base64) for " + jsObject);
                    return null;
                }
                iv64B = split[0];
                sessionKeyB64 = split[1];
            } else {
                iv64B = null;
                sessionKeyB64 = null;
            }
        } catch (JSONException e) {
            errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"manifestArray\" is not a JSON array) for " + jsObject);
            return null;
        }

        ArrayList<DownloadManifestEntry> manifestArrayList = new ArrayList<>(manifestArray.length());

        for (int i = 0; i < manifestArray.length(); i++) {
            try {
                JSONObject manifestArrayJSONObject = manifestArray.getJSONObject(i);
                DownloadManifestEntry downloadManifestEntry = DownloadManifestEntry.parseJson(manifestArrayJSONObject, errorCallback);
                manifestArrayList.add(downloadManifestEntry);
            } catch (JSONException e) {
                errorCallback.manifestErrorCallback( "DownloadManifest parsing failed (\"manifestArray\" -> " + i + " is not a JSON object) for " + jsObject);
                return null;
            }
        }

        return new DownloadManifest(version, manifestArrayList, iv64B, sessionKeyB64);
    }

    public String getSessionKey() {
        return sessionKeyB64;
    }

    public String getIv() {
        return iv64B;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(@NonNull Parcel dest, int flags) {
        dest.writeString(this.versionName);
        DownloadManifestEntry[] downloadManifestEntriesArray = this.downloadManifestEntries.toArray(new DownloadManifestEntry[0]);
        dest.writeParcelableArray(downloadManifestEntriesArray, 0);
    }

    public static final Parcelable.Creator<DownloadManifest> CREATOR
            = new Parcelable.Creator<DownloadManifest>() {
        public DownloadManifest createFromParcel(Parcel in) {
            return new DownloadManifest(in);
        }

        public DownloadManifest[] newArray(int size) {
            return new DownloadManifest[size];
        }
    };

    private DownloadManifest(Parcel in) {
        this.versionName = in.readString();
        this.downloadManifestEntries = new ArrayList<>(Arrays.asList((DownloadManifestEntry[]) Objects.requireNonNull(in.readParcelableArray(DownloadManifestEntry.class.getClassLoader()))));
    }

    public String getVersionName() {
        return versionName;
    }

    public ArrayList<DownloadManifestEntry> getDownloadManifestEntries() {
        return downloadManifestEntries;
    }
}


