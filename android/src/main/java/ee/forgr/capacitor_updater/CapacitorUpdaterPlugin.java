package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.Application;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

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
        this.autoUpdateUrl = getConfig().getString("autoUpdateUrl");
        if (this.autoUpdateUrl == null || this.autoUpdateUrl.equals("")) return;
        Application application = (Application) this.getContext().getApplicationContext();
        application.registerActivityLifecycleCallbacks(this);
        onActivityStarted(this.getActivity());
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
        Log.i("CapacitorUpdater", "getLastPathHot : " + pathHot);
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
            Log.i("CapacitorUpdater", "getLastPathHot : " + pathHot);
            this.bridge.setServerBasePath(pathHot);
            call.resolve();
        }
    }

    @PluginMethod
    public void delete(PluginCall call) {
        String version = call.getString("version");
        try {
            Boolean res = implementation.delete(version);

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

    @PluginMethod
    public void reset(PluginCall call) {
        implementation.reset();
        String pathHot = implementation.getLastPathHot();
        this.bridge.setServerAssetPath(pathHot);
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

    @Override
    public void onActivityStarted(@NonNull Activity activity) {
        Log.i("CapacitorUpdater", "on foreground");
        if (autoUpdateUrl == null || autoUpdateUrl.equals("")) return;
        implementation.getLatest(autoUpdateUrl, (res) -> {
            try {
                String name = implementation.getVersionName();
                String newVersion = (String) res.get("version");
                if (!newVersion.equals(name)) {
                    new Thread(new Runnable(){
                        @Override
                        public void run() {
                            // Do network action in this function
                            try {
                                String dl = implementation.download((String) res.get("url"));
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

    @Override
    public void onActivityStopped(@NonNull Activity activity) {
        Log.i("CapacitorUpdater", "on  background");
        String nextVersion = prefs.getString("nextVersion", "");
        String nextVersionName = prefs.getString("nextVersionName", "");
        if (nextVersion.equals("") || nextVersionName.equals("")) return;
        Log.i("CapacitorUpdater", "set: " + nextVersion + " " + nextVersionName);
        Boolean res = implementation.set(nextVersion, nextVersionName);
        if (res) {
            if (this._reload()) {
                Log.i("CapacitorUpdater", "Auto update to VersionName: " + nextVersionName + ", Version: " + nextVersion);
            }
            editor.putString("nextVersion", "");
            editor.putString("nextVersionName", "");
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
