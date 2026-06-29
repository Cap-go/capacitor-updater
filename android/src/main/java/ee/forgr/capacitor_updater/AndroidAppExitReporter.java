/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.annotation.TargetApi;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@TargetApi(Build.VERSION_CODES.R)
final class AndroidAppExitReporter {

    private AndroidAppExitReporter() {}

    static void reportPreviousAppExitReasons(
        final Context context,
        final SharedPreferences prefs,
        final CapgoUpdater implementation,
        final Logger logger,
        final String lastReportedAppExitTimestampPrefKey
    ) {
        try {
            final ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            if (activityManager == null) {
                return;
            }

            final List<ApplicationExitInfo> exitReasons = activityManager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 8);
            if (exitReasons == null || exitReasons.isEmpty()) {
                return;
            }

            final long lastReportedTimestamp = prefs.getLong(lastReportedAppExitTimestampPrefKey, 0L);
            long newestReportedTimestamp = lastReportedTimestamp;
            final BundleInfo current = implementation.getCurrentBundle();
            final String versionName = current == null ? "" : current.getVersionName();

            for (final ApplicationExitInfo exitInfo : exitReasons) {
                if (exitInfo == null || exitInfo.getTimestamp() <= lastReportedTimestamp) {
                    continue;
                }

                final String action = CapacitorUpdaterPlugin.statsActionForApplicationExitReason(exitInfo.getReason());
                if (action == null) {
                    continue;
                }

                implementation.sendStats(action, versionName, "", buildApplicationExitMetadata(exitInfo));
                newestReportedTimestamp = Math.max(newestReportedTimestamp, exitInfo.getTimestamp());
            }

            if (newestReportedTimestamp > lastReportedTimestamp) {
                prefs.edit().putLong(lastReportedAppExitTimestampPrefKey, newestReportedTimestamp).apply();
            }
        } catch (final Exception e) {
            logger.warn("Unable to report previous app exit reason: " + e.getMessage());
        }
    }

    private static Map<String, String> buildApplicationExitMetadata(final ApplicationExitInfo exitInfo) {
        final Map<String, String> metadata = new HashMap<>();
        metadata.put("exit_reason", CapacitorUpdaterPlugin.applicationExitReasonName(exitInfo.getReason()));
        metadata.put("exit_reason_code", Integer.toString(exitInfo.getReason()));
        metadata.put("exit_status", Integer.toString(exitInfo.getStatus()));
        metadata.put("exit_importance", Integer.toString(exitInfo.getImportance()));
        metadata.put("exit_timestamp", Long.toString(exitInfo.getTimestamp()));
        metadata.put("pid", Integer.toString(exitInfo.getPid()));
        metadata.put("pss_kb", Long.toString(exitInfo.getPss()));
        metadata.put("rss_kb", Long.toString(exitInfo.getRss()));

        final String processName = exitInfo.getProcessName();
        if (processName != null && !processName.isEmpty()) {
            metadata.put("process_name", CapacitorUpdaterPlugin.truncateStatsMetadataValue(processName, 128));
        }

        final String description = exitInfo.getDescription();
        if (description != null && !description.isEmpty()) {
            metadata.put("exit_description", CapacitorUpdaterPlugin.truncateStatsMetadataValue(description, 512));
        }

        return metadata;
    }
}
