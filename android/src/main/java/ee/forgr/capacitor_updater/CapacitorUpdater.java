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
import java.net.URLConnection;
import java.security.SecureRandom;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.ArrayList;
import android.provider.Settings.Secure;

interface Callback {
    void callback(JSONObject jsonObject);
}

public class CapacitorUpdater {
    public String statsUrl = "";
    public String appId = "";
    public String deviceID = "";

    private final CapacitorUpdaterPlugin plugin;
    private String versionBuild = "";
    private String TAG = "Capacitor-updater";
    private Context context;
    private String basePathHot = "versions";
    private SharedPreferences prefs;
    private SharedPreferences.Editor editor;

    static final String AB = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    static SecureRandom rnd = new SecureRandom();

    private int calcTotalPercent(int percent, int min, int max) {
        return (percent * (max - min)) / 100 + min;
    }

    private String randomString(int len){
        StringBuilder sb = new StringBuilder(len);
        for(int i = 0; i < len; i++)
            sb.append(AB.charAt(rnd.nextInt(AB.length())));
        return sb.toString();
    }

    public CapacitorUpdater (Context context) {
        this.context = context;
        this.plugin = new CapacitorUpdaterPlugin();
        this.prefs = context.getSharedPreferences("CapWebViewSettings", Activity.MODE_PRIVATE);
        this.editor = prefs.edit();
        this.deviceID = Secure.getString(context.getContentResolver(), Secure.ANDROID_ID);
        PackageInfo pInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
        this.versionBuild = pInfo.versionName;
    }
    public CapacitorUpdater (Context context, CapacitorUpdaterPlugin plugin) {
        this.context = context;
        this.plugin = plugin;
        this.prefs = context.getSharedPreferences("CapWebViewSettings", Activity.MODE_PRIVATE);
        this.editor = prefs.edit();
        this.deviceID = Secure.getString(context.getContentResolver(), Secure.ANDROID_ID);
        PackageInfo pInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
        this.versionBuild = pInfo.versionName;
    }

    private Boolean unzip(String source, String dest) {
        File zipFile = new File(this.context.getFilesDir()  + "/" + source);
        File targetDirectory = new File(this.context.getFilesDir()  + "/" + dest);
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
            int buffLength = 8192;
            byte[] buffer = new byte[buffLength];
            long totalLength = zipFile.length();
            long readedLength = buffLength;
            int percent = 0;
            this.plugin.notifyDownload(75);
            while ((ze = zis.getNextEntry()) != null) {
                File file = new File(targetDirectory, ze.getName());
                String canonicalPath = file.getCanonicalPath();
                String canonicalDir = (new File(String.valueOf(targetDirectory))).getCanonicalPath();
                File dir = ze.isDirectory() ? file : file.getParentFile();
                if (!canonicalPath.startsWith(canonicalDir)) {
                    throw new FileNotFoundException("SecurityException, Failed to ensure directory is the start path : " +
                            canonicalDir + " of " + canonicalPath);
                }
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
                int newPercent = (int)((readedLength * 100) / totalLength);
                if (totalLength > 1 && newPercent != percent) {
                    percent = newPercent;
                    this.plugin.notifyDownload(calcTotalPercent((int)percent, 75, 90));
                }
                readedLength += ze.getCompressedSize();
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

    private Boolean flattenAssets(String source, String dest) {
        File current = new File(this.context.getFilesDir()  + "/" + source);
        if (!current.exists()) {
            return false;
        }
        File fDest = new File(this.context.getFilesDir()  + "/" + dest);
        fDest.getParentFile().mkdirs();
        String[] pathsName = current.list();
        if (pathsName == null || pathsName.length == 0) {
            return false;
        }
        if (pathsName.length == 1 && !pathsName[0].equals("index.html")) {
            File newFlat =  new File(current.getPath() + "/" + pathsName[0]);
            newFlat.renameTo(fDest);
        } else {
            current.renameTo(fDest);
        }
        current.delete();
        return true;
    }

    private Boolean downloadFile(String url, String dest) throws JSONException {
        try {
            URL u = new URL(url);
            URLConnection uc = u.openConnection();
            InputStream is = u.openStream();
            DataInputStream dis = new DataInputStream(is);
            long totalLength = uc.getContentLength();
            int buffLength = 1024;
            byte[] buffer = new byte[buffLength];
            int length;
            File downFile = new File(this.context.getFilesDir()  + "/" + dest);
            downFile.getParentFile().mkdirs();
            downFile.createNewFile();
            FileOutputStream fos = new FileOutputStream(downFile);
            int readedLength = buffLength;
            int percent = 0;
            this.plugin.notifyDownload(10);
            while ((length = dis.read(buffer))>0) {
                fos.write(buffer, 0, length);
                int newPercent = (int)((readedLength * 100) / totalLength);
                if (totalLength > 1 && newPercent != percent) {
                    percent = newPercent;
                    this.plugin.notifyDownload(calcTotalPercent(percent, 10, 70));
                }
                readedLength += length;
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
            this.plugin.notifyDownload(0);
            String folderNameZip = this.randomString(10);
            File fileZip = new File(this.context.getFilesDir()  + "/" + folderNameZip);
            String folderNameUnZip = this.randomString(10);
            String version = this.randomString(10);
            String folderName = basePathHot + "/" + version;
            this.plugin.notifyDownload(5);
            Boolean downloaded = this.downloadFile(url, folderNameZip);
            if(!downloaded) return "";
            this.plugin.notifyDownload(71);
            Boolean unzipped = this.unzip(folderNameZip, folderNameUnZip);
            if(!unzipped) return "";
            fileZip.delete();
            this.plugin.notifyDownload(91);
            Boolean flatt = this.flattenAssets(folderNameUnZip, folderName);
            if(!flatt) return "";
            this.plugin.notifyDownload(100);
            return version;
        } catch (Exception e) {
            Log.e(TAG, "updateApp error", e);
            return "";
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
            Log.i(TAG, "No version available" + destHot);
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
        StringRequest stringRequest = new StringRequest(Request.Method.GET, url,
        new Response.Listener<String>() {
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
                Log.e(TAG, "Error getting Latest" +  error);
            }
        }) {     
            @Override
            public Map<String, String> getHeaders() throws AuthFailureError { 
                    Map<String, String>  params = new HashMap<String, String>();  
                    params.put("cap_device_id", this.deviceID);
                    params.put("cap_app_id", this.appId);
                    params.put("cap_version_build", this.versionBuild);
                    params.put("cap_version_name", this.getVersionName());
                    return params;
            }
        };
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
        this.sendStats("reset", version);
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
            json.put("platform", "android");
            json.put("action", action);
            json.put("version_name", version);
            json.put("device_id", this.deviceID);
            json.put("version_build", this.versionBuild);
            json.put("app_id", this.appId);
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
                        Log.e(TAG, "Stats error responseCode: " + responseCode);
                    } else {
                        Log.i(TAG, "Stats send for \"" + action + "\", version " + version);
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
