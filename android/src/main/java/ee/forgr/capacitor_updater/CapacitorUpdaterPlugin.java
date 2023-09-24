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
import android.content.res.Resources;
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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Phaser;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.json.JSONException;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

  private static final String updateUrlDefault =
    "https://api.capgo.app/updates";
  private static final String statsUrlDefault = "https://api.capgo.app/stats";
  private static final String defaultPrivateKey =
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKCAQEA4pW9olT0FBXXivRCzd3xcImlWZrqkwcF2xTkX/FwXmj9eh9H\nkBLrsQmfsC+PJisRXIOGq6a0z3bsGq6jBpp3/Jr9jiaW5VuPGaKeMaZZBRvi/N5f\nIMG3hZXSOcy0IYg+E1Q7RkYO1xq5GLHseqG+PXvJsNe4R8R/Bmd/ngq0xh/cvcrH\nHpXwO0Aj9tfprlb+rHaVV79EkVRWYPidOLnK1n0EFHFJ1d/MyDIp10TEGm2xHpf/\nBrlb1an8wXEuzoC0DgYaczgTjovwR+ewSGhSHJliQdM0Qa3o1iN87DldWtydImMs\nPjJ3DUwpsjAMRe5X8Et4+udFW2ciYnQo9H0CkwIDAQABAoIBAQCtjlMV/4qBxAU4\nu0ZcWA9yywwraX0aJ3v1xrfzQYV322Wk4Ea5dbSxA5UcqCE29DA1M824t1Wxv/6z\npWbcTP9xLuresnJMtmgTE7umfiubvTONy2sENT20hgDkIwcq1CfwOEm61zjQzPhQ\nkSB5AmEsyR/BZEsUNc+ygR6AWOUFB7tj4yMc32LOTWSbE/znnF2BkmlmnQykomG1\n2oVqM3lUFP7+m8ux1O7scO6IMts+Z/eFXjWfxpbebUSvSIR83GXPQZ34S/c0ehOg\nyHdmCSOel1r3VvInMe+30j54Jr+Ml/7Ee6axiwyE2e/bd85MsK9sVdp0OtelXaqA\nOZZqWvN5AoGBAP2Hn3lSq+a8GsDH726mHJw60xM0LPbVJTYbXsmQkg1tl3NKJTMM\nQqz41+5uys+phEgLHI9gVJ0r+HaGHXnJ4zewlFjsudstb/0nfctUvTqnhEhfNo9I\ny4kufVKPRF3sMEeo7CDVJs4GNBLycEyIBy6Mbv0VcO7VaZqggRwu4no9AoGBAOTK\n6NWYs1BWlkua2wmxexGOzehNGedInp0wGr2l4FDayWjkZLqvB+nNXUQ63NdHlSs4\nWB2Z1kQXZxVaI2tPYexGUKXEo2uFob63uflbuE029ovDXIIPFTPtGNdNXwhHT5a+\nPhmy3sMc+s2BSNM5qaNmfxQxhdd6gRU6oikE+c0PAoGAMn3cKNFqIt27hkFLUgIL\nGKIuf1iYy9/PNWNmEUaVj88PpopRtkTu0nwMpROzmH/uNFriKTvKHjMvnItBO4wV\nkHW+VadvrFL0Rrqituf9d7z8/1zXBNo+juePVe3qc7oiM2NVA4Tv4YAixtM5wkQl\nCgQ15nlqsGYYTg9BJ1e/CxECgYEAjEYPzO2reuUrjr0p8F59ev1YJ0YmTJRMk0ks\nC/yIdGo/tGzbiU3JB0LfHPcN8Xu07GPGOpfYM7U5gXDbaG6qNgfCaHAQVdr/mQPi\nJQ1kCQtay8QCkscWk9iZM1//lP7LwDtxraXqSCwbZSYP9VlUNZeg8EuQqNU2EUL6\nqzWexmcCgYEA0prUGNBacraTYEknB1CsbP36UPWsqFWOvevlz+uEC5JPxPuW5ZHh\nSQN7xl6+PHyjPBM7ttwPKyhgLOVTb3K7ex/PXnudojMUK5fh7vYfChVTSlx2p6r0\nDi58PdD+node08cJH+ie0Yphp7m+D4+R9XD0v0nEvnu4BtAW6DrJasw=\n-----END RSA PRIVATE KEY-----\n";
  private static final String channelUrlDefault =
    "https://api.capgo.app/channel_self";

  private final String PLUGIN_VERSION = "5.2.33";
  private static final String DELAY_CONDITION_PREFERENCES = "";

  private SharedPreferences.Editor editor;
  private SharedPreferences prefs;
  protected CapacitorUpdater implementation;

  private Integer appReadyTimeout = 10000;
  private Integer counterActivityCreate = 0;
  private Boolean autoDeleteFailed = true;
  private Boolean autoDeletePrevious = true;
  private Boolean autoUpdate = false;
  private String updateUrl = "";
  private Version currentVersionNative;
  private Boolean resetWhenUpdate = true;
  private Thread backgroundTask;
  private Boolean taskRunning = false;

  private Boolean isPreviousMainActivity = true;

  private volatile Thread backgroundDownloadTask;
  private volatile Thread appReadyCheck;

  //  private static final CountDownLatch semaphoreReady = new CountDownLatch(1);
  private static final Phaser semaphoreReady = new Phaser(1);

  private Resources resources = Resources.getSystem();

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
          public void directUpdateFinish(final BundleInfo latest) {
            CapacitorUpdaterPlugin.this.directUpdateFinish(latest);
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
      this.implementation.versionBuild =
        this.getConfig().getString("version", pInfo.versionName);
      this.implementation.PLUGIN_VERSION = this.PLUGIN_VERSION;
      this.implementation.versionCode = Integer.toString(pInfo.versionCode);
      this.implementation.requestQueue =
        Volley.newRequestQueue(this.getContext());
      this.implementation.directUpdate =
        this.getConfig().getBoolean("directUpdate", false);
      this.currentVersionNative =
        new Version(this.getConfig().getString("version", pInfo.versionName));
    } catch (final PackageManager.NameNotFoundException e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.errorInstantiating), e);
      return;
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.errorGettingCurrentVersion),
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
      resources.getString(R.string.initForDevice, this.implementation.deviceID)
    );
    Log.i(
      CapacitorUpdater.TAG,
      resources.getString(R.string.versionNative, this.currentVersionNative.getOriginalString())
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
    //    application.registerActivityLifecycleCallbacks(this);
  }

  private void semaphoreWait(Number waitTime) {
    Log.i(CapacitorUpdater.TAG, "semaphoreWait " + waitTime);
    try {
      //        Log.i(CapacitorUpdater.TAG, "semaphoreReady count " + CapacitorUpdaterPlugin.this.semaphoreReady.getCount());
      CapacitorUpdaterPlugin.this.semaphoreReady.awaitAdvanceInterruptibly(
          CapacitorUpdaterPlugin.this.semaphoreReady.getPhase(),
          waitTime.longValue(),
          TimeUnit.SECONDS
        );
      //        Log.i(CapacitorUpdater.TAG, "semaphoreReady await " + res);
      Log.i(
        CapacitorUpdater.TAG,
        "semaphoreReady count " +
        CapacitorUpdaterPlugin.this.semaphoreReady.getPhase()
      );
    } catch (InterruptedException e) {
      Log.i(CapacitorUpdater.TAG, "semaphoreWait " + resources.getString(R.string.interruptedException));
      e.printStackTrace();
    } catch (TimeoutException e) {
      throw new RuntimeException(e);
    }
  }

  private void semaphoreUp() {
    Log.i(CapacitorUpdater.TAG, "semaphoreUp");
    CapacitorUpdaterPlugin.this.semaphoreReady.register();
  }

  private void semaphoreDown() {
    Log.i(CapacitorUpdater.TAG, "semaphoreDown");
    Log.i(
      CapacitorUpdater.TAG,
      "semaphoreDown count " +
      CapacitorUpdaterPlugin.this.semaphoreReady.getPhase()
    );
    CapacitorUpdaterPlugin.this.semaphoreReady.arriveAndDeregister();
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
      final Version previous = new Version(
        this.prefs.getString("LatestVersionNative", "")
      );
      try {
        if (
          !"".equals(previous.getOriginalString()) &&
          !this.currentVersionNative.getOriginalString()
            .equals(previous.getOriginalString())
        ) {
          Log.i(
            CapacitorUpdater.TAG,
            resources.getString(R.string.newNativeVersionDetected, this.currentVersionNative)
          );
          this.implementation.reset(true);
          final List<BundleInfo> installed = this.implementation.list();
          for (final BundleInfo bundle : installed) {
            try {
              Log.i(
                CapacitorUpdater.TAG,
                resources.getString(R.string.deletingPreviousBundle) + bundle.getId()
              );
              this.implementation.delete(bundle.getId());
            } catch (final Exception e) {
              Log.e(
                CapacitorUpdater.TAG,
                resources.getString(R.string.failedToDelete) + bundle.getId(),
                e
              );
            }
          }
        }
      } catch (final Exception e) {
        Log.e(
          CapacitorUpdater.TAG,
          resources.getString(R.string.couldNotDetermine),
          e
        );
      }
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.errorCalculating),
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
        final JSObject retDownloadComplete = new JSObject(
          ret,
          new String[] { "bundle" }
        );
        this.notifyListeners("downloadComplete", retDownloadComplete);
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotNotify), e);
    }
  }

  @PluginMethod
  public void getBuiltinVersion(final PluginCall call) {
    try {
      final JSObject ret = new JSObject();
      ret.put("version", this.implementation.versionBuild);
      call.resolve(ret);
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotDetermine), e);
      call.reject(resources.getString(R.string.couldNotGetVersion), e);
    }
  }

  @PluginMethod
  public void getDeviceId(final PluginCall call) {
    try {
      final JSObject ret = new JSObject();
      ret.put("deviceId", this.implementation.deviceID);
      call.resolve(ret);
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotGetDeviceId), e);
      call.reject(resources.getString(R.string.couldNotGetDeviceId), e);
    }
  }

  @PluginMethod
  public void setCustomId(final PluginCall call) {
    final String customId = call.getString("customId");
    if (customId == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.setCustomIdCalled));
      call.reject(resources.getString(R.string.setCustomIdCalled));
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotGetPluginVersion), e);
      call.reject(resources.getString(R.string.couldNotGetPluginVersion), e);
    }
  }

  @PluginMethod
  public void setChannel(final PluginCall call) {
    final String channel = call.getString("channel");
    final Boolean triggerAutoUpdate = call.getBoolean(
      "triggerAutoUpdate",
      false
    );

    if (channel == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.setChannelCalledWithoutChannel));
      call.reject(resources.getString(R.string.setChannelCalledWithoutChannel));
      return;
    }
    try {
      Log.i(
        CapacitorUpdater.TAG,
        resources.getString(R.string.setChannelTrigger, channel, triggerAutoUpdate.toString())
//        "setChannel " + channel + " triggerAutoUpdate: " + triggerAutoUpdate
      );
      startNewThread(() -> {
        CapacitorUpdaterPlugin.this.implementation.setChannel(
            channel,
            res -> {
              if (res.has("error")) {
                call.reject(res.getString("error"));
              } else {
                if (
                  CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() &&
                  triggerAutoUpdate
                ) {
                  Log.i(
                    CapacitorUpdater.TAG,
                    resources.getString(R.string.callingAutoUpdater)
                  );
                  backgroundDownload();
                }
                call.resolve(res);
              }
            }
          );
      });
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.failedToSetChannel) + channel, e);
      call.reject(resources.getString(R.string.failedToSetChannel) + channel, e);
    }
  }

  @PluginMethod
  public void getChannel(final PluginCall call) {
    try {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.getChannel));
      startNewThread(() -> {
        CapacitorUpdaterPlugin.this.implementation.getChannel(res -> {
            if (res.has("error")) {
              call.reject(res.getString("error"));
            } else {
              call.resolve(res);
            }
          });
      });
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.failedToGetChannel), e);
      call.reject(resources.getString(R.string.failedToGetChannel), e);
    }
  }

  @PluginMethod
  public void download(final PluginCall call) {
    final String url = call.getString("url");
    final String version = call.getString("version");
    final String sessionKey = call.getString("sessionKey", "");
    final String checksum = call.getString("checksum", "");
    if (url == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.downloadCalledWithoutURL));
      call.reject(resources.getString(R.string.downloadCalledWithoutURL));
      return;
    }
    if (version == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.downloadCalledWithoutVersion));
      call.reject(resources.getString(R.string.downloadCalledWithoutVersion));
      return;
    }
    try {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.downloading, url));
      startNewThread(() -> {
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
          Log.e(CapacitorUpdater.TAG, resources.getString(R.string.failedToDownload, url), e);
          call.reject(resources.getString(R.string.failedToDownload, url), e);
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
      });
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.failedToDownload, url), e);
      call.reject(resources.getString(R.string.failedToDownload, url), e);
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

  protected boolean _reload() {
    final String path = this.implementation.getCurrentBundlePath();
    this.semaphoreUp();
    Log.i(CapacitorUpdater.TAG, resources.getString(R.string.reloading, path));
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
        Log.e(CapacitorUpdater.TAG, resources.getString(R.string.reloadFailed));
        call.reject(resources.getString(R.string.reloadFailed));
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.reloadFailed), e);
      call.reject(resources.getString(R.string.couldNotReload), e);
    }
  }

  @PluginMethod
  public void next(final PluginCall call) {
    final String id = call.getString("id");
    if (id == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.nextCalledWithoutId));
      call.reject(resources.getString(R.string.nextCalledWithoutId));
      return;
    }
    try {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.settingNextActiveId, id));
      if (!this.implementation.setNextBundle(id)) {
        Log.e(
          CapacitorUpdater.TAG,
          resources.getString(R.string.setNextIdFailed, id)
        );
        call.reject(resources.getString(R.string.setNextIdFailed, id));
      } else {
        call.resolve(this.implementation.getBundleInfo(id).toJSON());
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotSetNextId, id), e);
      call.reject(resources.getString(R.string.couldNotSetNextId, id), e);
    }
  }

  @PluginMethod
  public void set(final PluginCall call) {
    final String id = call.getString("id");
    if (id == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.setCalledWithoutId));
      call.reject(resources.getString(R.string.setCalledWithoutId));
      return;
    }
    try {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.settingActiveBundle, id));
      if (!this.implementation.set(id)) {
        Log.i(CapacitorUpdater.TAG, resources.getString(R.string.noSuchBundle, id));
        call.reject(resources.getString(R.string.updateFailedId, id));
      } else {
        Log.i(CapacitorUpdater.TAG, resources.getString(R.string.bundleSuccessfullySetTo, id));
        this.reload(call);
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotSetId, id), e);
      call.reject(resources.getString(R.string.couldNotSetId, id), e);
    }
  }

  @PluginMethod
  public void delete(final PluginCall call) {
    final String id = call.getString("id");
    if (id == null) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.missingId));
      call.reject(resources.getString(R.string.missingId));
      return;
    }
    Log.i(CapacitorUpdater.TAG, resources.getString(R.string.deletingId, id));
    try {
      final Boolean res = this.implementation.delete(id);
      if (res) {
        call.resolve();
      } else {
        Log.e(
          CapacitorUpdater.TAG,
          resources.getString(R.string.deleteFailed, id)
        );
        call.reject(resources.getString(R.string.deleteFailed, id));
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotDeleteId, id), e);
      call.reject(resources.getString(R.string.couldNotDeleteId, id), e);
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotListBundles), e);
      call.reject(resources.getString(R.string.couldNotListBundles), e);
    }
  }

  @PluginMethod
  public void getLatest(final PluginCall call) {
    startNewThread(() -> {
      CapacitorUpdaterPlugin.this.implementation.getLatest(
          CapacitorUpdaterPlugin.this.updateUrl,
          res -> {
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
          }
        );
    });
  }

  private boolean _reset(final Boolean toLastSuccessful) {
    final BundleInfo fallback = this.implementation.getFallbackBundle();
    this.implementation.reset();

    if (toLastSuccessful && !fallback.isBuiltin()) {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.resettingTo, fallback));
      return this.implementation.set(fallback) && this._reload();
    }

    Log.i(CapacitorUpdater.TAG, resources.getString(R.string.resettingToNative));
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.resetFailed));
      call.reject(resources.getString(R.string.resetFailed));
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.resetFailed), e);
      call.reject(resources.getString(R.string.resetFailed), e);
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotGetCurrentBundle), e);
      call.reject(resources.getString(R.string.couldNotGetCurrentBundle), e);
    }
  }

  @PluginMethod
  public void notifyAppReady(final PluginCall call) {
    try {
      final BundleInfo bundle = this.implementation.getCurrentBundle();
      this.implementation.setSuccess(bundle, this.autoDeletePrevious);
      Log.i(
        CapacitorUpdater.TAG,
        resources.getString(R.string.currentBundleSuccess) +
        bundle
      );
      Log.i(CapacitorUpdater.TAG, "semaphoreReady countDown");
      this.semaphoreDown();
      Log.i(CapacitorUpdater.TAG, "semaphoreReady countDown done");
      final JSObject ret = new JSObject();
      ret.put("bundle", bundle.toJSON());
      call.resolve(ret);
      call.resolve();
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.failedToNotifyState),
        e
      );
      call.reject(resources.getString(R.string.failedToCommit), e);
    }
  }

  @PluginMethod
  public void setMultiDelay(final PluginCall call) {
    try {
      final Object delayConditions = call.getData().opt("delayConditions");
      if (delayConditions == null) {
        Log.e(
          CapacitorUpdater.TAG,
          resources.getString(R.string.setMultiDelayCalled)
        );
        call.reject(resources.getString(R.string.setMultiDelayCalled));
        return;
      }
      if (_setMultiDelay(delayConditions.toString())) {
        call.resolve();
      } else {
        call.reject(resources.getString(R.string.failedToDelayUpdateOnly));
      }
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.failedToDelayUpdate),
        e
      );
      call.reject(resources.getString(R.string.failedToDelayUpdateOnly), e);
    }
  }

  private Boolean _setMultiDelay(String delayConditions) {
    try {
      this.editor.putString(DELAY_CONDITION_PREFERENCES, delayConditions);
      this.editor.commit();
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.delayUpdateSaved));
      return true;
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.failedToDelayUpdate2),
        e
      );
      return false;
    }
  }

  private boolean _cancelDelay(String source) {
    try {
      this.editor.remove(DELAY_CONDITION_PREFERENCES);
      this.editor.commit();
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.allDelaysCancelledFrom, source));
      return true;
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.failedToCancelUpdateDelay), e);
      return false;
    }
  }

  @PluginMethod
  public void cancelDelay(final PluginCall call) {
    if (this._cancelDelay("JS")) {
      call.resolve();
    } else {
      call.reject(resources.getString(R.string.failedToCancel));
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
        resources.getString(R.string.autoUpdateDisabled)
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.couldNotGetAutoUpdateStatus), e);
      call.reject(resources.getString(R.string.couldNotGetAutoUpdateStatus), e);
    }
  }

  private void checkAppReady() {
    try {
      if (this.appReadyCheck != null) {
        this.appReadyCheck.interrupt();
      }
      this.appReadyCheck = startNewThread(new DeferredNotifyAppReadyCheck());
    } catch (final Exception e) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.failedToStart, DeferredNotifyAppReadyCheck.class.getName()),
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

  private void endBackGroundTaskWithNotif(
    String msg,
    String latestVersionName,
    BundleInfo current,
    Boolean error
  ) {
    if (error) {
      Log.i(CapacitorUpdater.TAG, "endBackGroundTaskWithNotif error" + error);
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
      ? resources.getString(R.string.updateWillOccurNow)
      : resources.getString(R.string.updateWillOccurNext);
    return startNewThread(() -> {
      Log.i(
        CapacitorUpdater.TAG,
        resources.getString(R.string.checkForUpdateVia, CapacitorUpdaterPlugin.this.updateUrl)
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
                  resources.getString(R.string.apiMessage, res.get("message"))
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
                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                    res.getString("message"),
                    current.getVersionName(),
                    current,
                    true
                  );
                return;
              }

              if (
                !res.has("url") ||
                !CapacitorUpdaterPlugin.this.isValidURL(res.getString("url"))
              ) {
                Log.e(CapacitorUpdater.TAG, resources.getString(R.string.noUrlOrWrongFormat));
                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                    resources.getString(R.string.noUrlOrWrongFormat),
                    current.getVersionName(),
                    current,
                    true
                  );
                return;
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
                  final JSObject ret = new JSObject();
                  ret.put("bundle", latest.toJSON());
                  if (latest.isErrorStatus()) {
                    Log.e(
                      CapacitorUpdater.TAG,
                      resources.getString(R.string.latestBundleAlreadyExists)
                    );
                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                        resources.getString(R.string.latestBundleAlreadyExists),
                        latestVersionName,
                        current,
                        true
                      );
                    return;
                  }
                  if (latest.isDownloaded()) {
                    Log.i(
                      CapacitorUpdater.TAG,
                      resources.getString(R.string.downloadNotRequired) +
                      messageUpdate
                    );
                    if (
                      CapacitorUpdaterPlugin.this.implementation.directUpdate
                    ) {
                      CapacitorUpdaterPlugin.this.implementation.set(latest);
                      CapacitorUpdaterPlugin.this._reload();
                      CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                          resources.getString(R.string.updateInstalled),
                          latestVersionName,
                          latest,
                          false
                        );
                    } else {
                      CapacitorUpdaterPlugin.this.notifyListeners(
                          "updateAvailable",
                          ret
                        );
                      CapacitorUpdaterPlugin.this.implementation.setNextBundle(
                          latest.getId()
                        );
                      CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                          resources.getString(R.string.updateDownloaded),
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
                      resources.getString(R.string.latestBundleAlreadyExistsOverwrite)
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
                          resources.getString(R.string.failedBundleDeleted) + latest.getVersionName()
                        );
                      }
                    } catch (final IOException e) {
                      Log.e(
                        CapacitorUpdater.TAG,
                        resources.getString(R.string.failedToDeleteFailed, latest.getVersionName()),
                        e
                      );
                    }
                  }
                }
                startNewThread(() -> {
                  try {
                    Log.i(
                      CapacitorUpdater.TAG,
                      resources.getString(R.string.newBundleFound, latestVersionName, current.getVersionName(), messageUpdate)
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
                    Log.e(CapacitorUpdater.TAG, resources.getString(R.string.errorDownloadingFile), e);
                    CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                        resources.getString(R.string.errorDownloadingFile),
                        latestVersionName,
                        CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                        true
                      );
                  }
                });
              } else {
                Log.i(
                  CapacitorUpdater.TAG,
                  resources.getString(R.string.noNeedToUpdateWithId, current.getId())
                );
                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                    resources.getString(R.string.noNeedToUpdate),
                    latestVersionName,
                    current,
                    false
                  );
              }
            } catch (final JSONException e) {
              Log.e(CapacitorUpdater.TAG, resources.getString(R.string.errorParsingJson), e);
              CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                  resources.getString(R.string.errorParsingJson),
                  current.getVersionName(),
                  current,
                  true
                );
            }
          }
        );
    });
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
        Log.i(CapacitorUpdater.TAG, resources.getString(R.string.updateDelayed));
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
        Log.d(CapacitorUpdater.TAG, resources.getString(R.string.nextBundleIs, next.getVersionName()));
        if (this.implementation.set(next) && this._reload()) {
          Log.i(
            CapacitorUpdater.TAG,
            resources.getString(R.string.updateToBundle, next.getVersionName())
          );
          this.implementation.setNextBundle(null);
        } else {
          Log.e(
            CapacitorUpdater.TAG,
            resources.getString(R.string.updateToBundleFailed, next.getVersionName())
          );
        }
      }
    } catch (final Exception e) {
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.errorDuring), e);
    }
  }

  private void checkRevert() {
    // Automatically roll back to fallback version if notifyAppReady has not been called yet
    final BundleInfo current = this.implementation.getCurrentBundle();

    if (current.isBuiltin()) {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.builtInBundleActive));
      return;
    }
    Log.d(CapacitorUpdater.TAG, "Current bundle is: " + current);

    if (BundleStatus.SUCCESS != current.getStatus()) {
      Log.e(
        CapacitorUpdater.TAG,
        resources.getString(R.string.notifyAppReadyCalled,  current.getId())
      );
      Log.i(
        CapacitorUpdater.TAG,
        resources.getString(R.string.didYouForgetToCall)
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
          resources.getString(R.string.deletingFailingBundle, current.getVersionName())
        );
        try {
          final Boolean res =
            this.implementation.delete(current.getId(), false);
          if (res) {
            Log.i(
              CapacitorUpdater.TAG,
              resources.getString(R.string.failedBundleDeletedWithId, current.getVersionName())
            );
          }
        } catch (final IOException e) {
          Log.e(
            CapacitorUpdater.TAG,
            resources.getString(R.string.failedToDeleteFailedBundle, current.getVersionName()) ,
            e
          );
        }
      }
    } else {
      Log.i(
        CapacitorUpdater.TAG,
        resources.getString(R.string.thisIsFine, current.getId())
      );
    }
  }

  private class DeferredNotifyAppReadyCheck implements Runnable {

    @Override
    public void run() {
      try {
        Log.i(
          CapacitorUpdater.TAG,
          resources.getString(R.string.waitForThenCheckFor, CapacitorUpdaterPlugin.this.appReadyTimeout)
        );
        Thread.sleep(CapacitorUpdaterPlugin.this.appReadyTimeout);
        CapacitorUpdaterPlugin.this.checkRevert();
        CapacitorUpdaterPlugin.this.appReadyCheck = null;
      } catch (final InterruptedException e) {
        Log.i(
          CapacitorUpdater.TAG,
           resources.getString(R.string.wasInterrupted, DeferredNotifyAppReadyCheck.class.getName())
        );
      }
    }
  }

  public void appMovedToForeground() {
    final BundleInfo current =
      CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
    CapacitorUpdaterPlugin.this.implementation.sendStats(
        "app_moved_to_foreground",
        current.getVersionName()
      );
    this._checkCancelDelay(true);
    if (
      CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() &&
      this.backgroundDownloadTask == null
    ) {
      this.backgroundDownloadTask = this.backgroundDownload();
    } else {
      Log.i(CapacitorUpdater.TAG, resources.getString(R.string.autoUpdateDisabledOnly));
      this.sendReadyToJs(current, "disabled");
    }
    this.checkAppReady();
  }

  public void appMovedToBackground() {
    final BundleInfo current =
      CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
    CapacitorUpdaterPlugin.this.implementation.sendStats(
        "app_moved_to_background",
        current.getVersionName()
      );
    Log.i(CapacitorUpdater.TAG, resources.getString(R.string.checkingForPendingUpdate));
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
          startNewThread(
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
      Log.e(CapacitorUpdater.TAG, resources.getString(R.string.errorDuring), e);
    }
  }

  private boolean isMainActivity() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
      return false;
    }
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
    } catch (NullPointerException e) {
      return false;
    }
  }

  private void appKilled() {
    Log.d(CapacitorUpdater.TAG, resources.getString(R.string.allActivityDestroyed));
    this._checkCancelDelay(true);
  }

  @Override
  public void handleOnStart() {
    this.counterActivityCreate++;
    //  @Override
    //  public void onActivityStarted(@NonNull final Activity activity) {
    if (isPreviousMainActivity) {
      this.appMovedToForeground();
    }
    Log.i(
      CapacitorUpdater.TAG,
      "onActivityStarted " + getActivity().getClass().getName()
    );
    isPreviousMainActivity = true;
  }

  @Override
  public void handleOnStop() {
    //  @Override
    //  public void onActivityStopped(@NonNull final Activity activity) {
    isPreviousMainActivity = isMainActivity();
    if (isPreviousMainActivity) {
      this.appMovedToBackground();
    }
  }

  @Override
  public void handleOnResume() {
    //  @Override
    //  public void onActivityResumed(@NonNull final Activity activity) {
    if (backgroundTask != null && taskRunning) {
      backgroundTask.interrupt();
    }
    this.implementation.activity = getActivity();
    this.implementation.onResume();
  }

  @Override
  public void handleOnPause() {
    //  @Override
    //  public void onActivityPaused(@NonNull final Activity activity) {
    this.implementation.activity = getActivity();
    this.implementation.onPause();
  }

  //    @Override
  //    public void handleOnDestroy() {
  //  @Override
  //  public void onActivityCreated(
  //          @NonNull final Activity activity,
  //          @Nullable final Bundle savedInstanceState
  //  ) {
  //    this.implementation.activity = activity;
  //    this.counterActivityCreate++;
  //  }
  //
  //  @Override
  //  public void onActivitySaveInstanceState(
  //          @NonNull final Activity activity,
  //          @NonNull final Bundle outState
  //  ) {
  //    this.implementation.activity = activity;
  //  }

  @Override
  public void handleOnDestroy() {
    //  @Override
    //  public void onActivityDestroyed(@NonNull final Activity activity) {
    Log.i(
      CapacitorUpdater.TAG,
      "onActivityDestroyed " + getActivity().getClass().getName()
    );
    this.implementation.activity = getActivity();
    counterActivityCreate--;
    if (counterActivityCreate == 0) {
      this.appKilled();
    }
  }
}
