/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.AlertDialog;
import android.hardware.SensorManager;
import android.text.Editable;
import android.text.TextWatcher;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.JSObject;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

public class ShakeMenu implements ShakeDetector.Listener, ThreeFingerPinchDetector.Listener {

    private interface PreviewMenuAction {
        boolean run();
    }

    private CapacitorUpdaterPlugin plugin;
    private BridgeActivity activity;
    private ShakeDetector shakeDetector;
    private ThreeFingerPinchDetector pinchDetector;
    /** A menu, picker or switch is in progress: gestures are ignored until it ends. */
    private volatile boolean isShowing = false;
    private Logger logger;
    private String gesture;

    public ShakeMenu(CapacitorUpdaterPlugin plugin, BridgeActivity activity, Logger logger, String gesture) {
        this.plugin = plugin;
        this.activity = activity;
        this.logger = logger;
        this.gesture = gesture;

        if (CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_THREE_FINGER_PINCH.equals(gesture)) {
            this.pinchDetector = new ThreeFingerPinchDetector(this, logger);
            this.pinchDetector.start(activity);
        } else {
            SensorManager sensorManager = (SensorManager) activity.getSystemService(Activity.SENSOR_SERVICE);
            this.shakeDetector = new ShakeDetector(this);
            this.shakeDetector.start(sensorManager);
        }
    }

    public boolean usesGesture(String gesture) {
        return this.gesture != null && this.gesture.equals(gesture);
    }

    public void stop() {
        if (shakeDetector != null) {
            shakeDetector.stop();
        }
        if (pinchDetector != null) {
            pinchDetector.stop();
        }
    }

    @Override
    public void onShakeDetected() {
        onMenuGestureDetected("Shake");
    }

    @Override
    public void onThreeFingerPinchDetected() {
        onMenuGestureDetected("Three finger pinch");
    }

    private void onMenuGestureDetected(String gestureName) {
        logger.info(gestureName + " detected");

        boolean canShowPreviewMenu = plugin.shakeMenuEnabled && plugin.hasActivePreviewSession();
        boolean canShowChannelSelector = plugin.shakeChannelSelectorEnabled;
        if (!canShowPreviewMenu && !canShowChannelSelector) {
            if (plugin.shakeMenuEnabled) {
                logger.info("Shake preview menu ignored because no preview session is active");
            } else {
                logger.info("Shake menu is disabled");
            }
            return;
        }

        // Prevent multiple dialogs
        if (isShowing) {
            logger.info("Dialog already showing");
            return;
        }

        isShowing = true;

        if (canShowPreviewMenu) {
            showDefaultMenu();
        } else {
            showChannelSelector();
        }
    }

