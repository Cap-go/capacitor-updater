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
 * Manages auto splashscreen functionality.
 * Handles showing/hiding splashscreen and loader overlay.
 *
 * <p><b>IMPORTANT: Capacitor Version Dependency</b></p>
 * <p>This class uses reflection to access the private {@code msgHandler} field from
 * Capacitor's Bridge class in order to invoke SplashScreen plugin methods directly
 * from native code. This is necessary because Capacitor does not expose a public API
 * for invoking plugin methods from native code without JavaScript involvement.</p>
 *
 * <p><b>Tested with:</b> Capacitor 6.x, 7.x</p>
 *
 * <p>If Capacitor changes its internal implementation in future versions, the
 * reflection-based approach may fail. In such cases, the splashscreen operations
 * will fail gracefully with a warning logged, and the app will continue to function
 * (just without automatic splashscreen management).</p>
 *
 * <p>Alternative approaches considered but not implemented:</p>
 * <ul>
 *   <li>Using Bridge.triggerJSEvent() - requires JavaScript to be loaded first</li>
 *   <li>Direct plugin instance access - PluginHandle doesn't expose plugin methods</li>
 *   <li>Bridge.saveCall/getSavedCall - designed for async callbacks, not synchronous invocation</li>
 * </ul>
 */
public class SplashscreenManager {

    private final Logger logger;
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
        Logger logger,
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

    /**
     * Invokes a SplashScreen plugin method via reflection.
     *
     * <p>This method uses reflection to access Capacitor's private {@code msgHandler}
     * field to create a PluginCall. This is fragile and may break with future
     * Capacitor versions, but it's the only way to invoke plugin methods
     * synchronously from native code.</p>
     *
     * @param bridge The Capacitor bridge
     * @param methodName The plugin method to invoke ("show" or "hide")
     * @return true if the method was invoked successfully, false otherwise
     */
    private boolean invokeSplashScreenMethod(Bridge bridge, String methodName) {
        PluginHandle splashScreenPlugin = bridge.getPlugin("SplashScreen");
        if (splashScreenPlugin == null) {
            logger.warn("autoSplashscreen: SplashScreen plugin not found. Install @capacitor/splash-screen plugin.");
            return false;
        }

        try {
            // FRAGILE: Uses reflection to access private msgHandler field.
            // Tested with Capacitor 6.x and 7.x. If this fails in future versions,
            // the app will continue to work but without automatic splashscreen management.
            JSObject options = new JSObject();
            java.lang.reflect.Field msgHandlerField = bridge.getClass().getDeclaredField("msgHandler");
            msgHandlerField.setAccessible(true);
            Object msgHandler = msgHandlerField.get(bridge);

            PluginCall call = new PluginCall(
                (com.getcapacitor.MessageHandler) msgHandler,
                "SplashScreen",
                "FAKE_CALLBACK_ID_" + methodName.toUpperCase(),
                methodName,
                options
            );

            splashScreenPlugin.invoke(methodName, call);
            return true;
        } catch (NoSuchFieldException e) {
            // Capacitor internals have changed - msgHandler field no longer exists
            logger.error(
                "autoSplashscreen: Capacitor version incompatibility - 'msgHandler' field not found. " +
                    "This plugin may need to be updated for your Capacitor version."
            );
            return false;
        } catch (ClassCastException e) {
            // Capacitor internals have changed - msgHandler type has changed
            logger.error(
                "autoSplashscreen: Capacitor version incompatibility - MessageHandler type mismatch. " +
                    "This plugin may need to be updated for your Capacitor version."
            );
            return false;
        } catch (Exception e) {
            logger.error("autoSplashscreen: Failed to invoke SplashScreen." + methodName + ": " + e.getMessage());
            return false;
        }
    }

    private void hideInternal() {
        cancelTimeout();
        removeLoader();

        Bridge bridge = delegate.getSplashscreenBridge();
        if (bridge == null) {
            logger.warn("Bridge not ready for hiding splashscreen with autoSplashscreen");
            return;
        }

        if (invokeSplashScreenMethod(bridge, "hide")) {
            logger.info("Splashscreen hidden automatically");
        }
    }

    private void showInternal() {
        cancelTimeout();
        timedOut = false;

        Bridge bridge = delegate.getSplashscreenBridge();
        if (bridge != null) {
            if (invokeSplashScreenMethod(bridge, "show")) {
                logger.info("Splashscreen shown synchronously to prevent flash");
            }
        } else {
            logger.warn("Bridge not ready for showing splashscreen with autoSplashscreen");
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
