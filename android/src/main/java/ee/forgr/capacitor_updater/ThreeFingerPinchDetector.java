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
import java.lang.reflect.Field;

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
    private View.OnTouchListener previousOnTouchListener;
    private boolean touchListenerInstalled = false;
    private float initialSpan = 0;
    private boolean tracking = false;
    private boolean triggered = false;
    private long lastPinchTime = 0;

    public ThreeFingerPinchDetector(Listener listener, Logger logger) {
        this.listener = listener;
        this.logger = logger;
    }

    public void start(BridgeActivity activity) {
        if (targetView != null) {
            stop();
        }

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
        this.previousOnTouchListener = getCurrentOnTouchListener(view);
        if (this.previousOnTouchListener != this) {
            this.targetView.setOnTouchListener(this);
            this.touchListenerInstalled = true;
        }
    }

    public void stop() {
        if (targetView != null) {
            View.OnTouchListener currentOnTouchListener = getCurrentOnTouchListener(targetView);
            if (touchListenerInstalled && (currentOnTouchListener == this || currentOnTouchListener == null)) {
                targetView.setOnTouchListener(previousOnTouchListener);
            }
            targetView = null;
            previousOnTouchListener = null;
            touchListenerInstalled = false;
        }
        reset();
    }

    @Override
    public boolean onTouch(View view, MotionEvent event) {
        boolean consumedByPreviousListener = false;
        if (previousOnTouchListener != null && previousOnTouchListener != this) {
            consumedByPreviousListener = previousOnTouchListener.onTouch(view, event);
        }

        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_CANCEL || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) {
            reset();
            return consumedByPreviousListener;
        }

        if (event.getPointerCount() != REQUIRED_POINTER_COUNT) {
            if (action == MotionEvent.ACTION_POINTER_DOWN) {
                reset();
            }
            return consumedByPreviousListener;
        }

        float span = calculateSpan(event);
        if (span <= 0) {
            return consumedByPreviousListener;
        }

        if (!tracking || action == MotionEvent.ACTION_POINTER_DOWN) {
            initialSpan = span;
            tracking = true;
            triggered = false;
            return consumedByPreviousListener;
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

        return consumedByPreviousListener;
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

    private View.OnTouchListener getCurrentOnTouchListener(View view) {
        try {
            Field listenerInfoField = View.class.getDeclaredField("mListenerInfo");
            listenerInfoField.setAccessible(true);
            Object listenerInfo = listenerInfoField.get(view);
            if (listenerInfo == null) {
                return null;
            }
            Field onTouchListenerField = listenerInfo.getClass().getDeclaredField("mOnTouchListener");
            onTouchListenerField.setAccessible(true);
            Object listener = onTouchListenerField.get(listenerInfo);
            if (listener instanceof View.OnTouchListener) {
                return (View.OnTouchListener) listener;
            }
        } catch (ReflectiveOperationException | RuntimeException exception) {
            logger.warn("Three finger pinch detector could not inspect the current touch listener: " + exception.getMessage());
        }
        return null;
    }

    private void reset() {
        initialSpan = 0;
        tracking = false;
        triggered = false;
    }
}
