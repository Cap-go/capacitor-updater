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
import java.util.Map;
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
import org.json.JSONObject;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

    private final Logger logger = new Logger("CapgoUpdater");

    private static final String updateUrlDefault = "https://plugin.capgo.app/updates";
    private static final String statsUrlDefault = "https://plugin.capgo.app/stats";
    private static final String channelUrlDefault = "https://plugin.capgo.app/channel_self";

    private final String PLUGIN_VERSION = "7.3.3";
    private static final String DELAY_CONDITION_PREFERENCES = "";

    private SharedPreferences.Editor editor;
    private SharedPreferences prefs;
    protected CapgoUpdater implementation;

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

    private DelayUpdateUtils delayUpdateUtils;

    private JSObject mapToJSObject(Map<String, Object> map) {
        JSObject jsObject = new JSObject();
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            jsObject.put(entry.getKey(), entry.getValue());
        }
        return jsObject;
    }

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
            this.implementation = new CapgoUpdater(logger) {
                @Override
                public void notifyDownload(final String id, final int percent) {
                    CapacitorUpdaterPlugin.this.notifyDownload(id, percent);
                }

                @Override
                public void directUpdateFinish(final BundleInfo latest) {
                    CapacitorUpdaterPlugin.this.directUpdateFinish(latest);
                }

                @Override
                public void notifyListeners(final String id, final Map<String, Object> res) {
                    CapacitorUpdaterPlugin.this.notifyListeners(id, CapacitorUpdaterPlugin.this.mapToJSObject(res));
                }
            };
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.implementation.activity = this.getActivity();
            this.implementation.versionBuild = this.getConfig().getString("version", pInfo.versionName);
            this.implementation.CAP_SERVER_PATH = WebView.CAP_SERVER_PATH;
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
            this.delayUpdateUtils = new DelayUpdateUtils(
                this.prefs,
                this.editor,
                this.currentVersionNative,
                CapacitorUpdaterPlugin.this::installNext,
                logger
            );
        } catch (final PackageManager.NameNotFoundException e) {
            logger.error("Error instantiating implementation " + e.getMessage());
            return;
        } catch (final Exception e) {
            logger.error("Error getting current native app version " + e.getMessage());
            return;
        }

        boolean disableJSLogging = this.getConfig().getBoolean("disableJSLogging", false);
        // Set the bridge in the Logger when webView is available
        if (this.bridge != null && this.bridge.getWebView() != null && !disableJSLogging) {
            logger.setBridge(this.bridge);
            logger.info("WebView set successfully for logging");
        } else {
            logger.info("WebView not ready yet, will be set later");
        }

        // Set logger for shared classes
        CryptoCipherV2.setLogger(logger);
        DownloadService.setLogger(logger);
        DownloadWorkerManager.setLogger(logger);

        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.appId = InternalUtils.getPackageName(getContext().getPackageManager(), getContext().getPackageName());
        this.implementation.appId = config.getString("appId", this.implementation.appId);
        this.implementation.appId = this.getConfig().getString("appId", this.implementation.appId);
        if (this.implementation.appId == null || this.implementation.appId.isEmpty()) {
            // crash the app
            throw new RuntimeException(
                "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config"
            );
        }
        logger.info("appId: " + implementation.appId);
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
        logger.info("init for device " + this.implementation.deviceID);
        logger.info("version native " + this.currentVersionNative.getOriginalString());
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
        try {
            semaphoreReady.awaitAdvanceInterruptibly(semaphoreReady.getPhase(), waitTime.longValue(), TimeUnit.SECONDS);
            logger.info("semaphoreReady count " + semaphoreReady.getPhase());
        } catch (InterruptedException e) {
            logger.info("semaphoreWait InterruptedException");
            e.printStackTrace();
        } catch (TimeoutException e) {
            throw new RuntimeException(e);
        }
    }

    private void semaphoreUp() {
        logger.info("semaphoreUp");
        semaphoreReady.register();
    }

    private void semaphoreDown() {
        logger.info("semaphoreDown");
        logger.info("semaphoreDown count " + semaphoreReady.getPhase());
        semaphoreReady.arriveAndDeregister();
    }

    private void sendReadyToJs(final BundleInfo current, final String msg) {
        logger.info("sendReadyToJs");
        final JSObject ret = new JSObject();
        ret.put("bundle", mapToJSObject(current.toJSONMap()));
        ret.put("status", msg);
        startNewThread(() -> {
            logger.info("semaphoreReady sendReadyToJs");
            semaphoreWait(CapacitorUpdaterPlugin.this.appReadyTimeout);
            logger.info("semaphoreReady sendReadyToJs done");
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
                    logger.info("New native version detected: " + this.currentVersionNative);
                    this.implementation.reset(true);
                    final List<BundleInfo> installed = this.implementation.list(false);
                    for (final BundleInfo bundle : installed) {
                        try {
                            logger.info("Deleting obsolete bundle: " + bundle.getId());
                            this.implementation.delete(bundle.getId());
                        } catch (final Exception e) {
                            logger.error("Failed to delete: " + bundle.getId() + " " + e.getMessage());
                        }
                    }
                }
            } catch (final Exception e) {
                logger.error("Could not determine the current version " + e.getMessage());
            }
        } catch (final Exception e) {
            logger.error("Error calculating previous native version " + e.getMessage());
        }
        this.editor.putString("LatestVersionNative", this.currentVersionNative.toString());
        this.editor.commit();
    }

    public void notifyDownload(final String id, final int percent) {
        try {
            final JSObject ret = new JSObject();
            ret.put("percent", percent);
            final BundleInfo bundleInfo = this.implementation.getBundleInfo(id);
            ret.put("bundle", mapToJSObject(bundleInfo.toJSONMap()));
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
            logger.error("Could not notify listeners " + e.getMessage());
        }
    }

    @PluginMethod
    public void setUpdateUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            logger.error("setUpdateUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setUpdateUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            logger.error("setUpdateUrl called without url");
            call.reject("setUpdateUrl called without url");
            return;
        }
        this.updateUrl = url;
        call.resolve();
    }

    @PluginMethod
    public void setStatsUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            logger.error("setStatsUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setStatsUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            logger.error("setStatsUrl called without url");
            call.reject("setStatsUrl called without url");
            return;
        }
        this.implementation.statsUrl = url;
        call.resolve();
    }

    @PluginMethod
    public void setChannelUrl(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyUrl", false)) {
            logger.error("setChannelUrl not allowed set allowModifyUrl in your config to true to allow it");
            call.reject("setChannelUrl not allowed");
            return;
        }
        final String url = call.getString("url");
        if (url == null) {
            logger.error("setChannelUrl called without url");
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
            logger.error("Could not get version " + e.getMessage());
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
            logger.error("Could not get device id " + e.getMessage());
            call.reject("Could not get device id", e);
        }
    }

    @PluginMethod
    public void setCustomId(final PluginCall call) {
        final String customId = call.getString("customId");
        if (customId == null) {
            logger.error("setCustomId called without customId");
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
            logger.error("Could not get plugin version " + e.getMessage());
            call.reject("Could not get plugin version", e);
        }
    }

    @PluginMethod
    public void unsetChannel(final PluginCall call) {
        final Boolean triggerAutoUpdate = call.getBoolean("triggerAutoUpdate", false);

        try {
            logger.info("unsetChannel triggerAutoUpdate: " + triggerAutoUpdate);
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.unsetChannel(res -> {
                        JSObject jsRes = mapToJSObject(res);
                        if (jsRes.has("error")) {
                            call.reject(jsRes.getString("error"));
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                logger.info("Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(jsRes);
                        }
                    })
            );
        } catch (final Exception e) {
            logger.error("Failed to unsetChannel: " + e.getMessage());
            call.reject("Failed to unsetChannel: ", e);
        }
    }

    @PluginMethod
    public void setChannel(final PluginCall call) {
        final String channel = call.getString("channel");
        final Boolean triggerAutoUpdate = call.getBoolean("triggerAutoUpdate", false);

        if (channel == null) {
            logger.error("setChannel called without channel");
            call.reject("setChannel called without channel");
            return;
        }
        try {
            logger.info("setChannel " + channel + " triggerAutoUpdate: " + triggerAutoUpdate);
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.setChannel(channel, res -> {
                        JSObject jsRes = mapToJSObject(res);
                        if (jsRes.has("error")) {
                            call.reject(jsRes.getString("error"));
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                logger.info("Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(jsRes);
                        }
                    })
            );
        } catch (final Exception e) {
            logger.error("Failed to setChannel: " + channel + " " + e.getMessage());
            call.reject("Failed to setChannel: " + channel, e);
        }
    }

    @PluginMethod
    public void getChannel(final PluginCall call) {
        try {
            logger.info("getChannel");
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.getChannel(res -> {
                        JSObject jsRes = mapToJSObject(res);
                        if (jsRes.has("error")) {
                            call.reject(jsRes.getString("error"));
                        } else {
                            call.resolve(jsRes);
                        }
                    })
            );
        } catch (final Exception e) {
            logger.error("Failed to getChannel " + e.getMessage());
            call.reject("Failed to getChannel", e);
        }
    }

    @PluginMethod
    public void download(final PluginCall call) {
        final String url = call.getString("url");
        final String version = call.getString("version");
        final String sessionKey = call.getString("sessionKey", "");
        final String checksum = call.getString("checksum", "");
        final JSONArray manifest = call.getData().optJSONArray("manifest");
        if (url == null) {
            logger.error("Download called without url");
            call.reject("Download called without url");
            return;
        }
        if (version == null) {
            logger.error("Download called without version");
            call.reject("Download called without version");
            return;
        }
        try {
            logger.info("Downloading " + url);
            startNewThread(() -> {
                try {
                    final BundleInfo downloaded;
                    if (manifest != null) {
                        // For manifest downloads, we need to handle this asynchronously
                        // since there's no synchronous downloadManifest method in Java
                        CapacitorUpdaterPlugin.this.implementation.downloadBackground(url, version, sessionKey, checksum, manifest);
                        // Return immediately with a pending status - the actual result will come via listeners
                        final String id = CapacitorUpdaterPlugin.this.implementation.randomString();
                        downloaded = new BundleInfo(id, version, BundleStatus.DOWNLOADING, new Date(System.currentTimeMillis()), "");
                        call.resolve(mapToJSObject(downloaded.toJSONMap()));
                        return;
                    } else {
                        downloaded = CapacitorUpdaterPlugin.this.implementation.download(url, version, sessionKey, checksum);
                    }
                    if (downloaded.isErrorStatus()) {
                        throw new RuntimeException("Download failed: " + downloaded.getStatus());
                    } else {
                        call.resolve(mapToJSObject(downloaded.toJSONMap()));
                    }
                } catch (final Exception e) {
                    logger.error("Failed to download from: " + url + " " + e.getMessage());
                    call.reject("Failed to download from: " + url, e);
                    final JSObject ret = new JSObject();
                    ret.put("version", version);
                    CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
                    final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                    CapacitorUpdaterPlugin.this.implementation.sendStats("download_fail", current.getVersionName());
                }
            });
        } catch (final Exception e) {
            logger.error("Failed to download from: " + url + " " + e.getMessage());
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
        logger.info("Reloading: " + path);

        AtomicReference<URL> url = new AtomicReference<>();
        if (this.keepUrlPathAfterReload) {
            try {
                if (Looper.myLooper() != Looper.getMainLooper()) {
                    Semaphore mainThreadSemaphore = new Semaphore(0);
                    this.bridge.executeOnMainThread(() -> {
                            try {
                                url.set(new URL(this.bridge.getWebView().getUrl()));
                            } catch (Exception e) {
                                logger.error("Error executing on main thread " + e.getMessage());
                            }
                            mainThreadSemaphore.release();
                        });
                    mainThreadSemaphore.acquire();
                } else {
                    try {
                        url.set(new URL(this.bridge.getWebView().getUrl()));
                    } catch (Exception e) {
                        logger.error("Error executing on main thread " + e.getMessage());
                    }
                }
            } catch (InterruptedException e) {
                logger.error("Error waiting for main thread or getting the current URL from webview " + e.getMessage());
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
                logger.error("Cannot get finalUrl from capacitor bridge " + e.getMessage());

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
                logger.error("Reload failed");
                call.reject("Reload failed");
            }
        } catch (final Exception e) {
            logger.error("Could not reload " + e.getMessage());
            call.reject("Could not reload", e);
        }
    }

    @PluginMethod
    public void next(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            logger.error("Next called without id");
            call.reject("Next called without id");
            return;
        }
        try {
            logger.info("Setting next active id " + id);
            if (!this.implementation.setNextBundle(id)) {
                logger.error("Set next id failed. Bundle " + id + " does not exist.");
                call.reject("Set next id failed. Bundle " + id + " does not exist.");
            } else {
                call.resolve(mapToJSObject(this.implementation.getBundleInfo(id).toJSONMap()));
            }
        } catch (final Exception e) {
            logger.error("Could not set next id " + id + " " + e.getMessage());
            call.reject("Could not set next id: " + id, e);
        }
    }

    @PluginMethod
    public void set(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            logger.error("Set called without id");
            call.reject("Set called without id");
            return;
        }
        try {
            logger.info("Setting active bundle " + id);
            if (!this.implementation.set(id)) {
                logger.info("No such bundle " + id);
                call.reject("Update failed, id " + id + " does not exist.");
            } else {
                logger.info("Bundle successfully set to " + id);
                this.reload(call);
            }
        } catch (final Exception e) {
            logger.error("Could not set id " + id + " " + e.getMessage());
            call.reject("Could not set id " + id, e);
        }
    }

    @PluginMethod
    public void delete(final PluginCall call) {
        final String id = call.getString("id");
        if (id == null) {
            logger.error("missing id");
            call.reject("missing id");
            return;
        }
        logger.info("Deleting id " + id);
        try {
            final Boolean res = this.implementation.delete(id);
            if (res) {
                call.resolve();
            } else {
                logger.error("Delete failed, id " + id + " does not exist");
                call.reject("Delete failed, id " + id + " does not exist or it cannot be deleted (perhaps it is the 'next' bundle)");
            }
        } catch (final Exception e) {
            logger.error("Could not delete id " + id + " " + e.getMessage());
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
                values.put(mapToJSObject(bundle.toJSONMap()));
            }
            ret.put("bundles", values);
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not list bundles " + e.getMessage());
            call.reject("Could not list bundles", e);
        }
    }

    @PluginMethod
    public void getLatest(final PluginCall call) {
        final String channel = call.getString("channel");
        startNewThread(() ->
            CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, channel, res -> {
                    JSObject jsRes = mapToJSObject(res);
                    if (jsRes.has("error")) {
                        call.reject(jsRes.getString("error"));
                        return;
                    } else if (jsRes.has("message")) {
                        call.reject(jsRes.getString("message"));
                        return;
                    } else {
                        call.resolve(jsRes);
                    }
                })
        );
    }

    private boolean _reset(final Boolean toLastSuccessful) {
        final BundleInfo fallback = this.implementation.getFallbackBundle();
        this.implementation.reset();

        if (toLastSuccessful && !fallback.isBuiltin()) {
            logger.info("Resetting to: " + fallback);
            return this.implementation.set(fallback) && this._reload();
        }

        logger.info("Resetting to native.");
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
            logger.error("Reset failed");
            call.reject("Reset failed");
        } catch (final Exception e) {
            logger.error("Reset failed " + e.getMessage());
            call.reject("Reset failed", e);
        }
    }

    @PluginMethod
    public void current(final PluginCall call) {
        ensureBridgeSet();
        try {
            final JSObject ret = new JSObject();
            final BundleInfo bundle = this.implementation.getCurrentBundle();
            ret.put("bundle", mapToJSObject(bundle.toJSONMap()));
            ret.put("native", this.currentVersionNative);
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not get current bundle " + e.getMessage());
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

            call.resolve(mapToJSObject(bundle.toJSONMap()));
        } catch (final Exception e) {
            logger.error("Could not get next bundle " + e.getMessage());
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
                                JSObject jsRes = mapToJSObject(res);
                                if (jsRes.has("error")) {
                                    logger.error(Objects.requireNonNull(jsRes.getString("error")));
                                } else if (jsRes.has("version")) {
                                    String newVersion = jsRes.getString("version");
                                    String currentVersion = String.valueOf(CapacitorUpdaterPlugin.this.implementation.getCurrentBundle());
                                    if (!Objects.equals(newVersion, currentVersion)) {
                                        logger.info("New version found: " + newVersion);
                                        CapacitorUpdaterPlugin.this.backgroundDownload();
                                    }
                                }
                            });
                    } catch (final Exception e) {
                        logger.error("Failed to check for update " + e.getMessage());
                    }
                }
            },
            this.periodCheckDelay,
            this.periodCheckDelay
        );
    }

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        ensureBridgeSet();
        try {
            final BundleInfo bundle = this.implementation.getCurrentBundle();
            this.implementation.setSuccess(bundle, this.autoDeletePrevious);
            logger.info("Current bundle loaded successfully. ['notifyAppReady()' was called] " + bundle);
            logger.info("semaphoreReady countDown");
            this.semaphoreDown();
            logger.info("semaphoreReady countDown done");
            final JSObject ret = new JSObject();
            ret.put("bundle", mapToJSObject(bundle.toJSONMap()));
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Failed to notify app ready state. [Error calling 'notifyAppReady()'] " + e.getMessage());
            call.reject("Failed to commit app ready state.", e);
        }
    }

    @PluginMethod
    public void setMultiDelay(final PluginCall call) {
        try {
            final JSONArray delayConditions = call.getData().optJSONArray("delayConditions");
            if (delayConditions == null) {
                logger.error("setMultiDelay called without delayCondition");
                call.reject("setMultiDelay called without delayCondition");
                return;
            }
            for (int i = 0; i < delayConditions.length(); i++) {
                final JSONObject object = delayConditions.optJSONObject(i);
                if (object != null && object.optString("kind").equals("background") && object.optString("value").isEmpty()) {
                    object.put("value", "0");
                    delayConditions.put(i, object);
                }
            }

            if (this.delayUpdateUtils.setMultiDelay(delayConditions.toString())) {
                call.resolve();
            } else {
                call.reject("Failed to delay update");
            }
        } catch (final Exception e) {
            logger.error("Failed to delay update, [Error calling 'setMultiDelay()'] " + e.getMessage());
            call.reject("Failed to delay update", e);
        }
    }

    @PluginMethod
    public void cancelDelay(final PluginCall call) {
        if (this.delayUpdateUtils.cancelDelay("JS")) {
            call.resolve();
        } else {
            call.reject("Failed to cancel delay");
        }
    }

    private Boolean _isAutoUpdateEnabled() {
        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        String serverUrl = config.getServerUrl();
        if (serverUrl != null && !serverUrl.isEmpty()) {
            // log warning autoupdate disabled when serverUrl is set
            logger.warn("AutoUpdate is automatic disabled when serverUrl is set.");
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
            logger.error("Could not get autoUpdate status " + e.getMessage());
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
            logger.error("Could not get autoUpdate availability " + e.getMessage());
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
            logger.error("Failed to start " + DeferredNotifyAppReadyCheck.class.getName() + " " + e.getMessage());
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

    private void ensureBridgeSet() {
        if (this.bridge != null && this.bridge.getWebView() != null) {
            logger.setBridge(this.bridge);
        }
    }

    private void endBackGroundTaskWithNotif(String msg, String latestVersionName, BundleInfo current, Boolean error) {
        if (error) {
            logger.info(
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
        ret.put("bundle", mapToJSObject(current.toJSONMap()));
        this.notifyListeners("noNeedUpdate", ret);
        this.sendReadyToJs(current, msg);
        this.backgroundDownloadTask = null;
        logger.info("endBackGroundTaskWithNotif " + msg);
    }

    private Thread backgroundDownload() {
        String messageUpdate = this.implementation.directUpdate
            ? "Update will occur now."
            : "Update will occur next time app moves to background.";
        return startNewThread(() -> {
            logger.info("Check for update via: " + CapacitorUpdaterPlugin.this.updateUrl);
            CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, null, res -> {
                    JSObject jsRes = mapToJSObject(res);
                    final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                    try {
                        if (jsRes.has("message")) {
                            logger.info("API message: " + jsRes.get("message"));
                            if (jsRes.has("major") && jsRes.getBoolean("major") && jsRes.has("version")) {
                                final JSObject majorAvailable = new JSObject();
                                majorAvailable.put("version", jsRes.getString("version"));
                                CapacitorUpdaterPlugin.this.notifyListeners("majorAvailable", majorAvailable);
                            }
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                    jsRes.getString("message"),
                                    current.getVersionName(),
                                    current,
                                    true
                                );
                            return;
                        }

                        final String latestVersionName = jsRes.getString("version");

                        if ("builtin".equals(latestVersionName)) {
                            logger.info("Latest version is builtin");
                            if (CapacitorUpdaterPlugin.this.implementation.directUpdate) {
                                logger.info("Direct update to builtin version");
                                this._reset(false);
                                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                        "Updated to builtin version",
                                        latestVersionName,
                                        CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                                        false
                                    );
                            } else {
                                logger.info("Setting next bundle to builtin");
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

                        if (!jsRes.has("url") || !CapacitorUpdaterPlugin.this.isValidURL(jsRes.getString("url"))) {
                            logger.error("Error no url or wrong format");
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
                                ret.put("bundle", mapToJSObject(latest.toJSONMap()));
                                if (latest.isErrorStatus()) {
                                    logger.error("Latest bundle already exists, and is in error state. Aborting update.");
                                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                            "Latest bundle already exists, and is in error state. Aborting update.",
                                            latestVersionName,
                                            current,
                                            true
                                        );
                                    return;
                                }
                                if (latest.isDownloaded()) {
                                    logger.info("Latest bundle already exists and download is NOT required. " + messageUpdate);
                                    if (CapacitorUpdaterPlugin.this.implementation.directUpdate) {
                                        Gson gson = new Gson();
                                        String delayUpdatePreferences = prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]");
                                        Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
                                        ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
                                        if (delayConditionList != null && !delayConditionList.isEmpty()) {
                                            logger.info("Update delayed until delay conditions met");
                                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                                    "Update delayed until delay conditions met",
                                                    latestVersionName,
                                                    latest,
                                                    false
                                                );
                                            return;
                                        }
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
                                    logger.info("Latest bundle already exists and will be deleted, download will overwrite it.");
                                    try {
                                        final Boolean deleted = CapacitorUpdaterPlugin.this.implementation.delete(latest.getId(), true);
                                        if (deleted) {
                                            logger.info("Failed bundle deleted: " + latest.getVersionName());
                                        }
                                    } catch (final IOException e) {
                                        logger.error("Failed to delete failed bundle: " + latest.getVersionName() + " " + e.getMessage());
                                    }
                                }
                            }
                            startNewThread(() -> {
                                try {
                                    logger.info(
                                        "New bundle: " +
                                        latestVersionName +
                                        " found. Current is: " +
                                        current.getVersionName() +
                                        ". " +
                                        messageUpdate
                                    );

                                    final String url = jsRes.getString("url");
                                    final String sessionKey = jsRes.has("sessionKey") ? jsRes.getString("sessionKey") : "";
                                    final String checksum = jsRes.has("checksum") ? jsRes.getString("checksum") : "";

                                    if (jsRes.has("manifest")) {
                                        // Handle manifest-based download
                                        JSONArray manifest = jsRes.getJSONArray("manifest");
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
                                    logger.error("error downloading file " + e.getMessage());
                                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                            "Error downloading file",
                                            latestVersionName,
                                            CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                                            true
                                        );
                                }
                            });
                        } else {
                            logger.info("No need to update, " + current.getId() + " is the latest bundle.");
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif("No need to update", latestVersionName, current, false);
                        }
                    } catch (final JSONException e) {
                        logger.error("error parsing JSON " + e.getMessage());
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
            String delayUpdatePreferences = prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]");
            Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
            ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
            if (delayConditionList != null && !delayConditionList.isEmpty()) {
                logger.info("Update delayed until delay conditions met");
                return;
            }
            final BundleInfo current = this.implementation.getCurrentBundle();
            final BundleInfo next = this.implementation.getNextBundle();

            if (next != null && !next.isErrorStatus() && !next.getId().equals(current.getId())) {
                // There is a next bundle waiting for activation
                logger.debug("Next bundle is: " + next.getVersionName());
                if (this.implementation.set(next) && this._reload()) {
                    logger.info("Updated to bundle: " + next.getVersionName());
                    this.implementation.setNextBundle(null);
                } else {
                    logger.error("Update to bundle: " + next.getVersionName() + " Failed!");
                }
            }
        } catch (final Exception e) {
            logger.error("Error during onActivityStopped " + e.getMessage());
        }
    }

    private void checkRevert() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        final BundleInfo current = this.implementation.getCurrentBundle();

        if (current.isBuiltin()) {
            logger.info("Built-in bundle is active. We skip the check for notifyAppReady.");
            return;
        }
        logger.debug("Current bundle is: " + current);

        if (BundleStatus.SUCCESS != current.getStatus()) {
            logger.error("notifyAppReady was not called, roll back current bundle: " + current.getId());
            logger.info("Did you forget to call 'notifyAppReady()' in your Capacitor App code?");
            final JSObject ret = new JSObject();
            ret.put("bundle", mapToJSObject(current.toJSONMap()));
            this.notifyListeners("updateFailed", ret);
            this.implementation.sendStats("update_fail", current.getVersionName());
            this.implementation.setError(current);
            this._reset(true);
            if (CapacitorUpdaterPlugin.this.autoDeleteFailed && !current.isBuiltin()) {
                logger.info("Deleting failing bundle: " + current.getVersionName());
                try {
                    final Boolean res = this.implementation.delete(current.getId(), false);
                    if (res) {
                        logger.info("Failed bundle deleted: " + current.getVersionName());
                    }
                } catch (final IOException e) {
                    logger.error("Failed to delete failed bundle: " + current.getVersionName() + " " + e.getMessage());
                }
            }
        } else {
            logger.info("notifyAppReady was called. This is fine: " + current.getId());
        }
    }

    private class DeferredNotifyAppReadyCheck implements Runnable {

        @Override
        public void run() {
            try {
                logger.info("Wait for " + CapacitorUpdaterPlugin.this.appReadyTimeout + "ms, then check for notifyAppReady");
                Thread.sleep(CapacitorUpdaterPlugin.this.appReadyTimeout);
                CapacitorUpdaterPlugin.this.checkRevert();
                CapacitorUpdaterPlugin.this.appReadyCheck = null;
            } catch (final InterruptedException e) {
                logger.info(DeferredNotifyAppReadyCheck.class.getName() + " was interrupted.");
            }
        }
    }

    public void appMovedToForeground() {
        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
        CapacitorUpdaterPlugin.this.implementation.sendStats("app_moved_to_foreground", current.getVersionName());
        this.delayUpdateUtils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.FOREGROUND);
        this.delayUpdateUtils.unsetBackgroundTimestamp();
        if (
            CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() &&
            (this.backgroundDownloadTask == null || !this.backgroundDownloadTask.isAlive())
        ) {
            this.backgroundDownloadTask = this.backgroundDownload();
        } else {
            logger.info("Auto update is disabled");
            this.sendReadyToJs(current, "disabled");
        }
        this.checkAppReady();
    }

    public void appMovedToBackground() {
        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
        CapacitorUpdaterPlugin.this.implementation.sendStats("app_moved_to_background", current.getVersionName());
        logger.info("Checking for pending update");
        try {
            // We need to set "backgrounded time"
            this.delayUpdateUtils.setBackgroundTimestamp(System.currentTimeMillis());
            this.delayUpdateUtils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.BACKGROUND);
            this.installNext();
        } catch (final Exception e) {
            logger.error("Error during onActivityStopped " + e.getMessage());
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
        logger.debug("onActivityDestroyed: all activity destroyed");
        this.delayUpdateUtils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.KILLED);
    }

    @Override
    public void handleOnStart() {
        if (isPreviousMainActivity) {
            this.appMovedToForeground();
        }
        logger.info("onActivityStarted " + getActivity().getClass().getName());
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
        logger.info("onActivityDestroyed " + getActivity().getClass().getName());
        this.implementation.activity = getActivity();
        counterActivityCreate--;
        if (counterActivityCreate == 0) {
            this.appKilled();
        }
    }
}
