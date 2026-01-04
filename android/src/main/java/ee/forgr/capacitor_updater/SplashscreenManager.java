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

/**
 * Callback interface for splashscreen manager events
 */
interface SplashscreenManagerDelegate {
    /**
     * Get the Capacitor bridge
     */
    Bridge getSplashscreenBridge();

    /**
     * Get the current activity
     */
    Activity getSplashscreenActivity();

    /**
     * Called when splashscreen timeout occurs
     */
    void onSplashscreenTimeout();
}

/**
 * Manages auto splashscreen functionality
 * Handles showing/hiding splashscreen and loader overlay
 */
public class SplashscreenManager {
    private final CapgoLogger logger;
    private final int timeout;
    private final boolean loaderEnabled;
    private final SplashscreenManagerDelegate delegate;
    private final Handler mainHandler;

    private FrameLayout loaderOverlay;
    private Runnable timeoutRunnable;
    private boolean timedOut = false;

    /**
     * Whether the splashscreen has timed out
     */
    public boolean hasTimedOut() {
        return timedOut;
    }

    public SplashscreenManager(
            CapgoLogger logger,
            int timeout,
            boolean loaderEnabled,
            SplashscreenManagerDelegate delegate,
            Handler mainHandler
    ) {
        this.logger = logger;
        this.timeout = timeout;
        this.loaderEnabled = loaderEnabled;
        this.delegate = delegate;
        this.mainHandler = mainHandler;
    }

    // MARK: - Public Methods

    /**
     * Hide the splashscreen
     */
    public void hide() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            hideInternal();
        } else {
            mainHandler.post(this::hideInternal);
        }
    }

    /**
     * Show the splashscreen
     */
    public void show() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            showInternal();
        } else {
            mainHandler.post(this::showInternal);
        }
    }

    /**
     * Reset timeout state (call before showing splashscreen)
     */
    public void resetTimeoutState() {
        timedOut = false;
    }

    // MARK: - Private Methods

    private void hideInternal() {
        cancelTimeout();
        removeLoader();

        try {
            Bridge bridge = delegate.getSplashscreenBridge();
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

    private void showInternal() {
        cancelTimeout();
        timedOut = false;

        try {
            Bridge bridge = delegate.getSplashscreenBridge();
            if (bridge == null) {
                logger.warn("Bridge not ready for showing splashscreen with autoSplashscreen");
            } else {
                PluginHandle splashScreenPlugin = bridge.getPlugin("SplashScreen");
                if (splashScreenPlugin != null) {
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
                } else {
                    logger.warn("autoSplashscreen: SplashScreen plugin not found");
                }
            }
        } catch (Exception e) {
            logger.error("Failed to show splashscreen synchronously: " + e.getMessage());
        }

        addLoaderIfNeeded();
        scheduleTimeout();
    }

    // MARK: - Loader Management

    private void addLoaderIfNeeded() {
        if (!loaderEnabled) {
            return;
        }

        Runnable addLoader = () -> {
            if (loaderOverlay != null) {
                return;
            }

            Activity activity = delegate.getSplashscreenActivity();
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

            loaderOverlay = overlay;
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            addLoader.run();
        } else {
            mainHandler.post(addLoader);
        }
    }

    private void removeLoader() {
        Runnable removeLoader = () -> {
            if (loaderOverlay != null) {
                ViewGroup parent = (ViewGroup) loaderOverlay.getParent();
                if (parent != null) {
                    parent.removeView(loaderOverlay);
                }
                loaderOverlay = null;
            }
        };

        if (Looper.myLooper() == Looper.getMainLooper()) {
            removeLoader.run();
        } else {
            mainHandler.post(removeLoader);
        }
    }

    // MARK: - Timeout Management

    private void scheduleTimeout() {
        if (timeout <= 0) {
            return;
        }

        cancelTimeout();

        timeoutRunnable = () -> {
            logger.info("autoSplashscreen timeout reached, hiding splashscreen");
            timedOut = true;
            delegate.onSplashscreenTimeout();
            hide();
        };

        mainHandler.postDelayed(timeoutRunnable, timeout);
    }

    private void cancelTimeout() {
        if (timeoutRunnable != null) {
            mainHandler.removeCallbacks(timeoutRunnable);
            timeoutRunnable = null;
        }
    }
}
