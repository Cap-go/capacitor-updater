package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.util.Log;

import com.android.volley.RequestQueue;
import com.android.volley.Response;
import com.android.volley.VolleyError;
import com.android.volley.toolbox.StringRequest;
import com.android.volley.toolbox.Volley;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.SecureRandom;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.ArrayList;
import android.provider.Settings.Secure;

interface Callback {
    void callback(JSONObject jsonObject);
}

public class CapacitorUpdater {
    private String TAG = "Capacitor-updater";
    public String statsUrl = "";

    private Context context;
    private String basePathHot = "versions";
    private SharedPreferences prefs;
    private SharedPreferences.Editor editor;

    static final String AB = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    static SecureRandom rnd = new SecureRandom();

    private String randomString(int len){
        StringBuilder sb = new StringBuilder(len);
        for(int i = 0; i < len; i++)
            sb.append(AB.charAt(rnd.nextInt(AB.length())));
        return sb.toString();
    }

    public CapacitorUpdater (Context context) {
        this.context = context;
        this.prefs = context.getSharedPreferences("CapWebViewSettings", Activity.MODE_PRIVATE);
        this.editor = prefs.edit();
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
        if (pathsName.length == 1 && !pathsName[0].equals("index.html")) {
            File newFlat =  new File(current.getPath() + "/" + pathsName[0]);
            newFlat.renameTo(fDest);
        } else {
            current.renameTo(fDest);
        }
        current.delete();
    }

    private Boolean downloadFile(String url, String dest) throws JSONException {
        try {
            URL u = new URL(url);
            InputStream is = u.openStream();
            DataInputStream dis = new DataInputStream(is);
            byte[] buffer = new byte[1024];
            int length;
            File downFile = new File(this.context.getFilesDir()  + "/" + dest);
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

    private void deleteDirectory(File file) throws IOException {
        if (file.isDirectory()) {
            File[] entries = file.listFiles();
            if (entries != null) {
                for (File entry : entries) {
                    deleteDirectory(entry);
                }
            }
        }
        if (!file.delete()) {
            throw new IOException("Failed to delete " + file);
        }
    }

    public String download(String url) {
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
            Log.e(TAG, "updateApp error", e);
            return null;
        }
    }

    public ArrayList<String> list() {
        ArrayList<String> res = new ArrayList<String>();
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot);
        Log.i(TAG, "list File : " + destHot.getPath());
        if (destHot.exists()) {
            for (File i : destHot.listFiles()) {
                res.add(i.getName());
            }
        } else {
            Log.i(TAG, "NO version available" + destHot);
        }
        return res;
    }

    public Boolean delete(String version, String versionName) throws IOException {
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot + "/" + version);
        if (destHot.exists()) {
            deleteDirectory(destHot);
            return true;
        }
        Log.i(TAG, "Directory not removed: " + destHot.getPath());
        this.sendStats("delete", versionName);
        return false;
    }

    public Boolean set(String version, String versionName) {
        File destHot = new File(this.context.getFilesDir()  + "/" + basePathHot + "/" + version);
        File destIndex = new File(destHot.getPath()  + "/index.html");
        Log.i(TAG, "set File : " + destHot.getPath());
        if (destHot.exists() && destIndex.exists()) {
            editor.putString("lastPathHot", destHot.getPath());
            editor.putString("serverBasePath", destHot.getPath());
            editor.putString("versionName", versionName);
            editor.commit();
            sendStats("set", versionName);
            return true;
        }
        sendStats("set_fail", versionName);
        return false;
    }

    public void getLatest(String url, Callback callback) {
        Log.i(TAG, "Get Latest, URL: " + url);
        StringRequest stringRequest = new StringRequest(url, new Response.Listener<String>() {
            @Override
            public void onResponse(String response) {
                try {
                    JSONObject jsonObject = new JSONObject(response);
                    callback.callback(jsonObject);
                } catch (JSONException e) {
                    e.printStackTrace();
                }
            }
        }, new Response.ErrorListener() {
            @Override
            public void onErrorResponse(VolleyError error) {
                // Anything you want
                Log.e(TAG, "Error get Latest");
            }
        });
        RequestQueue requestQueue = Volley.newRequestQueue(this.context);
        requestQueue.add(stringRequest);
    }

    public String getLastPathHot() {
        return prefs.getString("lastPathHot", "");
    }

    public String getVersionName() {
        return prefs.getString("versionName", "");
    }

    public void reset() {        
        String version = prefs.getString("versionName", "");
        implementation.sendStats("reset", version);
        editor.putString("lastPathHot", "public");
        editor.putString("serverBasePath", "public");
        editor.putString("versionName", "");
        editor.commit();
    }

    public void sendStats(String action, String version) {
        if (statsUrl == "") { return; }
        URL url;
        JSONObject json = new JSONObject();
        String jsonString;
        try {
            url = new URL(statsUrl);
            String android_id = Secure.getString(context.getContentResolver(), Secure.ANDROID_ID);
            PackageInfo pInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            json.put("platform", "android");
            json.put("action", action);
            json.put("device_id", android_id);
            json.put("version_name", version);
            json.put("version_build", pInfo.versionName);
            json.put("app_id", pInfo.packageName);
            jsonString = json.toString();
        } catch (Exception ex) {
            Log.e(TAG, "Error get stats", ex);
            return;
        }
        new Thread(new Runnable(){
            @Override
            public void run() {
                HttpURLConnection con = null;
                try {
                    con = (HttpURLConnection) url.openConnection();
                    con.setRequestMethod("POST");
                    con.setRequestProperty("Content-Type", "application/json");
                    con.setRequestProperty("Accept", "application/json");
                    con.setRequestProperty("Content-Length", Integer.toString(jsonString.getBytes().length));
                    con.setDoOutput(true);
                    con.setConnectTimeout(500);
                    DataOutputStream wr = new DataOutputStream (con.getOutputStream());
                    wr.writeBytes(jsonString);
                    wr.close();
                    int responseCode = con.getResponseCode();
                    if (responseCode != 200) {
                        Log.e(TAG, "stats responseCode: " + responseCode);
                    } else {
                        Log.i(TAG, "Stats send for \"" + action + "\", version " + version + " in " + statsUrl);
                    }
                } catch (Exception ex) {
                    Log.e(TAG, "Error post stats", ex);
                } finally {
                    if (con != null) {
                        con.disconnect();
                    }
                }
            }
        }).start();
    }
}
