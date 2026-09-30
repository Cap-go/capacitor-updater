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
import android.os.Build;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Reads the previous process exits ({@link ApplicationExitInfo}, API 30+) for the engine, which reports the
 * ones worth a statistic ({@code previousExits} of {@code pluginLoad}). Kept out of the plugin class so older
 * Android versions never resolve {@link ApplicationExitInfo} while reflecting plugin methods.
 */
@TargetApi(Build.VERSION_CODES.R)
final class AndroidAppExitReporter {

    private static final int MAX_EXITS = 8;

    private AndroidAppExitReporter() {}

    /** Newest first; empty when unavailable. */
    static JSONArray previousExits(final Context context, final Logger logger) {
        final JSONArray exits = new JSONArray();
        try {
            final ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            if (activityManager == null) {
                return exits;
            }
            final List<ApplicationExitInfo> infos = activityManager.getHistoricalProcessExitReasons(context.getPackageName(), 0, MAX_EXITS);
            if (infos == null) {
                return exits;
            }
            for (final ApplicationExitInfo info : infos) {
                if (info == null) {
                    continue;
                }
                exits.put(
                    new JSONObject()
                        .put("reason", info.getReason())
                        .put("status", info.getStatus())
                        .put("importance", info.getImportance())
                        .put("timestamp", info.getTimestamp())
                        .put("pid", info.getPid())
                        .put("pss", info.getPss())
                        .put("rss", info.getRss())
                        .put("processName", info.getProcessName() == null ? "" : info.getProcessName())
                        .put("description", info.getDescription() == null ? "" : info.getDescription())
                );
            }
        } catch (final Exception e) {
            logger.warn("Unable to read previous app exit reasons: " + e.getMessage());
        }
        return exits;
    }
}
