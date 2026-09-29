/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.work.Data;
import androidx.work.Worker;
import androidx.work.WorkerParameters;
import java.io.File;
import java.io.IOException;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * WorkManager job for background bundle downloads. WorkManager only schedules the job (network constraint, backoff,
 * surviving the activity); the download itself (transfer, resume, verification, decryption, extraction, install) runs
 * in the shared Rust engine.
 */
public class DownloadService extends Worker {

    static final class DownloadRetryException extends RuntimeException {

        DownloadRetryException(String message) {
            super(message);
        }
    }

    static final class ZipWritePlan {

        final int statusCode;
        final long writeOffset;

        ZipWritePlan(int statusCode, long writeOffset) {
            this.statusCode = statusCode;
            this.writeOffset = writeOffset;
        }
    }

    static final class ContentRangeInfo {

        final long start;
        final long end;
        final long total;

        ContentRangeInfo(long start, long end, long total) {
            this.start = start;
            this.end = end;
            this.total = total;
        }
    }

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    public static final String URL = "URL";
    public static final String ID = "id";
    public static final String PERCENT = "percent";
    public static final String FILEDEST = "filendest";
    public static final String DOCDIR = "docdir";
    public static final String ERROR = "error";
    public static final String VERSION = "version";
    public static final String SESSIONKEY = "sessionkey";
    public static final String CHECKSUM = "checksum";
    public static final String PUBLIC_KEY = "publickey";
    public static final String IS_MANIFEST = "is_manifest";
    public static final String APP_ID = "app_id";
    public static final String pluginVersion = "plugin_version";
    public static final String INSTALL_SOURCE = "install_source";
    public static final String STATS_URL = "stats_url";
    public static final String DEVICE_ID = "device_id";
    public static final String CUSTOM_ID = "custom_id";
    public static final String VERSION_BUILD = "version_build";
    public static final String VERSION_CODE = "version_code";
    public static final String VERSION_OS = "version_os";
    public static final String DEFAULT_CHANNEL = "default_channel";
    public static final String IS_PROD = "is_prod";
    public static final String IS_EMULATOR = "is_emulator";

    /** Engine not running in this process (the plugin was not loaded). */
    static final String UPDATER_UNAVAILABLE = "updater_unavailable";

    // Runtime HTTP settings pushed to the engine by CapgoUpdater (config sync).
    private static volatile int httpTimeoutMs = 20_000;
    // Off by default: a redirect must never downgrade updater traffic from HTTPS to plain HTTP.
    private static volatile boolean allowHttpsToHttpRedirect = false;

