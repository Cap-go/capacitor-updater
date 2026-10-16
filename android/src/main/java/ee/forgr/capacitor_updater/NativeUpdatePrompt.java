package ee.forgr.capacitor_updater;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginConfig;
import com.google.android.play.core.appupdate.AppUpdateInfo;
import com.google.android.play.core.appupdate.AppUpdateManager;
import com.google.android.play.core.appupdate.AppUpdateOptions;
import com.google.android.play.core.install.model.AppUpdateType;
import com.google.android.play.core.install.model.UpdateAvailability;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

final class NativeUpdatePrompt {

    static final String PREF_LAST_NATIVE_VERSION = "CapacitorUpdater.nativeUpdatePromptLastNativeVersion";
    static final String PREF_LAST_SHOWN_MS = "CapacitorUpdater.nativeUpdatePromptLastShownMs";

    private static final Set<String> SESSION_SHOWN_NATIVE_VERSIONS = new HashSet<>();

    static void resetSessionStateForTesting() {
        SESSION_SHOWN_NATIVE_VERSIONS.clear();
    }

    void resetPresentationStateForTesting() {
        this.promptPresentationActive = false;
        if (this.pendingShowRunnable != null) {
            this.mainHandler.removeCallbacks(this.pendingShowRunnable);
            this.pendingShowRunnable = null;
        }
    }

    boolean isPromptPresentationActiveForTesting() {
        return this.promptPresentationActive;
    }

    private final boolean enabled;
    private final boolean onStoreCheck;
    private final String title;
    private final String message;
    private final String updateButton;
    private final String laterButton;
    private final String countryFilter;
    private final long cooldownMs;
    private final SharedPreferences prefs;
    private final Logger logger;
    private final NativeUpdatePromptHost host;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private volatile boolean promptPresentationActive = false;
    private Runnable pendingShowRunnable;

    interface NativeUpdatePromptHost {
        Activity getActivity();

        String getNativeBuildVersion();

        AppUpdateManager getAppUpdateManager();

        AppUpdateInfo getCachedAppUpdateInfo();

        void setCachedAppUpdateInfo(AppUpdateInfo info);

        String getPackageNameForStore();
    }

    NativeUpdatePrompt(final PluginConfig config, final SharedPreferences prefs, final Logger logger, final NativeUpdatePromptHost host) {
        this.prefs = prefs;
        this.logger = logger;
        this.host = host;
        this.enabled = config.getBoolean("nativeUpdatePrompt", false);
        this.onStoreCheck = config.getBoolean("nativeUpdatePromptOnStoreCheck", false);
        this.title = config.getString("nativeUpdatePromptTitle", null);
        this.message = config.getString("nativeUpdatePromptMessage", null);
        this.updateButton = config.getString("nativeUpdatePromptUpdateButton", null);
        this.laterButton = config.getString("nativeUpdatePromptLaterButton", null);
        this.countryFilter = config.getString("nativeUpdatePromptCountry", null);
        final int cooldownHours = Math.max(1, config.getInt("nativeUpdatePromptCooldownHours", 24));
        this.cooldownMs = (long) cooldownHours * 60L * 60L * 1000L;
    }

    boolean isOnStoreCheckEnabled() {
        return this.enabled && this.onStoreCheck;
    }

    static boolean isNativeStoreUpdateBlock(final JSObject response) {
        if (response == null) {
            return false;
        }
        if (response.optBoolean("breaking", false)) {
            return true;
        }
        if ("store_update_required".equals(response.optString("message", ""))) {
            return true;
        }
        final String error = response.optString("error", "");
        return error.startsWith("disable_auto_update");
    }

    void maybeShowForUpdateBlock(final JSObject response) {
        if (!this.enabled || !isNativeStoreUpdateBlock(response)) {
            return;
        }
        this.scheduleShow();
    }

    void maybeShowForStoreUpdateAvailable() {
        if (!this.isOnStoreCheckEnabled()) {
            return;
        }
        this.scheduleShow();
    }

    private void scheduleShow() {
        if (!this.matchesCountryFilter()) {
            return;
        }
        final String nativeVersion = this.host.getNativeBuildVersion();
        if (nativeVersion == null || nativeVersion.isEmpty()) {
            return;
        }
        if (!this.shouldShowForNativeVersion(nativeVersion)) {
            return;
        }
        if (this.promptPresentationActive) {
            return;
        }
        this.promptPresentationActive = true;
        if (this.pendingShowRunnable != null) {
            this.mainHandler.removeCallbacks(this.pendingShowRunnable);
        }
        this.pendingShowRunnable = () -> this.showDialog(nativeVersion);
        this.mainHandler.postDelayed(this.pendingShowRunnable, 600);
    }

    private void clearPresentationGuard() {
        this.promptPresentationActive = false;
        this.pendingShowRunnable = null;
    }

