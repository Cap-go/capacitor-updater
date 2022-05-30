package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.Application;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
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
import io.github.g00fy2.versioncompare.Version;

import org.json.JSONException;

import java.io.IOException;
import java.util.ArrayList;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin implements Application.ActivityLifecycleCallbacks {
    private static final String autoUpdateUrlDefault = "https://capgo.app/api/auto_update";
    private static final String statsUrlDefault = "https://capgo.app/api/stats";
    private final String TAG = "Capacitor-updater";
    private CapacitorUpdater implementation;

    private SharedPreferences prefs;
    private SharedPreferences.Editor editor;

    private String autoUpdateUrl = "";
    private Version currentVersionNative;
    private Boolean autoUpdate = false;
    private Boolean resetWhenUpdate = true;

    @Override
    public void load() {
        super.load();
        this.prefs = this.getContext().getSharedPreferences("CapWebViewSettings", Activity.MODE_PRIVATE);
        this.editor = this.prefs.edit();
        try {
            this.implementation = new CapacitorUpdater(this.getContext()) {
                @Override
                public void notifyDownload(final int percent) {
                    CapacitorUpdaterPlugin.this.notifyDownload(percent);
                }
            };
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.currentVersionNative = new Version(pInfo.versionName);
        } catch (final PackageManager.NameNotFoundException e) {
            Log.e(this.TAG, "Error instantiating implementation", e);
            return;
        } catch (final Exception ex) {
            Log.e(this.TAG, "Error getting current native app version", ex);
            return;
        }
        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.setAppId(config.getString("appId", ""));
        this.implementation.setStatsUrl(this.getConfig().getString("statsUrl", statsUrlDefault));
        this.autoUpdateUrl = this.getConfig().getString("autoUpdateUrl", autoUpdateUrlDefault);
        this.autoUpdate = this.getConfig().getBoolean("autoUpdate", false);
        this.resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);
        if (this.resetWhenUpdate) {
            final Version LatestVersionNative = new Version(this.prefs.getString("LatestVersionNative", ""));
            try {
                if (!LatestVersionNative.equals("") && this.currentVersionNative.getMajor() > LatestVersionNative.getMajor()) {
                    this._reset(false);
                    this.editor.putString("LatestVersionAutoUpdate", "");
                    this.editor.putString("LatestVersionNameAutoUpdate", "");
                    final ArrayList<String> res = this.implementation.list();
                    for (int i = 0; i < res.size(); i++) {
                        try {
                            final String version = res.get(i);
                            this.implementation.delete(version, "");
                            Log.i(this.TAG, "Deleted obsolete version: " + version);
                        } catch (final IOException e) {
                            Log.e(CapacitorUpdaterPlugin.this.TAG, "error deleting version", e);
                        }
                    }
                }
                this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
                this.editor.commit();
            } catch (final Exception ex) {
                Log.e(this.TAG, "Cannot get the current version " + ex.getMessage());
            }
        }
        if (!this.autoUpdate || this.autoUpdateUrl.equals("")) return;
        final Application application = (Application) this.getContext().getApplicationContext();
        application.registerActivityLifecycleCallbacks(this);
        this.onActivityStarted(this.getActivity());
    }

    public void notifyDownload(final int percent) {
        final JSObject ret = new JSObject();
        ret.put("percent", percent);
        this.notifyListeners("download", ret);
    }

    @PluginMethod
    public void getId(final PluginCall call) {
        final JSObject ret = new JSObject();
        ret.put("id", this.implementation.getDeviceID());
        call.resolve(ret);
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        final JSObject ret = new JSObject();
        ret.put("version", this.implementation.pluginVersion);
        call.resolve(ret);
    }

    @PluginMethod
    public void download(final PluginCall call) {
        new Thread(new Runnable(){
            @Override
            public void run() {
                try {
                    final String url = call.getString("url");
                    final String version = CapacitorUpdaterPlugin.this.implementation.download(url);
                    final JSObject ret = new JSObject();
                    ret.put("version", version);
                    call.resolve(ret);
                } catch (final IOException e) {
                    Log.e(CapacitorUpdaterPlugin.this.TAG, "download failed", e);
                    call.reject("download failed", e);
                }
            }
        }).start();
    }

    private boolean _reload() {
        final String pathHot = this.implementation.getLastPathHot();
        this.bridge.setServerBasePath(pathHot);
        return true;
    }

    @PluginMethod
    public void reload(final PluginCall call) {
        if (this._reload()) {
            call.resolve();
        } else {
            call.reject("reload failed");
        }
    }

    @PluginMethod
    public void set(final PluginCall call) {
        final String version = call.getString("version");
        final String versionName = call.getString("versionName", version);
        final Boolean res = this.implementation.set(version, versionName);

        if (!res) {
            call.reject("Update failed, version " + version + " doesn't exist");
        } else {
            this.reload(call);
        }
    }

    @PluginMethod
    public void delete(final PluginCall call) {
        final String version = call.getString("version");
        try {
            final Boolean res = this.implementation.delete(version, "");
            if (res) {
                call.resolve();
            } else {
                call.reject("Delete failed, version " + version + " doesn't exist");
            }
        } catch(final IOException ex) {
            Log.e(this.TAG, "An unexpected error occurred during deletion of folder. Message: " + ex.getMessage());
            call.reject("An unexpected error occurred during deletion of folder.");
        }
    }

    @PluginMethod
    public void list(final PluginCall call) {
        final ArrayList<String> res = this.implementation.list();
        final JSObject ret = new JSObject();
        ret.put("versions", new JSArray(res));
        call.resolve(ret);
    }

    private boolean _reset(final Boolean toAutoUpdate) {
        final String version = this.prefs.getString("LatestVersionAutoUpdate", "");
        final String versionName = this.prefs.getString("LatestVersionNameAutoUpdate", "");
        if (toAutoUpdate && !version.equals("") && !versionName.equals("")) {
            final Boolean res = this.implementation.set(version, versionName);
            return res && this._reload();
        }
        this.implementation.reset();
        final String pathHot = this.implementation.getLastPathHot();
        if (this.bridge.getLocalServer() != null) {
            // if the server is not ready yet, hot reload is not needed
            this.bridge.setServerAssetPath(pathHot);
        }
        return true;
    }

    @PluginMethod
    public void reset(final PluginCall call) {
        final Boolean toAutoUpdate = call.getBoolean("toAutoUpdate", false);
        if (this._reset(toAutoUpdate)) {
            call.resolve();
            return;
        }
        call.reject("✨  Capacitor-updater: Reset failed");
    }

    @PluginMethod
    public void versionName(final PluginCall call) {
        final String name = this.implementation.getVersionName();
        final JSObject ret = new JSObject();
        ret.put("versionName", name);
        call.resolve(ret);
    }

    @PluginMethod
    public void current(final PluginCall call) {
        final String pathHot = this.implementation.getLastPathHot();
        final JSObject ret = new JSObject();
        final String current = pathHot.length() >= 10 ? pathHot.substring(pathHot.length() - 10) : "builtin";
        ret.put("current", current);
        ret.put("currentNative", this.currentVersionNative);
        call.resolve(ret);
    }

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        this.editor.putBoolean("notifyAppReady", true);
        this.editor.commit();
        call.resolve();
    }

    @PluginMethod
    public void delayUpdate(final PluginCall call) {
        this.editor.putBoolean("delayUpdate", true);
        this.editor.commit();
        call.resolve();
    }

    @PluginMethod
    public void cancelDelay(final PluginCall call) {
        this.editor.putBoolean("delayUpdate", false);
        this.editor.commit();
        call.resolve();
    }

    @Override
    public void onActivityStarted(@NonNull final Activity activity) {
//        disableRevert disableBreaking
        Log.i(this.TAG, "Check for update in the server");
        if (this.autoUpdateUrl.equals("")) return;
        new Thread(new Runnable(){
            @Override
            public void run() {
                CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.autoUpdateUrl, (res) -> {
                    try {
                        if (res.has("message")) {
                            Log.i(CapacitorUpdaterPlugin.this.TAG, "Capacitor-updater: " + res.get("message"));
                            if (res.has("major") && res.getBoolean("major") && res.has("version")) {
                                final JSObject ret = new JSObject();
                                ret.put("newVersion", (String) res.get("version"));
                                CapacitorUpdaterPlugin.this.notifyListeners("majorAvailable", ret);
                            }
                            return;
                        }
                        final String currentVersion = CapacitorUpdaterPlugin.this.implementation.getVersionName();
                        final String newVersion = (String) res.get("version");
                        final JSObject ret = new JSObject();
                        ret.put("newVersion", newVersion);
                        final String failingVersion = CapacitorUpdaterPlugin.this.prefs.getString("failingVersion", "");
                        if (!newVersion.equals("") && !newVersion.equals(failingVersion)) {
                            new Thread(new Runnable(){
                                @Override
                                public void run() {
                                    try {
                                        final String url = (String) res.get("url");
                                        final String dl = CapacitorUpdaterPlugin.this.implementation.download(url);
                                        if (dl.equals("")) {
                                            Log.i(CapacitorUpdaterPlugin.this.TAG, "Download version: " + newVersion + " failed");
                                            return;
                                        }
                                        Log.i(CapacitorUpdaterPlugin.this.TAG, "New version: " + newVersion + " found. Current is " + (currentVersion.equals("") ? "builtin" : currentVersion) + ", next backgrounding will trigger update");
                                        CapacitorUpdaterPlugin.this.editor.putString("nextVersion", dl);
                                        CapacitorUpdaterPlugin.this.editor.putString("nextVersionName", (String) res.get("version"));
                                        CapacitorUpdaterPlugin.this.editor.commit();
                                        CapacitorUpdaterPlugin.this.notifyListeners("updateAvailable", ret);
                                    } catch (final Exception e) {
                                        Log.e(CapacitorUpdaterPlugin.this.TAG, "error downloading file", e);
                                    }
                                }
                            }).start();
                        } else {
                            Log.i(CapacitorUpdaterPlugin.this.TAG, "No need to update, " + currentVersion + " is the latest");
                        }
                    } catch (final JSONException e) {
                        Log.e(CapacitorUpdaterPlugin.this.TAG, "error parsing JSON", e);
                    }
                });
            }
        }).start();
    }

    @Override
    public void onActivityStopped(@NonNull final Activity activity) {
        final String pathHot = this.implementation.getLastPathHot();
        Log.i(this.TAG, "Check for waiting update");
        final String nextVersion = this.prefs.getString("nextVersion", "");
        final Boolean delayUpdate = this.prefs.getBoolean("delayUpdate", false);
        this.editor.putBoolean("delayUpdate", false);
        this.editor.commit();
        if (delayUpdate) {
            Log.i(this.TAG, "Update delayed to next backgrounding");
            return;
        }
        final String nextVersionName = this.prefs.getString("nextVersionName", "");
        final String pastVersion = this.prefs.getString("pastVersion", "");
        final String pastVersionName = this.prefs.getString("pastVersionName", "");
        final Boolean notifyAppReady = this.prefs.getBoolean("notifyAppReady", false);
        final String tmpCurVersion = this.implementation.getLastPathHot();
        final String curVersion = tmpCurVersion.substring(tmpCurVersion.lastIndexOf('/') +1);
        final String curVersionName = this.implementation.getVersionName();
        if (!nextVersion.equals("") && !nextVersionName.equals("")) {
            final Boolean res = this.implementation.set(nextVersion, nextVersionName);
            if (res && this._reload()) {
                Log.i(this.TAG, "Auto update to version: " + nextVersionName);
                this.editor.putString("LatestVersionAutoUpdate", nextVersion);
                this.editor.putString("LatestVersionNameAutoUpdate", nextVersionName);
                this.editor.putString("nextVersion", "");
                this.editor.putString("nextVersionName", "");
                this.editor.putString("pastVersion", curVersion);
                this.editor.putString("pastVersionName", curVersionName);
                this.editor.putBoolean("notifyAppReady", false);
                this.editor.commit();
            } else {
                Log.i(this.TAG, "Auto update to version: " + nextVersionName + "Failed");
            }
        } else if (!notifyAppReady && !pathHot.equals("public")) {
            Log.i(this.TAG, "notifyAppReady never trigger");
            Log.i(this.TAG, "Version: " + curVersionName + ", is considered broken");
            Log.i(this.TAG, "Will downgraded to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName) + " for next start");
            Log.i(this.TAG, "Don't forget to trigger 'notifyAppReady()' in js code to validate a version.");
            this.implementation.sendStats("revert", curVersionName)
            if (!pastVersion.equals("") && !pastVersionName.equals("")) {
                final Boolean res = this.implementation.set(pastVersion, pastVersionName);
                if (res && this._reload()) {
                    Log.i(this.TAG, "Revert to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName));
                    this.editor.putString("LatestVersionAutoUpdate", pastVersion);
                    this.editor.putString("LatestVersionNameAutoUpdate", pastVersionName);
                    this.editor.putString("pastVersion", "");
                    this.editor.putString("pastVersionName", "");
                    this.editor.commit();
                } else {
                    Log.i(this.TAG, "Revert to version: " + (pastVersionName.equals("") ? "builtin" : pastVersionName) + "Failed");
                }
            } else {
                if (this._reset(false)) {
                    this.editor.putString("LatestVersionAutoUpdate", "");
                    this.editor.putString("LatestVersionNameAutoUpdate", "");
                    Log.i(this.TAG, "Auto reset done");
                }
            }
            this.editor.putString("failingVersion", curVersionName);
            this.editor.commit();
            try {
                final Boolean res = this.implementation.delete(curVersion, curVersionName);
                if (res) {
                    Log.i(this.TAG, "Deleted failing version: " + curVersionName);
                }
            } catch (final IOException e) {
                Log.e(CapacitorUpdaterPlugin.this.TAG, "error deleting version", e);
            }
        } else if (!pastVersion.equals("")) {
            Log.i(this.TAG, "Validated version: " + curVersionName);
            try {
                final Boolean res = this.implementation.delete(pastVersion, pastVersionName);
                if (res) {
                    Log.i(this.TAG, "Deleted past version: " + pastVersionName);
                }
            } catch (final IOException e) {
                Log.e(CapacitorUpdaterPlugin.this.TAG, "error deleting version", e);
            }
            this.editor.putString("pastVersion", "");
            this.editor.putString("pastVersionName", "");
            this.editor.commit();
        }
    }

    // not use but necessary here to remove warnings
    @Override
    public void onActivityResumed(@NonNull final Activity activity) {
    }

    @Override
    public void onActivityPaused(@NonNull final Activity activity) {
    }
    @Override
    public void onActivityCreated(@NonNull final Activity activity, @Nullable final Bundle savedInstanceState) {
    }

    @Override
    public void onActivitySaveInstanceState(@NonNull final Activity activity, @NonNull final Bundle outState) {
    }

    @Override
    public void onActivityDestroyed(@NonNull final Activity activity) {
    }
}
