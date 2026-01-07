/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import androidx.annotation.NonNull;
import java.io.IOException;
import okhttp3.*;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Manages statistics sending and rate limiting for the CapacitorUpdater plugin.
 */
public class StatsManager {
    private final Logger logger;

    // Configuration
    private String statsUrl = "";
    private int timeout = 20000;

    // Rate limiting - static to persist across instances until app restart
    private static volatile boolean rateLimitExceeded = false;
    private static volatile boolean rateLimitStatisticSent = false;

    // Dependency injection
    private final InfoObjectProvider infoObjectProvider;
    private final CurrentVersionProvider currentVersionProvider;

    /**
     * Interface to provide info objects for stats requests
     */
    public interface InfoObjectProvider {
        JSONObject createInfoObject() throws JSONException;
    }

    /**
     * Interface to get current bundle version
     */
    public interface CurrentVersionProvider {
        String getCurrentVersionName();
    }

    public StatsManager(Logger logger, InfoObjectProvider infoObjectProvider, CurrentVersionProvider currentVersionProvider) {
        this.logger = logger;
        this.infoObjectProvider = infoObjectProvider;
        this.currentVersionProvider = currentVersionProvider;
    }

    /**
     * Configure the stats manager
     */
    public void configure(String statsUrl, int timeout) {
        this.statsUrl = statsUrl;
        this.timeout = timeout;
    }

    /**
     * Check if rate limit has been exceeded
     */
    public static boolean isRateLimited() {
        return rateLimitExceeded;
    }

    /**
     * Check and handle rate limit response. Returns true if rate limited.
     */
    public boolean checkAndHandleRateLimitResponse(Response response) {
        if (response.code() == 429) {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if (!rateLimitExceeded && !rateLimitStatisticSent) {
                rateLimitStatisticSent = true;
                sendRateLimitStatistic();
            }
            rateLimitExceeded = true;
            logger.warn("Rate limit exceeded (429). Stopping all stats and channel requests until app restart.");
            return true;
        }
        return false;
    }

    /**
     * Send stats with just an action
     */
    public void sendStats(String action) {
        sendStats(action, currentVersionProvider.getCurrentVersionName(), "");
    }

    /**
     * Send stats with action and version
     */
    public void sendStats(String action, String versionName) {
        sendStats(action, versionName, "");
    }

    /**
     * Send stats asynchronously
     */
    public void sendStats(String action, String versionName, String oldVersionName) {
        // Check if rate limit was exceeded
        if (rateLimitExceeded) {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.");
            return;
        }

        if (statsUrl == null || statsUrl.isEmpty()) {
            return;
        }

        JSONObject json;
        try {
            json = infoObjectProvider.createInfoObject();
            json.put("version_name", versionName);
            json.put("old_version_name", oldVersionName);
            json.put("action", action);
        } catch (JSONException e) {
            logger.error("Error preparing stats");
            logger.debug("JSONException: " + e.getMessage());
            return;
        }

        Request request = new Request.Builder()
            .url(statsUrl)
            .post(RequestBody.create(json.toString(), MediaType.get("application/json")))
            .build();

        DownloadService.sharedClient
            .newCall(request)
            .enqueue(new okhttp3.Callback() {
                @Override
                public void onFailure(@NonNull Call call, @NonNull IOException e) {
                    logger.error("Failed to send stats");
                    logger.debug("Error: " + e.getMessage());
                }

                @Override
                public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                    try (ResponseBody responseBody = response.body()) {
                        // Check for 429 rate limit
                        if (checkAndHandleRateLimitResponse(response)) {
                            return;
                        }

                        if (response.isSuccessful()) {
                            logger.info("Stats sent successfully");
                            logger.debug("Action: " + action + ", Version: " + versionName);
                        } else {
                            logger.error("Error sending stats");
                            logger.debug("Response code: " + response.code());
                        }
                    }
                }
            });
    }

    /**
     * Send a synchronous statistic about rate limiting
     */
    private void sendRateLimitStatistic() {
        if (statsUrl == null || statsUrl.isEmpty()) {
            return;
        }

        try {
            JSONObject json = infoObjectProvider.createInfoObject();
            json.put("version_name", currentVersionProvider.getCurrentVersionName());
            json.put("old_version_name", "");
            json.put("action", "rate_limit_reached");

            Request request = new Request.Builder()
                .url(statsUrl)
                .post(RequestBody.create(json.toString(), MediaType.get("application/json")))
                .build();

            // Send synchronously to ensure it goes out before the flag is set
            try (Response response = DownloadService.sharedClient.newCall(request).execute()) {
                if (response.isSuccessful()) {
                    logger.info("Rate limit statistic sent");
                } else {
                    logger.error("Error sending rate limit statistic");
                    logger.debug("Response code: " + response.code());
                }
            }
        } catch (Exception e) {
            logger.error("Failed to send rate limit statistic");
            logger.debug("Error: " + e.getMessage());
        }
    }
}