    boolean shouldShowForNativeVersion(final String nativeVersion) {
        if (SESSION_SHOWN_NATIVE_VERSIONS.contains(nativeVersion)) {
            return false;
        }
        final String lastVersion = this.prefs.getString(PREF_LAST_NATIVE_VERSION, "");
        final long lastShown = this.prefs.getLong(PREF_LAST_SHOWN_MS, 0L);
        if (nativeVersion.equals(lastVersion) && lastShown > 0L) {
            final long elapsed = System.currentTimeMillis() - lastShown;
            if (elapsed < this.cooldownMs) {
                return false;
            }
        }
        return true;
    }

    boolean matchesCountryFilter() {
        if (this.countryFilter == null || this.countryFilter.trim().isEmpty()) {
            return true;
        }
        final String deviceCountry = Locale.getDefault().getCountry();
        if (deviceCountry == null || deviceCountry.isEmpty()) {
            return false;
        }
        final String normalizedDevice = deviceCountry.toUpperCase(Locale.ROOT);
        final String[] allowed = this.countryFilter.split(",");
        for (final String entry : allowed) {
            if (entry != null && normalizedDevice.equals(entry.trim().toUpperCase(Locale.ROOT))) {
                return true;
            }
        }
        return false;
    }

    private void showDialog(final String nativeVersion) {
        final Activity activity = this.host.getActivity();
        if (activity == null || activity.isFinishing()) {
            this.clearPresentationGuard();
            return;
        }

        final String dialogTitle = this.title != null && !this.title.isEmpty() ? this.title : "Update available";
        final String dialogMessage =
            this.message != null && !this.message.isEmpty()
                ? this.message
                : "A new version of this app is available in the store. Update now to continue receiving live updates.";
        final String positive = this.updateButton != null && !this.updateButton.isEmpty() ? this.updateButton : "Update";
        final String negative = this.laterButton != null && !this.laterButton.isEmpty() ? this.laterButton : "Not now";

        try {
            final AlertDialog dialog = new AlertDialog.Builder(activity)
                .setTitle(dialogTitle)
                .setMessage(dialogMessage)
                .setCancelable(true)
                .setPositiveButton(positive, (d, which) -> this.onUpdateSelected())
                .setNegativeButton(negative, (d, which) -> d.dismiss())
                .create();
            final boolean[] recorded = { false };
            final Runnable markRecorded = () -> {
                if (!recorded[0]) {
                    recorded[0] = true;
                    this.recordShown(nativeVersion);
                }
            };
            dialog.setOnShowListener((d) -> markRecorded.run());
            dialog.setOnCancelListener((d) -> markRecorded.run());
            dialog.setOnDismissListener((d) -> this.clearPresentationGuard());
            dialog.show();
        } catch (final Exception e) {
            this.logger.warn("Could not show native update prompt: " + e.getMessage());
            this.clearPresentationGuard();
        }
    }

    void recordShown(final String nativeVersion) {
        SESSION_SHOWN_NATIVE_VERSIONS.add(nativeVersion);
        this.prefs
            .edit()
            .putString(PREF_LAST_NATIVE_VERSION, nativeVersion)
            .putLong(PREF_LAST_SHOWN_MS, System.currentTimeMillis())
            .apply();
    }

    private void onUpdateSelected() {
        final AppUpdateInfo cached = this.host.getCachedAppUpdateInfo();
        if (
            cached != null &&
            cached.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
            cached.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)
        ) {
            this.startImmediateUpdate(cached);
            return;
        }

        final AppUpdateManager manager = this.host.getAppUpdateManager();
        manager
            .getAppUpdateInfo()
            .addOnSuccessListener((appUpdateInfo) -> {
                this.host.setCachedAppUpdateInfo(appUpdateInfo);
                if (
                    appUpdateInfo.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                    appUpdateInfo.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)
                ) {
                    this.startImmediateUpdate(appUpdateInfo);
                } else {
                    this.openPlayStore();
                }
            })
            .addOnFailureListener((e) -> this.openPlayStore());
    }

    private void startImmediateUpdate(final AppUpdateInfo appUpdateInfo) {
        final Activity activity = this.host.getActivity();
        if (activity == null || activity.isFinishing()) {
            this.openPlayStore();
            return;
        }
        try {
            final AppUpdateManager manager = this.host.getAppUpdateManager();
            final boolean started = manager.startUpdateFlowForResult(
                appUpdateInfo,
                activity,
                AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(),
                CapacitorUpdaterPlugin.APP_UPDATE_REQUEST_CODE
            );
            if (!started) {
                this.openPlayStore();
            }
        } catch (final Exception e) {
            this.logger.warn("Immediate update from prompt failed: " + e.getMessage());
            this.openPlayStore();
        }
    }

    private void openPlayStore() {
        final String packageName = this.host.getPackageNameForStore();
        final Activity activity = this.host.getActivity();
        if (activity == null) {
            return;
        }
        try {
            final Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=" + packageName));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
        } catch (final android.content.ActivityNotFoundException e) {
            try {
                final Intent intent = new Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=" + packageName)
                );
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                activity.startActivity(intent);
            } catch (final Exception ex) {
                this.logger.error("Failed to open Play Store from native update prompt: " + ex.getMessage());
            }
        }
    }
}
