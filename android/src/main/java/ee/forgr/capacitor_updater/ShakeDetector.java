/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;

public class ShakeDetector implements SensorEventListener {
    
    public interface Listener {
        void onShakeDetected();
    }
    
    private static final float SHAKE_THRESHOLD = 12.0f; // Acceleration threshold for shake detection
    private static final int SHAKE_TIMEOUT = 500; // Minimum time between shake events (ms)
    
    private Listener listener;
    private SensorManager sensorManager;
    private Sensor accelerometer;
    private long lastShakeTime = 0;
    
    public ShakeDetector(Listener listener) {
        this.listener = listener;
    }
    
    public void start(SensorManager sensorManager) {
        this.sensorManager = sensorManager;
        this.accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        
        if (accelerometer != null) {
            sensorManager.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME);
        }
    }
    
    public void stop() {
        if (sensorManager != null) {
            sensorManager.unregisterListener(this);
        }
    }
    
    @Override
    public void onSensorChanged(SensorEvent event) {
        if (event.sensor.getType() == Sensor.TYPE_ACCELEROMETER) {
            float x = event.values[0];
            float y = event.values[1];
            float z = event.values[2];
            
            // Calculate the acceleration magnitude (excluding gravity)
            float acceleration = (float) Math.sqrt(x * x + y * y + z * z) - SensorManager.GRAVITY_EARTH;
            
            // Check if acceleration exceeds threshold and enough time has passed
            long currentTime = System.currentTimeMillis();
            if (Math.abs(acceleration) > SHAKE_THRESHOLD && 
                currentTime - lastShakeTime > SHAKE_TIMEOUT) {
                lastShakeTime = currentTime;
                if (listener != null) {
                    listener.onShakeDetected();
                }
            }
        }
    }
    
    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
        // Not needed for shake detection
    }
} 
