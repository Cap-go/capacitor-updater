/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import androidx.annotation.NonNull;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.ProcessLifecycleOwner;

/**
 * Observes app-level lifecycle events using ProcessLifecycleOwner.
 * This provides reliable detection of when the entire app (not just an activity)
 * moves to foreground or background.
 *
 * Unlike activity lifecycle callbacks, this won't trigger false positives when:
 * - Opening a native camera view
 * - Opening share sheets
 * - Any other native activity overlays within the app
 *
 * The ON_STOP event is dispatched with a ~700ms delay after the last activity
 * passes through onStop(), which helps avoid false triggers during configuration
 * changes or quick activity transitions.
 */
public class AppLifecycleObserver implements DefaultLifecycleObserver {

    public interface AppLifecycleListener {
        void onAppMovedToForeground();
        void onAppMovedToBackground();
    }

    private final AppLifecycleListener listener;
    private final Logger logger;
    private boolean isRegistered = false;

    public AppLifecycleObserver(AppLifecycleListener listener, Logger logger) {
        this.listener = listener;
        this.logger = logger;
    }

    public void register() {
        if (isRegistered) {
            return;
        }
        try {
            ProcessLifecycleOwner.get().getLifecycle().addObserver(this);
            isRegistered = true;
            logger.info("AppLifecycleObserver registered with ProcessLifecycleOwner");
        } catch (Exception e) {
            logger.error("Failed to register AppLifecycleObserver: " + e.getMessage());
        }
    }

    public void unregister() {
        if (!isRegistered) {
            return;
        }
        try {
            ProcessLifecycleOwner.get().getLifecycle().removeObserver(this);
            isRegistered = false;
            logger.info("AppLifecycleObserver unregistered from ProcessLifecycleOwner");
        } catch (Exception e) {
            logger.error("Failed to unregister AppLifecycleObserver: " + e.getMessage());
        }
    }

    @Override
    public void onStart(@NonNull LifecycleOwner owner) {
        // App moved to foreground (at least one activity is visible)
        logger.info("ProcessLifecycleOwner: App moved to foreground");
        if (listener != null) {
            listener.onAppMovedToForeground();
        }
    }

    @Override
    public void onStop(@NonNull LifecycleOwner owner) {
        // App moved to background (no activities are visible)
        // Note: This is called with a ~700ms delay to avoid false triggers
        logger.info("ProcessLifecycleOwner: App moved to background");
        if (listener != null) {
            listener.onAppMovedToBackground();
        }
    }
}
