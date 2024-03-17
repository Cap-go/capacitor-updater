package ee.forgr.capacitor_updater;

import android.os.Parcel;
import android.os.Parcelable;

import org.jetbrains.annotations.NotNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

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

    public String getCopyPath() {
        if (type != ManifestEntryType.URL || storagePathList.size() == 0) {
            return null;
        }

        // TODO: a bit smarter fetch
        return storagePathList.get(0);
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
