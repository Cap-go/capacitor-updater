/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import com.getcapacitor.Bridge;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import java.lang.ref.WeakReference;

/**
 * Manages the auto-splashscreen functionality for the CapacitorUpdater plugin.
 * Handles showing, hiding, timeout, and loader overlay for the splashscreen.
 */
public class SplashscreenManager {
    private final Logger logger;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final WeakReference<Activity> activityRef;
    private final BridgeProvider bridgeProvider;

    // Configuration
    private boolean autoSplashscreenEnabled = false;
    private boolean autoSplashscreenLoaderEnabled = false;
    private int autoSplashscreenTimeout = 10000;

    // State
    private FrameLayout splashscreenLoaderOverlay;
    private Runnable splashscreenTimeoutRunnable;
    private volatile boolean hasTimedOut = false;

    // Callback for timeout events
    private TimeoutCallback timeoutCallback;

    /**
     * Interface to provide the bridge (for plugin access)
     */
    public interface BridgeProvider {
        Bridge getBridge();
    }

    /**
     * Interface for timeout callbacks
     */
    public interface TimeoutCallback {
        void onSplashscreenTimeout();
    }

    public SplashscreenManager(Logger logger, Activity activity, BridgeProvider bridgeProvider) {
        this.logger = logger;
        this.activityRef = new WeakReference<>(activity);
        this.bridgeProvider = bridgeProvider;
    }

    /**
     * Configure the splashscreen manager with the given settings
     */
    public void configure(boolean enabled, boolean loaderEnabled, int timeout) {
        this.autoSplashscreenEnabled = enabled;
        this.autoSplashscreenLoaderEnabled = loaderEnabled;
        this.autoSplashscreenTimeout = Math.max(0, timeout);
    }

    /**
     * Set the timeout callback
     */
    public void setTimeoutCallback(TimeoutCallback callback) {
        this.timeoutCallback = callback;
    }

    /**
     * Returns whether auto-splashscreen is enabled
     */
    public boolean isEnabled() {
        return autoSplashscreenEnabled;
    }

    /**
     * Returns whether splashscreen has timed out
     */
    public boolean hasTimedOut() {
        return hasTimedOut;
    }

    /**
     * Reset timeout state (called when entering background)
     */
    public void resetTimeoutState() {
        hasTimedOut = false;
    }

    /**
     * Show the splashscreen
     */
    public void show() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            showSplashscreenNow();
        } else {
            mainHandler.post(this::showSplashscreenNow);
        }
    }

    /**
     * Hide the splashscreen
     */
    public void hide() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            hideSplashscreenInternal();
        } else {
            mainHandler.post(this::hideSplashscreenInternal);
        }
    }

    private void showSplashscreenNow() {
        cancelSplashscreenTimeout();
        hasTimedOut = false;

        try {
            Bridge bridge = bridgeProvider.getBridge();
            if (bridge == null) {
                logger.warn("Bridge not ready for showing splashscreen with autoSplashscreen");
            } else {
                PluginHandle splashScreenPlugin = bridge.getPlugin("SplashScreen");
                if (splashScreenPlugin != null) {
                    try {
                        JSObject options = new JSObject();
                        java.lang.reflect.Field msgHandlerField = bridge.getClass().getDeclaredField("msgHandler");
                        msgHandlerField.setAccessible(true);
                        Object msgHandler = msgHandlerField.get(bridge);

                        PluginCall call = new PluginCall(
                            (com.getcapacitor.MessageHandler) msgHandler,
                            "SplashScreen",
                            "FAKE_CALLBACK_ID_SHOW",
                            "show",
                            options
                        );

                        splashScreenPlugin.invoke("show", call);
                        logger.info("Splashscreen shown synchronously to prevent flash");
                    } catch (Exception e) {
                        logger.error("Failed to call SplashScreen show method: " + e.getMessage());
                    }
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

    private void hideSplashscreenInternal() {
        cancelSplashscreenTimeout();
        removeSplashscreenLoader();

        try {
            Bridge bridge = bridgeProvider.getBridge();
            if (bridge == null) {
                logger.warn("Bridge not ready for hiding splashscreen with autoSplashscreen");
                return;
            }

            // Try to call the SplashScreen plugin directly through the bridge
            PluginHandle splashScreenPlugin = bridge.getPlugin("SplashScreen");
            if (splashScreenPlugin != null) {
                try {
                    // Create a plugin call for the hide method using reflection to access private msgHandler
                    JSObject options = new JSObject();
                    java.lang.reflect.Field msgHandlerField = bridge.getClass().getDeclaredField("msgHandler");
                    msgHandlerField.setAccessible(true);
                    Object msgHandler = msgHandlerField.get(bridge);

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

    private void addSplashscreenLoaderIfNeeded() {
        if (!autoSplashscreenLoaderEnabled) {
            return;
        }

        Runnable addLoader = () -> {
            if (splashscreenLoaderOverlay != null) {
                return;
            }

            Activity activity = activityRef.get();
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

            splashscreenLoaderOverlay = overlay;
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            addLoader.run();
        } else {
            mainHandler.post(addLoader);
        }
    }

    private void removeSplashscreenLoader() {
        Runnable removeLoader = () -> {
            if (splashscreenLoaderOverlay != null) {
                ViewGroup parent = (ViewGroup) splashscreenLoaderOverlay.getParent();
                if (parent != null) {
                    parent.removeView(splashscreenLoaderOverlay);
                }
                splashscreenLoaderOverlay = null;
            }
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            removeLoader.run();
        } else {
            mainHandler.post(removeLoader);
        }
    }

    private void scheduleSplashscreenTimeout() {
        if (autoSplashscreenTimeout <= 0) {
            return;
        }

        cancelSplashscreenTimeout();

        splashscreenTimeoutRunnable = () -> {
            logger.info("autoSplashscreen timeout reached, hiding splashscreen");
            hasTimedOut = true;
            if (timeoutCallback != null) {
                timeoutCallback.onSplashscreenTimeout();
            }
            hide();
        };

        mainHandler.postDelayed(splashscreenTimeoutRunnable, autoSplashscreenTimeout);
    }

    private void cancelSplashscreenTimeout() {
        if (splashscreenTimeoutRunnable != null) {
            mainHandler.removeCallbacks(splashscreenTimeoutRunnable);
            splashscreenTimeoutRunnable = null;
        }
    }
}
