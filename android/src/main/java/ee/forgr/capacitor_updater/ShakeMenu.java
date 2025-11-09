/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.hardware.SensorManager;
import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;

public class ShakeMenu implements ShakeDetector.Listener {

    private CapacitorUpdaterPlugin plugin;
    private BridgeActivity activity;
    private ShakeDetector shakeDetector;
    private boolean isShowing = false;
    private Logger logger;

    public ShakeMenu(CapacitorUpdaterPlugin plugin, BridgeActivity activity, Logger logger) {
        this.plugin = plugin;
        this.activity = activity;
        this.logger = logger;

        SensorManager sensorManager = (SensorManager) activity.getSystemService(Activity.SENSOR_SERVICE);
        this.shakeDetector = new ShakeDetector(this);
        this.shakeDetector.start(sensorManager);
    }

    public void stop() {
        if (shakeDetector != null) {
            shakeDetector.stop();
        }
    }

    @Override
    public void onShakeDetected() {
        logger.info("Shake detected");

        // Check if shake menu is enabled
        if (!plugin.shakeMenuEnabled) {
            logger.info("Shake menu is disabled");
            return;
        }

        // Prevent multiple dialogs
        if (isShowing) {
            logger.info("Dialog already showing");
            return;
        }

        isShowing = true;
        showShakeMenu();
    }

    private void showShakeMenu() {
        activity.runOnUiThread(() -> {
            try {
                String appName = activity.getPackageManager().getApplicationLabel(activity.getApplicationInfo()).toString();
                String title = "Preview " + appName + " Menu";
                String message = "What would you like to do?";
                String okButtonTitle = "Go Home";
                String reloadButtonTitle = "Reload app";
                String cancelButtonTitle = "Close menu";

                CapgoUpdater updater = plugin.implementation;
                Bridge bridge = activity.getBridge();

                AlertDialog.Builder builder = new AlertDialog.Builder(activity);
                builder.setTitle(title);
                builder.setMessage(message);

                // Go Home button
                builder.setPositiveButton(
                    okButtonTitle,
                    new DialogInterface.OnClickListener() {
                        public void onClick(DialogInterface dialog, int id) {
                            try {
                                BundleInfo current = updater.getCurrentBundle();
                                logger.info("Current bundle: " + current.toString());

                                BundleInfo next = updater.getNextBundle();
                                logger.info("Next bundle: " + (next != null ? next.toString() : "null"));

                                if (next != null && !next.isBuiltin()) {
                                    logger.info("Setting bundle to: " + next.toString());
                                    updater.set(next);
                                    String path = updater.getCurrentBundlePath();
                                    logger.info("Setting server path: " + path);
                                    if (updater.isUsingBuiltin()) {
                                        bridge.setServerAssetPath(path);
                                    } else {
                                        bridge.setServerBasePath(path);
                                    }
                                } else {
                                    logger.info("Resetting to builtin");
                                    updater.reset();
                                    String path = updater.getCurrentBundlePath();
                                    bridge.setServerAssetPath(path);
                                }

                                // Try to delete the current bundle
                                try {
                                    updater.delete(current.getId());
                                } catch (Exception err) {
                                    logger.warn("Cannot delete version " + current.getId() + ": " + err.getMessage());
                                }

                                logger.info("Reload app done");
                            } catch (Exception e) {
                                logger.error("Error in Go Home action: " + e.getMessage());
                            } finally {
                                dialog.dismiss();
                                isShowing = false;
                            }
                        }
                    }
                );

                // Reload button
                builder.setNeutralButton(
                    reloadButtonTitle,
                    new DialogInterface.OnClickListener() {
                        public void onClick(DialogInterface dialog, int id) {
                            try {
                                logger.info("Reloading webview");
                                String pathHot = updater.getCurrentBundlePath();
                                bridge.setServerBasePath(pathHot);
                                activity.runOnUiThread(() -> {
                                    if (bridge.getWebView() != null) {
                                        bridge.getWebView().reload();
                                    }
                                });
                            } catch (Exception e) {
                                logger.error("Error in Reload action: " + e.getMessage());
                            } finally {
                                dialog.dismiss();
                                isShowing = false;
                            }
                        }
                    }
                );

                // Cancel button
                builder.setNegativeButton(
                    cancelButtonTitle,
                    new DialogInterface.OnClickListener() {
                        public void onClick(DialogInterface dialog, int id) {
                            logger.info("Shake menu cancelled");
                            dialog.dismiss();
                            isShowing = false;
                        }
                    }
                );

                AlertDialog dialog = builder.create();
                dialog.setOnDismissListener(dialogInterface -> isShowing = false);
                dialog.show();
            } catch (Exception e) {
                logger.error("Error showing shake menu: " + e.getMessage());
                isShowing = false;
            }
        });
    }
}
