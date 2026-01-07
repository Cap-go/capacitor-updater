/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import androidx.annotation.NonNull;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import okhttp3.*;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Manages channel operations (get, set, list, unset) for the CapacitorUpdater plugin.
 */
public class ChannelManager {
    private final Logger logger;
    private final InfoObjectProvider infoObjectProvider;
    private final RateLimitChecker rateLimitChecker;

    // Configuration
    private String channelUrl = "";
    private String defaultChannel = "";
    private int timeout = 20000;

    /**
     * Interface to provide info objects for channel requests
     */
    public interface InfoObjectProvider {
        JSONObject createInfoObject() throws JSONException;
    }

    /**
     * Interface to check and handle rate limits
     */
    public interface RateLimitChecker {
        boolean isRateLimited();
        boolean checkAndHandleRateLimitResponse(Response response);
    }

    public ChannelManager(Logger logger, InfoObjectProvider infoObjectProvider, RateLimitChecker rateLimitChecker) {
        this.logger = logger;
        this.infoObjectProvider = infoObjectProvider;
        this.rateLimitChecker = rateLimitChecker;
    }

    /**
     * Configure the channel manager
     */
    public void configure(String channelUrl, String defaultChannel, int timeout) {
        this.channelUrl = channelUrl;
        this.defaultChannel = defaultChannel;
        this.timeout = timeout;
    }

    /**
     * Update the default channel
     */
    public void setDefaultChannel(String channel) {
        this.defaultChannel = channel;
    }

    /**
     * Get the current default channel
     */
    public String getDefaultChannel() {
        return this.defaultChannel;
    }

    /**
     * Unset the channel override and revert to config default
     */
    public void unsetChannel(
        SharedPreferences.Editor editor,
        String defaultChannelKey,
        String configDefaultChannel,
        Callback callback
    ) {
        // Clear persisted defaultChannel and revert to config value
        editor.remove(defaultChannelKey);
        editor.apply();
        this.defaultChannel = configDefaultChannel;
        logger.info("Persisted defaultChannel cleared, reverted to config value: " + configDefaultChannel);

        Map<String, Object> ret = new HashMap<>();
        ret.put("status", "ok");
        ret.put("message", "Channel override removed");
        callback.callback(ret);
    }

    /**
     * Set the channel for updates
     */
    public void setChannel(
        String channel,
        SharedPreferences.Editor editor,
        String defaultChannelKey,
        boolean allowSetDefaultChannel,
        Callback callback
    ) {
        // Check if setting defaultChannel is allowed
        if (!allowSetDefaultChannel) {
            logger.error("setChannel is disabled by allowSetDefaultChannel config");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "setChannel is disabled by configuration");
            retError.put("error", "disabled_by_config");
            callback.callback(retError);
            return;
        }

