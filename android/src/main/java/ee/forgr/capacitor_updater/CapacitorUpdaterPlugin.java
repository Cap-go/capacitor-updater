/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.AlertDialog;
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
import android.webkit.RenderProcessGoneDetail;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import androidx.core.content.pm.PackageInfoCompat;
import com.getcapacitor.Bridge;
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.PluginResult;
import com.getcapacitor.WebViewListener;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.plugin.WebView;
import com.google.android.gms.tasks.Task;
// Play Store In-App Updates
import com.google.android.play.core.appupdate.AppUpdateInfo;
import com.google.android.play.core.appupdate.AppUpdateManager;
import com.google.android.play.core.appupdate.AppUpdateManagerFactory;
import com.google.android.play.core.appupdate.AppUpdateOptions;
import com.google.android.play.core.install.InstallStateUpdatedListener;
import com.google.android.play.core.install.model.AppUpdateType;
import com.google.android.play.core.install.model.InstallStatus;
import com.google.android.play.core.install.model.UpdateAvailability;
import java.net.MalformedURLException;
import java.net.URL;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Capacitor glue over the Rust updater engine ({@code core/src/engine/plugin}). The engine owns the update cycle,
 * bundles, rollback, delays, channels, previews and statistics; this class forwards JavaScript calls and lifecycle
 * events to it and implements the hooks that need Android (WebView, splash screen, loaders, dialogs, shake menu).
 */
