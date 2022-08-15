package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.Application;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.android.volley.toolbox.Volley;
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.plugin.WebView;

import io.github.g00fy2.versioncompare.Version;

import org.json.JSONException;

import java.io.IOException;
import java.net.MalformedURLException;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin implements Application.ActivityLifecycleCallbacks {
    private static final String updateUrlDefault = "https://api.capgo.app/updates";
    private static final String statsUrlDefault = "https://api.capgo.app/stats";
    private static final String DELAY_UPDATE = "delayUpdate";
    private static final String DELAY_UPDATE_VAL = "delayUpdateVal";

    private SharedPreferences.Editor editor;
    private SharedPreferences prefs;
    private CapacitorUpdater implementation;

    private Integer appReadyTimeout = 10000;
    private Boolean autoDeleteFailed = true;
    private Boolean autoDeletePrevious = true;
    private Boolean autoUpdate = false;
    private String updateUrl = "";
    private Version currentVersionNative;
    private Boolean resetWhenUpdate = true;

    private volatile Thread appReadyCheck;

    @Override
    public void load() {
        super.load();
        this.prefs = this.getContext().getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Activity.MODE_PRIVATE);
        this.editor = this.prefs.edit();

        try {
            this.implementation = new CapacitorUpdater() {
                @Override
                public void notifyDownload(final String id, final int percent) {
                    CapacitorUpdaterPlugin.this.notifyDownload(id, percent);
                }
            };
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.implementation.versionBuild = pInfo.versionName;
            this.implementation.versionCode = Integer.toString(pInfo.versionCode);
            this.implementation.requestQueue = Volley.newRequestQueue(this.getContext());
            this.currentVersionNative = new Version(pInfo.versionName);
        } catch (final PackageManager.NameNotFoundException e) {
            Log.e(CapacitorUpdater.TAG, "Error instantiating implementation", e);
            return;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error getting current native app version", e);
            return;
        }

        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.appId = config.getString("appId", "");
        this.implementation.statsUrl = this.getConfig().getString("statsUrl", statsUrlDefault);
        this.implementation.documentsDir = this.getContext().getFilesDir();
        this.implementation.prefs = this.prefs;
        this.implementation.editor = this.editor;
        this.implementation.versionOs = Build.VERSION.RELEASE;
        this.implementation.deviceID = this.prefs.getString("appUUID", UUID.randomUUID().toString());
        this.editor.putString("appUUID", this.implementation.deviceID);
        Log.e(CapacitorUpdater.TAG, "init for device " + this.implementation.deviceID);

        this.autoDeleteFailed = this.getConfig().getBoolean("autoDeleteFailed", true);
        this.autoDeletePrevious = this.getConfig().getBoolean("autoDeletePrevious", true);
        this.updateUrl = this.getConfig().getString("updateUrl", updateUrlDefault);
        this.autoUpdate = this.getConfig().getBoolean("autoUpdate", false);
        this.appReadyTimeout = this.getConfig().getInt("appReadyTimeout", 10000);
        this.resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);

        if (this.resetWhenUpdate) {
            this.cleanupObsoleteVersions();
        }
        final Application application = (Application) this.getContext().getApplicationContext();
        application.registerActivityLifecycleCallbacks(this);
        this.onActivityStarted(this.getActivity());
        this._checkCancelDelay(true);
    }

    private void cleanupObsoleteVersions() {
        try {
            final Version previous = new Version(this.prefs.getString("LatestVersionNative", ""));
            try {
                if (!"".equals(previous.getOriginalString()) && this.currentVersionNative.getMajor() > previous.getMajor()) {

                    Log.i(CapacitorUpdater.TAG, "New native major version detected: " + this.currentVersionNative);
                    this.implementation.reset(true);
                    final List<BundleInfo> installed = this.implementation.list();
                    for (final BundleInfo bundle: installed) {
                        try {
                            Log.i(CapacitorUpdater.TAG, "Deleting obsolete bundle: " + bundle.getId());
                            this.implementation.delete(bundle.getId());
                        } catch (final Exception e) {
                            Log.e(CapacitorUpdater.TAG, "Failed to delete: " + bundle.getId(), e);
                        }
                    }
                }
            } catch (final Exception e) {
                Log.e(CapacitorUpdater.TAG, "Could not determine the current version", e);
            }
        } catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error calculating previous native version", e);
        }
        this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
        this.editor.commit();
    }

    public void notifyDownload(final String id, final int percent) {
        try {
            final JSObject ret = new JSObject();
            ret.put("percent", percent);
            JSObject bundle = this.implementation.getBundleInfo(id).toJSON();
            ret.put("bundle", bundle);
            this.notifyListeners("download", ret);
            if (percent == 100) {
                this.notifyListeners("downloadComplete", bundle);
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not notify listeners", e);
        }
    }


    @PluginMethod
    public void getDeviceId(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("deviceId", this.implementation.deviceID);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get device id", e);
            call.reject("Could not get device id", e);
        }
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("version", CapacitorUpdater.pluginVersion);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get plugin version", e);
            call.reject("Could not get plugin version", e);
        }
    }

    @PluginMethod
    public void download(final PluginCall call) {
        final String url = call.getString("url");
        final String version = call.getString("version");
        if (url == null) {
            Log.e(CapacitorUpdater.TAG, "Download called without url");
            call.reject("Download called without url");
            return;
        }
        if (version == null) {
            Log.e(CapacitorUpdater.TAG, "Download called without version");
            call.reject("Download called without version");
            return;
        }
        try {
            Log.i(CapacitorUpdater.TAG, "Downloading " + url);
            new Thread(new Runnable(){
                @Override
                public void run() {
                    try {

                        final BundleInfo downloaded = CapacitorUpdaterPlugin.this.implementation.download(url, version);
                        call.resolve(downloaded.toJSON());
                    } catch (final IOException e) {
                        Log.e(CapacitorUpdater.TAG, "download failed", e);
                        call.reject("download failed", e);
                        final JSObject ret = new JSObject();
                        ret.put("version", version);
                        CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
                    }
                }
            }).start();
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to download " + url, e);
            call.reject("Failed to download " + url, e);
        }
    }

    private boolean _reload() {
        final String path = this.implementation.getCurrentBundlePath();
        Log.i(CapacitorUpdater.TAG, "Reloading: " + path);
        if(this.implementation.isUsingBuiltin()) {
            this.bridge.setServerAssetPath(path);
        } else {
            this.bridge.setServerBasePath(path);
        }
        this.checkAppReady();
        return true;
    }

    @PluginMethod
    public void reload(final PluginCall call) {
        try {
            if (this._reload()) {
                call.resolve();
            } else {
                Log.e(CapacitorUpdater.TAG, "Reload failed");
                call.reject("Reload failed");
            }
        } catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not reload", e);
            call.reject("Could not reload", e);
        }
    }

    @PluginMethod
    public void next(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            Log.e(CapacitorUpdater.TAG, "Next called without id");
            call.reject("Next called without id");
            return;
        }
        try {
            Log.i(CapacitorUpdater.TAG, "Setting next active id " + id);
            if (!this.implementation.setNextBundle(id)) {
                Log.e(CapacitorUpdater.TAG, "Set next id failed. Bundle " + id + " does not exist.");
                call.reject("Set next id failed. Bundle " + id + " does not exist.");
            } else {
                call.resolve(this.implementation.getBundleInfo(id).toJSON());
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not set next id " + id, e);
            call.reject("Could not set next id " + id, e);
        }
    }

    @PluginMethod
    public void set(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            Log.e(CapacitorUpdater.TAG, "Set called without id");
            call.reject("Set called without id");
            return;
        }
        try {
            Log.i(CapacitorUpdater.TAG, "Setting active bundle " + id);
            if (!this.implementation.set(id)) {
                Log.i(CapacitorUpdater.TAG, "No such bundle " + id);
                call.reject("Update failed, id " + id + " does not exist.");
            } else {
                Log.i(CapacitorUpdater.TAG, "Bundle successfully set to" + id);
                this.reload(call);
            }
        } catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not set id " + id, e);
            call.reject("Could not set id " + id, e);
        }
    }

    @PluginMethod
    public void delete(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            Log.e(CapacitorUpdater.TAG, "missing id");
            call.reject("missing id");
            return;
        }
        Log.i(CapacitorUpdater.TAG, "Deleting id: " + id);
        try {
            final Boolean res = this.implementation.delete(id);
            if (res) {
                call.resolve();
            } else {
                Log.e(CapacitorUpdater.TAG, "Delete failed, id " + id + " does not exist");
                call.reject("Delete failed, id " + id + " does not exist");
            }
        } catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not delete id " + id, e);
            call.reject("Could not delete id " + id, e);
        }
    }


    @PluginMethod
    public void list(final PluginCall call) {
        try {
            final List<BundleInfo> res = this.implementation.list();
            final JSObject ret = new JSObject();
            final JSArray values = new JSArray();
            for (final BundleInfo bundle : res) {
                values.put(bundle.toJSON());
            }
            ret.put("bundles", values);
            call.resolve(ret);
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not list bundles", e);
            call.reject("Could not list bundles", e);
        }
    }

    @PluginMethod
    public void getLatest(final PluginCall call) {
        new Thread(new Runnable(){
            @Override
            public void run() {
                CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, (res) -> {
                    final JSObject ret = new JSObject();
                    Iterator<String> keys = res.keys();
                    while(keys.hasNext()) {
                        String key = keys.next();
                        if (res.has(key)) {
                            try {
                                ret.put(key, res.get(key));
                            } catch (JSONException e) {
                                e.printStackTrace();
                            }
                        }
                    }
                    call.resolve(ret);
                });
            }
        });
    }

    private boolean _reset(final Boolean toLastSuccessful) {
        final BundleInfo fallback = this.implementation.getFallbackBundle();
        this.implementation.reset();

        if (toLastSuccessful && !fallback.isBuiltin()) {
            Log.i(CapacitorUpdater.TAG, "Resetting to: " + fallback);
            return this.implementation.set(fallback) && this._reload();
        }

        Log.i(CapacitorUpdater.TAG, "Resetting to native.");
        return this._reload();
    }

    @PluginMethod
    public void reset(final PluginCall call) {
        try {
            final Boolean toLastSuccessful = call.getBoolean("toLastSuccessful", false);
            if (this._reset(toLastSuccessful)) {
                call.resolve();
                return;
            }
            Log.e(CapacitorUpdater.TAG, "Reset failed");
            call.reject("Reset failed");
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Reset failed", e);
            call.reject("Reset failed", e);
        }
    }

    @PluginMethod
    public void current(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            final BundleInfo bundle = this.implementation.getCurrentBundle();
            ret.put("bundle", bundle.toJSON());
            ret.put("native", this.currentVersionNative);
            call.resolve(ret);
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get current bundle", e);
            call.reject("Could not get current bundle", e);
        }
    }

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        try {
            final BundleInfo bundle = this.implementation.getCurrentBundle();
            this.implementation.setSuccess(bundle, this.autoDeletePrevious);
            Log.i(CapacitorUpdater.TAG, "Current bundle loaded successfully. ['notifyAppReady()' was called] " + bundle.toString());
            call.resolve();
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to notify app ready state. [Error calling 'notifyAppReady()']", e);
            call.reject("Failed to commit app ready state.", e);
        }
    }

    @PluginMethod
    public void setDelay(final PluginCall call) {
        try {
            final String kind = call.getString("kind");
            final String value = call.getString("value");
            if (kind == null) {
                Log.e(CapacitorUpdater.TAG, "setDelay called without kind");
                call.reject("setDelay called without kind");
                return;
            }
            this.editor.putString(DELAY_UPDATE, kind);
            this.editor.putString(DELAY_UPDATE_VAL, value);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "Delay update saved");
            call.resolve();
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update", e);
            call.reject("Failed to delay update", e);
        }
    }

    private boolean _cancelDelay(String source) {
        try {
            this.editor.remove(DELAY_UPDATE);
            this.editor.remove(DELAY_UPDATE_VAL);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "delay canceled from " + source);
            return true;
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to cancel update delay", e);
            return false;
        }
    }

    @PluginMethod
    public void cancelDelay(final PluginCall call) {
        if(this._cancelDelay("JS")) {
            call.resolve();
        } else {
            call.reject("Failed to cancel delay");
        }
    }

    private void _checkCancelDelay(Boolean killed) {
        final String delayUpdate = this.prefs.getString(DELAY_UPDATE, "");
        if ("".equals(delayUpdate)) {
            if ("background".equals(delayUpdate) && !killed) {
                this._cancelDelay("background check");
            } else if ("kill".equals(delayUpdate) && killed) {
                this._cancelDelay("kill check");
            }
            final String delayVal = this.prefs.getString(DELAY_UPDATE_VAL, "");
            if ("".equals(delayVal)) {
                this._cancelDelay("delayVal absent");
            } else if ("date".equals(delayUpdate)) {
                try {
                    final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ");
                    Date date = sdf.parse(delayVal);
                    if (date.compareTo(new Date()) > 0)  {
                        this._cancelDelay("date expired");
                    }
                }
                catch(final Exception e) {
                    this._cancelDelay("date parsing issue");
                }

            } else if ("nativeVersion".equals(delayUpdate)) {
                try {
                    final Version versionLimit = new Version(delayVal);
                    if (this.currentVersionNative.isAtLeast(versionLimit)) {
                        this._cancelDelay("nativeVersion above limit");
                    }
                }
                catch(final Exception e) {
                    this._cancelDelay("nativeVersion parsing issue");
                }
            }
        }
    }

    private Boolean _isAutoUpdateEnabled() {
        return CapacitorUpdaterPlugin.this.autoUpdate && !"".equals(CapacitorUpdaterPlugin.this.updateUrl);
    }

    @PluginMethod
    public void isAutoUpdateEnabled(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("enabled", this._isAutoUpdateEnabled());
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get autoUpdate status", e);
            call.reject("Could not get autoUpdate status", e);
        }
    }

    private void checkAppReady() {
        try {
            if(this.appReadyCheck != null) {
                this.appReadyCheck.interrupt();
            }
            this.appReadyCheck = new Thread(new DeferredNotifyAppReadyCheck());
            this.appReadyCheck.start();
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to start " + DeferredNotifyAppReadyCheck.class.getName(), e);
        }
    }

    private boolean isValidURL(String urlStr) {
        try {
            URL url = new URL(urlStr);
            return true;
        }
        catch (MalformedURLException e) {
            return false;
        }
    }

    @Override // appMovedToForeground
    public void onActivityStarted(@NonNull final Activity activity) {
        if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled()) {
            new Thread(new Runnable(){
                @Override
                public void run() {

                    Log.i(CapacitorUpdater.TAG, "Check for update via: " + CapacitorUpdaterPlugin.this.updateUrl);
                    CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, (res) -> {
                        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                        try {
                            if (res.has("message")) {
                                Log.i(CapacitorUpdater.TAG, "message " + res.get("message"));
                                if (res.has("major") && res.getBoolean("major") && res.has("version")) {
                                    final JSObject majorAvailable = new JSObject();
                                    majorAvailable.put("version", (String) res.get("version"));
                                    CapacitorUpdaterPlugin.this.notifyListeners("majorAvailable", majorAvailable);
                                }
                                final JSObject retNoNeed = new JSObject();
                                retNoNeed.put("bundle", current.toJSON());
                                CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                                return;
                            }

                            if (!res.has("url") || CapacitorUpdaterPlugin.this.isValidURL((String)res.get("url"))) {
                                Log.e(CapacitorUpdater.TAG, "Error no url or wrong format");
                                final JSObject retNoNeed = new JSObject();
                                retNoNeed.put("bundle", current.toJSON());
                                CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                            }
                            final String latestVersionName = (String) res.get("version");

                            if (latestVersionName != null && !"".equals(latestVersionName) && !current.getVersionName().equals(latestVersionName)) {

                                final BundleInfo latest = CapacitorUpdaterPlugin.this.implementation.getBundleInfoByName(latestVersionName);
                                if(latest != null) {
                                    if(latest.isErrorStatus()) {
                                        Log.e(CapacitorUpdater.TAG, "Latest bundle already exists, and is in error state. Aborting update.");
                                        final JSObject retNoNeed = new JSObject();
                                        retNoNeed.put("bundle", current.toJSON());
                                        CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                                        return;
                                    }
                                    if(latest.isDownloaded()){
                                        Log.e(CapacitorUpdater.TAG, "Latest bundle already exists and download is NOT required. Update will occur next time app moves to background.");
                                        CapacitorUpdaterPlugin.this.implementation.setNextBundle(latest.getId());
                                        final JSObject ret = new JSObject();
                                        ret.put("bundle", latest.toJSON());
                                        CapacitorUpdaterPlugin.this.notifyListeners("updateAvailable", ret);
                                        return;
                                    }
                                }


                                new Thread(new Runnable(){
                                    @Override
                                    public void run() {
                                        try {
                                            Log.i(CapacitorUpdater.TAG, "New bundle: " + latestVersionName + " found. Current is: " + current.getVersionName() + ". Update will occur next time app moves to background.");

                                            final String url = (String) res.get("url");
                                            final BundleInfo next = CapacitorUpdaterPlugin.this.implementation.download(url, latestVersionName);
                                            final JSObject ret = new JSObject();
                                            ret.put("bundle", next.toJSON());
                                            CapacitorUpdaterPlugin.this.notifyListeners("updateAvailable", ret);
                                            CapacitorUpdaterPlugin.this.implementation.setNextBundle(next.getId());
                                        } catch (final Exception e) {
                                            Log.e(CapacitorUpdater.TAG, "error downloading file", e);
                                            final JSObject ret = new JSObject();
                                            ret.put("version", latestVersionName);
                                            CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
                                            final JSObject retNoNeed = new JSObject();
                                            retNoNeed.put("bundle", current.toJSON());
                                            CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                                        }
                                    }
                                }).start();
                            } else {
                                Log.i(CapacitorUpdater.TAG, "No need to update, " + current.getId() + " is the latest bundle.");
                                final JSObject retNoNeed = new JSObject();
                                retNoNeed.put("bundle", current.toJSON());
                                CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                            }
                        } catch (final JSONException e) {
                            Log.e(CapacitorUpdater.TAG, "error parsing JSON", e);
                            final JSObject retNoNeed = new JSObject();
                            retNoNeed.put("bundle", current.toJSON());
                            CapacitorUpdaterPlugin.this.notifyListeners("noNeedUpdate", retNoNeed);
                        }
                    });
                }
            }).start();
        }

        this.checkAppReady();
    }

    @Override // appMovedToBackground
    public void onActivityStopped(@NonNull final Activity activity) {
        Log.i(CapacitorUpdater.TAG, "Checking for pending update");
        try {
            final String delayUpdate = this.prefs.getString(DELAY_UPDATE, "");
            this._checkCancelDelay(false);
            if (!"".equals(delayUpdate)) {
                Log.i(CapacitorUpdater.TAG, "Update delayed to next backgrounding");
                return;
            }
            final BundleInfo current = this.implementation.getCurrentBundle();
            final BundleInfo next = this.implementation.getNextBundle();

            if (next != null && !next.isErrorStatus() && next.getId() != current.getId()) {
                // There is a next bundle waiting for activation
                Log.d(CapacitorUpdater.TAG, "Next bundle is: " + next.getVersionName());
                if (this.implementation.set(next) && this._reload()) {
                    Log.i(CapacitorUpdater.TAG, "Updated to bundle: " + next.getVersionName());
                    this.implementation.setNextBundle(null);
                } else {
                    Log.e(CapacitorUpdater.TAG, "Update to bundle: " + next.getVersionName() + " Failed!");
                }
            }
        }
        catch(final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error during onActivityStopped", e);
        }
    }

    private void checkRevert() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        final BundleInfo current = this.implementation.getCurrentBundle();

        if(current.isBuiltin()) {
            Log.i(CapacitorUpdater.TAG, "Built-in bundle is active. Nothing to do.");
            return;
        }
        Log.d(CapacitorUpdater.TAG, "Current bundle is: " + current);

        if(BundleStatus.SUCCESS != current.getStatus()) {
            Log.e(CapacitorUpdater.TAG, "notifyAppReady was not called, roll back current bundle: " + current.getId());
            Log.i(CapacitorUpdater.TAG, "Did you forget to call 'notifyAppReady()' in your Capacitor App code?");
            final JSObject ret = new JSObject();
            ret.put("bundle", current.toJSON());
            this.notifyListeners("updateFailed", ret);
            this.implementation.sendStats("update_fail", current.getVersionName());
            this.implementation.setError(current);
            this._reset(true);
            if (CapacitorUpdaterPlugin.this.autoDeleteFailed) {
                Log.i(CapacitorUpdater.TAG, "Deleting failing bundle: " + current.getVersionName());
                try {
                    final Boolean res = this.implementation.delete(current.getId(), false);
                    if (res) {
                        Log.i(CapacitorUpdater.TAG, "Failed bundle deleted: " + current.getVersionName());
                    }
                } catch (final IOException e) {
                    Log.e(CapacitorUpdater.TAG, "Failed to delete failed bundle: " + current.getVersionName(), e);
                }
            }
        } else {
            Log.i(CapacitorUpdater.TAG, "notifyAppReady was called. This is fine: " + current.getId());
        }
    }

    private class DeferredNotifyAppReadyCheck implements Runnable {
        @Override
        public void run() {
            try {
                Log.i(CapacitorUpdater.TAG, "Wait for " + CapacitorUpdaterPlugin.this.appReadyTimeout + "ms, then check for notifyAppReady");
                Thread.sleep(CapacitorUpdaterPlugin.this.appReadyTimeout);
                CapacitorUpdaterPlugin.this.checkRevert();
                CapacitorUpdaterPlugin.this.appReadyCheck = null;
            } catch (final InterruptedException e) {
                Log.e(CapacitorUpdater.TAG, DeferredNotifyAppReadyCheck.class.getName() + " was interrupted.");
            }
        }
    }

    // not use but necessary here to remove warnings
    @Override
    public void onActivityResumed(@NonNull final Activity activity) {
        // TODO: Implement background updating based on `backgroundUpdate` and `backgroundUpdateDelay` capacitor.config.ts settings
    }

    @Override
    public void onActivityPaused(@NonNull final Activity activity) {
        // TODO: Implement background updating based on `backgroundUpdate` and `backgroundUpdateDelay` capacitor.config.ts settings
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
