/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.plugin.WebView;
import com.google.android.gms.tasks.Task;
// Play Store In-App Updates
import com.google.android.play.core.appupdate.AppUpdateInfo;
import com.google.android.play.core.appupdate.AppUpdateManager;
import com.google.android.play.core.appupdate.AppUpdateManagerFactory;
import com.google.android.play.core.appupdate.AppUpdateOptions;
import com.google.android.play.core.install.InstallState;
import com.google.android.play.core.install.InstallStateUpdatedListener;
import com.google.android.play.core.install.model.AppUpdateType;
import com.google.android.play.core.install.model.InstallStatus;
import com.google.android.play.core.install.model.UpdateAvailability;
import io.github.g00fy2.versioncompare.Version;
import java.io.IOException;
import java.net.MalformedURLException;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.Timer;
import java.util.TimerTask;
import java.util.UUID;
import java.util.concurrent.Phaser;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;
// Removed OkHttpClient and Protocol imports - using shared client in DownloadService instead
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

    private final Logger logger = new Logger("CapgoUpdater");

    private static final String updateUrlDefault = "https://plugin.capgo.app/updates";
    private static final String statsUrlDefault = "https://plugin.capgo.app/stats";
    private static final String channelUrlDefault = "https://plugin.capgo.app/channel_self";
    private static final String KEEP_URL_FLAG_KEY = "__capgo_keep_url_path_after_reload";
    private static final String CUSTOM_ID_PREF_KEY = "CapacitorUpdater.customId";
    private static final String UPDATE_URL_PREF_KEY = "CapacitorUpdater.updateUrl";
    private static final String STATS_URL_PREF_KEY = "CapacitorUpdater.statsUrl";
    private static final String CHANNEL_URL_PREF_KEY = "CapacitorUpdater.channelUrl";
    private static final String DEFAULT_CHANNEL_PREF_KEY = "CapacitorUpdater.defaultChannel";
    private static final String[] BREAKING_EVENT_NAMES = { "breakingAvailable", "majorAvailable" };
    private static final String LAST_FAILED_BUNDLE_PREF_KEY = "CapacitorUpdater.lastFailedBundle";

    private final String pluginVersion = "6.40.0";
    private static final String DELAY_CONDITION_PREFERENCES = "";

    private SharedPreferences.Editor editor;
    private SharedPreferences prefs;
    protected CapgoUpdater implementation;
    private Boolean persistCustomId = false;
    private Boolean persistModifyUrl = false;

    private Integer appReadyTimeout = 10000;
    private Integer periodCheckDelay = 0;
    private Boolean autoDeleteFailed = true;
    private Boolean autoDeletePrevious = true;
    private Boolean autoUpdate = false;
    private String updateUrl = "";
    private Version currentVersionNative;
    private String currentBuildVersion;
    private Thread backgroundTask;
    private Boolean taskRunning = false;
    private Boolean keepUrlPathAfterReload = false;
    private Boolean autoSplashscreen = false;
    private Boolean autoSplashscreenLoader = false;
    private Integer autoSplashscreenTimeout = 10000;
    private Boolean autoSplashscreenTimedOut = false;
    private String directUpdateMode = "false";
    private Boolean wasRecentlyInstalledOrUpdated = false;
    private Boolean onLaunchDirectUpdateUsed = false;
    Boolean shakeMenuEnabled = false;
    private Boolean allowManualBundleError = false;
    private Boolean allowSetDefaultChannel = true;

    private Boolean isPreviousMainActivity = true;

    private volatile Thread backgroundDownloadTask;
    private volatile Thread appReadyCheck;

    //  private static final CountDownLatch semaphoreReady = new CountDownLatch(1);
    private static final Phaser semaphoreReady = new Phaser(1);

    // Lock to ensure cleanup completes before downloads start
    private final Object cleanupLock = new Object();
    private volatile boolean cleanupComplete = false;
    private volatile Thread cleanupThread = null;

    private int lastNotifiedStatPercent = 0;

    private DelayUpdateUtils delayUpdateUtils;

    private ShakeMenu shakeMenu;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private FrameLayout splashscreenLoaderOverlay;
    private Runnable splashscreenTimeoutRunnable;

    // Play Store In-App Updates
    private AppUpdateManager appUpdateManager;
    private AppUpdateInfo cachedAppUpdateInfo;
    private static final int APP_UPDATE_REQUEST_CODE = 9001;
    private InstallStateUpdatedListener installStateUpdatedListener;

    private void notifyBreakingEvents(final String version) {
        if (version == null || version.isEmpty()) {
            return;
        }
        for (final String eventName : BREAKING_EVENT_NAMES) {
            final JSObject payload = new JSObject();
            payload.put("version", version);
            CapacitorUpdaterPlugin.this.notifyListeners(eventName, payload);
        }
    }

    private JSObject mapToJSObject(Map<String, Object> map) {
        JSObject jsObject = new JSObject();
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            jsObject.put(entry.getKey(), entry.getValue());
        }
        return jsObject;
    }

    private void persistLastFailedBundle(BundleInfo bundle) {
        if (this.prefs == null) {
            return;
        }
        final SharedPreferences.Editor localEditor = this.prefs.edit();
        if (bundle == null) {
            localEditor.remove(LAST_FAILED_BUNDLE_PREF_KEY);
        } else {
            final JSONObject json = new JSONObject(bundle.toJSONMap());
            localEditor.putString(LAST_FAILED_BUNDLE_PREF_KEY, json.toString());
        }
        localEditor.apply();
    }

    private BundleInfo readLastFailedBundle() {
        if (this.prefs == null) {
            return null;
        }
        final String raw = this.prefs.getString(LAST_FAILED_BUNDLE_PREF_KEY, null);
        if (raw == null || raw.trim().isEmpty()) {
            return null;
        }
        try {
            return BundleInfo.fromJSON(raw);
        } catch (final JSONException e) {
            logger.error("Failed to parse failed bundle info: " + e.getMessage());
            this.persistLastFailedBundle(null);
            return null;
        }
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
        this.prefs = this.getContext().getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Activity.MODE_PRIVATE);
        this.editor = this.prefs.edit();

        try {
            this.implementation = new CapgoUpdater(logger) {
                @Override
                public void notifyDownload(final String id, final int percent) {
                    activity.runOnUiThread(() -> {
                        CapacitorUpdaterPlugin.this.notifyDownload(id, percent);
                    });
                }

                @Override
                public void directUpdateFinish(final BundleInfo latest) {
                    activity.runOnUiThread(() -> {
                        CapacitorUpdaterPlugin.this.directUpdateFinish(latest);
                    });
                }

                @Override
                public void notifyListeners(final String id, final Map<String, Object> res) {
                    activity.runOnUiThread(() -> {
                        CapacitorUpdaterPlugin.this.notifyListeners(id, CapacitorUpdaterPlugin.this.mapToJSObject(res));
                    });
                }
            };
            final PackageInfo pInfo = this.getContext().getPackageManager().getPackageInfo(this.getContext().getPackageName(), 0);
            this.implementation.activity = this.getActivity();
            this.implementation.versionBuild = this.getConfig().getString("version", pInfo.versionName);
            this.implementation.CAP_SERVER_PATH = WebView.CAP_SERVER_PATH;
            this.implementation.pluginVersion = this.pluginVersion;
            this.implementation.versionCode = Integer.toString(pInfo.versionCode);
            // Removed unused OkHttpClient creation - using shared client in DownloadService instead
            // Handle directUpdate configuration - support string values and backward compatibility
            String directUpdateConfig = this.getConfig().getString("directUpdate", null);
            if (directUpdateConfig != null) {
                // Handle backward compatibility for boolean true
                if (directUpdateConfig.equals("true")) {
                    this.directUpdateMode = "always";
                    this.implementation.directUpdate = true;
                } else {
                    this.directUpdateMode = directUpdateConfig;
                    this.implementation.directUpdate =
                        directUpdateConfig.equals("always") ||
                        directUpdateConfig.equals("atInstall") ||
                        directUpdateConfig.equals("onLaunch");
                    // Validate directUpdate value
                    if (
                        !directUpdateConfig.equals("false") &&
                        !directUpdateConfig.equals("always") &&
                        !directUpdateConfig.equals("atInstall") &&
                        !directUpdateConfig.equals("onLaunch")
                    ) {
                        logger.error(
                            "Invalid directUpdate value: \"" +
                                directUpdateConfig +
                                "\". Supported values are: \"false\", \"true\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\"."
                        );
                        this.directUpdateMode = "false";
                        this.implementation.directUpdate = false;
                    }
                }
            } else {
                Boolean directUpdateBool = this.getConfig().getBoolean("directUpdate", false);
                if (directUpdateBool) {
                    this.directUpdateMode = "always"; // backward compatibility: true = always
                    this.implementation.directUpdate = true;
                } else {
                    this.directUpdateMode = "false";
                    this.implementation.directUpdate = false;
                }
            }
            this.currentVersionNative = new Version(this.getConfig().getString("version", pInfo.versionName));
            this.currentBuildVersion = Integer.toString(pInfo.versionCode);
            this.delayUpdateUtils = new DelayUpdateUtils(this.prefs, this.editor, this.currentVersionNative, logger);
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
        CryptoCipher.setLogger(logger);
        DownloadService.setLogger(logger);
        DownloadWorkerManager.setLogger(logger);

        final CapConfig config = CapConfig.loadDefault(this.getActivity());
        this.implementation.appId = InternalUtils.getPackageName(getContext().getPackageManager(), getContext().getPackageName());
        this.implementation.appId = config.getString("appId", this.implementation.appId);
        this.implementation.appId = this.getConfig().getString("appId", this.implementation.appId);
        if (this.implementation.appId == null || this.implementation.appId.isEmpty()) {
            // crash the app on purpose it should not happen
            throw new RuntimeException(
                "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config"
            );
        }
        logger.info("appId: " + implementation.appId);

        this.persistCustomId = this.getConfig().getBoolean("persistCustomId", false);
        this.persistModifyUrl = this.getConfig().getBoolean("persistModifyUrl", false);
        this.allowSetDefaultChannel = this.getConfig().getBoolean("allowSetDefaultChannel", true);
        this.implementation.setPublicKey(this.getConfig().getString("publicKey", ""));
        // Log public key prefix if encryption is enabled
        String keyId = this.implementation.getKeyId();
        if (keyId != null && !keyId.isEmpty()) {
            logger.info("Public key prefix: " + keyId);
        }
        this.implementation.statsUrl = this.getConfig().getString("statsUrl", statsUrlDefault);
        this.implementation.channelUrl = this.getConfig().getString("channelUrl", channelUrlDefault);
        if (Boolean.TRUE.equals(this.persistModifyUrl)) {
            if (this.prefs.contains(STATS_URL_PREF_KEY)) {
                final String storedStatsUrl = this.prefs.getString(STATS_URL_PREF_KEY, this.implementation.statsUrl);
                if (storedStatsUrl != null) {
                    this.implementation.statsUrl = storedStatsUrl;
                    logger.info("Loaded persisted statsUrl");
                }
            }
            if (this.prefs.contains(CHANNEL_URL_PREF_KEY)) {
                final String storedChannelUrl = this.prefs.getString(CHANNEL_URL_PREF_KEY, this.implementation.channelUrl);
                if (storedChannelUrl != null) {
                    this.implementation.channelUrl = storedChannelUrl;
                    logger.info("Loaded persisted channelUrl");
                }
            }
        }

        // Load defaultChannel: first try from persistent storage (set via setChannel), then fall back to config
        if (this.prefs.contains(DEFAULT_CHANNEL_PREF_KEY)) {
            final String storedDefaultChannel = this.prefs.getString(DEFAULT_CHANNEL_PREF_KEY, "");
            if (storedDefaultChannel != null && !storedDefaultChannel.isEmpty()) {
                this.implementation.defaultChannel = storedDefaultChannel;
                logger.info("Loaded persisted defaultChannel from setChannel()");
            } else {
                this.implementation.defaultChannel = this.getConfig().getString("defaultChannel", "");
            }
        } else {
            this.implementation.defaultChannel = this.getConfig().getString("defaultChannel", "");
        }

        int userValue = this.getConfig().getInt("periodCheckDelay", 0);

        if (userValue >= 0 && userValue <= 600) {
            this.periodCheckDelay = 600 * 1000;
        } else if (userValue > 600) {
            this.periodCheckDelay = userValue * 1000;
        }

        this.implementation.documentsDir = this.getContext().getFilesDir();
        this.implementation.prefs = this.prefs;
        this.implementation.editor = this.editor;
        this.implementation.versionOs = Build.VERSION.RELEASE;
        // Use DeviceIdHelper to get or create device ID that persists across reinstalls
        this.implementation.deviceID = DeviceIdHelper.getOrCreateDeviceId(this.getContext(), this.prefs);

        // Update User-Agent for shared OkHttpClient with OS version
        DownloadService.updateUserAgent(this.implementation.appId, this.pluginVersion, this.implementation.versionOs);

        if (Boolean.TRUE.equals(this.persistCustomId)) {
            final String storedCustomId = this.prefs.getString(CUSTOM_ID_PREF_KEY, "");
            if (storedCustomId != null && !storedCustomId.isEmpty()) {
                this.implementation.customId = storedCustomId;
                logger.info("Loaded persisted customId");
            }
        }
        logger.info("init for device " + this.implementation.deviceID);
        logger.info("version native " + this.currentVersionNative.getOriginalString());
        this.autoDeleteFailed = this.getConfig().getBoolean("autoDeleteFailed", true);
        this.autoDeletePrevious = this.getConfig().getBoolean("autoDeletePrevious", true);
        this.updateUrl = this.getConfig().getString("updateUrl", updateUrlDefault);
        if (Boolean.TRUE.equals(this.persistModifyUrl)) {
            if (this.prefs.contains(UPDATE_URL_PREF_KEY)) {
                final String storedUpdateUrl = this.prefs.getString(UPDATE_URL_PREF_KEY, this.updateUrl);
                if (storedUpdateUrl != null) {
                    this.updateUrl = storedUpdateUrl;
                    logger.info("Loaded persisted updateUrl");
                }
            }
        }
        this.autoUpdate = this.getConfig().getBoolean("autoUpdate", true);
        this.appReadyTimeout = Math.max(1000, this.getConfig().getInt("appReadyTimeout", 10000)); // Minimum 1 second
        this.keepUrlPathAfterReload = this.getConfig().getBoolean("keepUrlPathAfterReload", false);
        this.syncKeepUrlPathFlag(this.keepUrlPathAfterReload);
        this.allowManualBundleError = this.getConfig().getBoolean("allowManualBundleError", false);
        this.autoSplashscreen = this.getConfig().getBoolean("autoSplashscreen", false);
        this.autoSplashscreenLoader = this.getConfig().getBoolean("autoSplashscreenLoader", false);
        int splashscreenTimeoutValue = this.getConfig().getInt("autoSplashscreenTimeout", 10000);
        this.autoSplashscreenTimeout = Math.max(0, splashscreenTimeoutValue);
        this.implementation.timeout = this.getConfig().getInt("responseTimeout", 20) * 1000;
        this.shakeMenuEnabled = this.getConfig().getBoolean("shakeMenu", false);
        boolean resetWhenUpdate = this.getConfig().getBoolean("resetWhenUpdate", true);

        // Check if app was recently installed/updated BEFORE cleanupObsoleteVersions updates LatestVersionNative
        this.wasRecentlyInstalledOrUpdated = this.checkIfRecentlyInstalledOrUpdated();

        this.implementation.autoReset();
        if (resetWhenUpdate) {
            this.cleanupObsoleteVersions();
        }

        // Check for 'kill' delay condition on app launch
        // This handles cases where the app was killed by the system (onDestroy is not reliable)
        this.delayUpdateUtils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.KILLED);

        this.checkForUpdateAfterDelay();
    }

    private void semaphoreWait(Number waitTime) {
        try {
            semaphoreReady.awaitAdvanceInterruptibly(semaphoreReady.getPhase(), waitTime.longValue(), TimeUnit.SECONDS);
            logger.info("semaphoreReady count " + semaphoreReady.getPhase());
        } catch (InterruptedException e) {
            logger.info("semaphoreWait InterruptedException");
            Thread.currentThread().interrupt(); // Restore interrupted status
        } catch (TimeoutException e) {
            logger.error("Semaphore timeout: " + e.getMessage());
            // Don't throw runtime exception, just log and continue
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
        sendReadyToJs(current, msg, false);
    }

    private void sendReadyToJs(final BundleInfo current, final String msg, final boolean isDirectUpdate) {
        logger.info("sendReadyToJs: " + msg);
        final JSObject ret = new JSObject();
        ret.put("bundle", mapToJSObject(current.toJSONMap()));
        ret.put("status", msg);

        // No need to wait for semaphore anymore since _reload() has already waited
        this.notifyListeners("appReady", ret, true);

        // Auto hide splashscreen if enabled
        // We show it on background when conditions are met, so we should hide it on foreground regardless of update outcome
        if (this.autoSplashscreen) {
            this.hideSplashscreen();
        }
    }

    private void hideSplashscreen() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            hideSplashscreenInternal();
        } else {
            this.mainHandler.post(this::hideSplashscreenInternal);
        }
    }

    private void hideSplashscreenInternal() {
        cancelSplashscreenTimeout();
        removeSplashscreenLoader();

        try {
            if (getBridge() == null) {
                logger.warn("Bridge not ready for hiding splashscreen with autoSplashscreen");
                return;
            }

            // Try to call the SplashScreen plugin directly through the bridge
            PluginHandle splashScreenPlugin = getBridge().getPlugin("SplashScreen");
            if (splashScreenPlugin != null) {
                try {
                    // Create a plugin call for the hide method using reflection to access private msgHandler
                    JSObject options = new JSObject();
                    java.lang.reflect.Field msgHandlerField = getBridge().getClass().getDeclaredField("msgHandler");
                    msgHandlerField.setAccessible(true);
                    Object msgHandler = msgHandlerField.get(getBridge());

                    PluginCall call = new PluginCall(
                        (com.getcapacitor.MessageHandler) msgHandler,
                        "SplashScreen",
                        "FAKE_CALLBACK_ID_HIDE",
                        "hide",
                        options
                    );

                    // Call the hide method directly
                    splashScreenPlugin.invoke("hide", call);
                    logger.info("Splashscreen hidden automatically via direct plugin call");
                } catch (Exception e) {
                    logger.error("Failed to call SplashScreen hide method: " + e.getMessage());
                }
            } else {
                logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.");
            }
        } catch (Exception e) {
            logger.error(
                "Error hiding splashscreen with autoSplashscreen: " +
                    e.getMessage() +
                    ". Make sure @capacitor/splash-screen plugin is installed and configured."
            );
        }
    }

    private void showSplashscreen() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            showSplashscreenNow();
        } else {
            this.mainHandler.post(this::showSplashscreenNow);
        }
    }

    private void showSplashscreenNow() {
        cancelSplashscreenTimeout();
        this.autoSplashscreenTimedOut = false;

        try {
            if (getBridge() == null) {
                logger.warn("Bridge not ready for showing splashscreen with autoSplashscreen");
            } else {
                PluginHandle splashScreenPlugin = getBridge().getPlugin("SplashScreen");
                if (splashScreenPlugin != null) {
                    JSObject options = new JSObject();
                    java.lang.reflect.Field msgHandlerField = getBridge().getClass().getDeclaredField("msgHandler");
                    msgHandlerField.setAccessible(true);
                    Object msgHandler = msgHandlerField.get(getBridge());

                    PluginCall call = new PluginCall(
                        (com.getcapacitor.MessageHandler) msgHandler,
                        "SplashScreen",
                        "FAKE_CALLBACK_ID_SHOW",
                        "show",
                        options
                    );

                    splashScreenPlugin.invoke("show", call);
                    logger.info("Splashscreen shown synchronously to prevent flash");
                } else {
                    logger.warn("autoSplashscreen: SplashScreen plugin not found");
                }
            }
        } catch (Exception e) {
            logger.error("Failed to show splashscreen synchronously: " + e.getMessage());
        }

        addSplashscreenLoaderIfNeeded();
        scheduleSplashscreenTimeout();
    }

    private void addSplashscreenLoaderIfNeeded() {
        if (!Boolean.TRUE.equals(this.autoSplashscreenLoader)) {
            return;
        }

        Runnable addLoader = () -> {
            if (this.splashscreenLoaderOverlay != null) {
                return;
            }

            Activity activity = getActivity();
            if (activity == null) {
                logger.warn("autoSplashscreen: Activity not available for loader overlay");
                return;
            }

            ProgressBar progressBar = new ProgressBar(activity);
            progressBar.setIndeterminate(true);

            FrameLayout overlay = new FrameLayout(activity);
            overlay.setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            overlay.setClickable(false);
            overlay.setFocusable(false);
            overlay.setBackgroundColor(Color.TRANSPARENT);
            overlay.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);

            FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            );
            params.gravity = Gravity.CENTER;
            overlay.addView(progressBar, params);

            ViewGroup decorView = (ViewGroup) activity.getWindow().getDecorView();
            decorView.addView(overlay);

            this.splashscreenLoaderOverlay = overlay;
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            addLoader.run();
        } else {
            this.mainHandler.post(addLoader);
        }
    }

    private void removeSplashscreenLoader() {
        Runnable removeLoader = () -> {
            if (this.splashscreenLoaderOverlay != null) {
                ViewGroup parent = (ViewGroup) this.splashscreenLoaderOverlay.getParent();
                if (parent != null) {
                    parent.removeView(this.splashscreenLoaderOverlay);
                }
                this.splashscreenLoaderOverlay = null;
            }
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            removeLoader.run();
        } else {
            this.mainHandler.post(removeLoader);
        }
    }

    private void scheduleSplashscreenTimeout() {
        if (this.autoSplashscreenTimeout == null || this.autoSplashscreenTimeout <= 0) {
            return;
        }

        cancelSplashscreenTimeout();

        this.splashscreenTimeoutRunnable = () -> {
            logger.info("autoSplashscreen timeout reached, hiding splashscreen");
            this.autoSplashscreenTimedOut = true;
            this.implementation.directUpdate = false;
            hideSplashscreen();
        };

        this.mainHandler.postDelayed(this.splashscreenTimeoutRunnable, this.autoSplashscreenTimeout);
    }

    private void cancelSplashscreenTimeout() {
        if (this.splashscreenTimeoutRunnable != null) {
            this.mainHandler.removeCallbacks(this.splashscreenTimeoutRunnable);
            this.splashscreenTimeoutRunnable = null;
        }
    }

    private boolean checkIfRecentlyInstalledOrUpdated() {
        String currentVersion = this.currentBuildVersion;
        String lastKnownVersion = this.prefs.getString("LatestNativeBuildVersion", "");

        if (lastKnownVersion.isEmpty()) {
            // First time running, consider it as recently installed
            return true;
        } else if (!lastKnownVersion.equals(currentVersion)) {
            // Version changed, consider it as recently updated
            return true;
        }

        return false;
    }

    private boolean shouldUseDirectUpdate() {
        if (Boolean.TRUE.equals(this.autoSplashscreenTimedOut)) {
            return false;
        }
        switch (this.directUpdateMode) {
            case "false":
                return false;
            case "always":
                return true;
            case "atInstall":
                if (this.wasRecentlyInstalledOrUpdated) {
                    // Reset the flag after first use to prevent subsequent foreground events from using direct update
                    this.wasRecentlyInstalledOrUpdated = false;
                    return true;
                }
                return false;
            case "onLaunch":
                if (!this.onLaunchDirectUpdateUsed) {
                    return true;
                }
                return false;
            default:
                logger.error(
                    "Invalid directUpdateMode: \"" +
                        this.directUpdateMode +
                        "\". Supported values are: \"false\", \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\" behavior."
                );
                return false;
        }
    }

    private boolean isDirectUpdateCurrentlyAllowed(final boolean plannedDirectUpdate) {
        return plannedDirectUpdate && !Boolean.TRUE.equals(this.autoSplashscreenTimedOut);
    }

    private void directUpdateFinish(final BundleInfo latest) {
        if ("onLaunch".equals(this.directUpdateMode)) {
            this.onLaunchDirectUpdateUsed = true;
            this.implementation.directUpdate = false;
        }
        CapacitorUpdaterPlugin.this.implementation.set(latest);
        CapacitorUpdaterPlugin.this._reload();
        sendReadyToJs(latest, "update installed", true);
    }

    private void cleanupObsoleteVersions() {
        cleanupThread = startNewThread(() -> {
            synchronized (cleanupLock) {
                try {
                    final String previous = this.prefs.getString("LatestNativeBuildVersion", "");
                    if (!"".equals(previous) && !Objects.equals(this.currentBuildVersion, previous)) {
                        logger.info("New native build version detected: " + this.currentBuildVersion);
                        this.implementation.reset(true);
                        final List<BundleInfo> installed = this.implementation.list(false);
                        for (final BundleInfo bundle : installed) {
                            // Check if thread was interrupted (cancelled)
                            if (Thread.currentThread().isInterrupted()) {
                                logger.warn("Cleanup was cancelled, stopping");
                                return;
                            }
                            try {
                                logger.info("Deleting obsolete bundle: " + bundle.getId());
                                this.implementation.delete(bundle.getId());
                            } catch (final Exception e) {
                                logger.error("Failed to delete: " + bundle.getId() + " " + e.getMessage());
                            }
                        }
                        final List<BundleInfo> storedBundles = this.implementation.list(true);
                        final Set<String> allowedIds = new HashSet<>();
                        for (final BundleInfo info : storedBundles) {
                            if (info != null && info.getId() != null && !info.getId().isEmpty()) {
                                allowedIds.add(info.getId());
                            }
                        }
                        this.implementation.cleanupDownloadDirectories(allowedIds, Thread.currentThread());
                        this.implementation.cleanupOrphanedTempFolders(Thread.currentThread());

                        // Check again before the expensive delta cache cleanup
                        if (Thread.currentThread().isInterrupted()) {
                            logger.warn("Cleanup was cancelled before delta cache cleanup");
                            return;
                        }
                        this.implementation.cleanupDeltaCache(Thread.currentThread());
                    }
                    this.editor.putString("LatestNativeBuildVersion", this.currentBuildVersion);
                    this.editor.apply();
                } catch (Exception e) {
                    logger.error("Error during cleanupObsoleteVersions: " + e.getMessage());
                } finally {
                    cleanupComplete = true;
                    logger.info("Cleanup complete");
                }
            }
        });

        // Start a timeout watchdog thread to cancel cleanup if it takes too long
        final long timeout = this.appReadyTimeout / 2;
        startNewThread(() -> {
            try {
                Thread.sleep(timeout);
                if (cleanupThread != null && cleanupThread.isAlive() && !cleanupComplete) {
                    logger.warn("Cleanup timeout exceeded (" + timeout + "ms), interrupting cleanup thread");
                    cleanupThread.interrupt();
                }
            } catch (InterruptedException e) {
                // Watchdog thread was interrupted, that's fine
            }
        });
    }

    private void waitForCleanupIfNeeded() {
        if (cleanupComplete) {
            return; // Already done, no need to wait
        }

        logger.info("Waiting for cleanup to complete before starting download...");

        // Wait for cleanup to complete - blocks until lock is released
        synchronized (cleanupLock) {
            logger.info("Cleanup finished, proceeding with download");
        }
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
        if (Boolean.TRUE.equals(this.persistModifyUrl)) {
            this.editor.putString(UPDATE_URL_PREF_KEY, url);
            this.editor.apply();
        }
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
        if (Boolean.TRUE.equals(this.persistModifyUrl)) {
            this.editor.putString(STATS_URL_PREF_KEY, url);
            this.editor.apply();
        }
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
        if (Boolean.TRUE.equals(this.persistModifyUrl)) {
            this.editor.putString(CHANNEL_URL_PREF_KEY, url);
            this.editor.apply();
        }
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
        if (Boolean.TRUE.equals(this.persistCustomId)) {
            if (customId.isEmpty()) {
                this.editor.remove(CUSTOM_ID_PREF_KEY);
            } else {
                this.editor.putString(CUSTOM_ID_PREF_KEY, customId);
            }
            this.editor.apply();
        }
        call.resolve();
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("version", this.pluginVersion);
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
            startNewThread(() -> {
                String configDefaultChannel = CapacitorUpdaterPlugin.this.getConfig().getString("defaultChannel", "");
                CapacitorUpdaterPlugin.this.implementation.unsetChannel(
                    CapacitorUpdaterPlugin.this.editor,
                    DEFAULT_CHANNEL_PREF_KEY,
                    configDefaultChannel,
                    (res) -> {
                        JSObject jsRes = mapToJSObject(res);
                        if (jsRes.has("error")) {
                            String errorMessage = jsRes.has("message") ? jsRes.getString("message") : jsRes.getString("error");
                            String errorCode = jsRes.getString("error");

                            JSObject errorObj = new JSObject();
                            errorObj.put("message", errorMessage);
                            errorObj.put("error", errorCode);

                            call.reject(errorMessage, "UNSETCHANNEL_FAILED", null, errorObj);
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                logger.info("Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(jsRes);
                        }
                    }
                );
            });
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
            JSObject errorObj = new JSObject();
            errorObj.put("message", "setChannel called without channel");
            errorObj.put("error", "missing_parameter");
            call.reject("setChannel called without channel", "SETCHANNEL_INVALID_PARAMS", null, errorObj);
            return;
        }
        try {
            logger.info("setChannel " + channel + " triggerAutoUpdate: " + triggerAutoUpdate);
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.setChannel(
                    channel,
                    CapacitorUpdaterPlugin.this.editor,
                    DEFAULT_CHANNEL_PREF_KEY,
                    CapacitorUpdaterPlugin.this.allowSetDefaultChannel,
                    (res) -> {
                        JSObject jsRes = mapToJSObject(res);
                        if (jsRes.has("error")) {
                            String errorMessage = jsRes.has("message") ? jsRes.getString("message") : jsRes.getString("error");
                            String errorCode = jsRes.getString("error");

                            // Fire channelPrivate event if channel doesn't allow self-assignment
                            if (
                                errorCode.contains("cannot_update_via_private_channel") ||
                                errorCode.contains("channel_self_set_not_allowed")
                            ) {
                                JSObject eventData = new JSObject();
                                eventData.put("channel", channel);
                                eventData.put("message", errorMessage);
                                notifyListeners("channelPrivate", eventData);
                            }

                            JSObject errorObj = new JSObject();
                            errorObj.put("message", errorMessage);
                            errorObj.put("error", errorCode);

                            call.reject(errorMessage, "SETCHANNEL_FAILED", null, errorObj);
                        } else {
                            if (CapacitorUpdaterPlugin.this._isAutoUpdateEnabled() && Boolean.TRUE.equals(triggerAutoUpdate)) {
                                logger.info("Calling autoupdater after channel change!");
                                backgroundDownload();
                            }
                            call.resolve(jsRes);
                        }
                    }
                )
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
                CapacitorUpdaterPlugin.this.implementation.getChannel((res) -> {
                    JSObject jsRes = mapToJSObject(res);
                    if (jsRes.has("error")) {
                        String errorMessage = jsRes.has("message") ? jsRes.getString("message") : jsRes.getString("error");
                        String errorCode = jsRes.getString("error");

                        JSObject errorObj = new JSObject();
                        errorObj.put("message", errorMessage);
                        errorObj.put("error", errorCode);

                        call.reject(errorMessage, "GETCHANNEL_FAILED", null, errorObj);
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
    public void listChannels(final PluginCall call) {
        try {
            logger.info("listChannels");
            startNewThread(() ->
                CapacitorUpdaterPlugin.this.implementation.listChannels((res) -> {
                    JSObject jsRes = mapToJSObject(res);
                    if (jsRes.has("error")) {
                        String errorMessage = jsRes.has("message") ? jsRes.getString("message") : jsRes.getString("error");
                        String errorCode = jsRes.getString("error");

                        JSObject errorObj = new JSObject();
                        errorObj.put("message", errorMessage);
                        errorObj.put("error", errorCode);

                        call.reject(errorMessage, "LISTCHANNELS_FAILED", null, errorObj);
                    } else {
                        call.resolve(jsRes);
                    }
                })
            );
        } catch (final Exception e) {
            logger.error("Failed to listChannels: " + e.getMessage());
            call.reject("Failed to listChannels", e);
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

    private void syncKeepUrlPathFlag(final boolean enabled) {
        if (this.bridge == null || this.bridge.getWebView() == null) {
            return;
        }
        final String script = enabled
            ? "(function(){try{localStorage.setItem('" +
              KEEP_URL_FLAG_KEY +
              "','1');}catch(e){}window.__capgoKeepUrlPathAfterReload=true;var evt;try{evt=new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload',{detail:{enabled:true}});}catch(err){evt=document.createEvent('CustomEvent');evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload',false,false,{enabled:true});}window.dispatchEvent(evt);})();"
            : "(function(){try{localStorage.removeItem('" +
              KEEP_URL_FLAG_KEY +
              "');}catch(e){}delete window.__capgoKeepUrlPathAfterReload;var evt;try{evt=new CustomEvent('CapacitorUpdaterKeepUrlPathAfterReload',{detail:{enabled:false}});}catch(err){evt=document.createEvent('CustomEvent');evt.initCustomEvent('CapacitorUpdaterKeepUrlPathAfterReload',false,false,{enabled:false});}window.dispatchEvent(evt);})();";
        this.bridge.getWebView().post(() -> this.bridge.getWebView().evaluateJavascript(script, null));
    }

    protected boolean _reload() {
        final String path = this.implementation.getCurrentBundlePath();
        if (this.keepUrlPathAfterReload) {
            this.syncKeepUrlPathFlag(true);
        }
        this.semaphoreUp();
        logger.info("Reloading: " + path);

        AtomicReference<URL> url = new AtomicReference<>();
        if (this.keepUrlPathAfterReload) {
            try {
                if (Looper.myLooper() != Looper.getMainLooper()) {
                    Semaphore mainThreadSemaphore = new Semaphore(0);
                    this.bridge.executeOnMainThread(() -> {
                        try {
                            if (this.bridge != null && this.bridge.getWebView() != null) {
                                String currentUrl = this.bridge.getWebView().getUrl();
                                if (currentUrl != null) {
                                    url.set(new URL(currentUrl));
                                }
                            }
                        } catch (Exception e) {
                            logger.error("Error executing on main thread " + e.getMessage());
                        }
                        mainThreadSemaphore.release();
                    });

                    // Add timeout to prevent indefinite blocking
                    if (!mainThreadSemaphore.tryAcquire(10, TimeUnit.SECONDS)) {
                        logger.error("Timeout waiting for main thread operation");
                    }
                } else {
                    try {
                        if (this.bridge != null && this.bridge.getWebView() != null) {
                            String currentUrl = this.bridge.getWebView().getUrl();
                            if (currentUrl != null) {
                                url.set(new URL(currentUrl));
                            }
                        }
                    } catch (Exception e) {
                        logger.error("Error executing on main thread " + e.getMessage());
                    }
                }
            } catch (InterruptedException e) {
                logger.error("Error waiting for main thread or getting the current URL from webview " + e.getMessage());
                Thread.currentThread().interrupt(); // Restore interrupted status
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
                this.bridge.getWebView().post(() -> {
                    this.bridge.getWebView().loadUrl(finalUrl1.toString());
                    if (!this.keepUrlPathAfterReload) {
                        this.bridge.getWebView().clearHistory();
                    }
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
            if (this.bridge != null && this.bridge.getWebView() != null) {
                this.bridge.getWebView().post(() -> {
                    if (this.bridge.getWebView() != null) {
                        this.bridge.getWebView().loadUrl(this.bridge.getAppUrl());
                        if (!this.keepUrlPathAfterReload) {
                            this.bridge.getWebView().clearHistory();
                        }
                    }
                });
            }
        }

        this.checkAppReady();
        this.notifyListeners("appReloaded", new JSObject());

        // Wait for the reload to complete (until notifyAppReady is called)
        try {
            this.semaphoreWait(this.appReadyTimeout);
        } catch (Exception e) {
            logger.error("Error waiting for app ready: " + e.getMessage());
            return false;
        }

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
    public void setBundleError(final PluginCall call) {
        if (!Boolean.TRUE.equals(this.allowManualBundleError)) {
            logger.error("setBundleError called without allowManualBundleError");
            call.reject("setBundleError not allowed. Set allowManualBundleError to true in your config to enable it.");
            return;
        }
        final String id = call.getString("id");
        if (id == null) {
            logger.error("setBundleError called without id");
            call.reject("setBundleError called without id");
            return;
        }
        try {
            final BundleInfo bundle = this.implementation.getBundleInfo(id);
            if (bundle == null || bundle.isUnknown()) {
                logger.error("setBundleError called with unknown bundle " + id);
                call.reject("Bundle " + id + " does not exist");
                return;
            }
            if (bundle.isBuiltin()) {
                logger.error("setBundleError called on builtin bundle");
                call.reject("Cannot set builtin bundle to error state");
                return;
            }
            if (Boolean.TRUE.equals(this.autoUpdate)) {
                logger.warn("setBundleError used while autoUpdate is enabled; this method is intended for manual mode");
            }
            this.implementation.setError(bundle);
            final JSObject ret = new JSObject();
            ret.put("bundle", mapToJSObject(this.implementation.getBundleInfo(id).toJSONMap()));
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not set bundle error for id " + id + " " + e.getMessage());
            call.reject("Could not set bundle error for id " + id, e);
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
            CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, channel, (res) -> {
                JSObject jsRes = mapToJSObject(res);
                if (jsRes.has("error")) {
                    String error = jsRes.getString("error");
                    String errorMessage = jsRes.has("message") ? jsRes.getString("message") : "server did not provide a message";
                    logger.error("getLatest failed with error: " + error + ", message: " + errorMessage);
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

    @PluginMethod
    public void getFailedUpdate(final PluginCall call) {
        try {
            final BundleInfo bundle = this.readLastFailedBundle();
            if (bundle == null || bundle.isUnknown()) {
                call.resolve(null);
                return;
            }

            this.persistLastFailedBundle(null);

            final JSObject ret = new JSObject();
            ret.put("bundle", mapToJSObject(bundle.toJSONMap()));
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not get failed update " + e.getMessage());
            call.reject("Could not get failed update", e);
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
                        CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, null, (res) -> {
                            JSObject jsRes = mapToJSObject(res);
                            if (jsRes.has("error")) {
                                String error = jsRes.getString("error");
                                String errorMessage = jsRes.has("message")
                                    ? jsRes.getString("message")
                                    : "server did not provide a message";
                                logger.error("getLatest failed with error: " + error + ", message: " + errorMessage);
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
        endBackGroundTaskWithNotif(msg, latestVersionName, current, error, false, "download_fail", "downloadFailed", true);
    }

    private void endBackGroundTaskWithNotif(
        String msg,
        String latestVersionName,
        BundleInfo current,
        Boolean error,
        Boolean isDirectUpdate
    ) {
        endBackGroundTaskWithNotif(msg, latestVersionName, current, error, isDirectUpdate, "download_fail", "downloadFailed", true);
    }

    private void endBackGroundTaskWithNotif(
        String msg,
        String latestVersionName,
        BundleInfo current,
        Boolean error,
        Boolean isDirectUpdate,
        String failureAction,
        String failureEvent
    ) {
        endBackGroundTaskWithNotif(msg, latestVersionName, current, error, isDirectUpdate, failureAction, failureEvent, true);
    }

    private void endBackGroundTaskWithNotif(
        String msg,
        String latestVersionName,
        BundleInfo current,
        Boolean error,
        Boolean isDirectUpdate,
        String failureAction,
        String failureEvent,
        boolean shouldSendStats
    ) {
        if (error) {
            logger.info(
                "endBackGroundTaskWithNotif error: " +
                    error +
                    " current: " +
                    current.getVersionName() +
                    "latestVersionName: " +
                    latestVersionName
            );
            if (shouldSendStats) {
                this.implementation.sendStats(failureAction, current.getVersionName());
            }
            final JSObject ret = new JSObject();
            ret.put("version", latestVersionName);
            this.notifyListeners(failureEvent, ret);
        }
        final JSObject ret = new JSObject();
        ret.put("bundle", mapToJSObject(current.toJSONMap()));
        this.notifyListeners("noNeedUpdate", ret);
        this.sendReadyToJs(current, msg, isDirectUpdate);
        this.backgroundDownloadTask = null;
        logger.info("endBackGroundTaskWithNotif " + msg);
    }

    private Thread backgroundDownload() {
        final boolean plannedDirectUpdate = this.shouldUseDirectUpdate();
        final boolean initialDirectUpdateAllowed = this.isDirectUpdateCurrentlyAllowed(plannedDirectUpdate);
        this.implementation.directUpdate = initialDirectUpdateAllowed;
        final String messageUpdate = initialDirectUpdateAllowed
            ? "Update will occur now."
            : "Update will occur next time app moves to background.";
        return startNewThread(() -> {
            // Wait for cleanup to complete before starting download
            waitForCleanupIfNeeded();
            logger.info("Check for update via: " + CapacitorUpdaterPlugin.this.updateUrl);
            try {
                CapacitorUpdaterPlugin.this.implementation.getLatest(CapacitorUpdaterPlugin.this.updateUrl, null, (res) -> {
                    JSObject jsRes = mapToJSObject(res);
                    final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();

                    // Handle network errors and other failures first
                    if (jsRes.has("error")) {
                        String error = jsRes.getString("error");
                        String errorMessage = jsRes.has("message") ? jsRes.getString("message") : "server did not provide a message";
                        int statusCode = jsRes.has("statusCode") ? jsRes.optInt("statusCode", 0) : 0;
                        boolean responseIsOk = statusCode >= 200 && statusCode < 300;

                        logger.error(
                            "getLatest failed with error: " + error + ", message: " + errorMessage + ", statusCode: " + statusCode
                        );
                        String latestVersion = jsRes.has("version") ? jsRes.getString("version") : current.getVersionName();

                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                            errorMessage,
                            latestVersion,
                            current,
                            true,
                            plannedDirectUpdate,
                            "download_fail",
                            "downloadFailed",
                            !responseIsOk
                        );
                        return;
                    }

                    try {
                        final String latestVersionName = jsRes.getString("version");

                        if ("builtin".equals(latestVersionName)) {
                            logger.info("Latest version is builtin");
                            final boolean directUpdateAllowedNow = CapacitorUpdaterPlugin.this.isDirectUpdateCurrentlyAllowed(
                                plannedDirectUpdate
                            );
                            if (directUpdateAllowedNow) {
                                logger.info("Direct update to builtin version");
                                this._reset(false);
                                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                    "Updated to builtin version",
                                    latestVersionName,
                                    CapacitorUpdaterPlugin.this.implementation.getCurrentBundle(),
                                    false,
                                    true
                                );
                            } else {
                                if (plannedDirectUpdate && !directUpdateAllowedNow) {
                                    logger.info(
                                        "Direct update skipped because splashscreen timeout occurred. Update will be applied later."
                                    );
                                }
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
                                true,
                                plannedDirectUpdate
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
                                        true,
                                        plannedDirectUpdate
                                    );
                                    return;
                                }
                                if (latest.isDownloaded()) {
                                    logger.info("Latest bundle already exists and download is NOT required. " + messageUpdate);
                                    final boolean directUpdateAllowedNow = CapacitorUpdaterPlugin.this.isDirectUpdateCurrentlyAllowed(
                                        plannedDirectUpdate
                                    );
                                    if (directUpdateAllowedNow) {
                                        String delayUpdatePreferences = prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]");
                                        ArrayList<DelayCondition> delayConditionList = delayUpdateUtils.parseDelayConditions(
                                            delayUpdatePreferences
                                        );
                                        if (!delayConditionList.isEmpty()) {
                                            logger.info("Update delayed until delay conditions met");
                                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                                "Update delayed until delay conditions met",
                                                latestVersionName,
                                                latest,
                                                false,
                                                plannedDirectUpdate
                                            );
                                            return;
                                        }
                                        CapacitorUpdaterPlugin.this.implementation.set(latest);
                                        CapacitorUpdaterPlugin.this._reload();
                                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                                            "Update installed",
                                            latestVersionName,
                                            latest,
                                            false,
                                            true
                                        );
                                    } else {
                                        if (plannedDirectUpdate && !directUpdateAllowedNow) {
                                            logger.info(
                                                "Direct update skipped because splashscreen timeout occurred. Update will install on next background."
                                            );
                                        }
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
                                        true,
                                        plannedDirectUpdate
                                    );
                                }
                            });
                        } else {
                            logger.info("No need to update, " + current.getId() + " is the latest bundle.");
                            CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif("No need to update", latestVersionName, current, false);
                        }
                    } catch (final Exception e) {
                        logger.error("error in update check " + e.getMessage());
                        CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                            "Error in update check",
                            current.getVersionName(),
                            current,
                            true,
                            plannedDirectUpdate
                        );
                    }
                });
            } catch (final Exception e) {
                logger.error("getLatest call failed: " + e.getMessage());
                final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();
                CapacitorUpdaterPlugin.this.endBackGroundTaskWithNotif(
                    "Network connection failed",
                    current.getVersionName(),
                    current,
                    true,
                    plannedDirectUpdate
                );
            }
        });
    }

    private void installNext() {
        try {
            String delayUpdatePreferences = prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]");
            ArrayList<DelayCondition> delayConditionList = delayUpdateUtils.parseDelayConditions(delayUpdatePreferences);
            if (!delayConditionList.isEmpty()) {
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
            this.persistLastFailedBundle(current);
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
            final CapConfig config = CapConfig.loadDefault(this.getActivity());
            String serverUrl = config.getServerUrl();
            if (serverUrl != null && !serverUrl.isEmpty()) {
                CapacitorUpdaterPlugin.this.implementation.sendStats("blocked_by_server_url", current.getVersionName());
            }
            logger.info("Auto update is disabled");
            this.sendReadyToJs(current, "disabled");
        }
        this.checkAppReady();
    }

    public void appMovedToBackground() {
        final BundleInfo current = CapacitorUpdaterPlugin.this.implementation.getCurrentBundle();

        // Show splashscreen FIRST, before any other background work to ensure launcher shows it
        if (this.autoSplashscreen) {
            boolean canShowSplashscreen = true;

            if (!this._isAutoUpdateEnabled()) {
                logger.warn(
                    "autoSplashscreen is enabled but autoUpdate is disabled. Splashscreen will not be shown. Enable autoUpdate or disable autoSplashscreen."
                );
                canShowSplashscreen = false;
            }

            if (!this.shouldUseDirectUpdate()) {
                if ("false".equals(this.directUpdateMode)) {
                    logger.warn(
                        "autoSplashscreen is enabled but directUpdate is not configured for immediate updates. Set directUpdate to 'always' or disable autoSplashscreen."
                    );
                } else if ("atInstall".equals(this.directUpdateMode) || "onLaunch".equals(this.directUpdateMode)) {
                    logger.info(
                        "autoSplashscreen is enabled but directUpdate is set to \"" +
                            this.directUpdateMode +
                            "\". This is normal. Skipping autoSplashscreen logic."
                    );
                }
                canShowSplashscreen = false;
            }

            if (canShowSplashscreen) {
                logger.info("Showing splashscreen for launcher/task switcher");
                this.showSplashscreen();
            }
        }

        // Do other background work after splashscreen is shown
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

    @Override
    public void handleOnStart() {
        try {
            if (isPreviousMainActivity) {
                logger.info("handleOnStart: appMovedToForeground");
                this.appMovedToForeground();
            }
            logger.info("handleOnStart: onActivityStarted " + getActivity().getClass().getName());
            isPreviousMainActivity = true;

            // Initialize shake menu if enabled and activity is BridgeActivity
            if (shakeMenuEnabled && getActivity() instanceof com.getcapacitor.BridgeActivity && shakeMenu == null) {
                try {
                    shakeMenu = new ShakeMenu(this, (com.getcapacitor.BridgeActivity) getActivity(), logger);
                    logger.info("Shake menu initialized");
                } catch (Exception e) {
                    logger.error("Failed to initialize shake menu: " + e.getMessage());
                }
            }
        } catch (Exception e) {
            logger.error("Failed to run handleOnStart: " + e.getMessage());
        }
    }

    @Override
    public void handleOnStop() {
        try {
            isPreviousMainActivity = isMainActivity();
            if (isPreviousMainActivity) {
                logger.info("handleOnStop: appMovedToBackground");
                this.appMovedToBackground();
            }
        } catch (Exception e) {
            logger.error("Failed to run handleOnStop: " + e.getMessage());
        }
    }

    @Override
    public void handleOnResume() {
        try {
            if (backgroundTask != null && taskRunning) {
                backgroundTask.interrupt();
            }
            this.implementation.activity = getActivity();
        } catch (Exception e) {
            logger.error("Failed to run handleOnResume: " + e.getMessage());
        }
    }

    @Override
    public void handleOnPause() {
        try {
            this.implementation.activity = getActivity();
        } catch (Exception e) {
            logger.error("Failed to run handleOnPause: " + e.getMessage());
        }
    }

    @PluginMethod
    public void setShakeMenu(final PluginCall call) {
        final Boolean enabled = call.getBoolean("enabled");
        if (enabled == null) {
            logger.error("setShakeMenu called without enabled parameter");
            call.reject("setShakeMenu called without enabled parameter");
            return;
        }

        this.shakeMenuEnabled = enabled;
        logger.info("Shake menu " + (enabled ? "enabled" : "disabled"));

        // Manage shake menu instance based on enabled state
        if (enabled && getActivity() instanceof com.getcapacitor.BridgeActivity && shakeMenu == null) {
            try {
                shakeMenu = new ShakeMenu(this, (com.getcapacitor.BridgeActivity) getActivity(), logger);
                logger.info("Shake menu initialized");
            } catch (Exception e) {
                logger.error("Failed to initialize shake menu: " + e.getMessage());
            }
        } else if (!enabled && shakeMenu != null) {
            try {
                shakeMenu.stop();
                shakeMenu = null;
                logger.info("Shake menu stopped");
            } catch (Exception e) {
                logger.error("Failed to stop shake menu: " + e.getMessage());
            }
        }

        call.resolve();
    }

    @PluginMethod
    public void isShakeMenuEnabled(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("enabled", this.shakeMenuEnabled);
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not get shake menu status " + e.getMessage());
            call.reject("Could not get shake menu status", e);
        }
    }

    @PluginMethod
    public void getAppId(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("appId", this.implementation.appId);
            call.resolve(ret);
        } catch (final Exception e) {
            logger.error("Could not get appId " + e.getMessage());
            call.reject("Could not get appId", e);
        }
    }

    @PluginMethod
    public void setAppId(final PluginCall call) {
        if (!this.getConfig().getBoolean("allowModifyAppId", false)) {
            logger.error("setAppId not allowed set allowModifyAppId in your config to true to allow it");
            call.reject("setAppId not allowed");
            return;
        }
        final String appId = call.getString("appId");
        if (appId == null) {
            logger.error("setAppId called without appId");
            call.reject("setAppId called without appId");
            return;
        }
        this.implementation.appId = appId;
        call.resolve();
    }

    // ============================================================================
    // Play Store In-App Update Methods
    // ============================================================================

    // AppUpdateAvailability enum values matching TypeScript definitions
    private static final int UPDATE_AVAILABILITY_UNKNOWN = 0;
    private static final int UPDATE_AVAILABILITY_NOT_AVAILABLE = 1;
    private static final int UPDATE_AVAILABILITY_AVAILABLE = 2;
    private static final int UPDATE_AVAILABILITY_IN_PROGRESS = 3;

    // AppUpdateResultCode enum values matching TypeScript definitions
    private static final int RESULT_OK = 0;
    private static final int RESULT_CANCELED = 1;
    private static final int RESULT_FAILED = 2;
    private static final int RESULT_NOT_AVAILABLE = 3;
    private static final int RESULT_NOT_ALLOWED = 4;
    private static final int RESULT_INFO_MISSING = 5;

    private AppUpdateManager getAppUpdateManager() {
        if (appUpdateManager == null) {
            appUpdateManager = AppUpdateManagerFactory.create(getContext());
        }
        return appUpdateManager;
    }

    private int mapUpdateAvailability(int playStoreAvailability) {
        switch (playStoreAvailability) {
            case UpdateAvailability.UPDATE_AVAILABLE:
                return UPDATE_AVAILABILITY_AVAILABLE;
            case UpdateAvailability.UPDATE_NOT_AVAILABLE:
                return UPDATE_AVAILABILITY_NOT_AVAILABLE;
            case UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS:
                return UPDATE_AVAILABILITY_IN_PROGRESS;
            default:
                return UPDATE_AVAILABILITY_UNKNOWN;
        }
    }

    @PluginMethod
    public void getAppUpdateInfo(final PluginCall call) {
        logger.info("Getting Play Store update info");

        try {
            AppUpdateManager manager = getAppUpdateManager();
            Task<AppUpdateInfo> appUpdateInfoTask = manager.getAppUpdateInfo();

            appUpdateInfoTask
                .addOnSuccessListener((appUpdateInfo) -> {
                    cachedAppUpdateInfo = appUpdateInfo;

                    JSObject result = new JSObject();
                    try {
                        PackageInfo pInfo = getContext().getPackageManager().getPackageInfo(getContext().getPackageName(), 0);
                        result.put("currentVersionName", pInfo.versionName);
                        result.put("currentVersionCode", String.valueOf(pInfo.versionCode));
                    } catch (PackageManager.NameNotFoundException e) {
                        result.put("currentVersionName", "0.0.0");
                        result.put("currentVersionCode", "0");
                    }

                    result.put("updateAvailability", mapUpdateAvailability(appUpdateInfo.updateAvailability()));

                    if (appUpdateInfo.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE) {
                        result.put("availableVersionCode", String.valueOf(appUpdateInfo.availableVersionCode()));
                        // Play Store doesn't provide version name, only version code
                        result.put("availableVersionName", String.valueOf(appUpdateInfo.availableVersionCode()));
                        result.put("updatePriority", appUpdateInfo.updatePriority());
                        result.put("immediateUpdateAllowed", appUpdateInfo.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE));
                        result.put("flexibleUpdateAllowed", appUpdateInfo.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE));

                        Integer stalenessDays = appUpdateInfo.clientVersionStalenessDays();
                        if (stalenessDays != null) {
                            result.put("clientVersionStalenessDays", stalenessDays);
                        }
                    } else {
                        result.put("immediateUpdateAllowed", false);
                        result.put("flexibleUpdateAllowed", false);
                    }

                    result.put("installStatus", appUpdateInfo.installStatus());

                    call.resolve(result);
                })
                .addOnFailureListener((e) -> {
                    logger.error("Failed to get app update info: " + e.getMessage());
                    call.reject("Failed to get app update info: " + e.getMessage());
                });
        } catch (Exception e) {
            logger.error("Error getting app update info: " + e.getMessage());
            call.reject("Error getting app update info: " + e.getMessage());
        }
    }

    @PluginMethod
    public void openAppStore(final PluginCall call) {
        String packageName = call.getString("packageName");
        if (packageName == null || packageName.isEmpty()) {
            packageName = getContext().getPackageName();
        }

        try {
            // Try to open Play Store app first
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=" + packageName));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(intent);
            call.resolve();
        } catch (android.content.ActivityNotFoundException e) {
            // Fall back to browser
            try {
                Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=" + packageName));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(intent);
                call.resolve();
            } catch (Exception ex) {
                logger.error("Failed to open Play Store: " + ex.getMessage());
                call.reject("Failed to open Play Store: " + ex.getMessage());
            }
        }
    }

    @PluginMethod
    public void performImmediateUpdate(final PluginCall call) {
        if (cachedAppUpdateInfo == null) {
            logger.error("No update info available. Call getAppUpdateInfo first.");
            JSObject result = new JSObject();
            result.put("code", RESULT_INFO_MISSING);
            call.resolve(result);
            return;
        }

        if (cachedAppUpdateInfo.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) {
            logger.info("No update available");
            JSObject result = new JSObject();
            result.put("code", RESULT_NOT_AVAILABLE);
            call.resolve(result);
            return;
        }

        if (!cachedAppUpdateInfo.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)) {
            logger.info("Immediate update not allowed");
            JSObject result = new JSObject();
            result.put("code", RESULT_NOT_ALLOWED);
            call.resolve(result);
            return;
        }

        try {
            Activity activity = getActivity();
            if (activity == null) {
                call.reject("Activity not available");
                return;
            }

            // Save the call for later resolution
            bridge.saveCall(call);

            AppUpdateManager manager = getAppUpdateManager();
            manager.startUpdateFlowForResult(
                cachedAppUpdateInfo,
                activity,
                AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(),
                APP_UPDATE_REQUEST_CODE
            );
        } catch (Exception e) {
            logger.error("Failed to start immediate update: " + e.getMessage());
            JSObject result = new JSObject();
            result.put("code", RESULT_FAILED);
            call.resolve(result);
        }
    }

    @PluginMethod
    public void startFlexibleUpdate(final PluginCall call) {
        if (cachedAppUpdateInfo == null) {
            logger.error("No update info available. Call getAppUpdateInfo first.");
            JSObject result = new JSObject();
            result.put("code", RESULT_INFO_MISSING);
            call.resolve(result);
            return;
        }

        if (cachedAppUpdateInfo.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) {
            logger.info("No update available");
            JSObject result = new JSObject();
            result.put("code", RESULT_NOT_AVAILABLE);
            call.resolve(result);
            return;
        }

        if (!cachedAppUpdateInfo.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)) {
            logger.info("Flexible update not allowed");
            JSObject result = new JSObject();
            result.put("code", RESULT_NOT_ALLOWED);
            call.resolve(result);
            return;
        }

        try {
            Activity activity = getActivity();
            if (activity == null) {
                call.reject("Activity not available");
                return;
            }

            // Register listener for flexible update state changes
            AppUpdateManager manager = getAppUpdateManager();

            // Remove any existing listener
            if (installStateUpdatedListener != null) {
                manager.unregisterListener(installStateUpdatedListener);
            }

            installStateUpdatedListener = (state) -> {
                JSObject eventData = new JSObject();
                eventData.put("installStatus", state.installStatus());

                if (state.installStatus() == InstallStatus.DOWNLOADING) {
                    eventData.put("bytesDownloaded", state.bytesDownloaded());
                    eventData.put("totalBytesToDownload", state.totalBytesToDownload());
                }

                notifyListeners("onFlexibleUpdateStateChange", eventData);
            };

            manager.registerListener(installStateUpdatedListener);

            // Save the call for later resolution
            bridge.saveCall(call);

            manager.startUpdateFlowForResult(
                cachedAppUpdateInfo,
                activity,
                AppUpdateOptions.newBuilder(AppUpdateType.FLEXIBLE).build(),
                APP_UPDATE_REQUEST_CODE
            );
        } catch (Exception e) {
            logger.error("Failed to start flexible update: " + e.getMessage());
            JSObject result = new JSObject();
            result.put("code", RESULT_FAILED);
            call.resolve(result);
        }
    }

    @PluginMethod
    public void completeFlexibleUpdate(final PluginCall call) {
        try {
            AppUpdateManager manager = getAppUpdateManager();
            manager
                .completeUpdate()
                .addOnSuccessListener((aVoid) -> {
                    // The app will restart, so this may not be called
                    call.resolve();
                })
                .addOnFailureListener((e) -> {
                    logger.error("Failed to complete flexible update: " + e.getMessage());
                    call.reject("Failed to complete flexible update: " + e.getMessage());
                });
        } catch (Exception e) {
            logger.error("Error completing flexible update: " + e.getMessage());
            call.reject("Error completing flexible update: " + e.getMessage());
        }
    }

    @Override
    protected void handleOnActivityResult(int requestCode, int resultCode, Intent data) {
        super.handleOnActivityResult(requestCode, resultCode, data);

        if (requestCode == APP_UPDATE_REQUEST_CODE) {
            PluginCall savedCall = bridge.getSavedCall("com.getcapacitor.PluginCall");
            if (savedCall == null) {
                // Try to get any saved call (for backward compatibility)
                return;
            }

            JSObject result = new JSObject();
            if (resultCode == Activity.RESULT_OK) {
                result.put("code", RESULT_OK);
            } else if (resultCode == Activity.RESULT_CANCELED) {
                result.put("code", RESULT_CANCELED);
            } else {
                result.put("code", RESULT_FAILED);
            }
            savedCall.resolve(result);
            bridge.releaseCall(savedCall);
        }
    }

    @Override
    protected void handleOnDestroy() {
        // Clean up the install state listener
        if (installStateUpdatedListener != null && appUpdateManager != null) {
            try {
                appUpdateManager.unregisterListener(installStateUpdatedListener);
                installStateUpdatedListener = null;
            } catch (Exception e) {
                logger.error("Failed to unregister install state listener: " + e.getMessage());
            }
        }

        handleOnDestroyInternal();
    }

    private void handleOnDestroyInternal() {
        // Original handleOnDestroy code
        try {
            logger.info("onActivityDestroyed " + getActivity().getClass().getName());
            this.implementation.activity = getActivity();

            // Check for 'kill' delay condition on activity destroy
            // Note: onDestroy is not reliably called - also check on next app launch
            this.delayUpdateUtils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.KILLED);
            this.delayUpdateUtils.setBackgroundTimestamp(0);

            // Clean up shake menu
            if (shakeMenu != null) {
                try {
                    shakeMenu.stop();
                    shakeMenu = null;
                    logger.info("Shake menu cleaned up");
                } catch (Exception e) {
                    logger.error("Failed to clean up shake menu: " + e.getMessage());
                }
            }
        } catch (Exception e) {
            logger.error("Failed to run handleOnDestroy: " + e.getMessage());
        }
    }
}
