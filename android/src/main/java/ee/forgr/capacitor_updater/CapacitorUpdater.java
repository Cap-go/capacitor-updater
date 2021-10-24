package ee.forgr.capacitor_updater;

import android.content.res.AssetManager;
import org.apache.commons.io.FileUtils;
import android.util.Log;
import org.json.JSONException;
import android.os.AsyncTask;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;

public class CapacitorUpdater {

    private String generateFolderName() {
        byte[] array = new byte[10];
        new Random().nextBytes(array);
        String generatedString = new String(array, Charset.forName("UTF-8"));
        return generatedString;
    }

    private void copyFile(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[1024];
        int read;
        while((read = in.read(buffer)) != -1){
            out.write(buffer, 0, read);
        }
    }

    private Boolean copyAssets(String assetPath, String targetDir) throws IOException {
        String[] files = null;
        try {
            assetManager = cordova.getContext().getAssets();
            files = assetManager.list(assetPath);
        } catch (IOException e) {
            Log.e("tag", "Failed to get asset file list.", e);
        }
        if (files != null) for (String filename : files) {
            InputStream in = null;
            OutputStream out = null;
            try {
                if (assetManager.list(assetPath + "/" + filename).length > 0) {
                    File newDir = new File(targetDir, filename);
                    newDir.mkdir();
                    copyAssets(assetPath + "/" + filename, newDir.getPath());
                    continue;
                }
                in = assetManager.open(assetPath + "/" + filename);
                File destDir = new File(targetDir);
                if (!destDir.exists()) {
                    destDir.mkdirs();
                }
                File outFile = new File(targetDir, filename);
                out = new FileOutputStream(outFile);
                copyFile(in, out);
            } catch(IOException e) {
                Log.e("tag", "Failed to copy asset file: " + filename, e);
                return false;
            }
            finally {
                if (in != null) {
                    try {
                        in.close();
                    } catch (IOException e) {
                        // NOOP
                    }
                }
                if (out != null) {
                    try {
                        out.close();
                    } catch (IOException e) {
                        // NOOP
                    }
                }
                return true;
            }
        }
    }

    /**
    * recursively remove a directory or a file
    *
    */
    public Boolean remove(String target) throws JSONException {
        Log.i("recursiveRemove called with " + target);
        File dest = new File(target);
        final PluginResult result;

        if (!dest.exists()) {
            Log.i("file or directory does not exist " + target);
            return false;
        }
        try {
            FileUtils.forceDelete(dest);
        } catch (IOException e) {
            Log.i("Cannot delete file or directory " + target, e.getMessage());
            return false;
        }
        return true;
    }

    // Use thread to copy assets to a temporary directory in background
    // public class DownloadandCopy extends AsyncTask<Void, Void, String>   {
    //     @Override protected String doInBackground(Void... params) {
    //         this.downloadFile(url, folderName)
    //     }
    //     @Override protected void onPostExecute(String result) {
    //         this.copyAssets(source, 'public')
    //     }
    // }


    private void unzip(final PluginCall call) {
        new AsyncTask<Void, Void, Void>() {
            @Override
            protected Void doInBackground(Void... params) {
                try {
                    File zipFile = new File(new URI(call.getString("zipFile")));
                    File targetDirectory = new File(new URI(call.getString("targetDirectory")));
                    ZipInputStream zis = new ZipInputStream(
                    new BufferedInputStream(new FileInputStream(zipFile)));
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
                    } finally {
                        zis.close();
                        call.resolve();
                    }
                } catch (Exception e) {
                    call.reject("An error occurred when trying to unzip package. " + e.getMessage());
                }

                return null;
            }
        }.execute();
    }

    private Boolean downloadFile(String url, String dest) throws JSONException {
        Log.i("downloadFile called with " + url);

        try {
            URL u = new URL(url);
            InputStream is = u.openStream();
            DataInputStream dis = new DataInputStream(is);
            byte[] buffer = new byte[1024];
            int length;
            File downFile = new File(dest);

            downFile.getParentFile().mkdirs();
            downFile.createNewFile();
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

    public Boolean updateApp(String url) {
        Log.i("updateApp", url);
        try {
            String folderName = this.generateFolderName();
            Boolean downloaded = this.downloadFile(url, folderName);
            if(!downloaded) return false;
            Boolean copied = this.copyAssets(source, "public");
            if(!copied) return false;
            return true;
        } catch (Exception e) {
            Log.e(TAG, "updateApp error", e);
            return false;
        }
    }
}
