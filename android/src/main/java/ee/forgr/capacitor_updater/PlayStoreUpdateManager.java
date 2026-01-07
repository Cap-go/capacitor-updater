/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import com.google.android.play.core.appupdate.AppUpdateInfo;
import com.google.android.play.core.appupdate.AppUpdateManager;
import com.google.android.play.core.appupdate.AppUpdateManagerFactory;
import com.google.android.play.core.appupdate.AppUpdateOptions;
import com.google.android.play.core.install.InstallStateUpdatedListener;
import com.google.android.play.core.install.model.AppUpdateType;
import com.google.android.play.core.install.model.InstallStatus;
import com.google.android.play.core.install.model.UpdateAvailability;
import java.lang.ref.WeakReference;
import java.util.Map;

/**
 * Manages Play Store in-app update functionality for the CapacitorUpdater plugin.
 * Handles immediate and flexible updates using Google Play Core library.
 */
public class PlayStoreUpdateManager {
    private final Logger logger;
    private final WeakReference<Context> contextRef;
    private final WeakReference<Activity> activityRef;

    private AppUpdateManager appUpdateManager;
    private AppUpdateInfo cachedAppUpdateInfo;
    private InstallStateUpdatedListener installStateUpdatedListener;

    public static final int APP_UPDATE_REQUEST_CODE = 9001;

    // Update availability constants matching TypeScript definitions
    public static final int UPDATE_AVAILABILITY_UNKNOWN = 0;
    public static final int UPDATE_AVAILABILITY_NOT_AVAILABLE = 1;
    public static final int UPDATE_AVAILABILITY_AVAILABLE = 2;
    public static final int UPDATE_AVAILABILITY_IN_PROGRESS = 3;

    // Result codes
    public static final int RESULT_OK = 0;
    public static final int RESULT_CANCELED = 1;
    public static final int RESULT_FAILED = 2;
    public static final int RESULT_NOT_AVAILABLE = 3;
    public static final int RESULT_NOT_ALLOWED = 4;
    public static final int RESULT_INFO_MISSING = 5;

    /**
     * Interface for update state change callbacks
     */
    public interface UpdateStateCallback {
        void onStateChange(int installStatus, long bytesDownloaded, long totalBytesToDownload);
    }

    /**
     * Interface for update info callback
     */
    public interface UpdateInfoCallback {
        void onSuccess(Map<String, Object> info);
        void onFailure(String error);
    }

    /**
     * Interface for update result callback
     */
    public interface UpdateResultCallback {
        void onResult(int resultCode);
        void onError(String error);
    }

    public PlayStoreUpdateManager(Logger logger, Context context, Activity activity) {
        this.logger = logger;
        this.contextRef = new WeakReference<>(context);
        this.activityRef = new WeakReference<>(activity);
    }

    /**
     * Get or create the AppUpdateManager instance
     */
    private AppUpdateManager getAppUpdateManager() {
        if (appUpdateManager == null) {
            Context context = contextRef.get();
            if (context != null) {
                appUpdateManager = AppUpdateManagerFactory.create(context);
            }
        }
        return appUpdateManager;
    }

    /**
     * Get cached update info (if available)
     */
    public AppUpdateInfo getCachedAppUpdateInfo() {
        return cachedAppUpdateInfo;
    }

    /**
     * Check if update info is available
     */
    public boolean hasUpdateInfo() {
        return cachedAppUpdateInfo != null;
    }

    /**
     * Map Play Store update availability to our constants
     */
    public int mapUpdateAvailability(int playStoreAvailability) {
        switch (playStoreAvailability) {
            case UpdateAvailability.UPDATE_AVAILABLE:
                return UPDATE_AVAILABILITY_AVAILABLE;
            case UpdateAvailability.UPDATE_NOT_AVAILABLE:
                return UPDATE_AVAILABILITY_NOT_AVAILABLE;
            case UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS:
                return UPDATE_AVAILABILITY_IN_PROGRESS;
            default:
                return UPDATE_AVAILABILITY_UNKNOWN;
        }
    }

