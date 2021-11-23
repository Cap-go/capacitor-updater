package ee.forgr.capacitor_updater;

import android.content.Context;
import android.util.Log;

import org.json.JSONException;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.security.SecureRandom;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.ArrayList;

public class CapacitorUpdater {
    String TAG = "CapacitorUpdater";
    private Context context;
    private String lastPathHot = "";
    private String basePathHot = "versions";

    static final String AB = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    static SecureRandom rnd = new SecureRandom();

    private String randomString(int len){
        StringBuilder sb = new StringBuilder(len);
        for(int i = 0; i < len; i++)
            sb.append(AB.charAt(rnd.nextInt(AB.length())));
        return sb.toString();
    }

    CapacitorUpdater (Context context) {
        this.context = context;
    }

    private Boolean unzip(String source, String dest) {
        File zipFile = new File(this.context.getFilesDir()  + "/" + source);
        File targetDirectory = new File(this.context.getFilesDir()  + "/" + dest);
        Log.i(TAG, "unzip " + zipFile.getPath() + " " + targetDirectory.getPath());

        ZipInputStream zis = null;
        try {
            zis = new ZipInputStream(
                    new BufferedInputStream(new FileInputStream(zipFile)));
        } catch (FileNotFoundException e) {
            e.printStackTrace();
            return false;
        }
        try {
            ZipEntry ze;
            int count;
            byte[] buffer = new byte[8192];
            while ((ze = zis.getNextEntry()) != null) {
                File file = new File(targetDirectory, ze.getName());
                File dir = ze.isDirectory() ? file : file.getParentFile();
                if (!dir.isDirectory() && !dir.mkdirs())
                    throw new FileNotFoundException("Failed to ensure directory: " +
                            dir.getAbsolutePath());
                if (ze.isDirectory())
                    continue;
                FileOutputStream fout = new FileOutputStream(file);
                try {
                    while ((count = zis.read(buffer)) != -1)
                        fout.write(buffer, 0, count);
                } finally {
                    fout.close();
                }
            }
        } catch (Exception e) {
            Log.i(TAG, "unzip error", e);
            return false;
        } finally {
            try {
                zis.close();
            } catch (IOException e) {
                e.printStackTrace();
                return false;
            }
            return true;
        }
    }
    private void flattenAssets(String source, String dest) {
        File current = new File(this.context.getFilesDir()  + "/" + source);
        File fDest = new File(this.context.getFilesDir()  + "/" + dest);
        fDest.getParentFile().mkdirs();
        String[] pathsName = current.list();
        if (pathsName.length == 1 && pathsName[0] != "index.html") {
            File newFlat =  new File(current.getPath() + "/" + pathsName[0]);
            newFlat.renameTo(fDest);
        } else {
            current.renameTo(fDest);
        }
        current.delete();
    }

    private Boolean downloadFile(String url, String dest) throws JSONException {
        Log.i(TAG, "downloadFile called with " + url);

        try {
            URL u = new URL(url);
            InputStream is = u.openStream();
            Log.i(TAG, "URL openStream");
            DataInputStream dis = new DataInputStream(is);
            byte[] buffer = new byte[1024];
            int length;
            File downFile = new File(this.context.getFilesDir()  + "/" + dest);

            Log.i(TAG, "mkdirs " + downFile.getPath());
            downFile.getParentFile().mkdirs();
            downFile.createNewFile();
            Log.i(TAG, "createNewFile ");
            FileOutputStream fos = new FileOutputStream(downFile);
            while ((length = dis.read(buffer))>0) {
                fos.write(buffer, 0, length);
            }
        } catch (Exception e) {
            Log.e(TAG, "downloadFile error", e);
            return false;
        }
        return true;
    }

    public String download(String url) {
        Log.i("CapacitorUpdater", "URL: " + url);
        try {
            String folderNameZip = this.randomString(10);
            File fileZip = new File(this.context.getFilesDir()  + "/" + folderNameZip);
            String folderNameUnZip = this.randomString(10);
            String version = this.randomString(10);
            String folderName = basePathHot + "/" + version;
            Boolean downloaded = this.downloadFile(url, folderNameZip);
            if(!downloaded) return null;
            Boolean unzipped = this.unzip(folderNameZip, folderNameUnZip);
            if(!unzipped) return null;
            fileZip.delete();
            this.flattenAssets(folderNameUnZip, folderName);
            return version;
        } catch (Exception e) {
            Log.e("TAG", "updateApp error", e);
            return null;
        }
    }

    public ArrayList<String> list() {
        ArrayList<String> res = new ArrayList<String>();
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot);
        Log.i(TAG, "list File : " + destHot.getPath());
        if (destHot.exists()) {
            for (File i : destHot.listFiles()) {
                res.add(i.getPath());
            }
        } else {
            Log.i(TAG, "NO version available" + destHot);
        }
        return res;
    }

    public Boolean delete(String version) {
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot + "/" + version);
        Log.i(TAG, "delete File : " + destHot.getPath());
        if (destHot.exists()) {
            destHot.delete();
            return true;
        }
        Log.i(TAG, "File not removed.");
        return false;
    }

    public Boolean set(String version) {
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot + "/" + version);
        Log.i(TAG, "set File : " + destHot.getPath());
        if (destHot.exists()) {
            lastPathHot = destHot.getPath();
            return true;
        }
        return false;
    }
    public String getLastPathHot() {
        return lastPathHot;
    }
}
