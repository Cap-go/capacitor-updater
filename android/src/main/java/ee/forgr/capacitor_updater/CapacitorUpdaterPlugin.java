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
        implementation = new CapacitorUpdater(this.getContext(), this);
        CapConfig config = CapConfig.loadDefault(getActivity());
        implementation.appId = config.getString("appId", "");
        implementation.statsUrl = getConfig().getString("statsUrl", "https://capgo.app/api/stats");
        this.autoUpdateUrl = getConfig().getString("autoUpdateUrl");
        if (this.autoUpdateUrl == null || this.autoUpdateUrl.equals("")) return;
        Application application = (Application) this.getContext().getApplicationContext();
        application.registerActivityLifecycleCallbacks(this);
        onActivityStarted(getActivity());
    }

    public void notifyDownload(int percent) {
        JSObject ret = new JSObject();
        ret.put("percent", percent);
        notifyListeners("download", ret);
    }

    @PluginMethod
    public void download(PluginCall call) {
        new Thread(new Runnable(){
            @Override
            public void run() {
                String url = call.getString("url");
                String res = implementation.download(url);
                if (!res.equals("")) {
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
            call.reject("Update failed, version " + version + " doesn't exist");
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
                call.reject("Delete failed, version " + version + " doesn't exist");
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

    private boolean _reset(Boolean toAutoUpdate) {
        String version = prefs.getString("LatestVersionAutoUpdate", "");
        String versionName = prefs.getString("LatestVersionNameAutoUpdate", "");
        if (toAutoUpdate && !version.equals("") && !versionName.equals("")) {
            Boolean res = implementation.set(version, versionName);
            return res && this._reload();
        }
        implementation.reset();
        String pathHot = implementation.getLastPathHot();
        this.bridge.setServerAssetPath(pathHot);
        return true;
    }

    @PluginMethod
    public void reset(PluginCall call) {
        Boolean toAutoUpdate = call.getBoolean("toAutoUpdate");
        if (this._reset(toAutoUpdate)) {
            call.resolve();
            return;
        }
        call.reject("✨  Capacitor-updater: Reset failed");
    }

    @PluginMethod
    public void versionName(PluginCall call) {
        String name = implementation.getVersionName();
        JSObject ret = new JSObject();
        ret.put("versionName", name);
        call.resolve(ret);
    }

    @PluginMethod
    public void current(PluginCall call) {
        String pathHot = implementation.getLastPathHot();
        JSObject ret = new JSObject();
        String current = pathHot.length() >= 10 ? pathHot.substring(pathHot.length() - 10) : "builtin";
        ret.put("current", current);
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

    @PluginMethod
    public void cancelDelay(PluginCall call) {
        editor.putBoolean("delayUpdate", false);
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
                        if (!newVersion.equals(currentVersion) && !newVersion.equals(failingVersion)) {
                            new Thread(new Runnable(){
                                @Override
                                public void run() {
                                    try {
                                        String dl = implementation.download((String) res.get("url"));
                                        if (dl.equals("")) {
                                            Log.i(TAG, "Download version: " + newVersion + " failed");
                                            return;
                                        }
                                        Log.i(TAG, "New version: " + newVersion + " found. Current is " + (currentVersion.equals("") ? "builtin" : currentVersion) + ", next backgrounding will trigger update");
                                        editor.putString("nextVersion", dl);
                                        editor.putString("nextVersionName", (String) res.get("version"));
                                        editor.commit();
                                    } catch (JSONException e) {
                                        e.printStackTrace();
                                    }
                                }
                            }).start();
                        } else {
                            Log.i(TAG, "No need to update, " + currentVersion + " is the latest");
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
        Log.i(TAG, "Next version: " + nextVersionName + ", past version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName));
        if (!nextVersion.equals("") && !nextVersionName.equals("")) {
            Boolean res = implementation.set(nextVersion, nextVersionName);
            if (res && this._reload()) {
                Log.i(TAG, "Auto update to version: " + nextVersionName);
                editor.putString("LatestVersionAutoUpdate", nextVersion);
                editor.putString("LatestVersionNameAutoUpdate", nextVersionName);
                editor.putString("nextVersion", "");
                editor.putString("nextVersionName", "");
                editor.putString("pastVersion", curVersion);
                editor.putString("pastVersionName", curVersionName);
                editor.putBoolean("notifyAppReady", false);
                editor.commit();
            } else {
                Log.i(TAG, "Auto update to version: " + nextVersionName + "Failed");
            }
        } else if (!notifyAppReady && !pathHot.equals("public")) {
            Log.i(TAG, "notifyAppReady never trigger");
            Log.i(TAG, "Version: " + curVersionName + ", is considered broken");
            Log.i(TAG, "Will downgraded to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName) + " for next start");
            Log.i(TAG, "Don't forget to trigger 'notifyAppReady()' in js code to validate a version.");
            if (!pastVersion.equals("") && !pastVersionName.equals("")) {
                Boolean res = implementation.set(pastVersion, pastVersionName);
                if (res && this._reload()) {
                    Log.i(TAG, "Revert to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName));
                    editor.putString("LatestVersionAutoUpdate", pastVersion);
                    editor.putString("LatestVersionNameAutoUpdate", pastVersionName);
                    editor.putString("pastVersion", "");
                    editor.putString("pastVersionName", "");
                    editor.commit();
                } else {
                    Log.i(TAG, "Revert to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName) + "Failed");
                }
            } else {
                if (this._reset()) {
                    editor.putString("LatestVersionAutoUpdate", "");
                    editor.putString("LatestVersionNameAutoUpdate", "");
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

    // not use but necessary here to remove warnings
    @Override
    public void onActivityResumed(@NonNull Activity activity) {
        super.onActivityResumed();
    }

    @Override
    public void onActivityPaused(@NonNull Activity activity) {
        super.onActivityPaused();
    }
    @Override
    public void onActivityCreated(@NonNull Activity activity, @Nullable Bundle savedInstanceState) {
        super.onActivityCreated();
    }

    @Override
    public void onActivitySaveInstanceState(@NonNull Activity activity, @NonNull Bundle outState) {
        super.onActivitySaveInstanceState();
    }

    @Override
    public void onActivityDestroyed(@NonNull Activity activity) {
        super.onActivityDestroyed();
    }
}
