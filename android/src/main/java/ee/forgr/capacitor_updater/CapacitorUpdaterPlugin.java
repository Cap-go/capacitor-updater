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
    private final String TAG = "Capacitor-updater";
    private CapacitorUpdater implementation;
    private SharedPreferences prefs;
    private SharedPreferences.Editor editor;
    private static final String autoUpdateUrlDefault = "https://capgo.app/api/auto_update";
    private static final String statsUrlDefault = "https://capgo.app/api/stats";
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
            this.implementation = new CapacitorUpdater(this.getContext(), this);
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.currentVersionNative = new Version(pInfo.versionName);
        } catch (final PackageManager.NameNotFoundException e) {
            e.printStackTrace();
            return;
        } catch (final Exception ex) {
            Log.e(this.TAG, "Error get currentVersionNative", ex);
            return;
        }

        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.appId = config.getString("appId", "");
        this.implementation.statsUrl = this.getConfig().getString("statsUrl", statsUrlDefault);
        this.autoUpdateUrl = this.getConfig().getString("autoUpdateUrl", autoUpdateUrlDefault);
        this.autoUpdate = this.getConfig().getBoolean("autoUpdate", false);
        this.resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);

        this.cleanupObsoleteVersions();

        if (this.autoUpdate || !"".equals(this.autoUpdateUrl)) {
            final Application application = (Application) this.getContext().getApplicationContext();
            application.registerActivityLifecycleCallbacks(this);
            this.onActivityStarted(this.getActivity());
        }

    }

    private void cleanupObsoleteVersions() {
        try {
            if (this.resetWhenUpdate) {
                final String lastRecordedVersion = this.prefs.getString("LatestVersionNative", "");
                if(!"".equals(lastRecordedVersion)) {
                    final Version previous = new Version(lastRecordedVersion);
                    try {
                        if (this.currentVersionNative.getMajor() > previous.getMajor()) {
                            this._reset(false);
                            final ArrayList<VersionInfo> res = this.implementation.list();
                            for (int i = 0; i < res.size(); i++) {
                                final VersionInfo version = res.get(i);
                                try {
                                    this.implementation.delete(version.getVersion());
                                } catch (final Exception e) {
                                    Log.e(this.TAG, "Failed to delete: " + version.getName(), e);
                                }
                            }
                        }
                        this.implementation.reset(true);
                    } catch (final Exception e) {
                        Log.e(this.TAG, "Could not determine the current version", e);
                    }
                }
            }
        } catch(final Exception e) {
            Log.e(this.TAG, "Error calculating previous native version", e);
        }

        this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
        this.editor.commit();
    }

    public void notifyDownload(final int percent) {
        try {
            final JSObject ret = new JSObject();
            ret.put("percent", percent);
            this.notifyListeners("download", ret);
        } catch (final Exception e) {
            Log.e(this.TAG, "Could not notify listeners", e);
        }
    }

    @PluginMethod
    public void getId(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("id", this.implementation.deviceID);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(this.TAG, "Could not get device id", e);
            call.reject("Could not get device id", e);
        }
    }

    @PluginMethod
    public void download(final PluginCall call) {
        new Thread(new Runnable(){
            @Override
            public void run() {
                try {
                    final String url = call.getString("url");
                    final VersionInfo downloaded = CapacitorUpdaterPlugin.this.implementation.download(url);
                    call.resolve(downloaded.toJSON());
                } catch (final IOException e) {
                    Log.e(CapacitorUpdaterPlugin.this.TAG, "download failed", e);
                    call.reject("download failed", e);
                }
            }
        }).start();
    }

    private boolean _reload() {
        final String path = this.implementation.getCurrentBundlePath();
        this.bridge.setServerAssetPath(path);

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
        final String versionName = call.getString("versionName", "");

        if(!"".equals(versionName)) {
            this.implementation.setVersionName(version, versionName);
        }

        if (!this.implementation.set(version)) {
            call.reject("Update failed, version " + version + " does not exist.");
        } else {
            this.reload(call);
        }
    }

    @PluginMethod
    public void delete(final PluginCall call) {
        final String version = call.getString("version");
        try {
            final Boolean res = this.implementation.delete(version);
            if (res) {
                call.resolve();
            } else {
                call.reject("Delete failed, version " + version + " does not exist");
            }
        } catch(final Exception ex) {
            Log.e(this.TAG, "An unexpected error occurred during deletion of folder. Message: " + ex.getMessage());
            call.reject("An unexpected error occurred during deletion of folder.");
        }
    }

    @PluginMethod
    public void list(final PluginCall call) {
        final ArrayList<VersionInfo> res = this.implementation.list();
        final JSObject ret = new JSObject();
        final JSArray values = new JSArray();
        for(final VersionInfo version : res) {
            values.put(version.toJSON());
        }
        ret.put("versions", values);
        call.resolve(ret);
    }

    private boolean _reset(final Boolean toLastFallback) {
        final VersionInfo fallback = this.implementation.getVersionFallback();
        if (toLastFallback && !fallback.isBuiltin()) {
            this.implementation.setVersionFallback(null);
            return this.implementation.set(fallback) && this._reload();
        }

        this.implementation.reset();

        if (this.bridge.getLocalServer() != null) {
            // if the server is not ready yet, hot reload is not needed
            final String path = this.implementation.getCurrentBundlePath();
            if(!this.bridge.getServerBasePath().equals(path)) {
                // Nothing to do
                this.bridge.setServerBasePath(path);
                return true;
            }
        }

        return false;
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
    public void current(final PluginCall call) {
        final JSObject ret = new JSObject();
        final VersionInfo bundle = this.implementation.getCurrentBundle();
        ret.put("bundle", bundle.toJSON());
        ret.put("native", this.currentVersionNative);
        call.resolve(ret);
    }

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        final VersionInfo version = this.implementation.getCurrentBundle();
        this.implementation.setVersionFallback(version);
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

        if (this.autoUpdateUrl.equals("")) {
            Log.i(this.TAG, "Auto-update is disabled in capacitor configuration.");
            return;
        }

        Log.i(this.TAG, "Check for update in the server");
        new Thread(new Runnable(){
            @Override
            public void run() {
                CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.autoUpdateUrl, (res) -> {
                    try {
                        if (res.has("message")) {
                            Log.i(CapacitorUpdaterPlugin.this.TAG, "message: " + res.get("message"));
                            if (res.has("major") && res.getBoolean("major") && res.has("version")) {
                                final JSObject ret = new JSObject();
                                ret.put("newVersion", (String) res.get("version"));
                                CapacitorUpdaterPlugin.this.notifyListeners("majorAvailable", ret);
                            }
                            return;
                        }
                        final VersionInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                        final String newVersion = (String) res.get("version");
                        final JSObject ret = new JSObject();
                        ret.put("newVersion", newVersion);
                        final String failingVersion = CapacitorUpdaterPlugin.this.prefs.getString("failingVersion", "");
                        if (!newVersion.equals("") && !newVersion.equals(failingVersion)) {
                            new Thread(new Runnable(){
                                @Override
                                public void run() {
                                    try {
                                        final VersionInfo next = CapacitorUpdaterPlugin.this.implementation.download((String) res.get("url"));
                                        Log.i(CapacitorUpdaterPlugin.this.TAG, "New version: " + newVersion + " found. Current is " + (current.getName().equals("") ? "builtin" : current.getName()) + ", next backgrounding will trigger update");

                                        CapacitorUpdaterPlugin.this.implementation.setVersionName(next.getVersion(), (String) res.get("version"));
                                        CapacitorUpdaterPlugin.this.implementation.setVersionNext(next);

                                        CapacitorUpdaterPlugin.this.editor.commit();
                                        CapacitorUpdaterPlugin.this.notifyListeners("updateAvailable", ret);
                                    } catch (final IOException e) {
                                        Log.e(CapacitorUpdaterPlugin.this.TAG,"Failed to download update", e);
                                    } catch (final JSONException e) {
                                        Log.e(CapacitorUpdaterPlugin.this.TAG,"Failed to process JSON", e);
                                    }
                                }
                            }).start();
                        } else {
                            Log.i(CapacitorUpdaterPlugin.this.TAG, "No need to update, " + current.getName() + " is the latest");
                        }
                    } catch (final JSONException e) {
                       Log.e(CapacitorUpdaterPlugin.this.TAG, "Failed to process JSON", e);
                    }
                });
            }
        }).start();
    }

    @Override
    public void onActivityStopped(@NonNull final Activity activity) {
        Log.i(this.TAG, "Check for waiting update");

        final Boolean delayUpdate = this.prefs.getBoolean("delayUpdate", false);
        this.editor.putBoolean("delayUpdate", false);
        this.editor.commit();

        if (delayUpdate) {
            Log.i(this.TAG, "Update delayed to next backgrounding");
            return;
        }

        final VersionInfo next = this.implementation.getVersionNext();
        final VersionInfo fallback = this.implementation.getVersionFallback();

        final VersionInfo current = this.implementation.getCurrentBundle();

        final Boolean builtin = this.implementation.isUsingBuiltin();
        final Boolean success = current.getStatus() == VersionStatus.SUCCESS;

        if (next != null && !next.isErrorStatus() && (next.getVersion() != current.getVersion())) {
            if (this.implementation.set(next) && this._reload()) {
                Log.i(this.TAG, "Auto update to version: " + next.getName());
                this.implementation.setVersionNext(null);
            } else {
                Log.e(this.TAG, "Auto update to version: " + next.getName() + " Failed!");
            }
        } else if (!success && !builtin) {
            Log.i(this.TAG, "Update failed: 'notifyAppReady()' was never called.");
            Log.i(this.TAG, "Version: " + current.getVersion() + ", is in error state.");
            Log.i(this.TAG, "Will fallback to version: " + fallback.getName() + " on application restart.");
            Log.i(this.TAG, "Did you forget to call 'notifyAppReady()' in your Capacitor App code?");

            if (!fallback.isBuiltin()) {
                final Boolean res = this.implementation.set(fallback);
                if (res && this._reload()) {
                    Log.i(this.TAG, "Revert to version: " + fallback.getName());
                } else {
                    Log.e(this.TAG, "Revert to version: " + fallback.getName() + " Failed!");
                }
            } else {
                if (this._reset(false)) {
                    Log.i(this.TAG, "Reverted to builtin bundle.");
                }
            }

            this.implementation.setVersionStatus(current.getVersion(), VersionStatus.ERROR);

            try {
                final Boolean res = this.implementation.delete(current.getVersion());
                if (res) {
                    Log.i(this.TAG, "Delete failing version: " + current.getName());
                }
            } catch (final IOException e) {
                Log.e(this.TAG, "Failed to delete failed version: " + current.getVersion(), e);
            }

        } else if (!fallback.isBuiltin()) {
            Log.i(this.TAG, "Validated version: " + current.getName());
            try {
                final Boolean res = this.implementation.delete(fallback.getVersion());
                if (res) {
                    Log.i(this.TAG, "Delete past version: " + fallback.getName());
                }
            } catch (final IOException e) {
                Log.e(this.TAG, "Failed to delete fallback version: " + fallback.getVersion(), e);
            }

            this.implementation.setVersionFallback(null);
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