@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

    static final String SHAKE_MENU_GESTURE_SHAKE = "shake";
    static final String SHAKE_MENU_GESTURE_THREE_FINGER_PINCH = "threeFingerPinch";

    private static final String KEEP_URL_FLAG_KEY = "__capgo_keep_url_path_after_reload";
    private static final String SPLASH_SCREEN_PLUGIN_ID = "SplashScreen";
    private static final int SPLASH_SCREEN_RETRY_DELAY_MS = 100;
    private static final int SPLASH_SCREEN_MAX_RETRIES = 20;
    private static final long PENDING_BUNDLE_APP_READY_MIN_TIMEOUT_MS = 30000L;
    private static final long PREVIEW_TRANSITION_LOADER_TIMEOUT_MS = 60000L;
    private static final long MAIN_THREAD_TIMEOUT_SECONDS = 10;

    private final String pluginVersion = "8.52.1";

    private Logger logger;
    // Cleared (and the Rust engine freed) in handleOnDestroy.
    private volatile CapgoEngine engine;
    private boolean jsLoggingEnabled = true;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    /** Engine methods can block (set / reload wait for notifyAppReady), so each call gets its own thread. */
    private final ExecutorService methodExecutor = Executors.newCachedThreadPool();

    volatile boolean shakeMenuEnabled = false;
    volatile boolean shakeChannelSelectorEnabled = false;
    volatile String shakeMenuGesture = SHAKE_MENU_GESTURE_SHAKE;
    private ShakeMenu shakeMenu;
    /** Progress of the running shake-menu channel switch ({@code shakeMenuProgress} hook). */
    volatile java.util.function.Consumer<String> shakeMenuProgressListener;

    private volatile boolean keepUrlPathAfterReload = false;
    private boolean autoSplashscreenLoader = false;
    private int splashscreenInvocationToken = 0;
    private FrameLayout splashscreenLoaderOverlay;
    private FrameLayout previewTransitionLoaderOverlay;
    private Runnable previewTransitionLoaderTimeoutRunnable;
    private boolean previewTransitionLoaderRequested = false;

    private WebViewListener webViewStatsListener;
    private volatile long webViewPageStartedAtMs = 0;

    // Activity-based foreground/background detection on Android < 14
    private Boolean isPreviousMainActivity = true;
    // ProcessLifecycleOwner-based detection on Android 14+
    private AppLifecycleObserver appLifecycleObserver;

    // Play Store In-App Updates
    private AppUpdateManager appUpdateManager;
    private PluginCall pendingAppUpdateCall;
    private AppUpdateInfo cachedAppUpdateInfo;
    private static final int APP_UPDATE_REQUEST_CODE = 9001;
    private InstallStateUpdatedListener installStateUpdatedListener;

    private static final class FireAndForgetPluginCall extends PluginCall {

        FireAndForgetPluginCall(final String methodName, final JSObject data) {
            super(null, SPLASH_SCREEN_PLUGIN_ID, PluginCall.CALLBACK_ID_DANGLING, methodName, data);
        }

        @Override
        public void successCallback(final PluginResult successResult) {}

        @Override
        public void resolve(final JSObject data) {}

        @Override
        public void resolve() {}

        @Override
        public void errorCallback(final String msg) {}

        @Override
        public void reject(final String msg, final String code, final Exception ex, final JSObject data) {}
    }

    // ---- load ----------------------------------------------------------------------------------

    @Override
    public void load() {
        super.load();

        final boolean osLogging = this.getConfig().getBoolean("osLogging", true);
        this.logger = new Logger("CapgoUpdater", new Logger.Options(osLogging));
        this.jsLoggingEnabled = !this.getConfig().getBoolean("disableJSLogging", false);
        if (this.ensureBridgeSet()) {
            logger.info("WebView set successfully for logging");
        } else {
            logger.info("WebView not ready yet, will be set later");
        }

        final PackageInfo packageInfo;
        try {
            packageInfo = this.getCurrentPackageInfo();
        } catch (final Exception e) {
            logger.error("Error getting current native app version " + e.getMessage());
            return;
        }
        final String versionName = this.getConfig().getString("version", packageInfo.versionName);
        final String versionCode = getVersionCode(packageInfo);

        String appId = this.getContext().getPackageName();
        appId = CapConfig.loadDefault(this.getActivity()).getString("appId", appId);
        appId = this.getConfig().getString("appId", appId);
        if (appId == null || appId.isEmpty()) {
            // crash the app on purpose it should not happen
            throw new RuntimeException(
                "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config"
            );
        }
        this.autoSplashscreenLoader = this.getConfig().getBoolean("autoSplashscreenLoader", false);

        final SharedPreferences prefs = this.getContext().getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Activity.MODE_PRIVATE);
        final CapgoUpdater updater = new CapgoUpdater(
            this.getContext(),
            prefs,
            logger,
            new CapgoUpdater.Listener() {
                @Override
                public void onEvent(final String event, final String payloadJson) {
                    CapacitorUpdaterPlugin.this.forwardEvent(event, payloadJson);
                }

                @Override
                public String onHook(final String name, final String payloadJson) {
                    return CapacitorUpdaterPlugin.this.handleHook(name, payloadJson);
                }
            }
        );
        final JSONObject result;
        try {
            final JSONObject identity =
                new JSONObject()
                    .put("appId", appId)
                    .put("pluginVersion", this.pluginVersion)
                    .put("versionBuild", versionName)
                    .put("versionCode", versionCode)
                    .put("versionOs", Build.VERSION.RELEASE)
                    // Persists across reinstalls
                    .put("deviceId", DeviceIdHelper.getOrCreateDeviceId(this.getContext(), prefs));
            this.engine = updater.createEngine(identity, WebView.CAP_SERVER_PATH);
            result = this.engine.call(
                "pluginLoad",
                new JSONObject().put("config", this.getConfig().getConfigJSON()).put("native", this.nativeInfo(versionName, versionCode))
            );
        } catch (final CapgoCore.Failure e) {
            // Invalid public key or missing appId: fail loudly, like every previous version.
            throw new RuntimeException(e.getMessage(), e);
        } catch (final JSONException e) {
            throw new IllegalStateException("Invalid plugin configuration", e);
        }
        logger.info("appId: " + result.optString("appId", appId));

        this.installWebViewStatsReporter();

        // On Android 14+ (API 34+), topActivity in RecentTaskInfo returns null due to
        // security restrictions (StrandHogg task hijacking mitigations). Use ProcessLifecycleOwner
        // for reliable app-level foreground/background detection on these versions.
        // On older versions, we use the traditional activity lifecycle callbacks in handleOnStart/handleOnStop.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            this.appLifecycleObserver = new AppLifecycleObserver(
                new AppLifecycleObserver.AppLifecycleListener() {
                    @Override
                    public void onAppMovedToForeground() {
                        CapacitorUpdaterPlugin.this.appMovedToForeground();
                    }

                    @Override
                    public void onAppMovedToBackground() {
                        CapacitorUpdaterPlugin.this.appMovedToBackground();
                    }
                },
                logger
            );
            this.appLifecycleObserver.register(this.getContext());
            if (!this.appLifecycleObserver.isRegistered()) {
                logger.warn("ProcessLifecycleOwner unavailable; using activity lifecycle callbacks");
            } else {
                logger.info("Using ProcessLifecycleOwner for foreground/background detection (Android 14+)");
            }
        } else {
            logger.info("Using activity lifecycle callbacks for foreground/background detection (Android <14)");
        }
    }

    /** Native facts for {@code pluginLoad}. */
    private JSONObject nativeInfo(final String versionName, final String versionCode) throws JSONException {
        final String serverUrl = CapConfig.loadDefault(this.getActivity()).getServerUrl();
        final JSONObject info = new JSONObject()
            .put("versionName", versionName)
            .put("versionCode", versionCode)
            .put("serverUrlConfigured", serverUrl != null && !serverUrl.isEmpty())
            .put("noBackupDir", this.getContext().getNoBackupFilesDir().getAbsolutePath())
            .put("reloadWaitsForAppReady", true)
            .put("pendingBundleMinAppReadyTimeoutMs", PENDING_BUNDLE_APP_READY_MIN_TIMEOUT_MS);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            info.put("previousExits", AndroidAppExitReporter.previousExits(this.getContext(), logger));
        }
        final Activity activity = this.getActivity();
        final Intent intent = activity == null ? null : activity.getIntent();
        if (intent != null && Intent.ACTION_VIEW.equals(intent.getAction()) && intent.getData() != null) {
            info.put("launchUrl", intent.getData().toString());
        }
        return info;
    }

    private PackageInfo getCurrentPackageInfo() throws PackageManager.NameNotFoundException {
        final PackageManager packageManager = this.getContext().getPackageManager();
        final String packageName = this.getContext().getPackageName();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0));
        }
        return packageManager.getPackageInfo(packageName, 0);
    }

    private static String getVersionCode(final PackageInfo packageInfo) {
        return Long.toString(PackageInfoCompat.getLongVersionCode(packageInfo));
    }

    private boolean ensureBridgeSet() {
        if (this.jsLoggingEnabled && this.bridge != null && this.bridge.getWebView() != null) {
            logger.setBridge(this.bridge);
            return true;
        }
        return false;
    }

    // ---- engine calls ----------------------------------------------------------------------------

    /** Runs an engine operation; failures are logged and answered with an empty object. */
    private JSONObject engineCall(final String operation, final JSONObject input) {
        final CapgoEngine engine = this.engine;
        if (engine == null) {
            return new JSONObject();
        }
        try {
            return engine.call(operation, input);
        } catch (final CapgoCore.Failure e) {
            logger.error("Engine " + operation + " failed: " + e.getMessage());
            return new JSONObject();
        }
    }

    private JSONObject engineCall(final String operation) {
        return this.engineCall(operation, new JSONObject());
    }

    /** Shake-menu channel switch, blocking: {@code {status, message, bundleId?, version?}}. */
    JSONObject switchChannelFromShakeMenu(final String channel) {
        return this.engineCall("shakeMenuSwitchChannel", CapgoCore.input("channel", channel));
    }

    /** Runs a JavaScript method in the engine, blocking: {@code {resolve: value}} or {@code {reject: {...}}}. */
    JSONObject runEngineMethod(final String name, final JSONObject args) {
        try {
            final CapgoEngine engine = this.engine;
            if (engine == null) {
                throw new CapgoCore.Failure("not_loaded", "CapacitorUpdater failed to load");
            }
            return engine.call("pluginMethod", new JSONObject().put("name", name).put("args", args == null ? new JSONObject() : args));
        } catch (final CapgoCore.Failure | JSONException e) {
            final JSONObject rejection = new JSONObject();
            try {
                rejection.put("reject", new JSONObject().put("message", e.getMessage()));
            } catch (final JSONException ignored) {
                // Constant keys.
            }
            return rejection;
        }
    }

    /** Every JavaScript method implemented by the engine: runs off the bridge thread, then settles the call. */
    private void engineMethod(final PluginCall call) {
        this.ensureBridgeSet();
        final String name = call.getMethodName();
        final JSObject args = call.getData();
        try {
            this.methodExecutor.execute(() -> settle(call, this.runEngineMethod(name, args)));
        } catch (final RejectedExecutionException e) {
            call.reject("CapacitorUpdater was destroyed");
        }
    }

    static void settle(final PluginCall call, final JSONObject result) {
        try {
            final JSONObject rejection = result.optJSONObject("reject");
            if (rejection != null) {
                final JSONObject data = rejection.optJSONObject("data");
                call.reject(
                    rejection.optString("message", "Unknown error"),
                    rejection.isNull("code") ? null : rejection.optString("code", null),
                    null,
                    data == null ? null : JSObject.fromJSONObject(data)
                );
                return;
            }
            final Object value = result.opt("resolve");
            if (value instanceof JSONObject) {
                call.resolve(JSObject.fromJSONObject((JSONObject) value));
            } else if (value == null || value == JSONObject.NULL) {
                call.resolve();
            } else {
                final JSObject wrapped = new JSObject();
                wrapped.put("value", value);
                call.resolve(wrapped);
            }
        } catch (final JSONException e) {
            call.reject("Invalid engine result: " + e.getMessage());
        }
    }

    // ---- JavaScript methods (engine) ---------------------------------------------------------------

    @PluginMethod
    public void notifyAppReady(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setUpdateUrl(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setStatsUrl(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setChannelUrl(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void download(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void next(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void set(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void startPreviewSession(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void listPreviews(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setPreview(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void resetPreview(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void deletePreview(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void checkPreviewUpdate(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void updatePreview(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void delete(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setBundleError(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void list(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void reset(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void current(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void reload(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setMultiDelay(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void cancelDelay(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void triggerUpdateCheck(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getLatest(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getMissingBundleFiles(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getBundleDownloadSize(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setChannel(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void unsetChannel(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getChannel(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void listChannels(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setCustomId(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getBuiltinVersion(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getDeviceId(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void isAutoUpdateEnabled(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void isAutoUpdateAvailable(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getNextBundle(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getFailedUpdate(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setShakeMenu(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void isShakeMenuEnabled(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setShakeChannelSelector(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void isShakeChannelSelectorEnabled(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void getAppId(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void setAppId(final PluginCall call) {
        this.engineMethod(call);
    }

    @PluginMethod
    public void reportWebViewError(final PluginCall call) {
        this.engineMethod(call);
    }

    // ---- events and hooks ------------------------------------------------------------------------

    void forwardEvent(final String event, final String payloadJson) {
        if ("statsSent".equals(event)) {
            return;
        }
        final JSObject payload;
        try {
            payload = payloadJson == null || payloadJson.isEmpty() ? new JSObject() : new JSObject(payloadJson);
        } catch (final JSONException e) {
            logger.error("Invalid payload for event " + event + ": " + e.getMessage());
            return;
        }
        // Kept for listeners registered after they fired.
        final boolean retain = "set".equals(event) || "appReady".equals(event) || "updateAvailable".equals(event);
        this.runOnMain(() -> this.notifyListeners(event, payload, retain));
    }

    String handleHook(final String name, final String payloadJson) {
        final JSONObject payload;
        try {
            payload = payloadJson == null || payloadJson.isEmpty() ? new JSONObject() : new JSONObject(payloadJson);
        } catch (final JSONException e) {
            logger.error("Invalid payload for hook " + name + ": " + e.getMessage());
            return null;
        }
        switch (name) {
            case "applyBundle":
                return this.applyBundle(
                    payload.optString("path", "public"),
                    payload.optBoolean("isBuiltin", true),
                    payload.optInt("readyGeneration", 0),
                    payload.optString("readyScript", "")
                ).toString();
            case "splash":
                if ("show".equals(payload.optString("action"))) {
                    this.showSplashscreen();
                } else {
                    this.hideSplashscreen();
                }
                return null;
            case "previewLoader":
                if ("show".equals(payload.optString("action"))) {
                    this.showPreviewTransitionLoader(payload.optString("reason", ""));
                } else {
                    this.hidePreviewTransitionLoader(payload.optString("reason", ""));
                }
                return null;
            case "previewNotice":
                return "{\"shown\":" + this.showPreviewSessionNotice(payload.optString("gesture", SHAKE_MENU_GESTURE_SHAKE)) + "}";
            case "shakeMenu":
                this.shakeMenuEnabled = payload.optBoolean("enabled", false);
                this.shakeChannelSelectorEnabled = payload.optBoolean("channelSelector", false);
                this.shakeMenuGesture = payload.optString("gesture", SHAKE_MENU_GESTURE_SHAKE);
                this.runOnMain(this::syncShakeMenuLifecycle);
                return null;
            case "shakeMenuProgress": {
                final java.util.function.Consumer<String> listener = this.shakeMenuProgressListener;
                if (listener != null) {
                    listener.accept(payload.optString("message", ""));
                }
                return null;
            }
            case "keepUrlPath":
                this.keepUrlPathAfterReload = payload.optBoolean("enabled", false);
                this.syncKeepUrlPathFlag(this.keepUrlPathAfterReload);
                return null;
            default:
                // backgroundTask, excludeFromBackup: nothing to do on Android (noBackupDir is never backed up).
                return null;
        }
    }

    private void runOnMain(final Runnable runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runnable.run();
        } else {
            this.mainHandler.post(runnable);
        }
    }

    /** Runs on the main thread and waits (bounded); {@code null} on timeout or failure. */
    private <T> T callOnMain(final Callable<T> callable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                return callable.call();
            } catch (final Exception e) {
                logger.error("Main thread operation failed: " + e.getMessage());
                return null;
            }
        }
        final AtomicReference<T> result = new AtomicReference<>();
        final CountDownLatch done = new CountDownLatch(1);
        this.mainHandler.post(() -> {
            try {
                result.set(callable.call());
            } catch (final Exception e) {
                logger.error("Main thread operation failed: " + e.getMessage());
            } finally {
                done.countDown();
            }
        });
        try {
            if (!done.await(MAIN_THREAD_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                logger.error("Timeout waiting for main thread operation");
            }
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return result.get();
    }

    // ---- WebView: apply a bundle -------------------------------------------------------------------

    /**
     * {@code applyBundle} hook: stamp the next page's ready generation (the engine's {@code readyScript}), point the
     * WebView at the bundle and reload.
     */
    private JSONObject applyBundle(final String path, final boolean usingBuiltin, final int generation, final String readyScript) {
        final JSONObject reply = new JSONObject();
        final Bridge bridge = this.bridge;
        final android.webkit.WebView webView = bridge == null ? null : bridge.getWebView();
        try {
            if (webView == null) {
                return reply.put("ok", false);
            }
            webView.post(() -> {
                if (!this.installReadyGenerationScript(webView, readyScript)) {
                    this.engineCall("readyGuardDisarm", CapgoCore.input("generation", generation));
                }
            });
            final boolean keepUrlPath = this.keepUrlPathAfterReload;
            if (keepUrlPath) {
                this.syncKeepUrlPathFlag(true);
            }
            final URL currentUrl = keepUrlPath
                ? this.callOnMain(() -> {
                      final String url = bridge.getWebView() == null ? null : bridge.getWebView().getUrl();
                      return url == null ? null : new URL(url);
                  })
                : null;

            if (currentUrl != null) {
                if (usingBuiltin) {
                    bridge.getLocalServer().hostAssets(path);
                } else {
                    bridge.getLocalServer().hostFiles(path);
                }
                try {
                    final URL appUrl = new URL(bridge.getAppUrl());
                    final URL finalUrl = new URL(appUrl.getProtocol(), appUrl.getHost(), appUrl.getPort(), currentUrl.getPath());
                    webView.post(() -> {
                        webView.loadUrl(finalUrl.toString());
                        if (!keepUrlPath) {
                            webView.clearHistory();
                        }
                    });
                } catch (final MalformedURLException e) {
                    logger.error("Cannot get finalUrl from capacitor bridge " + e.getMessage());
                    if (usingBuiltin) {
                        bridge.setServerAssetPath(path);
                    } else {
                        bridge.setServerBasePath(path);
                    }
                }
            } else {
                if (usingBuiltin) {
                    bridge.setServerAssetPath(path);
                } else {
                    bridge.setServerBasePath(path);
                }
                webView.post(() -> {
                    if (bridge.getWebView() != null) {
                        bridge.getWebView().loadUrl(bridge.getAppUrl());
                        if (!keepUrlPath) {
                            bridge.getWebView().clearHistory();
                        }
                    }
                });
            }
            return reply.put("ok", true).put("guard", true);
        } catch (final JSONException e) {
            return reply;
        } catch (final RuntimeException e) {
            logger.error("Failed to apply bundle " + path + ": " + e.getMessage());
            try {
                return new JSONObject().put("ok", false);
            } catch (final JSONException ignored) {
                return reply;
            }
        }
    }

    private boolean installReadyGenerationScript(final android.webkit.WebView webView, final String script) {
        try {
            if (script.isEmpty() || this.bridge == null || this.bridge.getAppUrl() == null) {
                return false;
            }
            return this.addDocumentStartScript(webView, script);
        } catch (final Exception e) {
            logger.warn("Unable to stamp notifyAppReady generation: " + e.getMessage());
            return false;
        }
    }

    /** {@code WebViewCompat.addDocumentStartJavaScript} through reflection (androidx.webkit is optional). */
    private boolean addDocumentStartScript(final android.webkit.WebView webView, final String script) throws Exception {
        final Class<?> webViewFeature = Class.forName("androidx.webkit.WebViewFeature");
        final String feature = (String) webViewFeature.getField("DOCUMENT_START_SCRIPT").get(null);
        final Boolean supported = (Boolean) webViewFeature.getMethod("isFeatureSupported", String.class).invoke(null, feature);
        if (!Boolean.TRUE.equals(supported)) {
            return false;
        }
        final String allowedOrigin = Uri.parse(this.bridge.getAppUrl())
            .buildUpon()
            .path(null)
            .fragment(null)
            .clearQuery()
            .build()
            .toString();
        final Class<?> webViewCompat = Class.forName("androidx.webkit.WebViewCompat");
        webViewCompat
            .getMethod("addDocumentStartJavaScript", android.webkit.WebView.class, String.class, Set.class)
            .invoke(null, webView, script, java.util.Collections.singleton(allowedOrigin));
        return true;
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
        final android.webkit.WebView webView = this.bridge.getWebView();
        webView.post(() -> webView.evaluateJavascript(script, null));
    }

    // ---- splash screen and loaders -----------------------------------------------------------------

    private void showSplashscreen() {
        this.runOnMain(() -> {
            final JSObject options = new JSObject();
            options.put("autoHide", false);
            this.invokeSplashScreenPluginMethod("show", options, SPLASH_SCREEN_MAX_RETRIES, ++this.splashscreenInvocationToken);
            this.addSplashscreenLoaderIfNeeded();
        });
    }

    private void hideSplashscreen() {
        this.runOnMain(() -> {
            this.removeSplashscreenLoader();
            this.invokeSplashScreenPluginMethod("hide", new JSObject(), SPLASH_SCREEN_MAX_RETRIES, ++this.splashscreenInvocationToken);
        });
    }

    private void invokeSplashScreenPluginMethod(
        final String methodName,
        final JSObject options,
        final int retriesRemaining,
        final int requestToken
    ) {
        if (requestToken != this.splashscreenInvocationToken) {
            return;
        }
        try {
            final Bridge bridge = getBridge();
            if (bridge == null) {
                this.retrySplashScreenInvocation(
                    methodName,
                    options,
                    retriesRemaining,
                    requestToken,
                    "Bridge not ready for " + ("show".equals(methodName) ? "showing" : "hiding") + " splashscreen"
                );
                return;
            }
            final PluginHandle splashScreenPlugin = bridge.getPlugin(SPLASH_SCREEN_PLUGIN_ID);
            if (splashScreenPlugin == null) {
                this.retrySplashScreenInvocation(
                    methodName,
                    options,
                    retriesRemaining,
                    requestToken,
                    "autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin."
                );
                return;
            }
            splashScreenPlugin.invoke(methodName, new FireAndForgetPluginCall(methodName, options));
            logger.info("Splashscreen " + methodName + " invoked automatically");
        } catch (final Exception e) {
            this.retrySplashScreenInvocation(
                methodName,
                options,
                retriesRemaining,
                requestToken,
                "Failed to call SplashScreen " + methodName + " method: " + e.getMessage()
            );
        }
    }

    private void retrySplashScreenInvocation(
        final String methodName,
        final JSObject options,
        final int retriesRemaining,
        final int requestToken,
        final String message
    ) {
        if (retriesRemaining > 0) {
            logger.info(message + ". Retrying.");
            this.mainHandler.postDelayed(
                () -> this.invokeSplashScreenPluginMethod(methodName, options, retriesRemaining - 1, requestToken),
                SPLASH_SCREEN_RETRY_DELAY_MS
            );
            return;
        }
        if ("show".equals(methodName)) {
            logger.warn(message);
        } else {
            logger.error(message);
        }
    }

    void setLoggerForTesting(final Logger logger) {
        this.logger = logger;
    }

    boolean isCurrentSplashscreenInvocationTokenForTesting(final int requestToken) {
        return requestToken == this.splashscreenInvocationToken;
    }

    private FrameLayout createLoaderOverlay(final Activity activity, final boolean blocksTouches, final int backgroundColor) {
        final ProgressBar progressBar = new ProgressBar(activity);
        progressBar.setIndeterminate(true);

        final FrameLayout overlay = new FrameLayout(activity);
        overlay.setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        overlay.setClickable(blocksTouches);
        overlay.setFocusable(blocksTouches);
        overlay.setBackgroundColor(backgroundColor);
        overlay.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);

        final FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
        params.gravity = Gravity.CENTER;
        overlay.addView(progressBar, params);
        return overlay;
    }

    private static void attachLoaderOverlay(final Activity activity, final FrameLayout overlay) {
        ((ViewGroup) activity.getWindow().getDecorView()).addView(overlay);
    }

    private static void removeLoaderOverlay(final FrameLayout overlay) {
        final ViewGroup parent = (ViewGroup) overlay.getParent();
        if (parent != null) {
            parent.removeView(overlay);
        }
    }

    /** Main thread only. */
    private void addSplashscreenLoaderIfNeeded() {
        if (!this.autoSplashscreenLoader || this.splashscreenLoaderOverlay != null) {
            return;
        }
        final Activity activity = getActivity();
        if (activity == null) {
            logger.warn("autoSplashscreen: Activity not available for loader overlay");
            return;
        }
        final FrameLayout overlay = this.createLoaderOverlay(activity, false, Color.TRANSPARENT);
        attachLoaderOverlay(activity, overlay);
        this.splashscreenLoaderOverlay = overlay;
    }

    /** Main thread only. */
    private void removeSplashscreenLoader() {
        if (this.splashscreenLoaderOverlay != null) {
            removeLoaderOverlay(this.splashscreenLoaderOverlay);
            this.splashscreenLoaderOverlay = null;
        }
    }

    private void showPreviewTransitionLoader(final String reason) {
        this.previewTransitionLoaderRequested = true;
        this.runOnMain(() -> {
            if (!this.previewTransitionLoaderRequested) {
                return;
            }
            if (this.previewTransitionLoaderOverlay != null) {
                this.schedulePreviewTransitionLoaderTimeout();
                this.previewTransitionLoaderOverlay.bringToFront();
                return;
            }
            final Activity activity = getActivity();
            if (activity == null) {
                logger.warn("Preview transition loader unavailable: activity missing for " + reason);
                this.previewTransitionLoaderRequested = false;
                return;
            }
            this.schedulePreviewTransitionLoaderTimeout();
            final FrameLayout overlay = this.createLoaderOverlay(activity, true, Color.argb(46, 0, 0, 0));
            attachLoaderOverlay(activity, overlay);
            this.previewTransitionLoaderOverlay = overlay;
            logger.info("Preview transition loader shown: " + reason);
        });
    }

    private void hidePreviewTransitionLoader(final String reason) {
        if (
            !this.previewTransitionLoaderRequested &&
            this.previewTransitionLoaderOverlay == null &&
            this.previewTransitionLoaderTimeoutRunnable == null
        ) {
            return;
        }
        this.runOnMain(() -> {
            this.previewTransitionLoaderRequested = false;
            this.cancelPreviewTransitionLoaderTimeout();
            if (this.previewTransitionLoaderOverlay == null) {
                return;
            }
            removeLoaderOverlay(this.previewTransitionLoaderOverlay);
            this.previewTransitionLoaderOverlay = null;
            logger.info("Preview transition loader hidden: " + reason);
        });
    }

    private void schedulePreviewTransitionLoaderTimeout() {
        this.cancelPreviewTransitionLoaderTimeout();
        this.previewTransitionLoaderTimeoutRunnable = () -> this.hidePreviewTransitionLoader("preview-transition-timeout");
        this.mainHandler.postDelayed(this.previewTransitionLoaderTimeoutRunnable, PREVIEW_TRANSITION_LOADER_TIMEOUT_MS);
    }

    private void cancelPreviewTransitionLoaderTimeout() {
        if (this.previewTransitionLoaderTimeoutRunnable != null) {
            this.mainHandler.removeCallbacks(this.previewTransitionLoaderTimeoutRunnable);
            this.previewTransitionLoaderTimeoutRunnable = null;
        }
    }

    /** {@code previewNotice} hook: the "Preview started" dialog; false when it could not be shown. */
    private boolean showPreviewSessionNotice(final String gesture) {
        final Boolean shown = this.callOnMain(() -> {
            final Activity activity = getActivity();
            if (activity == null || activity.isFinishing()) {
                return false;
            }
            new AlertDialog.Builder(activity)
                .setTitle("Preview started")
                .setMessage(SHAKE_MENU_GESTURE_SHAKE.equals(gesture) ? "Shake to open menu." : "Three-finger pinch to open menu.")
                .setPositiveButton("Got it", (dialog, which) -> dialog.dismiss())
                .show();
            return true;
        });
        if (!Boolean.TRUE.equals(shown)) {
            logger.warn("Could not show preview session notice");
            return false;
        }
        return true;
    }

    // ---- shake menu ---------------------------------------------------------------------------------

    /** Main thread only. */
    private void syncShakeMenuLifecycle() {
        if (this.shakeMenuEnabled || this.shakeChannelSelectorEnabled) {
            this.ensureShakeMenuStarted();
        } else if (this.shakeMenu != null) {
            try {
                this.shakeMenu.stop();
                this.shakeMenu = null;
                logger.info("Shake menu stopped");
            } catch (final Exception e) {
                logger.error("Failed to stop shake menu: " + e.getMessage());
            }
        }
    }

    private void ensureShakeMenuStarted() {
        final String gesture = this.shakeMenuGesture;
        if (this.shakeMenu != null && !this.shakeMenu.usesGesture(gesture)) {
            try {
                this.shakeMenu.stop();
                this.shakeMenu = null;
                logger.info("Shake menu restarted for " + gesture + " gesture");
            } catch (final Exception e) {
                logger.error("Failed to restart shake menu: " + e.getMessage());
                return;
            }
        }
        if (getActivity() instanceof com.getcapacitor.BridgeActivity && this.shakeMenu == null) {
            try {
                this.shakeMenu = new ShakeMenu(this, (com.getcapacitor.BridgeActivity) getActivity(), logger, gesture);
                logger.info("Shake menu initialized with " + gesture + " gesture");
            } catch (final Exception e) {
                logger.error("Failed to initialize shake menu: " + e.getMessage());
            }
        }
    }

    boolean hasActivePreviewSession() {
        return this.engineCall("previewSessionActive").optBoolean("active", false);
    }

    JSONArray previewMenuPreviews() {
        final CapgoEngine engine = this.engine;
        if (engine == null) {
            return new JSONArray();
        }
        try {
            return engine.callArray("previewMenuPreviews", new JSONObject());
        } catch (final CapgoCore.Failure e) {
            logger.error("Could not list previews: " + e.getMessage());
            return new JSONArray();
        }
    }

    /** Blocking (reloads the WebView): call from a background thread. */
    boolean setPreviewFromShakeMenu(final String id) {
        return this.engineCall("previewMenuSet", CapgoCore.input("id", id)).optBoolean("ok", false);
    }

    /** Blocking (reloads the WebView): call from a background thread. */
    boolean leavePreviewSessionFromShakeMenu() {
        return this.engineCall("previewMenuLeave").optBoolean("ok", false);
    }

    /** Blocking (reloads the WebView): call from a background thread. */
    boolean reloadPreviewSessionFromShakeMenu() {
        return this.engineCall("previewMenuReload").optBoolean("ok", false);
    }

    // ---- WebView statistics ------------------------------------------------------------------------

    private void installWebViewStatsReporter() {
        if (this.bridge == null || this.bridge.getWebView() == null || this.webViewStatsListener != null) {
            return;
        }
        final android.webkit.WebView webView = this.bridge.getWebView();
        final String script = buildWebViewStatsReporterScript();
        try {
            this.addDocumentStartScript(webView, script);
        } catch (final Exception e) {
            logger.debug("Unable to install document-start WebView stats reporter: " + e.getMessage());
        }

        this.webViewStatsListener = new WebViewListener() {
            @Override
            public void onPageStarted(final android.webkit.WebView view) {
                CapacitorUpdaterPlugin.this.webViewPageStartedAtMs = System.currentTimeMillis();
                CapacitorUpdaterPlugin.this.evaluateWebViewStatsReporterScript(view, script);
            }

            @Override
            public void onPageLoaded(final android.webkit.WebView view) {
                CapacitorUpdaterPlugin.this.reportWebViewPageLoaded(view);
                CapacitorUpdaterPlugin.this.evaluateWebViewStatsReporterScript(view, script);
            }
        };
        this.bridge.addWebViewListener(this.webViewStatsListener);
        // Keep RenderProcessGoneDetail off the Plugin class method table and off this
        // listener so Android < 8 (API 26) does not crash during plugin reflection.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            this.installWebViewRenderProcessGoneReporter();
        }
        this.evaluateWebViewStatsReporterScript(webView, script);
    }

    private void installWebViewRenderProcessGoneReporter() {
        this.bridge.addWebViewListener(
            new WebViewListener() {
                @Override
                public boolean onRenderProcessGone(final android.webkit.WebView view, final RenderProcessGoneDetail detail) {
                    CapacitorUpdaterPlugin.this.engineCall(
                        "reportRenderProcessGone",
                        CapgoCore.input("metadata", buildWebViewRenderProcessGoneMetadata(detail))
                    );
                    return false;
                }
            }
        );
    }

    private void evaluateWebViewStatsReporterScript(final android.webkit.WebView webView, final String script) {
        if (webView == null) {
            return;
        }
        this.mainHandler.post(() -> {
            try {
                webView.evaluateJavascript(script, null);
            } catch (final Exception e) {
                logger.debug("Unable to evaluate WebView stats reporter: " + e.getMessage());
            }
        });
    }

    private void reportWebViewPageLoaded(final android.webkit.WebView view) {
        final JSONObject metadata = new JSONObject();
        try {
            metadata.put("source", "android_webview_listener");
            final long pageStartedAt = this.webViewPageStartedAtMs;
            if (pageStartedAt > 0) {
                metadata.put("duration_ms", Long.toString(Math.max(0, System.currentTimeMillis() - pageStartedAt)));
                metadata.put("page_started_at", Long.toString(pageStartedAt));
            }
            final String url = view == null ? null : view.getUrl();
            if (url != null && !url.isEmpty()) {
                // The engine sanitizes and truncates URL fields (reportWebViewStats).
                metadata.put("href", url);
            }
        } catch (final JSONException ignored) {
            // Constant keys.
        }
        this.engineCall("reportWebViewStats", CapgoCore.input("action", "webview_page_loaded", "metadata", metadata));
    }

    /** Parameter typed as Object so Android < 8 ART does not resolve RenderProcessGoneDetail while reflecting this class. */
    private static JSONObject buildWebViewRenderProcessGoneMetadata(final Object detailObj) {
        final JSONObject metadata = new JSONObject();
        try {
            metadata.put("error_type", "render_process_gone");
            metadata.put("source", "android_on_render_process_gone");
            metadata.put("timestamp", Long.toString(System.currentTimeMillis()));
            if (detailObj != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                final RenderProcessGoneDetail detail = (RenderProcessGoneDetail) detailObj;
                metadata.put("did_crash", Boolean.toString(detail.didCrash()));
                metadata.put("renderer_priority_at_exit", Integer.toString(detail.rendererPriorityAtExit()));
            }
        } catch (final JSONException ignored) {
            // Constant keys.
        }
        return metadata;
    }

    static String buildWebViewStatsReporterScript() {
        return (
            "(function(){" +
            "if(window.__capgoWebViewErrorReporterInstalled){return;}" +
            "window.__capgoWebViewErrorReporterInstalled=true;" +
            "var maxReports=20,sentReports=0,queue=[],seen={};" +
            "var sessionKey='CapacitorUpdater.webViewSession';" +
            "var sessionId=String(Date.now())+'-'+Math.random().toString(36).slice(2);" +
            "function s(value){try{if(value===undefined){return '';}if(value===null){return 'null';}if(typeof value==='string'){return value;}if(value&&typeof value.message==='string'){return value.message;}return String(value);}catch(_){return '';}}" +
            "function stack(value){try{return value&&value.stack?String(value.stack):'';}catch(_){return '';}}" +
            "function updater(){var cap=window.Capacitor;if(!cap||!cap.Plugins){return null;}return cap.Plugins.CapacitorUpdater||null;}" +
            "function flush(){var plugin=updater();if(!plugin||typeof plugin.reportWebViewError!=='function'){return false;}while(queue.length){var payload=queue.shift();try{var result=plugin.reportWebViewError(payload);if(result&&typeof result.catch==='function'){result.catch(function(){});}}catch(_){}}return true;}" +
            "var retries=0;function scheduleFlush(){if(flush()){return;}if(retries++<40){setTimeout(scheduleFlush,250);}}" +
            "function send(payload){try{if(sentReports>=maxReports){return;}payload.href=payload.href||location.href||'';payload.user_agent=navigator.userAgent||'';payload.session_id=sessionId;var key=[payload.type,payload.message,payload.source,payload.line,payload.column,payload.tag_name].join('|');if(seen[key]){return;}seen[key]=true;sentReports+=1;queue.push(payload);scheduleFlush();}catch(_){}}" +
            "function readSession(){try{return JSON.parse(localStorage.getItem(sessionKey)||'null')||null;}catch(_){return null;}}" +
            "function writeSession(active){try{localStorage.setItem(sessionKey,JSON.stringify({id:sessionId,active:active,href:location.href||'',started_at:window.__capgoWebViewSessionStartedAt,updated_at:String(Date.now())}));}catch(_){}}" +
            "window.__capgoWebViewSessionStartedAt=String(Date.now());" +
            "var previous=readSession();" +
            "if(previous&&previous.active){send({type:'webview_unclean_restart',message:'WebView restarted without a clean page unload',previous_session_id:s(previous.id),previous_href:s(previous.href),previous_started_at:s(previous.started_at),previous_updated_at:s(previous.updated_at)});}" +
            "writeSession(true);" +
            "setInterval(function(){writeSession(true);},15000);" +
            "function pageDuration(){var started=Number(window.__capgoWebViewSessionStartedAt||Date.now());return String(Math.max(0,Date.now()-started));}" +
            "function markClean(){writeSession(false);}" +
            "window.addEventListener('pagehide',markClean,true);" +
            "window.addEventListener('beforeunload',markClean,true);" +
            "window.addEventListener('error',function(event){var target=event&&event.target;if(target&&target!==window&&(target.src||target.href)){send({type:'resource_error',message:'Resource failed to load',source:s(target.src||target.href),tag_name:s(target.tagName)});return;}send({type:'javascript_error',message:s((event&&event.message)||(event&&event.error)),source:s(event&&event.filename),line:s(event&&event.lineno),column:s(event&&event.colno),stack:stack(event&&event.error)});},true);" +
            "window.addEventListener('unhandledrejection',function(event){var reason=event&&event.reason;send({type:'unhandled_rejection',message:s(reason),stack:stack(reason)});},true);" +
            "document.addEventListener('securitypolicyviolation',function(event){send({type:'security_policy_violation',message:s(event&&event.violatedDirective),source:s(event&&event.blockedURI)});},true);" +
            "document.addEventListener('DOMContentLoaded',function(){send({type:'webview_dom_content_loaded',message:'WebView DOM content loaded',duration_ms:pageDuration(),page_started_at:String(window.__capgoWebViewSessionStartedAt)});},true);" +
            "document.addEventListener('deviceready',scheduleFlush,false);" +
            "setTimeout(scheduleFlush,0);" +
            "})();"
        );
    }

    // ---- lifecycle ----------------------------------------------------------------------------------

    public void appMovedToForeground() {
        this.engineCall("appForeground");
    }

    public void appMovedToBackground() {
        this.engineCall("appBackground");
    }

    /**
     * Check if the current activity is the main activity.
     * Used for activity-based foreground/background detection on Android < 14.
     * On Android 14+, topActivity returns null due to security restrictions, so we use
     * ProcessLifecycleOwner instead.
     */
    private boolean isMainActivity() {
        try {
            final Context context = this.getContext();
            final android.app.ActivityManager activityManager = (android.app.ActivityManager) context.getSystemService(
                Context.ACTIVITY_SERVICE
            );
            final java.util.List<android.app.ActivityManager.AppTask> runningTasks = activityManager.getAppTasks();
            if (runningTasks.isEmpty()) {
                return false;
            }
            final android.app.ActivityManager.RecentTaskInfo runningTask = runningTasks.get(0).getTaskInfo();
            final String className = java.util.Objects.requireNonNull(runningTask.baseIntent.getComponent()).getClassName();
            if (runningTask.topActivity == null) {
                return false;
            }
            return className.equals(runningTask.topActivity.getClassName());
        } catch (final NullPointerException e) {
            return false;
        }
    }

    private boolean isProcessLifecycleObserverActive() {
        return this.appLifecycleObserver != null && this.appLifecycleObserver.isRegistered();
    }

    @Override
    protected void handleOnNewIntent(final Intent intent) {
        super.handleOnNewIntent(intent);
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || intent.getData() == null) {
            return;
        }
        // A preview deep link while previewing: the engine restores the live bundle, then the app routes the link.
        if (this.engineCall("openUrl", CapgoCore.input("url", intent.getData().toString())).optBoolean("leavingPreview", false)) {
            if (getActivity() != null) {
                getActivity().setIntent(intent);
            }
            logger.info("Preview deeplink received while preview session is active; restoring fallback before routing");
        }
    }

    @Override
    public void handleOnStart() {
        try {
            logger.info("handleOnStart: onActivityStarted " + getActivity().getClass().getName());
            // On Android < 14, use activity lifecycle for foreground detection
            // On Android 14+, ProcessLifecycleOwner handles this via AppLifecycleObserver
            if (!this.isProcessLifecycleObserverActive()) {
                if (isPreviousMainActivity || Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    logger.info("handleOnStart: appMovedToForeground");
                    this.appMovedToForeground();
                }
                isPreviousMainActivity = true;
            }
            this.syncShakeMenuLifecycle();
        } catch (final Exception e) {
            logger.error("Failed to run handleOnStart: " + e.getMessage());
        }
    }

    @Override
    public void handleOnStop() {
        try {
            logger.info("handleOnStop: onActivityStopped");
            // On Android < 14, use activity lifecycle for background detection
            // On Android 14+, ProcessLifecycleOwner handles this via AppLifecycleObserver
            if (!this.isProcessLifecycleObserverActive()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    logger.info("handleOnStop: appMovedToBackground");
                    this.appMovedToBackground();
                } else {
                    isPreviousMainActivity = this.isMainActivity();
                    if (isPreviousMainActivity) {
                        logger.info("handleOnStop: appMovedToBackground (Android <14 path)");
                        this.appMovedToBackground();
                    }
                }
            }
        } catch (final Exception e) {
            logger.error("Failed to run handleOnStop: " + e.getMessage());
        }
    }

    @Override
    public void handleOnResume() {
        try {
            this.syncShakeMenuLifecycle();
        } catch (final Exception e) {
            logger.error("Failed to run handleOnResume: " + e.getMessage());
        }
    }

    @Override
    protected void handleOnDestroy() {
        if (installStateUpdatedListener != null && appUpdateManager != null) {
            try {
                appUpdateManager.unregisterListener(installStateUpdatedListener);
                installStateUpdatedListener = null;
            } catch (final Exception e) {
                logger.error("Failed to unregister install state listener: " + e.getMessage());
            }
        }
        try {
            logger.info("onActivityDestroyed " + getActivity().getClass().getName());
            // 'kill' delay conditions; onDestroy is not reliable, the engine also checks at the next launch.
            this.engineCall("appTerminate");
            if (shakeMenu != null) {
                try {
                    shakeMenu.stop();
                    shakeMenu = null;
                    logger.info("Shake menu cleaned up");
                } catch (final Exception e) {
                    logger.error("Failed to clean up shake menu: " + e.getMessage());
                }
            }
            if (appLifecycleObserver != null) {
                try {
                    appLifecycleObserver.unregister();
                    appLifecycleObserver = null;
                    logger.info("AppLifecycleObserver cleaned up");
                } catch (final Exception e) {
                    logger.error("Failed to clean up AppLifecycleObserver: " + e.getMessage());
                }
            }
            if (webViewStatsListener != null && bridge != null) {
                bridge.removeWebViewListener(webViewStatsListener);
                webViewStatsListener = null;
            }
        } catch (final Exception e) {
            logger.error("Failed to run handleOnDestroy: " + e.getMessage());
        }
        this.releaseEngine();
    }

    /**
     * Frees the Rust engine, which holds the host (and through it this plugin and the Activity), and stops its
     * background work (periodic checks, timers). Running calls finish first; close() runs off the main thread
     * because a running call can be waiting on a main-thread hook.
     */
    private void releaseEngine() {
        final CapgoEngine engine = this.engine;
        this.engine = null;
        this.methodExecutor.shutdown();
        if (engine != null) {
            new Thread(engine::close, "capgo-engine-close").start();
        }
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
                        PackageInfo pInfo = getCurrentPackageInfo();
                        result.put("currentVersionName", pInfo.versionName);
                        result.put("currentVersionCode", getVersionCode(pInfo));
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

            if (pendingAppUpdateCall != null) {
                call.reject("An app update flow is already in progress");
                return;
            }

            call.setKeepAlive(true);
            pendingAppUpdateCall = call;

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

            if (pendingAppUpdateCall != null) {
                call.reject("An app update flow is already in progress");
                return;
            }

            call.setKeepAlive(true);
            pendingAppUpdateCall = call;

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
            PluginCall savedCall = pendingAppUpdateCall;
            if (savedCall == null) {
                return;
            }
            pendingAppUpdateCall = null;

            JSObject result = new JSObject();
            if (resultCode == Activity.RESULT_OK) {
                result.put("code", RESULT_OK);
            } else if (resultCode == Activity.RESULT_CANCELED) {
                result.put("code", RESULT_CANCELED);
            } else {
                result.put("code", RESULT_FAILED);
            }
            savedCall.setKeepAlive(false);
            savedCall.resolve(result);
        }
    }
}