    /**
     * Get app update info from Play Store
     */
    public void getAppUpdateInfo(UpdateInfoCallback callback) {
        logger.info("Getting Play Store update info");

        try {
            AppUpdateManager manager = getAppUpdateManager();
            if (manager == null) {
                callback.onFailure("Context not available");
                return;
            }

            manager.getAppUpdateInfo()
                .addOnSuccessListener((appUpdateInfo) -> {
                    cachedAppUpdateInfo = appUpdateInfo;

                    Context context = contextRef.get();
                    if (context == null) {
                        callback.onFailure("Context not available");
                        return;
                    }

                    java.util.HashMap<String, Object> result = new java.util.HashMap<>();

                    try {
                        PackageInfo pInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
                        result.put("currentVersionName", pInfo.versionName);
                        result.put("currentVersionCode", String.valueOf(pInfo.versionCode));
                    } catch (PackageManager.NameNotFoundException e) {
                        result.put("currentVersionName", "0.0.0");
                        result.put("currentVersionCode", "0");
                    }

                    result.put("updateAvailability", mapUpdateAvailability(appUpdateInfo.updateAvailability()));

                    if (appUpdateInfo.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE) {
                        result.put("availableVersionCode", String.valueOf(appUpdateInfo.availableVersionCode()));
                        // Play Store doesn't provide version name, only version code
                        result.put("availableVersionName", String.valueOf(appUpdateInfo.availableVersionCode()));
                        result.put("updatePriority", appUpdateInfo.updatePriority());
                        result.put("immediateUpdateAllowed", appUpdateInfo.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE));
                        result.put("flexibleUpdateAllowed", appUpdateInfo.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE));

                        Integer stalenessDays = appUpdateInfo.clientVersionStalenessDays();
                        if (stalenessDays != null) {
                            result.put("clientVersionStalenessDays", stalenessDays);
                        }
                    } else {
                        result.put("immediateUpdateAllowed", false);
                        result.put("flexibleUpdateAllowed", false);
                    }

                    result.put("installStatus", appUpdateInfo.installStatus());

                    callback.onSuccess(result);
                })
                .addOnFailureListener((e) -> {
                    logger.error("Failed to get app update info: " + e.getMessage());
                    callback.onFailure("Failed to get app update info: " + e.getMessage());
                });
        } catch (Exception e) {
            logger.error("Error getting app update info: " + e.getMessage());
            callback.onFailure("Error getting app update info: " + e.getMessage());
        }
    }

    /**
     * Open Play Store for the specified package
     */
    public boolean openAppStore(String packageName) {
        Context context = contextRef.get();
        if (context == null) {
            return false;
        }

        if (packageName == null || packageName.isEmpty()) {
            packageName = context.getPackageName();
        }

        try {
            // Try to open Play Store app first
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=" + packageName));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
            return true;
        } catch (android.content.ActivityNotFoundException e) {
            // Fall back to browser
            try {
                Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=" + packageName));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
                return true;
            } catch (Exception ex) {
                logger.error("Failed to open Play Store: " + ex.getMessage());
                return false;
            }
        }
    }

    /**
     * Start immediate update flow
     */
    public int performImmediateUpdate() {
        if (cachedAppUpdateInfo == null) {
            logger.error("No update info available. Call getAppUpdateInfo first.");
            return RESULT_INFO_MISSING;
        }

        if (cachedAppUpdateInfo.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) {
            logger.info("No update available");
            return RESULT_NOT_AVAILABLE;
        }

        if (!cachedAppUpdateInfo.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)) {
            logger.info("Immediate update not allowed");
            return RESULT_NOT_ALLOWED;
        }

        Activity activity = activityRef.get();
        if (activity == null) {
            return RESULT_FAILED;
        }

        try {
            AppUpdateManager manager = getAppUpdateManager();
            if (manager == null) {
                return RESULT_FAILED;
            }

            manager.startUpdateFlowForResult(
                cachedAppUpdateInfo,
                activity,
                AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(),
                APP_UPDATE_REQUEST_CODE
            );

            // Return OK to indicate flow started (actual result will come from activity result)
            return RESULT_OK;
        } catch (Exception e) {
            logger.error("Failed to start immediate update: " + e.getMessage());
            return RESULT_FAILED;
        }
    }

    /**
     * Start flexible update flow with state callback
     */
    public int startFlexibleUpdate(UpdateStateCallback stateCallback) {
        if (cachedAppUpdateInfo == null) {
            logger.error("No update info available. Call getAppUpdateInfo first.");
            return RESULT_INFO_MISSING;
        }

        if (cachedAppUpdateInfo.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) {
            logger.info("No update available");
            return RESULT_NOT_AVAILABLE;
        }

        if (!cachedAppUpdateInfo.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)) {
            logger.info("Flexible update not allowed");
            return RESULT_NOT_ALLOWED;
        }

        Activity activity = activityRef.get();
        if (activity == null) {
            return RESULT_FAILED;
        }

        try {
            AppUpdateManager manager = getAppUpdateManager();
            if (manager == null) {
                return RESULT_FAILED;
            }

            // Remove any existing listener
            if (installStateUpdatedListener != null) {
                manager.unregisterListener(installStateUpdatedListener);
            }

            // Create new listener
            installStateUpdatedListener = (state) -> {
                if (stateCallback != null) {
                    long bytesDownloaded = 0;
                    long totalBytes = 0;

                    if (state.installStatus() == InstallStatus.DOWNLOADING) {
                        bytesDownloaded = state.bytesDownloaded();
                        totalBytes = state.totalBytesToDownload();
                    }

                    stateCallback.onStateChange(state.installStatus(), bytesDownloaded, totalBytes);
                }
            };

            manager.registerListener(installStateUpdatedListener);

            manager.startUpdateFlowForResult(
                cachedAppUpdateInfo,
                activity,
                AppUpdateOptions.newBuilder(AppUpdateType.FLEXIBLE).build(),
                APP_UPDATE_REQUEST_CODE
            );

            return RESULT_OK;
        } catch (Exception e) {
            logger.error("Failed to start flexible update: " + e.getMessage());
            return RESULT_FAILED;
        }
    }

    /**
     * Complete flexible update (triggers app restart)
     */
    public void completeFlexibleUpdate(UpdateResultCallback callback) {
        try {
            AppUpdateManager manager = getAppUpdateManager();
            if (manager == null) {
                callback.onError("AppUpdateManager not available");
                return;
            }

            manager.completeUpdate()
                .addOnSuccessListener((aVoid) -> {
                    // The app will restart, so this may not be called
                    callback.onResult(RESULT_OK);
                })
                .addOnFailureListener((e) -> {
                    logger.error("Failed to complete flexible update: " + e.getMessage());
                    callback.onError("Failed to complete flexible update: " + e.getMessage());
                });
        } catch (Exception e) {
            logger.error("Error completing flexible update: " + e.getMessage());
            callback.onError("Error completing flexible update: " + e.getMessage());
        }
    }

    /**
     * Clean up resources
     */
    public void cleanup() {
        if (installStateUpdatedListener != null && appUpdateManager != null) {
            try {
                appUpdateManager.unregisterListener(installStateUpdatedListener);
                installStateUpdatedListener = null;
            } catch (Exception e) {
                logger.error("Failed to unregister install state listener: " + e.getMessage());
            }
        }
    }
}