    private void showDefaultMenu() {
        activity.runOnUiThread(() -> {
            try {
                if (!plugin.hasActivePreviewSession()) {
                    logger.info("Shake preview menu ignored because no preview session is active");
                    isShowing = false;
                    return;
                }

                showPreviewActionsMenu(plugin.shakeChannelSelectorEnabled);
            } catch (Exception e) {
                logger.error("Error showing shake menu: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private void showPreviewActionsMenu(boolean includeChannelSelector) {
        String appName = activity.getPackageManager().getApplicationLabel(activity.getApplicationInfo()).toString();
        String title = "Preview " + appName + " Menu";
        String message = "Reload, switch, or leave the current preview.";
        final boolean[] openingNestedSelector = { false };
        final boolean[] previewActionRunning = { false };
        final AlertDialog[] dialogRef = { null };
        List<Button> buttons = new ArrayList<>();

        LinearLayout layout = new LinearLayout(activity);
        layout.setOrientation(LinearLayout.VERTICAL);
        int horizontalPadding = dpToPx(16);
        int verticalPadding = dpToPx(8);
        layout.setPadding(horizontalPadding, verticalPadding, horizontalPadding, verticalPadding);

        addPreviewMenuButton(layout, buttons, "Reload preview", () -> {
            AlertDialog dialog = dialogRef[0];
            previewActionRunning[0] = true;
            setPreviewMenuButtonsEnabled(buttons, false);
            logger.info("Reloading webview");
            runPreviewMenuAction(dialog, "Could not reload the test app.", "Error reloading test app: ", () ->
                plugin.reloadPreviewSessionFromShakeMenu()
            );
        });

        if (plugin.previewMenuPreviews().length() > 0) {
            addPreviewMenuButton(layout, buttons, "Switch preview", () -> {
                AlertDialog dialog = dialogRef[0];
                openingNestedSelector[0] = true;
                dialog.dismiss();
                showPreviewSelector();
            });
        }

        if (includeChannelSelector) {
            addPreviewMenuButton(layout, buttons, "Switch channel", () -> {
                AlertDialog dialog = dialogRef[0];
                openingNestedSelector[0] = true;
                dialog.dismiss();
                showChannelSelector();
            });
        }

        addPreviewMenuButton(layout, buttons, "Leave test app", () -> {
            AlertDialog dialog = dialogRef[0];
            previewActionRunning[0] = true;
            setPreviewMenuButtonsEnabled(buttons, false);
            runPreviewMenuAction(dialog, "Could not leave the test app.", "Error leaving test app: ", () ->
                plugin.leavePreviewSessionFromShakeMenu()
            );
        });

        addPreviewMenuButton(layout, buttons, "Close menu", () -> {
            AlertDialog dialog = dialogRef[0];
            if (dialog != null) {
                logger.info("Shake menu cancelled");
                dialog.dismiss();
                isShowing = false;
            }
        });

        AlertDialog.Builder builder = new AlertDialog.Builder(activity);
        builder.setTitle(title);
        builder.setMessage(message);
        builder.setView(layout);

        AlertDialog dialog = builder.create();
        dialogRef[0] = dialog;
        dialog.setOnDismissListener((dialogInterface) -> {
            if (!openingNestedSelector[0] && !previewActionRunning[0]) {
                isShowing = false;
            }
        });
        dialog.show();
    }

    private void addPreviewMenuButton(LinearLayout layout, List<Button> buttons, String title, Runnable action) {
        Button button = new Button(activity);
        button.setAllCaps(false);
        button.setText(title);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        );
        params.setMargins(0, 0, 0, dpToPx(8));
        button.setLayoutParams(params);
        button.setOnClickListener((view) -> action.run());
        buttons.add(button);
        layout.addView(button);
    }

    private void runPreviewMenuAction(AlertDialog dialog, String failureMessage, String errorPrefix, PreviewMenuAction action) {
        new Thread(() -> {
            try {
                if (!action.run()) {
                    activity.runOnUiThread(() -> showError(failureMessage));
                }
            } catch (Exception e) {
                logger.error(errorPrefix + e.getMessage());
                activity.runOnUiThread(() -> showError(errorPrefix + e.getMessage()));
            } finally {
                activity.runOnUiThread(() -> {
                    dialog.dismiss();
                    isShowing = false;
                });
            }
        }).start();
    }

    private void setPreviewMenuButtonsEnabled(List<Button> buttons, boolean enabled) {
        for (Button button : buttons) {
            if (!enabled && "Close menu".equals(button.getText().toString())) {
                continue;
            }
            button.setEnabled(enabled);
        }
    }

    private void showPreviewSelector() {
        activity.runOnUiThread(() -> {
            try {
                JSONArray previewsRaw = plugin.previewMenuPreviews();
                List<JSObject> previews = new ArrayList<>();
                for (int i = 0; i < previewsRaw.length(); i++) {
                    JSONObject json = previewsRaw.optJSONObject(i);
                    if (json != null) {
                        previews.add(JSObject.fromJSONObject(json));
                    }
                }

                if (previews.isEmpty()) {
                    showError("No saved previews available on this device.");
                    return;
                }

                presentPreviewPicker(previews);
            } catch (Exception e) {
                logger.error("Error showing preview selector: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private String previewLabel(JSObject preview) {
        String name = preview.optString("name", "");
        JSObject bundle = preview.getJSObject("bundle");
        String version = bundle == null ? "" : bundle.optString("version", "");
        String label = !name.isEmpty() ? name : !version.isEmpty() ? version : preview.optString("id", "Preview");
        if (preview.optBoolean("isActive", false)) {
            label += " (current)";
        }
        return label;
    }

    private void presentPreviewPicker(List<JSObject> previews) {
        try {
            AlertDialog.Builder builder = new AlertDialog.Builder(activity);
            builder.setTitle("Select Preview");

            LinearLayout layout = new LinearLayout(activity);
            layout.setOrientation(LinearLayout.VERTICAL);
            int padding = dpToPx(16);
            layout.setPadding(padding, padding, padding, padding);

            EditText searchField = new EditText(activity);
            searchField.setHint("Search previews...");
            searchField.setSingleLine(true);
            layout.addView(searchField);

            final List<JSObject> displayedPreviews = new ArrayList<>();
            displayedPreviews.addAll(previews.subList(0, Math.min(5, previews.size())));
            final ArrayAdapter<String> adapter = new ArrayAdapter<>(
                activity,
                android.R.layout.simple_list_item_1,
                previewLabels(displayedPreviews)
            );

            ListView listView = new ListView(activity);
            listView.setAdapter(adapter);
            LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dpToPx(250));
            listView.setLayoutParams(listParams);
            layout.addView(listView);

            builder.setView(layout);
            builder.setNegativeButton("Cancel", (dialog, which) -> {
                dialog.dismiss();
                isShowing = false;
            });

            AlertDialog dialog = builder.create();
            // Picking a preview dismisses the picker: the menu stays busy until the switch ends.
            final boolean[] picked = { false };
            dialog.setOnDismissListener((d) -> {
                if (!picked[0]) {
                    isShowing = false;
                }
            });

            searchField.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        String query = s.toString().toLowerCase();
                        displayedPreviews.clear();

                        for (JSObject preview : previews) {
                            if (previewLabel(preview).toLowerCase().contains(query)) {
                                displayedPreviews.add(preview);
                                if (displayedPreviews.size() >= 5) break;
                            }
                        }

                        adapter.clear();
                        adapter.addAll(previewLabels(displayedPreviews));
                        adapter.notifyDataSetChanged();
                    }
                }
            );

            listView.setOnItemClickListener((parent, view, position, id) -> {
                JSObject selectedPreview = displayedPreviews.get(position);
                String previewId = selectedPreview.optString("id", "");
                picked[0] = true;
                dialog.dismiss();
                selectPreview(previewId);
            });

            dialog.show();
        } catch (Exception e) {
            logger.error("Error presenting preview picker: " + e.getMessage());
            isShowing = false;
        }
    }

    private List<String> previewLabels(List<JSObject> previews) {
        List<String> labels = new ArrayList<>();
        for (JSObject preview : previews) {
            labels.add(previewLabel(preview));
        }
        return labels;
    }

    private void selectPreview(String previewId) {
        new Thread(() -> {
            try {
                if (plugin.setPreviewFromShakeMenu(previewId)) {
                    isShowing = false;
                } else {
                    // The error dialog ends the menu when dismissed.
                    activity.runOnUiThread(() -> showError("Could not switch preview."));
                }
            } catch (Exception e) {
                logger.error("Error switching preview: " + e.getMessage());
                activity.runOnUiThread(() -> showError("Error switching preview: " + e.getMessage()));
            }
        }).start();
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

                final boolean[] didCancel = { false };

                loadingBuilder.setNegativeButton("Cancel", (dialog, which) -> {
                    didCancel[0] = true;
                    dialog.dismiss();
                    isShowing = false;
                });

                AlertDialog loadingDialog = loadingBuilder.create();
                loadingDialog.setOnCancelListener((d) -> {
                    didCancel[0] = true;
                    isShowing = false;
                });
                loadingDialog.setOnDismissListener((d) -> {
                    if (didCancel[0]) {
                        isShowing = false;
                    }
                });
                loadingDialog.show();

                // Fetch channels in background
                new Thread(() -> {
                    final JSONObject res = plugin.runEngineMethod("listChannels", new JSONObject());
                    activity.runOnUiThread(() -> {
                        loadingDialog.dismiss();

                        if (didCancel[0]) {
                            return;
                        }

                        final String error = rejection(res);
                        if (error != null) {
                            showError("Failed to load channels: " + error);
                            return;
                        }

                        final JSONObject result = res.optJSONObject("resolve");
                        final JSONArray channelsRaw = result == null ? null : result.optJSONArray("channels");
                        final List<String> channels = channelNames(channelsRaw);
                        if (channels.isEmpty()) {
                            showError("No channels available for self-assignment");
                            return;
                        }

                        presentChannelPicker(channels);
                    });
                }).start();
            } catch (Exception e) {
                logger.error("Error showing channel selector: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    /** Rejection message of an engine method result, or {@code null} when it resolved. */
    private static String rejection(JSONObject result) {
        final JSONObject reject = result == null ? null : result.optJSONObject("reject");
        if (reject == null) {
            return result == null ? "unknown error" : null;
        }
        return reject.optString("message", "unknown error");
    }

    private static List<String> channelNames(JSONArray channels) {
        final List<String> names = new ArrayList<>();
        if (channels == null) {
            return names;
        }
        for (int i = 0; i < channels.length(); i++) {
            final JSONObject channel = channels.optJSONObject(i);
            final String name = channel == null ? "" : channel.optString("name", "");
            if (!name.isEmpty()) {
                names.add(name);
            }
        }
        return names;
    }

    private void presentChannelPicker(List<String> allChannelNames) {
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

            // Displayed channels (first 5 by default)
            final List<String> displayedChannels = new ArrayList<>();
            displayedChannels.addAll(allChannelNames.subList(0, Math.min(5, allChannelNames.size())));

            final ArrayAdapter<String> adapter = new ArrayAdapter<>(activity, android.R.layout.simple_list_item_1, displayedChannels);

            ListView listView = new ListView(activity);
            listView.setAdapter(adapter);

            // Set fixed height for list (about 5 items)
            LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dpToPx(250));
            listView.setLayoutParams(listParams);
            layout.addView(listView);

            builder.setView(layout);
            builder.setNegativeButton("Cancel", (dialog, which) -> {
                dialog.dismiss();
                isShowing = false;
            });

            AlertDialog dialog = builder.create();
            // Picking a channel dismisses the picker: the menu stays busy until the switch ends, so a
            // second gesture cannot start a concurrent switch (one shakeMenuProgress listener).
            final boolean[] picked = { false };
            dialog.setOnDismissListener((d) -> {
                if (!picked[0]) {
                    isShowing = false;
                }
            });

            // Search filter
            searchField.addTextChangedListener(
                new TextWatcher() {
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
                }
            );

            // Channel selection
            listView.setOnItemClickListener((parent, view, position, id) -> {
                String selectedChannel = displayedChannels.get(position);
                picked[0] = true;
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
                    // The engine runs setChannel, getLatest, download and next; progress arrives
                    // through the shakeMenuProgress hook.
                    plugin.shakeMenuProgressListener = (message) -> activity.runOnUiThread(() -> progressDialog.setMessage(message));
                    JSONObject result;
                    try {
                        result = plugin.switchChannelFromShakeMenu(channelName);
                    } catch (RuntimeException e) {
                        result = jsonOf("status", "error", "message", "Error switching channel: " + e.getMessage());
                    } finally {
                        plugin.shakeMenuProgressListener = null;
                    }
                    final String status = result.optString("status", "error");
                    final String message = result.optString("message", "Failed to set channel");
                    final String bundleId = result.optString("bundleId", "");
                    activity.runOnUiThread(() -> {
                        progressDialog.dismiss();
                        if ("updateReady".equals(status)) {
                            showSuccessWithReload(message, () ->
                                new Thread(() -> {
                                    final String setBundleError = rejection(plugin.runEngineMethod("set", jsonOf("id", bundleId)));
                                    if (setBundleError != null) {
                                        logger.error("Error applying bundle before reload: " + setBundleError);
                                    }
                                }).start()
                            );
                        } else if ("success".equals(status)) {
                            showSuccess(message);
                        } else {
                            showError(message);
                        }
                    });
                }).start();
            } catch (Exception e) {
                logger.error("Error selecting channel: " + e.getMessage());
                isShowing = false;
            }
        });
    }

    private static JSONObject jsonOf(Object... keyValues) {
        return CapgoCore.input(keyValues);
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

    private void showSuccessWithReload(String message, Runnable onReload) {
        logger.info(message);
        new AlertDialog.Builder(activity)
            .setTitle("Update Ready")
            .setMessage(message)
            .setPositiveButton("Reload Now", (d, w) -> {
                d.dismiss();
                isShowing = false;
                if (onReload != null) {
                    onReload.run();
                }
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