        // Check if rate limit was exceeded
        if (rateLimitChecker.isRateLimited()) {
            logger.debug("Skipping setChannel due to rate limit (429). Requests will resume after app restart.");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "channelUrl missing");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }

        JSONObject json;
        try {
            json = infoObjectProvider.createInfoObject();
            json.put("channel", channel);
        } catch (JSONException e) {
            logger.error("Error setting channel");
            logger.debug("JSONException: " + e.getMessage());
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        Request request = new Request.Builder()
            .url(channelUrl)
            .post(RequestBody.create(json.toString(), MediaType.get("application/json")))
            .build();

        DownloadService.sharedClient.newCall(request).enqueue(new okhttp3.Callback() {
            @Override
            public void onFailure(@NonNull Call call, @NonNull IOException e) {
                Map<String, Object> retError = new HashMap<>();
                retError.put("message", "Request failed: " + e.getMessage());
                retError.put("error", "network_error");
                callback.callback(retError);
            }

            @Override
            public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                try (ResponseBody responseBody = response.body()) {
                    int statusCode = response.code();

                    // Check for 429 rate limit
                    if (rateLimitChecker.checkAndHandleRateLimitResponse(response)) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Rate limit exceeded");
                        retError.put("error", "rate_limit_exceeded");
                        retError.put("statusCode", statusCode);
                        callback.callback(retError);
                        return;
                    }

                    if (!response.isSuccessful()) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Server error: " + response.code());
                        retError.put("error", "response_error");
                        retError.put("statusCode", statusCode);
                        callback.callback(retError);
                        return;
                    }

                    assert responseBody != null;
                    String responseData = responseBody.string();
                    JSONObject jsonResponse = new JSONObject(responseData);

                    // Check for server-side errors
                    if (jsonResponse.has("error")) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("error", jsonResponse.getString("error"));
                        if (jsonResponse.has("message")) {
                            retError.put("message", jsonResponse.getString("message"));
                        } else {
                            retError.put("message", "server did not provide a message");
                        }
                        retError.put("statusCode", statusCode);
                        callback.callback(retError);
                        return;
                    }

                    // Success - persist defaultChannel
                    ChannelManager.this.defaultChannel = channel;
                    editor.putString(defaultChannelKey, channel);
                    editor.apply();
                    logger.info("defaultChannel persisted locally: " + channel);

                    Map<String, Object> ret = new HashMap<>();
                    ret.put("statusCode", statusCode);

                    Iterator<String> keys = jsonResponse.keys();
                    while (keys.hasNext()) {
                        String key = keys.next();
                        if (jsonResponse.has(key)) {
                            ret.put(key, jsonResponse.get(key));
                        }
                    }
                    callback.callback(ret);
                } catch (JSONException e) {
                    Map<String, Object> retError = new HashMap<>();
                    retError.put("message", "JSON parse error: " + e.getMessage());
                    retError.put("error", "parse_error");
                    callback.callback(retError);
                }
            }
        });
    }

    /**
     * Get the current channel
     */
    public void getChannel(Callback callback) {
        // Check if rate limit was exceeded
        if (rateLimitChecker.isRateLimited()) {
            logger.debug("Skipping getChannel due to rate limit (429). Requests will resume after app restart.");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Channel URL is not set");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }

        JSONObject json;
        try {
            json = infoObjectProvider.createInfoObject();
        } catch (JSONException e) {
            logger.error("Error getting channel");
            logger.debug("JSONException: " + e.getMessage());
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        Request request = new Request.Builder()
            .url(channelUrl)
            .put(RequestBody.create(json.toString(), MediaType.get("application/json")))
            .build();

        DownloadService.sharedClient.newCall(request).enqueue(new okhttp3.Callback() {
            @Override
            public void onFailure(@NonNull Call call, @NonNull IOException e) {
                Map<String, Object> retError = new HashMap<>();
                retError.put("message", "Request failed: " + e.getMessage());
                retError.put("error", "network_error");
                callback.callback(retError);
            }

            @Override
            public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                try (ResponseBody responseBody = response.body()) {
                    // Check for 429 rate limit
                    if (rateLimitChecker.checkAndHandleRateLimitResponse(response)) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Rate limit exceeded");
                        retError.put("error", "rate_limit_exceeded");
                        callback.callback(retError);
                        return;
                    }

                    if (response.code() == 400) {
                        assert responseBody != null;
                        String data = responseBody.string();
                        if (data.contains("channel_not_found") && !defaultChannel.isEmpty()) {
                            Map<String, Object> ret = new HashMap<>();
                            ret.put("channel", defaultChannel);
                            ret.put("status", "default");
                            logger.info("Channel get to \"" + ret);
                            callback.callback(ret);
                            return;
                        }
                    }

                    if (!response.isSuccessful()) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Server error: " + response.code());
                        retError.put("error", "response_error");
                        callback.callback(retError);
                        return;
                    }

                    assert responseBody != null;
                    String responseData = responseBody.string();
                    JSONObject jsonResponse = new JSONObject(responseData);

                    // Check for server-side errors
                    if (jsonResponse.has("error")) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("error", jsonResponse.getString("error"));
                        if (jsonResponse.has("message")) {
                            retError.put("message", jsonResponse.getString("message"));
                        } else {
                            retError.put("message", "server did not provide a message");
                        }
                        callback.callback(retError);
                        return;
                    }

                    Map<String, Object> ret = new HashMap<>();
                    Iterator<String> keys = jsonResponse.keys();
                    while (keys.hasNext()) {
                        String key = keys.next();
                        if (jsonResponse.has(key)) {
                            ret.put(key, jsonResponse.get(key));
                        }
                    }
                    logger.info("Channel get to \"" + ret);
                    callback.callback(ret);
                } catch (JSONException e) {
                    Map<String, Object> retError = new HashMap<>();
                    retError.put("message", "JSON parse error: " + e.getMessage());
                    retError.put("error", "parse_error");
                    callback.callback(retError);
                }
            }
        });
    }

    /**
     * List all available channels
     */
    public void listChannels(Callback callback) {
        // Check if rate limit was exceeded
        if (rateLimitChecker.isRateLimited()) {
            logger.debug("Skipping listChannels due to rate limit (429). Requests will resume after app restart.");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Rate limit exceeded");
            retError.put("error", "rate_limit_exceeded");
            callback.callback(retError);
            return;
        }

        if (channelUrl == null || channelUrl.isEmpty()) {
            logger.error("Channel URL is not set");
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Channel URL is not set");
            retError.put("error", "missing_config");
            callback.callback(retError);
            return;
        }

        JSONObject json;
        try {
            json = infoObjectProvider.createInfoObject();
        } catch (JSONException e) {
            logger.error("Error creating info object");
            logger.debug("JSONException: " + e.getMessage());
            Map<String, Object> retError = new HashMap<>();
            retError.put("message", "Cannot get info: " + e);
            retError.put("error", "json_error");
            callback.callback(retError);
            return;
        }

        // Build URL with query parameters from JSON
        HttpUrl.Builder urlBuilder = HttpUrl.parse(channelUrl).newBuilder();
        try {
            Iterator<String> keys = json.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                Object value = json.get(key);
                if (value != null) {
                    urlBuilder.addQueryParameter(key, value.toString());
                }
            }
        } catch (JSONException e) {
            logger.error("Error adding query parameters");
            logger.debug("JSONException: " + e.getMessage());
        }

        Request request = new Request.Builder().url(urlBuilder.build()).get().build();

        DownloadService.sharedClient.newCall(request).enqueue(new okhttp3.Callback() {
            @Override
            public void onFailure(@NonNull Call call, @NonNull IOException e) {
                Map<String, Object> retError = new HashMap<>();
                retError.put("message", "Request failed: " + e.getMessage());
                retError.put("error", "network_error");
                callback.callback(retError);
            }

            @Override
            public void onResponse(@NonNull Call call, @NonNull Response response) throws IOException {
                try (ResponseBody responseBody = response.body()) {
                    // Check for 429 rate limit
                    if (rateLimitChecker.checkAndHandleRateLimitResponse(response)) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Rate limit exceeded");
                        retError.put("error", "rate_limit_exceeded");
                        callback.callback(retError);
                        return;
                    }

                    if (!response.isSuccessful()) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "Server error: " + response.code());
                        retError.put("error", "response_error");
                        callback.callback(retError);
                        return;
                    }

                    assert responseBody != null;
                    String data = responseBody.string();

                    try {
                        Map<String, Object> ret = new HashMap<>();

                        try {
                            // Try to parse as direct array first
                            JSONArray channelsJson = new JSONArray(data);
                            List<Map<String, Object>> channelsList = new ArrayList<>();

                            for (int i = 0; i < channelsJson.length(); i++) {
                                JSONObject channelJson = channelsJson.getJSONObject(i);
                                Map<String, Object> channel = new HashMap<>();
                                channel.put("id", channelJson.optString("id", ""));
                                channel.put("name", channelJson.optString("name", ""));
                                channel.put("public", channelJson.optBoolean("public", false));
                                channel.put("allow_self_set", channelJson.optBoolean("allow_self_set", false));
                                channelsList.add(channel);
                            }

                            // Wrap in channels object for JS API
                            ret.put("channels", channelsList);

                            logger.info("Channels listed successfully");
                            callback.callback(ret);
                        } catch (JSONException arrayException) {
                            // If not an array, try to parse as error object
                            try {
                                JSONObject jsonObj = new JSONObject(data);
                                if (jsonObj.has("error")) {
                                    Map<String, Object> retError = new HashMap<>();
                                    retError.put("error", jsonObj.getString("error"));
                                    if (jsonObj.has("message")) {
                                        retError.put("message", jsonObj.getString("message"));
                                    } else {
                                        retError.put("message", "server did not provide a message");
                                    }
                                    callback.callback(retError);
                                    return;
                                }
                            } catch (JSONException objException) {
                                // If neither array nor object, throw parse error
                                throw arrayException;
                            }
                        }
                    } catch (JSONException e) {
                        Map<String, Object> retError = new HashMap<>();
                        retError.put("message", "JSON parse error: " + e.getMessage());
                        retError.put("error", "parse_error");
                        callback.callback(retError);
                    }
                }
            }
        });
    }
}
