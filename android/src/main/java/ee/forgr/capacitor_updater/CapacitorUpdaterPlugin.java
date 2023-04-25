/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.Application;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
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
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import io.github.g00fy2.versioncompare.Version;
import java.io.IOException;
import java.lang.reflect.Type;
import java.net.MalformedURLException;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;
import org.json.JSONException;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin
  extends Plugin
  implements Application.ActivityLifecycleCallbacks {

  private static final String updateUrlDefault =
    "https://api.capgo.app/updates";
  private static final String statsUrlDefault = "https://api.capgo.app/stats";
  private static final String defaultPrivateKey =
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKCAQEA4pW9olT0FBXXivRCzd3xcImlWZrqkwcF2xTkX/FwXmj9eh9H\nkBLrsQmfsC+PJisRXIOGq6a0z3bsGq6jBpp3/Jr9jiaW5VuPGaKeMaZZBRvi/N5f\nIMG3hZXSOcy0IYg+E1Q7RkYO1xq5GLHseqG+PXvJsNe4R8R/Bmd/ngq0xh/cvcrH\nHpXwO0Aj9tfprlb+rHaVV79EkVRWYPidOLnK1n0EFHFJ1d/MyDIp10TEGm2xHpf/\nBrlb1an8wXEuzoC0DgYaczgTjovwR+ewSGhSHJliQdM0Qa3o1iN87DldWtydImMs\nPjJ3DUwpsjAMRe5X8Et4+udFW2ciYnQo9H0CkwIDAQABAoIBAQCtjlMV/4qBxAU4\nu0ZcWA9yywwraX0aJ3v1xrfzQYV322Wk4Ea5dbSxA5UcqCE29DA1M824t1Wxv/6z\npWbcTP9xLuresnJMtmgTE7umfiubvTONy2sENT20hgDkIwcq1CfwOEm61zjQzPhQ\nkSB5AmEsyR/BZEsUNc+ygR6AWOUFB7tj4yMc32LOTWSbE/znnF2BkmlmnQykomG1\n2oVqM3lUFP7+m8ux1O7scO6IMts+Z/eFXjWfxpbebUSvSIR83GXPQZ34S/c0ehOg\nyHdmCSOel1r3VvInMe+30j54Jr+Ml/7Ee6axiwyE2e/bd85MsK9sVdp0OtelXaqA\nOZZqWvN5AoGBAP2Hn3lSq+a8GsDH726mHJw60xM0LPbVJTYbXsmQkg1tl3NKJTMM\nQqz41+5uys+phEgLHI9gVJ0r+HaGHXnJ4zewlFjsudstb/0nfctUvTqnhEhfNo9I\ny4kufVKPRF3sMEeo7CDVJs4GNBLycEyIBy6Mbv0VcO7VaZqggRwu4no9AoGBAOTK\n6NWYs1BWlkua2wmxexGOzehNGedInp0wGr2l4FDayWjkZLqvB+nNXUQ63NdHlSs4\nWB2Z1kQXZxVaI2tPYexGUKXEo2uFob63uflbuE029ovDXIIPFTPtGNdNXwhHT5a+\nPhmy3sMc+s2BSNM5qaNmfxQxhdd6gRU6oikE+c0PAoGAMn3cKNFqIt27hkFLUgIL\nGKIuf1iYy9/PNWNmEUaVj88PpopRtkTu0nwMpROzmH/uNFriKTvKHjMvnItBO4wV\nkHW+VadvrFL0Rrqituf9d7z8/1zXBNo+juePVe3qc7oiM2NVA4Tv4YAixtM5wkQl\nCgQ15nlqsGYYTg9BJ1e/CxECgYEAjEYPzO2reuUrjr0p8F59ev1YJ0YmTJRMk0ks\nC/yIdGo/tGzbiU3JB0LfHPcN8Xu07GPGOpfYM7U5gXDbaG6qNgfCaHAQVdr/mQPi\nJQ1kCQtay8QCkscWk9iZM1//lP7LwDtxraXqSCwbZSYP9VlUNZeg8EuQqNU2EUL6\nqzWexmcCgYEA0prUGNBacraTYEknB1CsbP36UPWsqFWOvevlz+uEC5JPxPuW5ZHh\nSQN7xl6+PHyjPBM7ttwPKyhgLOVTb3K7ex/PXnudojMUK5fh7vYfChVTSlx2p6r0\nDi58PdD+node08cJH+ie0Yphp7m+D4+R9XD0v0nEvnu4BtAW6DrJasw=\n-----END RSA PRIVATE KEY-----\n";
  private static final String channelUrlDefault =
    "https://api.capgo.app/channel_self";

  private final String PLUGIN_VERSION = "4.48.0";
  private static final String DELAY_CONDITION_PREFERENCES = "";

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
  private Thread backgroundTask;
  private Boolean taskRunning = false;

  private Boolean isPreviousMainActivity = true;

  private volatile Thread appReadyCheck;

  @Override
  public void load() {
    super.load();
    this.prefs =
      this.getContext()
        .getSharedPreferences(
          WebView.WEBVIEW_PREFS_NAME,
          Activity.MODE_PRIVATE
        );
    this.editor = this.prefs.edit();

    try {
      this.implementation =
        new CapacitorUpdater() {
          @Override
          public void notifyDownload(final String id, final int percent) {
            CapacitorUpdaterPlugin.this.notifyDownload(id, percent);
          }

          @Override
          public void notifyListeners(final String id, final JSObject res) {
            CapacitorUpdaterPlugin.this.notifyListeners(id, res);
          }
        };
      final PackageInfo pInfo =
        this.getContext()
          .getPackageManager()
          .getPackageInfo(this.getContext().getPackageName(), 0);
      this.implementation.activity = this.getActivity();
      this.implementation.versionBuild = pInfo.versionName;
      this.implementation.PLUGIN_VERSION = this.PLUGIN_VERSION;
      this.implementation.versionCode = Integer.toString(pInfo.versionCode);
      this.implementation.requestQueue =
        Volley.newRequestQueue(this.getContext());
      this.currentVersionNative =
        new Version(this.getConfig().getString("version", pInfo.versionName));
    } catch (final PackageManager.NameNotFoundException e) {
      Log.e(CapacitorUpdater.TAG, "Error instantiating implementation", e);
      return;
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Error getting current native app version",
        e
      );
      return;
    }

    final CapConfig config = CapConfig.loadDefault(this.getActivity());
    this.implementation.appId = config.getString("appId", "");
    this.implementation.privateKey =
      this.getConfig().getString("privateKey", defaultPrivateKey);
    this.implementation.statsUrl =
      this.getConfig().getString("statsUrl", statsUrlDefault);
    this.implementation.channelUrl =
      this.getConfig().getString("channelUrl", channelUrlDefault);
    this.implementation.documentsDir = this.getContext().getFilesDir();
    this.implementation.prefs = this.prefs;
    this.implementation.editor = this.editor;
    this.implementation.versionOs = Build.VERSION.RELEASE;
    this.implementation.deviceID =
      this.prefs.getString("appUUID", UUID.randomUUID().toString());
    this.editor.putString("appUUID", this.implementation.deviceID);
    Log.i(
      CapacitorUpdater.TAG,
      "init for device " + this.implementation.deviceID
    );

    this.autoDeleteFailed =
      this.getConfig().getBoolean("autoDeleteFailed", true);
    this.autoDeletePrevious =
      this.getConfig().getBoolean("autoDeletePrevious", true);
    this.updateUrl = this.getConfig().getString("updateUrl", updateUrlDefault);
    this.autoUpdate = this.getConfig().getBoolean("autoUpdate", true);
    this.appReadyTimeout = this.getConfig().getInt("appReadyTimeout", 10000);
    this.resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);

    if (this.resetWhenUpdate) {
      this.cleanupObsoleteVersions();
    }
    final Application application = (Application) this.getContext()
      .getApplicationContext();
    application.registerActivityLifecycleCallbacks(this);
  }

  private void cleanupObsoleteVersions() {
    try {
      final Version previous = new Version(
        this.prefs.getString("LatestVersionNative", "")
      );
      try {
        if (
          !"".equals(previous.getOriginalString()) && 
          !this.currentVersionNative.getOriginalString().equals(previous.getOriginalString())
        ) {
          Log.i(
            CapacitorUpdater.TAG,
            "New native version detected: " + this.currentVersionNative
          );
          this.implementation.reset(true);
          final List<BundleInfo> installed = this.implementation.list();
          for (final BundleInfo bundle : installed) {
            try {
              Log.i(
                CapacitorUpdater.TAG,
                "Deleting obsolete bundle: " + bundle.getId()
              );
              this.implementation.delete(bundle.getId());
            } catch (final Exception e) {
              Log.e(
                CapacitorUpdater.TAG,
                "Failed to delete: " + bundle.getId(),
                e
              );
            }
          }
        }
      } catch (final Exception e) {
        Log.e(
          CapacitorUpdater.TAG,
          "Could not determine the current version",
          e
        );
      }
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Error calculating previous native version",
        e
      );
    }
    this.editor.putString(
        "LatestVersionNative",
        this.currentVersionNative.toString()
      );
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
        this.notifyListeners("downloadComplete", bundleInfo.toJSON());
        this.implementation.sendStats(
            "download_complete",
            bundleInfo.getVersionName()
          );
      } else if (percent % 10 == 0) {
        this.implementation.sendStats(
            "download_" + percent,
            bundleInfo.getVersionName()
          );
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
  public void setChannel(final PluginCall call) {
    final String channel = call.getString("channel");
    if (channel == null) {
      Log.e(CapacitorUpdater.TAG, "setChannel called without channel");
      call.reject("setChannel called without channel");
      return;
    }
    try {
      Log.i(CapacitorUpdater.TAG, "setChannel " + channel);
      new Thread(
        new Runnable() {
          @Override
          public void run() {
            CapacitorUpdaterPlugin.this.implementation.setChannel(
                channel,
                res -> {
                  if (res.has("error")) {
                    call.reject(res.getString("error"));
                  } else {
                    call.resolve(res);
                  }
                }
              );
          }
        }
      )
        .start();
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Failed to setChannel: " + channel, e);
      call.reject("Failed to setChannel: " + channel, e);
    }
  }

  @PluginMethod
  public void getChannel(final PluginCall call) {
    try {
      Log.i(CapacitorUpdater.TAG, "getChannel");
      new Thread(
        new Runnable() {
          @Override
          public void run() {
            CapacitorUpdaterPlugin.this.implementation.getChannel(res -> {
                if (res.has("error")) {
                  call.reject(res.getString("error"));
                } else {
                  call.resolve(res);
                }
              });
          }
        }
      )
        .start();
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
      new Thread(
        new Runnable() {
          @Override
          public void run() {
            try {
              final BundleInfo downloaded =
                CapacitorUpdaterPlugin.this.implementation.download(
                    url,
                    version,
                    sessionKey,
                    checksum
                  );

              call.resolve(downloaded.toJSON());
            } catch (final IOException e) {
              Log.e(CapacitorUpdater.TAG, "Failed to download from: " + url, e);
              call.reject("Failed to download from: " + url, e);
              final JSObject ret = new JSObject();
              ret.put("version", version);
              CapacitorUpdaterPlugin.this.notifyListeners(
                  "downloadFailed",
                  ret
                );
              final BundleInfo current =
                CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
              CapacitorUpdaterPlugin.this.implementation.sendStats(
                  "download_fail",
                  current.getVersionName()
                );
            }
          }
        }
      )
        .start();
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Failed to download from: " + url, e);
      call.reject("Failed to download from: " + url, e);
      final JSObject ret = new JSObject();
      ret.put("version", version);
      CapacitorUpdaterPlugin.this.notifyListeners("downloadFailed", ret);
      final BundleInfo current =
        CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
      CapacitorUpdaterPlugin.this.implementation.sendStats(
          "download_fail",
          current.getVersionName()
        );
    }
  }

  private boolean _reload() {
    final String path = this.implementation.getCurrentBundlePath();
    Log.i(CapacitorUpdater.TAG, "Reloading: " + path);
    if (this.implementation.isUsingBuiltin()) {
      this.bridge.setServerAssetPath(path);
    } else {
      this.bridge.setServerBasePath(path);
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
        Log.e(
          CapacitorUpdater.TAG,
          "Set next id failed. Bundle " + id + " does not exist."
        );
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
        Log.e(
          CapacitorUpdater.TAG,
          "Delete failed, id " + id + " does not exist"
        );
        call.reject("Delete failed, id " + id + " does not exist");
      }
    } catch (final Exception e) {
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
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Could not list bundles", e);
      call.reject("Could not list bundles", e);
    }
  }

  @PluginMethod
  public void getLatest(final PluginCall call) {
    try {
      new Thread(
        new Runnable() {
          @Override
          public void run() {
            CapacitorUpdaterPlugin.this.implementation.getLatest(
                CapacitorUpdaterPlugin.this.updateUrl,
                res -> {
                  if (res.has("error")) {
                    call.reject(res.getString("error"));
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
                }
              );
          }
        }
      )
        .start();
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Failed to getLatest", e);
      call.reject("Failed to getLatest", e);
    }
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
      final Boolean toLastSuccessful = call.getBoolean(
        "toLastSuccessful",
        false
      );
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
  public void notifyAppReady(final PluginCall call) {
    try {
      final BundleInfo bundle = this.implementation.getCurrentBundle();
      this.implementation.setSuccess(bundle, this.autoDeletePrevious);
      Log.i(
        CapacitorUpdater.TAG,
        "Current bundle loaded successfully. ['notifyAppReady()' was called] " +
        bundle
      );
      call.resolve();
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Failed to notify app ready state. [Error calling 'notifyAppReady()']",
        e
      );
      call.reject("Failed to commit app ready state.", e);
    }
  }

  @PluginMethod
  public void setMultiDelay(final PluginCall call) {
    try {
      final Object delayConditions = call.getData().opt("delayConditions");
      if (delayConditions == null) {
        Log.e(
          CapacitorUpdater.TAG,
          "setMultiDelay called without delayCondition"
        );
        call.reject("setMultiDelay called without delayCondition");
        return;
      }
      if (_setMultiDelay(delayConditions.toString())) {
        call.resolve();
      } else {
        call.reject("Failed to delay update");
      }
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Failed to delay update, [Error calling 'setMultiDelay()']",
        e
      );
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
      Log.e(
        CapacitorUpdater.TAG,
        "Failed to delay update, [Error calling '_setMultiDelay()']",
        e
      );
      return false;
    }
  }

  @Deprecated
  @PluginMethod
  public void setDelay(final PluginCall call) {
    try {
      String kind = call.getString("kind");
      String value = call.getString("value");
      String delayConditions =
        "[{\"kind\":\"" +
        kind +
        "\", \"value\":\"" +
        (value != null ? value : "") +
        "\"}]";
      if (_setMultiDelay(delayConditions)) {
        call.resolve();
      } else {
        call.reject("Failed to delay update");
      }
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Failed to delay update, [Error calling 'setDelay()']",
        e
      );
      call.reject("Failed to delay update", e);
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
    String delayUpdatePreferences = prefs.getString(
      DELAY_CONDITION_PREFERENCES,
      "[]"
    );
    Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
    ArrayList<DelayCondition> delayConditionList = gson.fromJson(
      delayUpdatePreferences,
      type
    );
    for (DelayCondition condition : delayConditionList) {
      String kind = condition.getKind().toString();
      String value = condition.getValue();
      if (!"".equals(kind)) {
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
                final SimpleDateFormat sdf = new SimpleDateFormat(
                  "yyyy-MM-dd'T'HH:mm:ss.SSS"
                );
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
    if (serverUrl != null && !"".equals(serverUrl)) {
      // log warning autoupdate disabled when serverUrl is set
      Log.w(
        CapacitorUpdater.TAG,
        "AutoUpdate is automatic disabled when serverUrl is set."
      );
    }
    return (
      CapacitorUpdaterPlugin.this.autoUpdate &&
      !"".equals(CapacitorUpdaterPlugin.this.updateUrl) &&
      serverUrl == null &&
      !"".equals(serverUrl)
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

  private void checkAppReady() {
    try {
      if (this.appReadyCheck != null) {
        this.appReadyCheck.interrupt();
      }
      this.appReadyCheck = new Thread(new DeferredNotifyAppReadyCheck());
      this.appReadyCheck.start();
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        "Failed to start " + DeferredNotifyAppReadyCheck.class.getName(),
        e
      );
    }
  }

  private boolean isValidURL(String urlStr) {
    try {
      URL url = new URL(urlStr);
      return true;
    } catch (MalformedURLException e) {
      return false;
    }
  }

  private void backgroundDownload() {
    new Thread(
      new Runnable() {
        @Override
        public void run() {
          Log.i(
            CapacitorUpdater.TAG,
            "Check for update via: " + CapacitorUpdaterPlugin.this.updateUrl
          );
          CapacitorUpdaterPlugin.this.implementation.getLatest(
              CapacitorUpdaterPlugin.this.updateUrl,
              res -> {
                final BundleInfo current =
                  CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                try {
                  if (res.has("message")) {
                    Log.i(
                      CapacitorUpdater.TAG,
                      "message " + res.get("message")
                    );
                    if (
                      res.has("major") &&
                      res.getBoolean("major") &&
                      res.has("version")
                    ) {
                      final JSObject majorAvailable = new JSObject();
                      majorAvailable.put("version", res.getString("version"));
                      CapacitorUpdaterPlugin.this.notifyListeners(
                          "majorAvailable",
                          majorAvailable
                        );
                    }
                    final JSObject retNoNeed = new JSObject();
                    retNoNeed.put("bundle", current.toJSON());
                    CapacitorUpdaterPlugin.this.notifyListeners(
                        "noNeedUpdate",
                        retNoNeed
                      );
                    return;
                  }

                  if (
                    !res.has("url") ||
                    !CapacitorUpdaterPlugin.this.isValidURL(
                        res.getString("url")
                      )
                  ) {
                    Log.e(CapacitorUpdater.TAG, "Error no url or wrong format");
                    final JSObject retNoNeed = new JSObject();
                    retNoNeed.put("bundle", current.toJSON());
                    CapacitorUpdaterPlugin.this.notifyListeners(
                        "noNeedUpdate",
                        retNoNeed
                      );
                  }
                  final String latestVersionName = res.getString("version");

                  if (
                    latestVersionName != null &&
                    !"".equals(latestVersionName) &&
                    !current.getVersionName().equals(latestVersionName)
                  ) {
                    final BundleInfo latest =
                      CapacitorUpdaterPlugin.this.implementation.getBundleInfoByName(
                          latestVersionName
                        );
                    if (latest != null) {
                      if (latest.isErrorStatus()) {
                        Log.e(
                          CapacitorUpdater.TAG,
                          "Latest bundle already exists, and is in error state. Aborting update."
                        );
                        final JSObject retNoNeed = new JSObject();
                        retNoNeed.put("bundle", current.toJSON());
                        CapacitorUpdaterPlugin.this.notifyListeners(
                            "noNeedUpdate",
                            retNoNeed
                          );
                        return;
                      }
                      if (latest.isDownloaded()) {
                        Log.i(
                          CapacitorUpdater.TAG,
                          "Latest bundle already exists and download is NOT required. Update will occur next time app moves to background."
                        );
                        final JSObject ret = new JSObject();
                        ret.put("bundle", latest.toJSON());
                        CapacitorUpdaterPlugin.this.notifyListeners(
                            "updateAvailable",
                            ret
                          );
                        CapacitorUpdaterPlugin.this.implementation.setNextBundle(
                            latest.getId()
                          );
                        return;
                      }
                      if (latest.isDeleted()) {
                        Log.i(
                          CapacitorUpdater.TAG,
                          "Latest bundle already exists and will be deleted, download will overwrite it."
                        );
                        try {
                          final Boolean deleted =
                            CapacitorUpdaterPlugin.this.implementation.delete(
                                latest.getId(),
                                true
                              );
                          if (deleted) {
                            Log.i(
                              CapacitorUpdater.TAG,
                              "Failed bundle deleted: " +
                              latest.getVersionName()
                            );
                          }
                        } catch (final IOException e) {
                          Log.e(
                            CapacitorUpdater.TAG,
                            "Failed to delete failed bundle: " +
                            latest.getVersionName(),
                            e
                          );
                        }
                      }
                    }

                    new Thread(
                      new Runnable() {
                        @Override
                        public void run() {
                          try {
                            Log.i(
                              CapacitorUpdater.TAG,
                              "New bundle: " +
                              latestVersionName +
                              " found. Current is: " +
                              current.getVersionName() +
                              ". Update will occur next time app moves to background."
                            );

                            final String url = res.getString("url");
                            final String sessionKey = res.has("sessionKey")
                              ? res.getString("sessionKey")
                              : "";
                            final String checksum = res.has("checksum")
                              ? res.getString("checksum")
                              : "";
                            CapacitorUpdaterPlugin.this.implementation.downloadBackground(
                                url,
                                latestVersionName,
                                sessionKey,
                                checksum
                              );
                          } catch (final Exception e) {
                            Log.e(
                              CapacitorUpdater.TAG,
                              "error downloading file",
                              e
                            );
                            final JSObject ret = new JSObject();
                            ret.put("version", latestVersionName);
                            CapacitorUpdaterPlugin.this.notifyListeners(
                                "downloadFailed",
                                ret
                              );
                            final BundleInfo current =
                              CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                            CapacitorUpdaterPlugin.this.implementation.sendStats(
                                "download_fail",
                                current.getVersionName()
                              );
                            final JSObject retNoNeed = new JSObject();
                            retNoNeed.put("bundle", current.toJSON());
                            CapacitorUpdaterPlugin.this.notifyListeners(
                                "noNeedUpdate",
                                retNoNeed
                              );
                          }
                        }
                      }
                    )
                      .start();
                  } else {
                    Log.i(
                      CapacitorUpdater.TAG,
                      "No need to update, " +
                      current.getId() +
                      " is the latest bundle."
                    );
                    final JSObject retNoNeed = new JSObject();
                    retNoNeed.put("bundle", current.toJSON());
                    CapacitorUpdaterPlugin.this.notifyListeners(
                        "noNeedUpdate",
                        retNoNeed
                      );
                  }
                } catch (final JSONException e) {
                  Log.e(CapacitorUpdater.TAG, "error parsing JSON", e);
                  final JSObject retNoNeed = new JSObject();
                  retNoNeed.put("bundle", current.toJSON());
                  CapacitorUpdaterPlugin.this.notifyListeners(
                      "noNeedUpdate",
                      retNoNeed
                    );
                }
              }
            );
        }
      }
    )
      .start();
  }

  private void installNext() {
    try {
      Gson gson = new Gson();
      String delayUpdatePreferences = prefs.getString(
        DELAY_CONDITION_PREFERENCES,
        "[]"
      );
      Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
      ArrayList<DelayCondition> delayConditionList = gson.fromJson(
        delayUpdatePreferences,
        type
      );
      if (delayConditionList != null && delayConditionList.size() != 0) {
        Log.i(CapacitorUpdater.TAG, "Update delayed to next backgrounding");
        return;
      }
      final BundleInfo current = this.implementation.getCurrentBundle();
      final BundleInfo next = this.implementation.getNextBundle();

      if (
        next != null &&
        !next.isErrorStatus() &&
        !next.getId().equals(current.getId())
      ) {
        // There is a next bundle waiting for activation
        Log.d(CapacitorUpdater.TAG, "Next bundle is: " + next.getVersionName());
        if (this.implementation.set(next) && this._reload()) {
          Log.i(
            CapacitorUpdater.TAG,
            "Updated to bundle: " + next.getVersionName()
          );
          this.implementation.setNextBundle(null);
        } else {
          Log.e(
            CapacitorUpdater.TAG,
            "Update to bundle: " + next.getVersionName() + " Failed!"
          );
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
      Log.i(CapacitorUpdater.TAG, "Built-in bundle is active. Nothing to do.");
      return;
    }
    Log.d(CapacitorUpdater.TAG, "Current bundle is: " + current);

    if (BundleStatus.SUCCESS != current.getStatus()) {
      Log.e(
        CapacitorUpdater.TAG,
        "notifyAppReady was not called, roll back current bundle: " +
        current.getId()
      );
      Log.i(
        CapacitorUpdater.TAG,
        "Did you forget to call 'notifyAppReady()' in your Capacitor App code?"
      );
      final JSObject ret = new JSObject();
      ret.put("bundle", current.toJSON());
      this.notifyListeners("updateFailed", ret);
      this.implementation.sendStats("update_fail", current.getVersionName());
      this.implementation.setError(current);
      this._reset(true);
      if (
        CapacitorUpdaterPlugin.this.autoDeleteFailed && !current.isBuiltin()
      ) {
        Log.i(
          CapacitorUpdater.TAG,
          "Deleting failing bundle: " + current.getVersionName()
        );
        try {
          final Boolean res =
            this.implementation.delete(current.getId(), false);
          if (res) {
            Log.i(
              CapacitorUpdater.TAG,
              "Failed bundle deleted: " + current.getVersionName()
            );
          }
        } catch (final IOException e) {
          Log.e(
            CapacitorUpdater.TAG,
            "Failed to delete failed bundle: " + current.getVersionName(),
            e
          );
        }
      }
    } else {
      Log.i(
        CapacitorUpdater.TAG,
        "notifyAppReady was called. This is fine: " + current.getId()
      );
    }
  }

  private class DeferredNotifyAppReadyCheck implements Runnable {

    @Override
    public void run() {
      try {
        Log.i(
          CapacitorUpdater.TAG,
          "Wait for " +
          CapacitorUpdaterPlugin.this.appReadyTimeout +
          "ms, then check for notifyAppReady"
        );
        Thread.sleep(CapacitorUpdaterPlugin.this.appReadyTimeout);
        CapacitorUpdaterPlugin.this.checkRevert();
        CapacitorUpdaterPlugin.this.appReadyCheck = null;
      } catch (final InterruptedException e) {
        Log.i(
          CapacitorUpdater.TAG,
          DeferredNotifyAppReadyCheck.class.getName() + " was interrupted."
        );
      }
    }
  }

  public void appMovedToForeground() {
    this._checkCancelDelay(true);
    if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled()) {
      this.backgroundDownload();
    }
    this.checkAppReady();
  }

  public void appMovedToBackground() {
    Log.i(CapacitorUpdater.TAG, "Checking for pending update");
    try {
      Gson gson = new Gson();
      String delayUpdatePreferences = prefs.getString(
        DELAY_CONDITION_PREFERENCES,
        "[]"
      );
      Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
      ArrayList<DelayCondition> delayConditionList = gson.fromJson(
        delayUpdatePreferences,
        type
      );
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
        backgroundTask =
          new Thread(
            new Runnable() {
              @Override
              public void run() {
                try {
                  Thread.sleep(timeout);
                  taskRunning = false;
                  _checkCancelDelay(false);
                  installNext();
                } catch (InterruptedException e) {
                  Log.i(
                    CapacitorUpdater.TAG,
                    "Background Task canceled, Activity resumed before timer completes"
                  );
                }
              }
            }
          );
        backgroundTask.start();
      } else {
        this._checkCancelDelay(false);
        this.installNext();
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Error during onActivityStopped", e);
    }
  }

  private boolean isMainActivity() {
    try {
      Context mContext = this.getContext();
      ActivityManager activityManager =
        (ActivityManager) mContext.getSystemService(Context.ACTIVITY_SERVICE);
      List<ActivityManager.AppTask> runningTasks =
        activityManager.getAppTasks();
      ActivityManager.RecentTaskInfo runningTask = runningTasks
        .get(0)
        .getTaskInfo();
      String className = runningTask.baseIntent.getComponent().getClassName();
      String runningActivity = runningTask.topActivity.getClassName();
      boolean isThisAppActivity = className.equals(runningActivity);
      return isThisAppActivity;
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, "Error getting Main Activity", e);
      return false;
    }
  }

  @Override
  public void onActivityStarted(@NonNull final Activity activity) {
    if (isPreviousMainActivity) {
      this.appMovedToForeground();
    }
    isPreviousMainActivity = true;
  }

  @Override
  public void onActivityStopped(@NonNull final Activity activity) {
    isPreviousMainActivity = isMainActivity();
    if (isPreviousMainActivity) {
      this.appMovedToBackground();
    }
  }

  @Override
  public void onActivityResumed(@NonNull final Activity activity) {
    if (backgroundTask != null && taskRunning) {
      backgroundTask.interrupt();
    }
    this.implementation.activity = activity;
    this.implementation.onResume();
  }

  @Override
  public void onActivityPaused(@NonNull final Activity activity) {
    this.implementation.activity = activity;
    this.implementation.onPause();
  }

  @Override
  public void onActivityCreated(
    @NonNull final Activity activity,
    @Nullable final Bundle savedInstanceState
  ) {
    this.implementation.activity = activity;
  }

  @Override
  public void onActivitySaveInstanceState(
    @NonNull final Activity activity,
    @NonNull final Bundle outState
  ) {
    this.implementation.activity = activity;
  }

  @Override
  public void onActivityDestroyed(@NonNull final Activity activity) {
    this.implementation.activity = activity;
  }
}
