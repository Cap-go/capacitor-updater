/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Looper;
import android.util.Log;
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.plugin.WebView;
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import io.github.g00fy2.versioncompare.Version;
import java.io.IOException;
import java.lang.reflect.Type;
import java.net.MalformedURLException;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.Iterator;
import java.util.List;
import java.util.Objects;
import java.util.Timer;
import java.util.TimerTask;
import java.util.UUID;
import java.util.concurrent.Phaser;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import org.json.JSONArray;
import org.json.JSONException;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

    private static final String updateUrlDefault = "https://plugin.capgo.app/updates";
    private static final String statsUrlDefault = "https://plugin.capgo.app/stats";
    private static final String channelUrlDefault = "https://plugin.capgo.app/channel_self";

    private final String PLUGIN_VERSION = "6.14.7";
    private static final String DELAY_CONDITION_PREFERENCES = "";

    private SharedPreferences.Editor editor;
    private SharedPreferences prefs;
    protected CapacitorUpdater implementation;

    private Integer appReadyTimeout = 10000;
    private Integer counterActivityCreate = 0;
    private Integer periodCheckDelay = 0;
    private Boolean autoDeleteFailed = true;
    private Boolean autoDeletePrevious = true;
    private Boolean autoUpdate = false;
    private String updateUrl = "";
    private Version currentVersionNative;
    private Thread backgroundTask;
    private Boolean taskRunning = false;
    private Boolean keepUrlPathAfterReload = false;

    private Boolean isPreviousMainActivity = true;

    private volatile Thread backgroundDownloadTask;
    private volatile Thread appReadyCheck;

    //  private static final CountDownLatch semaphoreReady = new CountDownLatch(1);
    private static final Phaser semaphoreReady = new Phaser(1);

    private int lastNotifiedStatPercent = 0;

    public Thread startNewThread(final Runnable function, Number waitTime) {
        Thread bgTask = new Thread(() -> {
            try {
                if (waitTime.longValue() > 0) {
                    Thread.sleep(waitTime.longValue());
                }
                function.run();
            } catch (Exception e) {
                e.printStackTrace();
            }
        });
        bgTask.start();
        return bgTask;
    }

    public Thread startNewThread(final Runnable function) {
        return startNewThread(function, 0);
    }

    @Override
    public void load() {
        super.load();
        this.counterActivityCreate++;
        this.prefs = this.getContext().getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Activity.MODE_PRIVATE);
        this.editor = this.prefs.edit();

        try {
            this.implementation = new CapacitorUpdater() {
                @Override
                public void notifyDownload(final String id, final int percent) {
                    CapacitorUpdaterPlugin.this.notifyDownload(id, percent);
                }

                @Override
                public void directUpdateFinish(final BundleInfo latest) {
                    CapacitorUpdaterPlugin.this.directUpdateFinish(latest);
                }

                @Override
                public void notifyListeners(final String id, final JSObject res) {
                    CapacitorUpdaterPlugin.this.notifyListeners(id, res);
                }
            };
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.implementation.activity = this.getActivity();
            this.implementation.versionBuild = this.getConfig().getString("version", pInfo.versionName);
            this.implementation.PLUGIN_VERSION = this.PLUGIN_VERSION;
            this.implementation.versionCode = Integer.toString(pInfo.versionCode);
            this.implementation.client = new OkHttpClient.Builder()
                .protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1))
                .connectTimeout(this.implementation.timeout, TimeUnit.MILLISECONDS)
                .readTimeout(this.implementation.timeout, TimeUnit.MILLISECONDS)
                .writeTimeout(this.implementation.timeout, TimeUnit.MILLISECONDS)
                .build();

            this.implementation.directUpdate = this.getConfig().getBoolean("directUpdate", false);
            this.currentVersionNative = new Version(this.getConfig().getString("version", pInfo.versionName));
        } catch (final PackageManager.NameNotFoundException e) {
            Log.e(CapacitorUpdater.TAG, "Error instantiating implementation", e);
            return;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error getting current native app version", e);
            return;
        }
        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.appId = config.getString("appId", this.implementation.appId);
        this.implementation.appId = this.getConfig().getString("appId", this.implementation.appId);
        if (this.implementation.appId == null || this.implementation.appId.isEmpty()) {
            // crash the app
            throw new RuntimeException(
                "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config"
            );
        }
        Log.i(CapacitorUpdater.TAG, "appId: " + implementation.appId);
        this.implementation.publicKey = this.getConfig().getString("publicKey", "");
        this.implementation.statsUrl = this.getConfig().getString("statsUrl", statsUrlDefault);
        this.implementation.channelUrl = this.getConfig().getString("channelUrl", channelUrlDefault);
        int userValue = this.getConfig().getInt("periodCheckDelay", 0);
        this.implementation.defaultChannel = this.getConfig().getString("defaultChannel", "");

        if (userValue >= 0 && userValue <= 600) {
            this.periodCheckDelay = 600 * 1000;
        } else if (userValue > 600) {
            this.periodCheckDelay = userValue * 1000;
        }

        this.implementation.documentsDir = this.getContext().getFilesDir();
        this.implementation.prefs = this.prefs;
        this.implementation.editor = this.editor;
        this.implementation.versionOs = Build.VERSION.RELEASE;
        this.implementation.deviceID = this.prefs.getString("appUUID", UUID.randomUUID().toString()).toLowerCase();
        this.editor.putString("appUUID", this.implementation.deviceID);
        this.editor.commit();
        Log.i(CapacitorUpdater.TAG, "init for device " + this.implementation.deviceID);
        Log.i(CapacitorUpdater.TAG, "version native " + this.currentVersionNative.getOriginalString());
        this.autoDeleteFailed = this.getConfig().getBoolean("autoDeleteFailed", true);
        this.autoDeletePrevious = this.getConfig().getBoolean("autoDeletePrevious", true);
        this.updateUrl = this.getConfig().getString("updateUrl", updateUrlDefault);
        this.autoUpdate = this.getConfig().getBoolean("autoUpdate", true);
        this.appReadyTimeout = this.getConfig().getInt("appReadyTimeout", 10000);
        this.keepUrlPathAfterReload = this.getConfig().getBoolean("keepUrlPathAfterReload", false);
        this.implementation.timeout = this.getConfig().getInt("responseTimeout", 20) * 1000;
        boolean resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);

        this.implementation.autoReset();
        if (resetWhenUpdate) {
            this.cleanupObsoleteVersions();
        }
        this.checkForUpdateAfterDelay();
    }

    private void semaphoreWait(Number waitTime) {
        Log.i(CapacitorUpdater.TAG, "semaphoreWait " + waitTime);
        try {
            //        Log.i(CapacitorUpdater.TAG, "semaphoreReady count " + CapacitorUpdaterPlugin.this.semaphoreReady.getCount());
            semaphoreReady.awaitAdvanceInterruptibly(semaphoreReady.getPhase(), waitTime.longValue(), TimeUnit.SECONDS);
            //        Log.i(CapacitorUpdater.TAG, "semaphoreReady await " + res);
            Log.i(CapacitorUpdater.TAG, "semaphoreReady count " + semaphoreReady.getPhase());
        } catch (InterruptedException e) {
            Log.i(CapacitorUpdater.TAG, "semaphoreWait InterruptedException");
            e.printStackTrace();
        } catch (TimeoutException e) {
            throw new RuntimeException(e);
        }
    }

    private void semaphoreUp() {
        Log.i(CapacitorUpdater.TAG, "semaphoreUp");
        semaphoreReady.register();
    }

    private void semaphoreDown() {
        Log.i(CapacitorUpdater.TAG, "semaphoreDown");
        Log.i(CapacitorUpdater.TAG, "semaphoreDown count " + semaphoreReady.getPhase());
        semaphoreReady.arriveAndDeregister();
    }

    private void sendReadyToJs(final BundleInfo current, final String msg) {
        Log.i(CapacitorUpdater.TAG, "sendReadyToJs");
        final JSObject ret = new JSObject();
        ret.put("bundle", current.toJSON());
        ret.put("status", msg);
        startNewThread(() -> {
            Log.i(CapacitorUpdater.TAG, "semaphoreReady sendReadyToJs");
            semaphoreWait(CapacitorUpdaterPlugin.this.appReadyTimeout);
            Log.i(CapacitorUpdater.TAG, "semaphoreReady sendReadyToJs done");
            CapacitorUpdaterPlugin.this.notifyListeners("appReady", ret);
        });
    }

    private void directUpdateFinish(final BundleInfo latest) {
        CapacitorUpdaterPlugin.this.implementation.set(latest);
        CapacitorUpdaterPlugin.this._reload();
        sendReadyToJs(latest, "update installed");
    }

    private void cleanupObsoleteVersions() {
        try {
            final Version previous = new Version(this.prefs.getString("LatestVersionNative", ""));
            try {
                if (
                    !"".equals(previous.getOriginalString()) &&
                    !Objects.equals(this.currentVersionNative.getOriginalString(), previous.getOriginalString())
                ) {
                    Log.i(CapacitorUpdater.TAG, "New native version detected: " + this.currentVersionNative);
                    this.implementation.reset(true);
                    final List<BundleInfo> installed = this.implementation.list(false);
                    for (final BundleInfo bundle : installed) {
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
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error calculating previous native version", e);
        }
        this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
        this.editor.commit();
    }

    public void notifyDownload(final String id, final int percent) {
        try {
            final JSObject ret = new JSObject();
            ret.put("percent", percent);
            final BundleInfo bundleInfo = this.implementation.getBundleInfo(id);
            ret.put("bundle", bundleInfo.toJSON());
            this.notifyListeners("download", ret);

            if (percent == 100) {
                final JSObject retDownloadComplete = new JSObject(ret, new String[] { "bundle" });
                this.notifyListeners("downloadComplete", retDownloadComplete);
                this.implementation.sendStats("download_complete", bundleInfo.getVersionName());
                lastNotifiedStatPercent = 100;
            } else {
                int currentStatPercent = (percent / 10) * 10; // Round down to nearest 10
                if (currentStatPercent > lastNotifiedStatPercent) {
                    this.implementation.sendStats("download_" + currentStatPercent, bundleInfo.getVersionName());
                    lastNotifiedStatPercent = currentStatPercent;
                }
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not notify listeners", e);
        }
    }

    @PluginMethod
    public void setUpdateUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            Log.e(CapacitorUpdater.TAG, "setUpdateUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setUpdateUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            Log.e(CapacitorUpdater.TAG, "setUpdateUrl called without url");
            call.reject("setUpdateUrl called without url");
            return;
        }
        this.updateUrl = url;
        call.resolve();
    }

    @PluginMethod
    public void setStatsUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            Log.e(CapacitorUpdater.TAG, "setStatsUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setStatsUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            Log.e(CapacitorUpdater.TAG, "setStatsUrl called without url");
            call.reject("setStatsUrl called without url");
            return;
        }
        this.implementation.statsUrl = url;
        call.resolve();
    }

    @PluginMethod
    public void setChannelUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            Log.e(CapacitorUpdater.TAG, "setChannelUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setChannelUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            Log.e(CapacitorUpdater.TAG, "setChannelUrl called without url");
            call.reject("setChannelUrl called without url");
            return;
        }
        this.implementation.channelUrl = url;
        call.resolve();
    }

    @PluginMethod
    public void getBuiltinVersion(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("version", this.implementation.versionBuild);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get version", e);
            call.reject("Could not get version", e);
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
    public void setCustomId(final PluginCall call) {
        final String customId = call.getString("customId");
        if (customId == null) {
            Log.e(CapacitorUpdater.TAG, "setCustomId called without customId");
            call.reject("setCustomId called without customId");
            return;
        }
        this.implementation.customId = customId;
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("version", this.PLUGIN_VERSION);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get plugin version", e);
            call.reject("Could not get plugin version", e);
        }
    }

    @PluginMethod
    public void unsetChannel(final PluginCall call) {
        final Boolean triggerAutoUpdate = call.getBoolean("triggerAutoUpdate", false);

        try {
            Log.i(CapacitorUpdater.TAG, "unsetChannel triggerAutoUpdate: " + triggerAutoUpdate);
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.unsetChannel(res -> {
                        if (res.has("error")) {
                            call.reject(res.getString("error"));
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                Log.i(CapacitorUpdater.TAG, "Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(res);
                        }
                    })
            );
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to unsetChannel: ", e);
            call.reject("Failed to unsetChannel: ", e);
        }
    }

    @PluginMethod
    public void setChannel(final PluginCall call) {
        final String channel = call.getString("channel");
        final Boolean triggerAutoUpdate = call.getBoolean("triggerAutoUpdate", false);

        if (channel == null) {
            Log.e(CapacitorUpdater.TAG, "setChannel called without channel");
            call.reject("setChannel called without channel");
            return;
        }
        try {
            Log.i(CapacitorUpdater.TAG, "setChannel " + channel + " triggerAutoUpdate: " + triggerAutoUpdate);
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.setChannel(channel, res -> {
                        if (res.has("error")) {
                            call.reject(res.getString("error"));
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                Log.i(CapacitorUpdater.TAG, "Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(res);
                        }
                    })
            );
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to setChannel: " + channel, e);
            call.reject("Failed to setChannel: " + channel, e);
        }
    }

    @PluginMethod
    public void getChannel(final PluginCall call) {
        try {
            Log.i(CapacitorUpdater.TAG, "getChannel");
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.getChannel(res -> {
                        if (res.has("error")) {
                            call.reject(res.getString("error"));
                        } else {
                            call.resolve(res);
                        }
                    })
            );
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to getChannel", e);
            call.reject("Failed to getChannel", e);
        }
    }

    @PluginMethod
    public void download(final PluginCall call) {
        final String url = call.getString("url");
        final String version = call.getString("version");
        final String sessionKey = call.getString("sessionKey", "");
        final String checksum = call.getString("checksum", "");
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
            startNewThread(() -> {
                try {
                    final BundleInfo downloaded = CapacitorUpdaterPlugin.this.implementation.download(url, version, sessionKey, checksum);
                    if (downloaded.isErrorStatus()) {
                        throw new RuntimeException("Download failed: " + downloaded.getStatus());
                    } else {
                        call.resolve(downloaded.toJSON());
                    }
                } catch (final Exception e) {
                    Log.e(CapacitorUpdater.TAG, "Failed to download from: " + url, e);
                    call.reject("Failed to download from: " + url, e);
                    final JSObject ret = new JSObject();
                    ret.put("version", version);
                    CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
                    final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                    CapacitorUpdaterPlugin.this.implementation.sendStats("download_fail", current.getVersionName());
                }
            });
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to download from: " + url, e);
            call.reject("Failed to download from: " + url, e);
            final JSObject ret = new JSObject();
            ret.put("version", version);
            CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
            final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
            CapacitorUpdaterPlugin.this.implementation.sendStats("download_fail", current.getVersionName());
        }
    }

    protected boolean _reload() {
        final String path = this.implementation.getCurrentBundlePath();
        this.semaphoreUp();
        Log.i(CapacitorUpdater.TAG, "Reloading: " + path);

        AtomicReference<URL> url = new AtomicReference<>();
        if (this.keepUrlPathAfterReload) {
            try {
                if (Looper.myLooper() != Looper.getMainLooper()) {
                    Semaphore mainThreadSemaphore = new Semaphore(0);
                    this.bridge.executeOnMainThread(() -> {
                            try {
                                url.set(new URL(this.bridge.getWebView().getUrl()));
                            } catch (Exception e) {
                                Log.e(CapacitorUpdater.TAG, "Error executing on main thread", e);
                            }
                            mainThreadSemaphore.release();
                        });
                    mainThreadSemaphore.acquire();
                } else {
                    try {
                        url.set(new URL(this.bridge.getWebView().getUrl()));
                    } catch (Exception e) {
                        Log.e(CapacitorUpdater.TAG, "Error executing on main thread", e);
                    }
                }
            } catch (InterruptedException e) {
                Log.e(CapacitorUpdater.TAG, "Error waiting for main thread or getting the current URL from webview", e);
            }
        }

        if (url.get() != null) {
            if (this.implementation.isUsingBuiltin()) {
                this.bridge.getLocalServer().hostAssets(path);
            } else {
                this.bridge.getLocalServer().hostFiles(path);
            }

            try {
                URL finalUrl = null;
                finalUrl = new URL(this.bridge.getAppUrl());
                finalUrl = new URL(finalUrl.getProtocol(), finalUrl.getHost(), finalUrl.getPort(), url.get().getPath());
                URL finalUrl1 = finalUrl;
                this.bridge.getWebView()
                    .post(() -> {
                        this.bridge.getWebView().loadUrl(finalUrl1.toString());
                        this.bridge.getWebView().clearHistory();
                    });
            } catch (MalformedURLException e) {
                Log.e(CapacitorUpdater.TAG, "Cannot get finalUrl from capacitor bridge", e);

                if (this.implementation.isUsingBuiltin()) {
                    this.bridge.setServerAssetPath(path);
                } else {
                    this.bridge.setServerBasePath(path);
                }
            }
        } else {
            if (this.implementation.isUsingBuiltin()) {
                this.bridge.setServerAssetPath(path);
            } else {
                this.bridge.setServerBasePath(path);
            }
        }

        this.checkAppReady();
        this.notifyListeners("appReloaded", new JSObject());
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
        } catch (final Exception e) {
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
            call.reject("Could not set next id: " + id, e);
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
                Log.i(CapacitorUpdater.TAG, "Bundle successfully set to " + id);
                this.reload(call);
            }
        } catch (final Exception e) {
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
        Log.i(CapacitorUpdater.TAG, "Deleting id " + id);
        try {
            final Boolean res = this.implementation.delete(id);
            if (res) {
                call.resolve();
            } else {
                Log.e(CapacitorUpdater.TAG, "Delete failed, id " + id + " does not exist");
                call.reject("Delete failed, id " + id + " does not exist or it cannot be deleted (perhaps it is the 'next' bundle)");
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not delete id " + id, e);
            call.reject("Could not delete id " + id, e);
        }
    }

    @PluginMethod
    public void list(final PluginCall call) {
        try {
            final List<BundleInfo> res = this.implementation.list(call.getBoolean("raw", false));
            final JSObject ret = new JSObject();
            final JSArray values = new JSArray();
            for (final BundleInfo bundle : res) {
                values.put(bundle.toJSON());
            }
            ret.put("bundles", values);
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not list bundles", e);
            call.reject("Could not list bundles", e);
        }
    }

    @PluginMethod
    public void getLatest(final PluginCall call) {
        final String channel = call.getString("channel");
        startNewThread(() ->
            CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, channel, res -> {
                    if (res.has("error")) {
                        call.reject(res.getString("error"));
                        return;
                    } else if (res.has("message")) {
                        call.reject(res.getString("message"));
                        return;
                    } else {
                        call.resolve(res);
                    }
                    final JSObject ret = new JSObject();
                    Iterator<String> keys = res.keys();
                    while (keys.hasNext()) {
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
                })
        );
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
        } catch (final Exception e) {
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
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get current bundle", e);
            call.reject("Could not get current bundle", e);
        }
    }

    @PluginMethod
    public void getNextBundle(final PluginCall call) {
        try {
            final BundleInfo bundle = this.implementation.getNextBundle();
            if (bundle == null) {
                call.resolve(null);
                return;
            }

            call.resolve(bundle.toJSON());
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get next bundle", e);
            call.reject("Could not get next bundle", e);
        }
    }

    public void checkForUpdateAfterDelay() {
        if (this.periodCheckDelay == 0 || !this._isAutoUpdateEnabled()) {
            return;
        }
        final Timer timer = new Timer();
        timer.schedule(
            new TimerTask() {
                @Override
                public void run() {
                    try {
                        CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, null, res -> {
                                if (res.has("error")) {
                                    Log.e(CapacitorUpdater.TAG, Objects.requireNonNull(res.getString("error")));
                                } else if (res.has("version")) {
                                    String newVersion = res.getString("version");
                                    String currentVersion = String.valueOf(CapacitorUpdaterPlugin.this.implementation.getCurrentBundle());
                                    if (!Objects.equals(newVersion, currentVersion)) {
                                        Log.i(CapacitorUpdater.TAG, "New version found: " + newVersion);
                                        CapacitorUpdaterPlugin.this.backgroundDownload();
                                    }
                                }
                            });
                    } catch (final Exception e) {
                        Log.e(CapacitorUpdater.TAG, "Failed to check for update", e);
                    }
                }
            },
            this.periodCheckDelay,
            this.periodCheckDelay
        );
    }

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        try {
            final BundleInfo bundle = this.implementation.getCurrentBundle();
            this.implementation.setSuccess(bundle, this.autoDeletePrevious);
            Log.i(CapacitorUpdater.TAG, "Current bundle loaded successfully. ['notifyAppReady()' was called] " + bundle);
            Log.i(CapacitorUpdater.TAG, "semaphoreReady countDown");
            this.semaphoreDown();
            Log.i(CapacitorUpdater.TAG, "semaphoreReady countDown done");
            final JSObject ret = new JSObject();
            ret.put("bundle", bundle.toJSON());
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to notify app ready state. [Error calling 'notifyAppReady()']", e);
            call.reject("Failed to commit app ready state.", e);
        }
    }

    @PluginMethod
    public void setMultiDelay(final PluginCall call) {
        try {
            final Object delayConditions = call.getData().opt("delayConditions");
            if (delayConditions == null) {
                Log.e(CapacitorUpdater.TAG, "setMultiDelay called without delayCondition");
                call.reject("setMultiDelay called without delayCondition");
                return;
            }
            if (_setMultiDelay(delayConditions.toString())) {
                call.resolve();
            } else {
                call.reject("Failed to delay update");
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling 'setMultiDelay()']", e);
            call.reject("Failed to delay update", e);
        }
    }

    private Boolean _setMultiDelay(String delayConditions) {
        try {
            this.editor.putString(DELAY_CONDITION_PREFERENCES, delayConditions);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "Delay update saved");
            return true;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling '_setMultiDelay()']", e);
            return false;
        }
    }

    private boolean _cancelDelay(String source) {
        try {
            this.editor.remove(DELAY_CONDITION_PREFERENCES);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "All delays canceled from " + source);
            return true;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to cancel update delay", e);
            return false;
        }
    }

    @PluginMethod
    public void cancelDelay(final PluginCall call) {
        if (this._cancelDelay("JS")) {
            call.resolve();
        } else {
            call.reject("Failed to cancel delay");
        }
    }

    private void _checkCancelDelay(Boolean killed) {
        Gson gson = new Gson();
        String delayUpdatePreferences = prefs.getString(DELAY_CONDITION_PREFERENCES, "[]");
        Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
        ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
        for (DelayCondition condition : delayConditionList) {
            String kind = condition.getKind().toString();
            String value = condition.getValue();
            if (!kind.isEmpty()) {
                switch (kind) {
                    case "background":
                        if (!killed) {
                            this._cancelDelay("background check");
                        }
                        break;
                    case "kill":
                        if (killed) {
                            this._cancelDelay("kill check");
                            this.installNext();
                        }
                        break;
                    case "date":
                        if (!"".equals(value)) {
                            try {
                                final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS");
                                Date date = sdf.parse(value);
                                assert date != null;
                                if (new Date().compareTo(date) > 0) {
                                    this._cancelDelay("date expired");
                                }
                            } catch (final Exception e) {
                                this._cancelDelay("date parsing issue");
                            }
                        } else {
                            this._cancelDelay("delayVal absent");
                        }
                        break;
                    case "nativeVersion":
                        if (!"".equals(value)) {
                            try {
                                final Version versionLimit = new Version(value);
                                if (this.currentVersionNative.isAtLeast(versionLimit)) {
                                    this._cancelDelay("nativeVersion above limit");
                                }
                            } catch (final Exception e) {
                                this._cancelDelay("nativeVersion parsing issue");
                            }
                        } else {
                            this._cancelDelay("delayVal absent");
                        }
                        break;
                }
            }
        }
    }

    private Boolean _isAutoUpdateEnabled() {
        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        String serverUrl = config.getServerUrl();
        if (serverUrl != null && !serverUrl.isEmpty()) {
            // log warning autoupdate disabled when serverUrl is set
            Log.w(CapacitorUpdater.TAG, "AutoUpdate is automatic disabled when serverUrl is set.");
        }
        return (
            CapacitorUpdaterPlugin.this.autoUpdate &&
            !"".equals(CapacitorUpdaterPlugin.this.updateUrl) &&
            (serverUrl == null || serverUrl.isEmpty())
        );
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

    @PluginMethod
    public void isAutoUpdateAvailable(final PluginCall call) {
        try {
            final CapConfig config = CapConfig.loadDefault(this.getActivity());
            String serverUrl = config.getServerUrl();
            final JSObject ret = new JSObject();
            ret.put("available", serverUrl == null || serverUrl.isEmpty());
            call.resolve(ret);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Could not get autoUpdate availability", e);
            call.reject("Could not get autoUpdate availability", e);
        }
    }

    private void checkAppReady() {
        try {
            if (this.appReadyCheck != null) {
                this.appReadyCheck.interrupt();
            }
            this.appReadyCheck = startNewThread(new DeferredNotifyAppReadyCheck());
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to start " + DeferredNotifyAppReadyCheck.class.getName(), e);
        }
    }

    private boolean isValidURL(String urlStr) {
        try {
            new URL(urlStr);
            return true;
        } catch (MalformedURLException e) {
            return false;
        }
    }

    private void endBackGroundTaskWithNotif(String msg, String latestVersionName, BundleInfo current, Boolean error) {
        if (error) {
            Log.i(
                CapacitorUpdater.TAG,
                "endBackGroundTaskWithNotif error: " +
                error +
                " current: " +
                current.getVersionName() +
                "latestVersionName: " +
                latestVersionName
            );
            this.implementation.sendStats("download_fail", current.getVersionName());
            final JSObject ret = new JSObject();
            ret.put("version", latestVersionName);
            this.notifyListeners("downloadFailed", ret);
        }
        final JSObject ret = new JSObject();
        ret.put("bundle", current.toJSON());
        this.notifyListeners("noNeedUpdate", ret);
        this.sendReadyToJs(current, msg);
        this.backgroundDownloadTask = null;
        Log.i(CapacitorUpdater.TAG, "endBackGroundTaskWithNotif " + msg);
    }

    private Thread backgroundDownload() {
        String messageUpdate = this.implementation.directUpdate
            ? "Update will occur now."
            : "Update will occur next time app moves to background.";
        return startNewThread(() -> {
            Log.i(CapacitorUpdater.TAG, "Check for update via: " + CapacitorUpdaterPlugin.this.updateUrl);
            CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, null, res -> {
                    final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                    try {
                        if (res.has("message")) {
                            Log.i(CapacitorUpdater.TAG, "API message: " + res.get("message"));
                            if (res.has("major") && res.getBoolean("major") && res.has("version")) {
                                final JSObject majorAvailable = new JSObject();
                                majorAvailable.put("version", res.getString("version"));
                                CapacitorUpdaterPlugin.this.notifyListeners("majorAvailable", majorAvailable);
                            }
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                    res.getString("message"),
                                    current.getVersionName(),
                                    current,
                                    true
                                );
                            return;
                        }

                        final String latestVersionName = res.getString("version");

                        if ("builtin".equals(latestVersionName)) {
                            Log.i(CapacitorUpdater.TAG, "Latest version is builtin");
                            if (CapacitorUpdaterPlugin.this.implementation.directUpdate) {
                                Log.i(CapacitorUpdater.TAG, "Direct update to builtin version");
                                this._reset(false);
                                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                        "Updated to builtin version",
                                        latestVersionName,
                                        CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                                        false
                                    );
                            } else {
                                Log.i(CapacitorUpdater.TAG, "Setting next bundle to builtin");
                                CapacitorUpdaterPlugin.this.implementation.setNextBundle(BundleInfo.ID_BUILTIN);
                                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                        "Next update will be to builtin version",
                                        latestVersionName,
                                        current,
                                        false
                                    );
                            }
                            return;
                        }

                        if (!res.has("url") || !CapacitorUpdaterPlugin.this.isValidURL(res.getString("url"))) {
                            Log.e(CapacitorUpdater.TAG, "Error no url or wrong format");
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                    "Error no url or wrong format",
                                    current.getVersionName(),
                                    current,
                                    true
                                );
                            return;
                        }

                        if (
                            latestVersionName != null && !latestVersionName.isEmpty() && !current.getVersionName().equals(latestVersionName)
                        ) {
                            final BundleInfo latest = CapacitorUpdaterPlugin.this.implementation.getBundleInfoByName(latestVersionName);
                            if (latest != null) {
                                final JSObject ret = new JSObject();
                                ret.put("bundle", latest.toJSON());
                                if (latest.isErrorStatus()) {
                                    Log.e(CapacitorUpdater.TAG, "Latest bundle already exists, and is in error state. Aborting update.");
                                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                            "Latest bundle already exists, and is in error state. Aborting update.",
                                            latestVersionName,
                                            current,
                                            true
                                        );
                                    return;
                                }
                                if (latest.isDownloaded()) {
                                    Log.i(
                                        CapacitorUpdater.TAG,
                                        "Latest bundle already exists and download is NOT required. " + messageUpdate
                                    );
                                    if (CapacitorUpdaterPlugin.this.implementation.directUpdate) {
                                        CapacitorUpdaterPlugin.this.implementation.set(latest);
                                        CapacitorUpdaterPlugin.this._reload();
                                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                                "Update installed",
                                                latestVersionName,
                                                latest,
                                                false
                                            );
                                    } else {
                                        CapacitorUpdaterPlugin.this.notifyListeners("updateAvailable", ret);
                                        CapacitorUpdaterPlugin.this.implementation.setNextBundle(latest.getId());
                                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                                "update downloaded, will install next background",
                                                latestVersionName,
                                                latest,
                                                false
                                            );
                                    }
                                    return;
                                }
                                if (latest.isDeleted()) {
                                    Log.i(
                                        CapacitorUpdater.TAG,
                                        "Latest bundle already exists and will be deleted, download will overwrite it."
                                    );
                                    try {
                                        final Boolean deleted = CapacitorUpdaterPlugin.this.implementation.delete(latest.getId(), true);
                                        if (deleted) {
                                            Log.i(CapacitorUpdater.TAG, "Failed bundle deleted: " + latest.getVersionName());
                                        }
                                    } catch (final IOException e) {
                                        Log.e(CapacitorUpdater.TAG, "Failed to delete failed bundle: " + latest.getVersionName(), e);
                                    }
                                }
                            }
                            startNewThread(() -> {
                                try {
                                    Log.i(
                                        CapacitorUpdater.TAG,
                                        "New bundle: " +
                                        latestVersionName +
                                        " found. Current is: " +
                                        current.getVersionName() +
                                        ". " +
                                        messageUpdate
                                    );

                                    final String url = res.getString("url");
                                    final String sessionKey = res.has("sessionKey") ? res.getString("sessionKey") : "";
                                    final String checksum = res.has("checksum") ? res.getString("checksum") : "";

                                    if (res.has("manifest")) {
                                        // Handle manifest-based download
                                        JSONArray manifest = res.getJSONArray("manifest");
                                        CapacitorUpdaterPlugin.this.implementation.downloadBackground(
                                                url,
                                                latestVersionName,
                                                sessionKey,
                                                checksum,
                                                manifest
                                            );
                                    } else {
                                        // Handle single file download (existing code)
                                        CapacitorUpdaterPlugin.this.implementation.downloadBackground(
                                                url,
                                                latestVersionName,
                                                sessionKey,
                                                checksum,
                                                null
                                            );
                                    }
                                } catch (final Exception e) {
                                    Log.e(CapacitorUpdater.TAG, "error downloading file", e);
                                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                            "Error downloading file",
                                            latestVersionName,
                                            CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                                            true
                                        );
                                }
                            });
                        } else {
                            Log.i(CapacitorUpdater.TAG, "No need to update, " + current.getId() + " is the latest bundle.");
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif("No need to update", latestVersionName, current, false);
                        }
                    } catch (final JSONException e) {
                        Log.e(CapacitorUpdater.TAG, "error parsing JSON", e);
                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                "Error parsing JSON",
                                current.getVersionName(),
                                current,
                                true
                            );
                    }
                });
        });
    }

    private void installNext() {
        try {
            Gson gson = new Gson();
            String delayUpdatePreferences = prefs.getString(DELAY_CONDITION_PREFERENCES, "[]");
            Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
            ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
            if (delayConditionList != null && !delayConditionList.isEmpty()) {
                Log.i(CapacitorUpdater.TAG, "Update delayed until delay conditions met");
                return;
            }
            final BundleInfo current = this.implementation.getCurrentBundle();
            final BundleInfo next = this.implementation.getNextBundle();

            if (next != null && !next.isErrorStatus() && !next.getId().equals(current.getId())) {
                // There is a next bundle waiting for activation
                Log.d(CapacitorUpdater.TAG, "Next bundle is: " + next.getVersionName());
                if (this.implementation.set(next) && this._reload()) {
                    Log.i(CapacitorUpdater.TAG, "Updated to bundle: " + next.getVersionName());
                    this.implementation.setNextBundle(null);
                } else {
                    Log.e(CapacitorUpdater.TAG, "Update to bundle: " + next.getVersionName() + " Failed!");
                }
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error during onActivityStopped", e);
        }
    }

    private void checkRevert() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        final BundleInfo current = this.implementation.getCurrentBundle();

        if (current.isBuiltin()) {
            Log.i(CapacitorUpdater.TAG, "Built-in bundle is active. We skip the check for notifyAppReady.");
            return;
        }
        Log.d(CapacitorUpdater.TAG, "Current bundle is: " + current);

        if (BundleStatus.SUCCESS != current.getStatus()) {
            Log.e(CapacitorUpdater.TAG, "notifyAppReady was not called, roll back current bundle: " + current.getId());
            Log.i(CapacitorUpdater.TAG, "Did you forget to call 'notifyAppReady()' in your Capacitor App code?");
            final JSObject ret = new JSObject();
            ret.put("bundle", current.toJSON());
            this.notifyListeners("updateFailed", ret);
            this.implementation.sendStats("update_fail", current.getVersionName());
            this.implementation.setError(current);
            this._reset(true);
            if (CapacitorUpdaterPlugin.this.autoDeleteFailed && !current.isBuiltin()) {
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
                Log.i(
                    CapacitorUpdater.TAG,
                    "Wait for " + CapacitorUpdaterPlugin.this.appReadyTimeout + "ms, then check for notifyAppReady"
                );
                Thread.sleep(CapacitorUpdaterPlugin.this.appReadyTimeout);
                CapacitorUpdaterPlugin.this.checkRevert();
                CapacitorUpdaterPlugin.this.appReadyCheck = null;
            } catch (final InterruptedException e) {
                Log.i(CapacitorUpdater.TAG, DeferredNotifyAppReadyCheck.class.getName() + " was interrupted.");
            }
        }
    }

    public void appMovedToForeground() {
        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
        CapacitorUpdaterPlugin.this.implementation.sendStats("app_moved_to_foreground", current.getVersionName());
        this._checkCancelDelay(false);
        if (
            CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() &&
            (this.backgroundDownloadTask == null || !this.backgroundDownloadTask.isAlive())
        ) {
            this.backgroundDownloadTask = this.backgroundDownload();
        } else {
            Log.i(CapacitorUpdater.TAG, "Auto update is disabled");
            this.sendReadyToJs(current, "disabled");
        }
        this.checkAppReady();
    }

    public void appMovedToBackground() {
        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
        CapacitorUpdaterPlugin.this.implementation.sendStats("app_moved_to_background", current.getVersionName());
        Log.i(CapacitorUpdater.TAG, "Checking for pending update");
        try {
            Gson gson = new Gson();
            String delayUpdatePreferences = prefs.getString(DELAY_CONDITION_PREFERENCES, "[]");
            Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
            ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
            String backgroundValue = null;
            for (DelayCondition delayCondition : delayConditionList) {
                if (delayCondition.getKind().toString().equals("background")) {
                    String value = delayCondition.getValue();
                    backgroundValue = (value != null && !value.isEmpty()) ? value : "0";
                }
            }
            if (backgroundValue != null) {
                taskRunning = true;
                final Long timeout = Long.parseLong(backgroundValue);
                if (backgroundTask != null) {
                    backgroundTask.interrupt();
                }
                backgroundTask = startNewThread(
                    () -> {
                        taskRunning = false;
                        _checkCancelDelay(false);
                        installNext();
                    },
                    timeout
                );
            } else {
                this._checkCancelDelay(false);
                this.installNext();
            }
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Error during onActivityStopped", e);
        }
    }

    private boolean isMainActivity() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return false;
        }
        try {
            Context mContext = this.getContext();
            ActivityManager activityManager = (ActivityManager) mContext.getSystemService(Context.ACTIVITY_SERVICE);
            List<ActivityManager.AppTask> runningTasks = activityManager.getAppTasks();
            if (runningTasks.isEmpty()) {
                return false;
            }
            ActivityManager.RecentTaskInfo runningTask = runningTasks.get(0).getTaskInfo();
            String className = Objects.requireNonNull(runningTask.baseIntent.getComponent()).getClassName();
            if (runningTask.topActivity == null) {
                return false;
            }
            String runningActivity = runningTask.topActivity.getClassName();
            return className.equals(runningActivity);
        } catch (NullPointerException e) {
            return false;
        }
    }

    private void appKilled() {
        Log.d(CapacitorUpdater.TAG, "onActivityDestroyed: all activity destroyed");
        this._checkCancelDelay(true);
    }

    @Override
    public void handleOnStart() {
        if (isPreviousMainActivity) {
            this.appMovedToForeground();
        }
        Log.i(CapacitorUpdater.TAG, "onActivityStarted " + getActivity().getClass().getName());
        isPreviousMainActivity = true;
    }

    @Override
    public void handleOnStop() {
        isPreviousMainActivity = isMainActivity();
        if (isPreviousMainActivity) {
            this.appMovedToBackground();
        }
    }

    @Override
    public void handleOnResume() {
        if (backgroundTask != null && taskRunning) {
            backgroundTask.interrupt();
        }
        this.implementation.activity = getActivity();
    }

    @Override
    public void handleOnPause() {
        this.implementation.activity = getActivity();
    }

    @Override
    public void handleOnDestroy() {
        Log.i(CapacitorUpdater.TAG, "onActivityDestroyed " + getActivity().getClass().getName());
        this.implementation.activity = getActivity();
        counterActivityCreate--;
        if (counterActivityCreate == 0) {
            this.appKilled();
        }
    }
}