    public DownloadService(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    static int httpTimeoutMs() {
        return httpTimeoutMs;
    }

    /** 0 or less keeps the 20 s default (plugin responseTimeout). */
    static void applyHttpTimeouts(int timeoutMs) {
        httpTimeoutMs = timeoutMs > 0 ? timeoutMs : 20_000;
    }

    static void setAllowHttpsToHttpRedirect(boolean allow) {
        allowHttpsToHttpRedirect = allow;
    }

    static boolean allowHttpsToHttpRedirect() {
        return allowHttpsToHttpRedirect;
    }

    /** The engine builds the User-Agent from the updater configuration; kept for API compatibility. */
    public static void updateUserAgent(String appId, String pluginVersion, String versionOs) {
        if (logger != null) {
            logger.debug("User-Agent: " + buildUserAgent(appId, pluginVersion, versionOs));
        }
    }

    // ---- shared core rules (thin delegates, kept for callers and contract tests) -----------------

    static int manifestMaxConcurrentFiles() {
        return manifestMaxConcurrentFiles(Runtime.getRuntime().availableProcessors());
    }

    static int manifestMaxConcurrentFiles(int processors) {
        return (int) CapgoCore.number("manifestConcurrency", CapgoCore.input("processorCount", processors), "maxConcurrentFiles", 8);
    }

    static String buildUserAgent(String appId, String pluginVersion, String versionOs) {
        return CapgoCore.string(
            "userAgent",
            CapgoCore.input("appId", appId, "pluginVersion", pluginVersion, "versionOs", versionOs, "platform", "android"),
            "userAgent",
            "CapacitorUpdater/unknown (unknown) android/unknown"
        );
    }

    static File resolveManifestTargetFile(final File destFolder, final String fileName) throws IOException {
        return CapgoUpdater.resolveInsideDirectory("manifestTargetPath", destFolder, "fileName", fileName);
    }

    static File resolveManifestBuiltinFile(final File builtinFolder, final String fileName) throws IOException {
        return resolveManifestTargetFile(builtinFolder, fileName);
    }

    /** APK web assets live in assets/public/; strip .br so store files match. */
    static String resolveBuiltinAssetPath(final String fileName) throws IOException {
        try {
            return CapgoCore.call("builtinAssetPath", CapgoCore.input("fileName", fileName)).getString("assetPath");
        } catch (CapgoCore.Failure | JSONException e) {
            throw new IOException("Invalid manifest file path: " + fileName);
        }
    }

    static boolean isRetryableHttpStatus(int responseCode) {
        return CapgoCore.bool("retryableHttpStatus", CapgoCore.input("status", responseCode), "retryable", false);
    }

    static long parseContentRangeStart(String contentRange) {
        ContentRangeInfo range = parseContentRange(contentRange);
        return range == null ? -1 : range.start;
    }

    static ContentRangeInfo parseContentRange(String contentRange) {
        try {
            final JSONObject range = CapgoCore.call("contentRange", CapgoCore.input("header", contentRange)).optJSONObject("range");
            if (range == null) {
                return null;
            }
            return new ContentRangeInfo(range.getLong("start"), range.getLong("end"), range.getLong("total"));
        } catch (CapgoCore.Failure | JSONException e) {
            return null;
        }
    }

    static ZipWritePlan planZipResumeWrite(int responseCode, long downloadedBytes, String contentRange) {
        try {
            final JSONObject plan = CapgoCore.call(
                "zipResumePlan",
                CapgoCore.input("responseCode", responseCode, "downloadedBytes", downloadedBytes, "contentRange", contentRange)
            );
            return new ZipWritePlan(plan.getInt("responseCode"), plan.getLong("writeOffset"));
        } catch (CapgoCore.Failure e) {
            throw new DownloadRetryException(e.code);
        } catch (JSONException e) {
            throw new DownloadRetryException("invalid_content_range");
        }
    }

    static String safePartialToken(String fileName) {
        return CryptoCipher.shortPathKey(fileName);
    }

    static File manifestPartialFile(File cacheDir, String hash, String fileName) {
        final String name = CapgoCore.string(
            "manifestPartialName",
            CapgoCore.input("hash", hash, "fileName", fileName),
            "name",
            "partial_" + safePartialToken(fileName) + ".tmp"
        );
        return new File(cacheDir, name);
    }

    static boolean shouldAppendHttpBody(int statusCode, long existingBytes) {
        return CapgoCore.bool("appendHttpBody", CapgoCore.input("statusCode", statusCode, "existingBytes", existingBytes), "append", false);
    }

    // ---- worker ----------------------------------------------------------------------------------

    private Result failure(final String error, final String version) {
        return Result.failure(new Data.Builder().putString(ERROR, error).putString(VERSION, version).build());
    }

    @NonNull
    @Override
    public Result doWork() {
        final Data input = getInputData();
        final String id = input.getString(ID);
        final String version = input.getString(VERSION);
        final CapgoUpdater updater = CapgoUpdater.running();
        if (updater == null) {
            if (logger != null) {
                logger.error("Updater engine not available in this process, cannot download " + version);
            }
            return this.failure(UPDATER_UNAVAILABLE, version);
        }
        JSONArray manifest = null;
        if (input.getBoolean(IS_MANIFEST, false)) {
            manifest = DataManager.getInstance().getAndClearManifest(id);
            if (manifest == null) {
                return this.failure(this.isStopped() ? "download_cancelled" : "Manifest is null", version);
            }
        }
        try {
            final BundleInfo installed = updater.runEngineDownload(
                id,
                input.getString(URL),
                version,
                input.getString(SESSIONKEY),
                input.getString(CHECKSUM),
                manifest
            );
            return Result.success(new Data.Builder().putString(ID, installed.getId()).putString(VERSION, version).build());
        } catch (CapgoCore.Failure e) {
            return this.failure(e.code, version);
        }
    }

    @Override
    public void onStopped() {
        super.onStopped();
        final CapgoUpdater updater = CapgoUpdater.running();
        final String version = getInputData().getString(VERSION);
        if (updater != null && version != null) {
            updater.cancelEngineDownload(version);
        }
    }
}
