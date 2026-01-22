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
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;

import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;

import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

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

        // Check if channel selector mode is enabled
        if (plugin.shakeChannelSelectorEnabled) {
            showChannelSelector();
        } else {
            showDefaultMenu();
        }
    }

    private void showDefaultMenu() {
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
                dialog.setOnDismissListener((dialogInterface) -> isShowing = false);
                dialog.show();
            } catch (Exception e) {
                logger.error("Error showing shake menu: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private void showChannelSelector() {
        activity.runOnUiThread(() -> {
            try {
                // Show loading dialog
                AlertDialog.Builder loadingBuilder = new AlertDialog.Builder(activity);
                loadingBuilder.setTitle("Loading Channels...");
                loadingBuilder.setCancelable(true);

                ProgressBar progressBar = new ProgressBar(activity);
                progressBar.setIndeterminate(true);
                int padding = dpToPx(20);
                progressBar.setPadding(padding, padding, padding, padding);
                loadingBuilder.setView(progressBar);

                loadingBuilder.setNegativeButton("Cancel", (dialog, which) -> {
                    dialog.dismiss();
                    isShowing = false;
                });

                AlertDialog loadingDialog = loadingBuilder.create();
                loadingDialog.setOnDismissListener((d) -> {
                    // Only reset isShowing if we're still showing the loading dialog
                    // (not if we dismissed it to show the channel picker)
                });
                loadingDialog.show();

                // Fetch channels in background
                new Thread(() -> {
                    final CapgoUpdater updater = plugin.implementation;
                    final ListChannels result = updater.listChannels();

                    activity.runOnUiThread(() -> {
                        loadingDialog.dismiss();

                        if (!result.error.isEmpty()) {
                            showError("Failed to load channels: " + result.error);
                            return;
                        }

                        if (result.channels == null || result.channels.isEmpty()) {
                            showError("No channels available for self-assignment");
                            return;
                        }

                        presentChannelPicker(result.channels);
                    });
                }).start();
            } catch (Exception e) {
                logger.error("Error showing channel selector: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private void presentChannelPicker(List<Map<String, Object>> channels) {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(activity);
            builder.setTitle("Select Channel");

            // Create custom layout with search and channel list
            LinearLayout layout = new LinearLayout(activity);
            layout.setOrientation(LinearLayout.VERTICAL);
            int padding = dpToPx(16);
            layout.setPadding(padding, padding, padding, padding);

            // Search field
            EditText searchField = new EditText(activity);
            searchField.setHint("Search channels...");
            searchField.setSingleLine(true);
            layout.addView(searchField);

            // Create list of channel names
            List<String> allChannelNames = new ArrayList<>();
            for (Map<String, Object> channel : channels) {
                String name = (String) channel.get("name");
                if (name != null) {
                    allChannelNames.add(name);
                }
            }

            // Displayed channels (first 5 by default)
            final List<String> displayedChannels = new ArrayList<>();
            displayedChannels.addAll(allChannelNames.subList(0, Math.min(5, allChannelNames.size())));

            final ArrayAdapter<String> adapter = new ArrayAdapter<>(
                activity,
                android.R.layout.simple_list_item_1,
                displayedChannels
            );

            ListView listView = new ListView(activity);
            listView.setAdapter(adapter);

            // Set fixed height for list (about 5 items)
            LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dpToPx(250)
            );
            listView.setLayoutParams(listParams);
            layout.addView(listView);

            builder.setView(layout);
            builder.setNegativeButton("Cancel", (dialog, which) -> {
                dialog.dismiss();
                isShowing = false;
            });

            AlertDialog dialog = builder.create();
            dialog.setOnDismissListener((d) -> isShowing = false);

            // Search filter
            searchField.addTextChangedListener(new TextWatcher() {
                @Override
                public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

                @Override
                public void onTextChanged(CharSequence s, int start, int before, int count) {}

                @Override
                public void afterTextChanged(Editable s) {
                    String query = s.toString().toLowerCase();
                    displayedChannels.clear();

                    int count = 0;
                    for (String name : allChannelNames) {
                        if (name.toLowerCase().contains(query)) {
                            displayedChannels.add(name);
                            count++;
                            if (count >= 5) break;
                        }
                    }

                    adapter.notifyDataSetChanged();
                }
            });

            // Channel selection
            listView.setOnItemClickListener((parent, view, position, id) -> {
                String selectedChannel = displayedChannels.get(position);
                dialog.dismiss();
                selectChannel(selectedChannel);
            });

            dialog.show();
        } catch (Exception e) {
            logger.error("Error presenting channel picker: " + e.getMessage());
            isShowing = false;
        }
    }

    private void selectChannel(String channelName) {
        activity.runOnUiThread(() -> {
            try {
                // Show progress dialog
                AlertDialog.Builder progressBuilder = new AlertDialog.Builder(activity);
                progressBuilder.setTitle("Switching to " + channelName);
                progressBuilder.setMessage("Setting channel...");
                progressBuilder.setCancelable(false);

                ProgressBar progressBar = new ProgressBar(activity);
                progressBar.setIndeterminate(true);
                int padding = dpToPx(20);
                progressBar.setPadding(padding, padding, padding, padding);
                progressBuilder.setView(progressBar);

                AlertDialog progressDialog = progressBuilder.create();
                progressDialog.show();

                new Thread(() -> {
                    final CapgoUpdater updater = plugin.implementation;
                    final Bridge bridge = activity.getBridge();

                    // Set the channel
                    SetChannel setResult = updater.setChannel(channelName, "CapacitorUpdater.defaultChannel", true);

                    if (!setResult.error.isEmpty()) {
                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showError("Failed to set channel: " + setResult.error);
                        });
                        return;
                    }

                    // Update progress message
                    activity.runOnUiThread(() -> progressDialog.setMessage("Checking for updates..."));

                    // Check for updates
                    String updateUrlStr = updater.updateUrl;
                    if (updateUrlStr == null || updateUrlStr.isEmpty()) {
                        updateUrlStr = "https://plugin.capgo.app/updates";
                    }

                    LatestVersion latest;
                    try {
                        latest = updater.getLatest(new URL(updateUrlStr), channelName);
                    } catch (Exception e) {
                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showSuccess("Channel set to " + channelName + ". Could not check for updates.");
                        });
                        return;
                    }

                    // Check if there's an actual update available
                    if ("no_new_version_available".equals(latest.error) || latest.url == null || latest.url.isEmpty()) {
                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showSuccess("Channel set to " + channelName + ". Already on latest version.");
                        });
                        return;
                    }

                    if (latest.error != null && !latest.error.isEmpty() && !"no_new_version_available".equals(latest.error)) {
                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showSuccess("Channel set to " + channelName + ". Update check failed: " + latest.error);
                        });
                        return;
                    }

                    // Update message
                    final String version = latest.version;
                    activity.runOnUiThread(() -> progressDialog.setMessage("Downloading update " + version + "..."));

                    // Download the update
                    try {
                        BundleInfo bundle;
                        if (latest.manifest != null && !latest.manifest.isEmpty()) {
                            bundle = updater.downloadManifest(
                                latest.manifest,
                                latest.version,
                                latest.sessionKey != null ? latest.sessionKey : ""
                            );
                        } else {
                            bundle = updater.download(
                                latest.url,
                                latest.version,
                                latest.sessionKey != null ? latest.sessionKey : "",
                                ""
                            );
                        }

                        // Set as next bundle
                        updater.setNextBundle(bundle.getId());

                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showSuccessWithReload("Update downloaded! Reload to apply version " + version + "?", bridge);
                        });
                    } catch (Exception e) {
                        activity.runOnUiThread(() -> {
                            progressDialog.dismiss();
                            showError("Failed to download update: " + e.getMessage());
                        });
                    }
                }).start();
            } catch (Exception e) {
                logger.error("Error selecting channel: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private void showError(String message) {
        logger.error(message);
        new AlertDialog.Builder(activity)
            .setTitle("Error")
            .setMessage(message)
            .setPositiveButton("OK", (d, w) -> {
                d.dismiss();
                isShowing = false;
            })
            .setOnDismissListener((d) -> isShowing = false)
            .show();
    }

    private void showSuccess(String message) {
        logger.info(message);
        new AlertDialog.Builder(activity)
            .setTitle("Success")
            .setMessage(message)
            .setPositiveButton("OK", (d, w) -> {
                d.dismiss();
                isShowing = false;
            })
            .setOnDismissListener((d) -> isShowing = false)
            .show();
    }

    private void showSuccessWithReload(String message, Bridge bridge) {
        logger.info(message);
        new AlertDialog.Builder(activity)
            .setTitle("Update Ready")
            .setMessage(message)
            .setPositiveButton("Reload Now", (d, w) -> {
                d.dismiss();
                isShowing = false;
                activity.runOnUiThread(() -> {
                    if (bridge != null && bridge.getWebView() != null) {
                        bridge.getWebView().reload();
                    }
                });
            })
            .setNegativeButton("Later", (d, w) -> {
                d.dismiss();
                isShowing = false;
            })
            .setOnDismissListener((d) -> isShowing = false)
            .show();
    }

    private int dpToPx(int dp) {
        float density = activity.getResources().getDisplayMetrics().density;
        return Math.round(dp * density);
    }
}
