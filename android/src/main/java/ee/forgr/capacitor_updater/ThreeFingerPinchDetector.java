/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.view.MotionEvent;
import android.view.View;
import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;

public class ThreeFingerPinchDetector implements View.OnTouchListener {

    public interface Listener {
        void onThreeFingerPinchDetected();
    }

    private static final int REQUIRED_POINTER_COUNT = 3;
    private static final float MIN_SCALE_DELTA = 0.30f;
    private static final long PINCH_TIMEOUT = 1000;

    private final Listener listener;
    private final Logger logger;
    private View targetView;
    private float initialSpan = 0;
    private boolean tracking = false;
    private boolean triggered = false;
    private long lastPinchTime = 0;

    public ThreeFingerPinchDetector(Listener listener, Logger logger) {
        this.listener = listener;
        this.logger = logger;
    }

    public void start(BridgeActivity activity) {
        View view = null;
        Bridge bridge = activity.getBridge();
        if (bridge != null && bridge.getWebView() != null) {
            view = bridge.getWebView();
        }
        if (view == null && activity.getWindow() != null) {
            view = activity.getWindow().getDecorView().getRootView();
        }
        if (view == null) {
            logger.warn("Three finger pinch detector could not find a target view");
            return;
        }

        this.targetView = view;
        this.targetView.setOnTouchListener(this);
    }

    public void stop() {
        if (targetView != null) {
            targetView.setOnTouchListener(null);
            targetView = null;
        }
        reset();
    }

    @Override
    public boolean onTouch(View view, MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_CANCEL || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) {
            reset();
            return false;
        }

        if (event.getPointerCount() != REQUIRED_POINTER_COUNT) {
            if (action == MotionEvent.ACTION_POINTER_DOWN) {
                reset();
            }
            return false;
        }

        float span = calculateSpan(event);
        if (span <= 0) {
            return false;
        }

        if (!tracking || action == MotionEvent.ACTION_POINTER_DOWN) {
            initialSpan = span;
            tracking = true;
            triggered = false;
            return false;
        }

        if (!triggered && Math.abs(span - initialSpan) / initialSpan >= MIN_SCALE_DELTA) {
            long currentTime = System.currentTimeMillis();
            if (currentTime - lastPinchTime > PINCH_TIMEOUT) {
                triggered = true;
                lastPinchTime = currentTime;
                if (listener != null) {
                    listener.onThreeFingerPinchDetected();
                }
            }
        }

        return false;
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
}
