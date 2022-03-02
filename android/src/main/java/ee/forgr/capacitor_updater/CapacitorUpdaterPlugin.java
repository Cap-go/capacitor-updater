package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.Application;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.getcapacitor.CapConfig;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.util.JSONUtils;

import org.json.JSONException;

import java.io.IOException;
import java.util.ArrayList;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin implements Application.ActivityLifecycleCallbacks {
    private String TAG = "Capacitor-updater";
    private CapacitorUpdater implementation;
    private SharedPreferences prefs;
    private SharedPreferences.Editor editor;
    private String autoUpdateUrl = null;

    @Override
    public void load() {
        super.load();
        this.prefs = this.getContext().getSharedPreferences("CapWebViewSettings", Activity.MODE_PRIVATE);
        this.editor = prefs.edit();
        implementation = new CapacitorUpdater(this.getContext());
        CapConfig config = CapConfig.loadDefault(getActivity());
        implementation.appId = config.getString("appId", "");
        implementation.statsUrl = getConfig().getString("statsUrl", "https://capgo.app/api/stats");
        this.autoUpdateUrl = getConfig().getString("autoUpdateUrl");
        if (this.autoUpdateUrl == null || this.autoUpdateUrl.equals("")) return;
        Application application = (Application) this.getContext().getApplicationContext();
        application.registerActivityLifecycleCallbacks(this);
        onActivityStarted(getActivity());
    }

    @PluginMethod
    public void download(PluginCall call) {
        new Thread(new Runnable(){
            @Override
            public void run() {
                String url = call.getString("url");
                String res = implementation.download(url);
                if ((res) != null) {
                    JSObject ret = new JSObject();
                    ret.put("version", res);
                    call.resolve(ret);
                } else {
                    call.reject("download failed");
                }
            }
        }).start();
    }

    private boolean _reload() {
        String pathHot = implementation.getLastPathHot();
        Log.i(TAG, "getLastPathHot : " + pathHot);
        this.bridge.setServerBasePath(pathHot);
        return true;
    }
    @PluginMethod
    public void reload(PluginCall call) {
        if (this._reload()) {
            call.resolve();
        } else {
            call.reject("reload failed");
        }
    }
    @PluginMethod
    public void set(PluginCall call) {
        String version = call.getString("version");
        String versionName = call.getString("versionName", version);
        Boolean res = implementation.set(version, versionName);

        if (!res) {
            call.reject("Update failed, version don't exist");
        } else {
            String pathHot = implementation.getLastPathHot();
            Log.i(TAG, "getLastPathHot : " + pathHot);
            this.bridge.setServerBasePath(pathHot);
            call.resolve();
        }
    }

    @PluginMethod
    public void delete(PluginCall call) {
        String version = call.getString("version");
        try {
            Boolean res = implementation.delete(version, "");
            if (res) {
                call.resolve();
            } else {
                call.reject("Delete failed, version don't exist");
            }
        } catch(IOException ex) {
            Log.e("CapacitorUpdater", "An unexpected error occurred during deletion of folder. Message: " + ex.getMessage());
            call.reject("An unexpected error occurred during deletion of folder.");
        }
    }

    @PluginMethod
    public void list(PluginCall call) {
        ArrayList<String> res = implementation.list();
        JSObject ret = new JSObject();
        ret.put("versions", new JSArray(res));
        call.resolve(ret);
    }

    private boolean _reset() {
        implementation.reset();
        String pathHot = implementation.getLastPathHot();
        this.bridge.setServerAssetPath(pathHot);
        return true;
    }
    @PluginMethod
    public void reset(PluginCall call) {
        this._reset();
        call.resolve();
    }

    @PluginMethod
    public void current(PluginCall call) {
        String pathHot = implementation.getLastPathHot();
        JSObject ret = new JSObject();
        String current = pathHot.length() >= 10 ? pathHot.substring(pathHot.length() - 10) : "default";
        ret.put("current", current);
        call.resolve(ret);
    }

    @PluginMethod
    public void versionName(PluginCall call) {
        String name = implementation.getVersionName();
        JSObject ret = new JSObject();
        ret.put("versionName", name);
        call.resolve(ret);
    }
    @PluginMethod
    public void notifyAppReady(PluginCall call) {
        editor.putBoolean("notifyAppReady", true);
        editor.commit();
        call.resolve();
    }

    @PluginMethod
    public void delayUpdate(PluginCall call) {
        editor.putBoolean("delayUpdate", true);
        editor.commit();
        call.resolve();
    }

    @Override
    public void onActivityStarted(@NonNull Activity activity) {
        Log.i(TAG, "Check for update in the server");
        if (autoUpdateUrl == null || autoUpdateUrl.equals("")) return;
        new Thread(new Runnable(){
            @Override
            public void run() {
                implementation.getLatest(autoUpdateUrl, (res) -> {
                    try {
                        String currentVersion = implementation.getVersionName();
                        String newVersion = (String) res.get("version");
                        String failingVersion = prefs.getString("failingVersion", "");
                        Log.i(TAG, "currentVersion " + currentVersion + ", newVersion " + newVersion + ", failingVersion " + failingVersion + ".");
                        if (!newVersion.equals(currentVersion) && !newVersion.equals(failingVersion)) {
                            new Thread(new Runnable(){
                                @Override
                                public void run() {
                                    // Do network action in this function
                                    try {
                                        String dl = implementation.download((String) res.get("url"));
                                        Log.i(TAG, "New version: " + newVersion + " found. Current is " + (currentVersion == "" ? "builtin" : currentVersion) + ", next backgrounding will trigger update.");
                                        editor.putString("nextVersion", dl);
                                        editor.putString("nextVersionName", (String) res.get("version"));
                                        editor.commit();
                                    } catch (JSONException e) {
                                        e.printStackTrace();
                                    }
                                }
                            }).start();
                        }
                    } catch (JSONException e) {
                        e.printStackTrace();
                    }
                });
            }
        }).start();
    }

    @Override
    public void onActivityStopped(@NonNull Activity activity) {
        String pathHot = implementation.getLastPathHot();
        Log.i(TAG, "Check for waiting update");
        String nextVersion = prefs.getString("nextVersion", "");
        Boolean delayUpdate = prefs.getBoolean("delayUpdate", false);
        editor.putBoolean("delayUpdate", false);
        editor.commit();
        if (delayUpdate) {
            Log.i(TAG, "Update delayed to next backgrounding");
            return;
        }
        String nextVersionName = prefs.getString("nextVersionName", "");
        String pastVersion = prefs.getString("pastVersion", "");
        String pastVersionName = prefs.getString("pastVersionName", "");
        Boolean notifyAppReady = prefs.getBoolean("notifyAppReady", false);
        String tmpCurVersion = implementation.getLastPathHot();
        String curVersion = tmpCurVersion.substring(tmpCurVersion.lastIndexOf('/') +1);
        String curVersionName = implementation.getVersionName();

        Log.i(TAG, "next version: " + nextVersionName + ", past version: " + pastVersionName);
        if (!nextVersion.equals("") && !nextVersionName.equals("")) {
            Boolean res = implementation.set(nextVersion, nextVersionName);
            if (res) {
                if (this._reload()) {
                    Log.i(TAG, "Auto update to version: " + nextVersionName);
                }
                editor.putString("nextVersion", "");
                editor.putString("nextVersionName", "");
                editor.putString("pastVersion", curVersion);
                editor.putString("pastVersionName", curVersionName);
                editor.putBoolean("notifyAppReady", false);
                editor.commit();
            }
        } else if (!notifyAppReady && !pathHot.equals("public")) {
            Log.i(TAG, "notifyAppReady never trigger");
            Log.i(TAG, "Version: " + curVersionName + ", is considered broken");
            Log.i(TAG, "Will downgraded to " + pastVersionName + " for next start");
            Log.i(TAG, "Don't forget to trigger 'notifyAppReady()' in js code to validate a version.");
            if (!pastVersion.equals("") && !pastVersionName.equals("")) {
                Boolean res = implementation.set(pastVersion, pastVersionName);
                if (res) {
                    if (this._reload()) {
                        Log.i(TAG, "Revert update to version: " + pastVersionName);
                    }
                    editor.putString("pastVersion", "");
                    editor.putString("pastVersionName", "");
                    editor.commit();
                }
            } else {
                if (this._reset()) {
                    Log.i(TAG, "Auto reset done");
                }
            }
            editor.putString("failingVersion", curVersionName);
            editor.commit();
            try {
                Boolean res = implementation.delete(curVersion, curVersionName);
                if (res) {
                    Log.i(TAG, "Delete failing version: " + curVersionName);
                }
            } catch (IOException e) {
                e.printStackTrace();
            }
        } else if (!pastVersion.equals("")) {
            Log.i(TAG, "Validated version: " + curVersionName);
            try {
                Boolean res = implementation.delete(pastVersion, pastVersionName);
                if (res) {
                    Log.i(TAG, "Delete past version: " + pastVersionName);
                }
            } catch (IOException e) {
                e.printStackTrace();
            }
            editor.putString("pastVersion", "");
            editor.putString("pastVersionName", "");
            editor.commit();
        }

    }

    @Override
    public void onActivityResumed(@NonNull Activity activity) {

    }

    @Override
    public void onActivityPaused(@NonNull Activity activity) {

    }
    @Override
    public void onActivityCreated(@NonNull Activity activity, @Nullable Bundle savedInstanceState) {

    }

    @Override
    public void onActivitySaveInstanceState(@NonNull Activity activity, @NonNull Bundle outState) {

    }

    @Override
    public void onActivityDestroyed(@NonNull Activity activity) {

    }
}
