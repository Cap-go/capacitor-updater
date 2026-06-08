/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.view.ActionMode;
import android.view.KeyEvent;
import android.view.KeyboardShortcutGroup;
import android.view.Menu;
import android.view.MenuItem;
import android.view.MotionEvent;
import android.view.SearchEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import com.getcapacitor.BridgeActivity;
import java.lang.ref.WeakReference;
import java.util.List;

public class ThreeFingerPinchDetector {

    public interface Listener {
        void onThreeFingerPinchDetected();
    }

    private static final int REQUIRED_POINTER_COUNT = 3;
    private static final float MIN_SCALE_DELTA = 0.12f;
    private static final long PINCH_TIMEOUT = 1000;

    private final Listener listener;
    private final Logger logger;
    private Window targetWindow;
    private Window.Callback previousWindowCallback;
    private Window.Callback windowCallback;
    private WeakReference<ThreeFingerPinchDetector> detectorReference;
    private float initialSpan = 0;
    private boolean tracking = false;
    private boolean triggered = false;
    private long lastPinchTime = 0;

    public ThreeFingerPinchDetector(Listener listener, Logger logger) {
        this.listener = listener;
        this.logger = logger;
    }

    public void start(BridgeActivity activity) {
        if (targetWindow != null) {
            stop();
        }

        Window window = activity.getWindow();
        if (window == null) {
            logger.warn("Three finger pinch detector could not find a target window");
            return;
        }

        this.targetWindow = window;
        this.previousWindowCallback = window.getCallback();
        this.detectorReference = new WeakReference<>(this);
        this.windowCallback = new PinchWindowCallback(this.previousWindowCallback, this.detectorReference);
        window.setCallback(this.windowCallback);
        logger.info("Three finger pinch detector installed on activity window");
    }

    public void stop() {
        if (targetWindow != null) {
            if (windowCallback instanceof PinchWindowCallback) {
                ((PinchWindowCallback) windowCallback).disable();
            }
            if (detectorReference != null) {
                detectorReference.clear();
            }
            if (targetWindow.getCallback() == windowCallback) {
                targetWindow.setCallback(previousWindowCallback);
            }
            targetWindow = null;
            previousWindowCallback = null;
            windowCallback = null;
            detectorReference = null;
        }
        reset();
    }

    private void handleTouch(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_CANCEL || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) {
            reset();
            return;
        }

        if (event.getPointerCount() != REQUIRED_POINTER_COUNT) {
            if (action == MotionEvent.ACTION_POINTER_DOWN) {
                reset();
            }
            return;
        }

        float span = calculateSpan(event);
        if (span <= 0) {
            return;
        }

        if (!tracking || action == MotionEvent.ACTION_POINTER_DOWN) {
            initialSpan = span;
            tracking = true;
            triggered = false;
            logger.info("Three finger pinch tracking started");
            return;
        }

        if (!triggered && Math.abs(span - initialSpan) / initialSpan >= MIN_SCALE_DELTA) {
            long currentTime = System.currentTimeMillis();
            if (currentTime - lastPinchTime > PINCH_TIMEOUT) {
                triggered = true;
                lastPinchTime = currentTime;
                logger.info("Three finger pinch threshold reached");
                if (listener != null) {
                    listener.onThreeFingerPinchDetected();
                }
            }
        }
    }

    private float calculateSpan(MotionEvent event) {
        float centerX = 0;
        float centerY = 0;
        for (int i = 0; i < REQUIRED_POINTER_COUNT; i++) {
            centerX += event.getX(i);
            centerY += event.getY(i);
        }
        centerX /= REQUIRED_POINTER_COUNT;
        centerY /= REQUIRED_POINTER_COUNT;

        float totalDistance = 0;
        for (int i = 0; i < REQUIRED_POINTER_COUNT; i++) {
            float dx = event.getX(i) - centerX;
            float dy = event.getY(i) - centerY;
            totalDistance += Math.sqrt(dx * dx + dy * dy);
        }
        return totalDistance / REQUIRED_POINTER_COUNT;
    }

    private void reset() {
        initialSpan = 0;
        tracking = false;
        triggered = false;
    }

    private static class PinchWindowCallback implements Window.Callback {

        private final Window.Callback delegate;
        private final WeakReference<ThreeFingerPinchDetector> detectorReference;
        private boolean enabled = true;

        PinchWindowCallback(Window.Callback delegate, WeakReference<ThreeFingerPinchDetector> detectorReference) {
            this.delegate = delegate;
            this.detectorReference = detectorReference;
        }

        void disable() {
            enabled = false;
            if (detectorReference != null) {
                detectorReference.clear();
            }
        }

        @Override
        public boolean dispatchKeyEvent(KeyEvent event) {
            return delegate != null && delegate.dispatchKeyEvent(event);
        }

        @Override
        public boolean dispatchKeyShortcutEvent(KeyEvent event) {
            return delegate != null && delegate.dispatchKeyShortcutEvent(event);
        }

        @Override
        public boolean dispatchTouchEvent(MotionEvent event) {
            boolean handled = delegate != null && delegate.dispatchTouchEvent(event);
            if (enabled) {
                ThreeFingerPinchDetector detector = detectorReference == null ? null : detectorReference.get();
                if (detector != null) {
                    detector.handleTouch(event);
                }
            }
            return handled;
        }

        @Override
        public boolean dispatchTrackballEvent(MotionEvent event) {
            return delegate != null && delegate.dispatchTrackballEvent(event);
        }

        @Override
        public boolean dispatchGenericMotionEvent(MotionEvent event) {
            return delegate != null && delegate.dispatchGenericMotionEvent(event);
        }

        @Override
        public boolean dispatchPopulateAccessibilityEvent(AccessibilityEvent event) {
            return delegate != null && delegate.dispatchPopulateAccessibilityEvent(event);
        }

        @Override
        public View onCreatePanelView(int featureId) {
            return delegate == null ? null : delegate.onCreatePanelView(featureId);
        }

        @Override
        public boolean onCreatePanelMenu(int featureId, Menu menu) {
            return delegate != null && delegate.onCreatePanelMenu(featureId, menu);
        }

        @Override
        public boolean onPreparePanel(int featureId, View view, Menu menu) {
            return delegate != null && delegate.onPreparePanel(featureId, view, menu);
        }

        @Override
        public boolean onMenuOpened(int featureId, Menu menu) {
            return delegate != null && delegate.onMenuOpened(featureId, menu);
        }

        @Override
        public boolean onMenuItemSelected(int featureId, MenuItem item) {
            return delegate != null && delegate.onMenuItemSelected(featureId, item);
        }

        @Override
        public void onWindowAttributesChanged(WindowManager.LayoutParams attrs) {
            if (delegate != null) {
                delegate.onWindowAttributesChanged(attrs);
            }
        }

        @Override
        public void onContentChanged() {
            if (delegate != null) {
                delegate.onContentChanged();
            }
        }

        @Override
        public void onWindowFocusChanged(boolean hasFocus) {
            if (delegate != null) {
                delegate.onWindowFocusChanged(hasFocus);
            }
        }

        @Override
        public void onAttachedToWindow() {
            if (delegate != null) {
                delegate.onAttachedToWindow();
            }
        }

        @Override
        public void onDetachedFromWindow() {
            if (delegate != null) {
                delegate.onDetachedFromWindow();
            }
        }

        @Override
        public void onPanelClosed(int featureId, Menu menu) {
            if (delegate != null) {
                delegate.onPanelClosed(featureId, menu);
            }
        }

        @Override
        public boolean onSearchRequested() {
            return delegate != null && delegate.onSearchRequested();
        }

        @Override
        public boolean onSearchRequested(SearchEvent searchEvent) {
            return delegate != null && delegate.onSearchRequested(searchEvent);
        }

        @Override
        public ActionMode onWindowStartingActionMode(ActionMode.Callback callback) {
            return delegate == null ? null : delegate.onWindowStartingActionMode(callback);
        }

        @Override
        public ActionMode onWindowStartingActionMode(ActionMode.Callback callback, int type) {
            return delegate == null ? null : delegate.onWindowStartingActionMode(callback, type);
        }

        @Override
        public void onActionModeStarted(ActionMode mode) {
            if (delegate != null) {
                delegate.onActionModeStarted(mode);
            }
        }

        @Override
        public void onActionModeFinished(ActionMode mode) {
            if (delegate != null) {
                delegate.onActionModeFinished(mode);
            }
        }

        @Override
        public void onProvideKeyboardShortcuts(List<KeyboardShortcutGroup> data, Menu menu, int deviceId) {
            if (delegate != null) {
                delegate.onProvideKeyboardShortcuts(data, menu, deviceId);
            }
        }

        @Override
        public void onPointerCaptureChanged(boolean hasCapture) {
            if (delegate != null) {
                delegate.onPointerCaptureChanged(hasCapture);
            }
        }
    }
}
