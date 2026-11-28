/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package ee.forgr.capacitor_updater;

import android.content.Context;
import android.os.Build;
import android.os.ext.SdkExtensions;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.io.IOException;
import java.net.SocketTimeoutException;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import okhttp3.Call;
import okhttp3.Headers;
import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;

/**
 * HTTP/3 for bundle and manifest downloads.
 *
 * <p>Where the device has the platform {@code android.net.http.HttpEngine} (Android 14+, or Android 12 and 13
 * with the S extension at level 7), https downloads tagged with {@link #markDownload} run on one shared engine.
 * The engine speaks HTTP/3 when the server advertises it through Alt-Svc and falls back to HTTP/2 on its own when
 * QUIC is blocked. Its storage path and {@code HTTP_CACHE_DISK_NO_HTTP} cache keep the Alt-Svc entries across
 * launches without caching any response, so the next process goes straight to HTTP/3 (finding from
 * https://github.com/Cap-go/capacitor-updater/issues/1027, credit autopylotben).
 *
 * <p>Everything else stays on OkHttp: API calls, requests with a body, plain http, devices without HttpEngine,
 * an engine that failed to start, and apps that set {@code http3: false}.
 */
final class Http3 {

    /** Request tag for downloads allowed to run on HttpEngine. */
    static final class Download {

        static final Download TAG = new Download();

        private Download() {}
    }

    /** Runs one tagged download outside OkHttp's network stack. */
    interface Transport {
        @NonNull
        Response execute(@NonNull Request request, int connectTimeoutMs, int readTimeoutMs, @Nullable Call call) throws IOException;
    }

    interface TransportFactory {
        @NonNull
        Transport create(@NonNull Context context, @Nullable Logger logger);
    }

    /**
     * The engine made no progress at all (no callback for any request) for {@link #STALL_MS} while a download
     * waited on it. Seen on an Android 16 emulator (HttpEngine 133): right after a large receive burst the QUIC session
     * stops answering, and the engine only gives up on it after its own 6 to 40 s timeout.
     */
    static final class EngineStalledException extends SocketTimeoutException {

        EngineStalledException(String message) {
            super(message);
        }
    }

    /**
     * How long the whole engine may stay silent, while downloads wait on it, before they move to OkHttp. A live
     * connection with requests in flight answers in a few round trips, far below this.
     */
    static final long STALL_MS = 500;
    /** After a stall, new downloads skip the engine for this long instead of each paying the stall again. */
    static final long STALL_COOLDOWN_MS = 60_000;

    private static volatile Transport transport;
    private static volatile boolean enabled = true;
    // System.nanoTime() until which downloads skip the engine after a stall; only read while stalledOnce is true.
    private static volatile long suspendedUntilNanos;
    private static volatile boolean stalledOnce;
    // True once the plugin or the headless worker applied the http3 config in this process.
    private static volatile boolean configured;
    // Guards the configured check plus the enabled write, kept apart from init() so it never waits on engine setup.
    private static final Object OPTION_LOCK = new Object();
    private static boolean initialized;

    private Http3() {}

    /** The http3 config value, applied by plugin load and the headless worker. Wins over saved job values. */
    static void setEnabled(boolean value) {
        synchronized (OPTION_LOCK) {
            enabled = value;
            configured = true;
        }
    }

    /**
     * The http3 value saved with a WorkManager job. Only used when this process has not loaded the config yet
     * (a job resumed in a fresh process), so a stale job never overrides the current config.
     */
    static void restoreSavedOption(boolean value) {
        synchronized (OPTION_LOCK) {
            if (!configured) {
                enabled = value;
            }
        }
    }

    static boolean isEnabled() {
        return enabled;
    }

    /** HttpEngine is public API from 34, and ships to 31-33 through the S extension at level 7. */
    static boolean isHttpEngineAvailable(int sdkInt, int sExtensionVersion) {
        return sdkInt >= 34 || (sdkInt >= 31 && sExtensionVersion >= 7);
    }

    private static int sExtensionVersion() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return 0;
        }
        return SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S);
    }

    /** Builds the shared engine once per process. Safe to call before every download. */
    static void init(@NonNull Context context, @Nullable Logger logger) {
        if (transport != null || !enabled) {
            return;
        }
        int sdkInt = Build.VERSION.SDK_INT;
        int extension;
        try {
            extension = sExtensionVersion();
        } catch (RuntimeException e) {
            extension = 0;
        }
        init(context, logger, sdkInt, extension, HttpEngineTransport::create);
    }

    static synchronized void init(
        @NonNull Context context,
        @Nullable Logger logger,
        int sdkInt,
        int sExtensionVersion,
        @NonNull TransportFactory factory
    ) {
        if (initialized || !enabled) {
            return;
        }
        initialized = true;
        if (!isHttpEngineAvailable(sdkInt, sExtensionVersion)) {
            debug(logger, "HttpEngine not available (API " + sdkInt + "), downloads stay on OkHttp");
            return;
        }
        try {
            transport = factory.create(context.getApplicationContext() != null ? context.getApplicationContext() : context, logger);
            debug(logger, "HttpEngine ready, HTTP/3 enabled for bundle downloads");
        } catch (RuntimeException | LinkageError e) {
            // LinkageError: a device that reports the extension but cannot load the engine classes.
            transport = null;
            if (logger != null) {
                logger.warn("HttpEngine failed to start, downloads stay on OkHttp: " + e.getMessage());
            }
        }
    }

    @Nullable
    static Transport transport() {
        return transport;
    }

    /** Called when the engine stalled: downloads use OkHttp for {@link #STALL_COOLDOWN_MS}. */
    static void suspendAfterStall(long nowNanos) {
        suspendedUntilNanos = nowNanos + TimeUnit.MILLISECONDS.toNanos(STALL_COOLDOWN_MS);
        stalledOnce = true;
    }

    static boolean isSuspended(long nowNanos) {
        return stalledOnce && nowNanos - suspendedUntilNanos < 0;
    }

    /** Test hook: forget the engine so the next init() starts over. */
    static synchronized void resetForTest() {
        transport = null;
        initialized = false;
        stalledOnce = false;
        synchronized (OPTION_LOCK) {
            enabled = true;
            configured = false;
        }
    }

    @NonNull
    static Request.Builder markDownload(@NonNull Request.Builder builder) {
        return builder.tag(Download.class, Download.TAG);
    }

    static boolean shouldUseEngine(@NonNull Request request) {
        return (
            enabled &&
            request.tag(Download.class) != null &&
            "GET".equals(request.method()) &&
            request.body() == null &&
            // HTTP/3 only exists over TLS, so plain http (local dev servers) keeps the OkHttp path.
            request.isHttps() &&
            !isSuspended(System.nanoTime())
        );
    }

    /**
     * Last application interceptor on the shared client, so User-Agent and the httpsOnly gate already ran.
     * The engine follows redirects itself, and checks every hop with {@link #redirectError}.
     */
    static final class EngineInterceptor implements Interceptor {

        @NonNull
        @Override
        public Response intercept(@NonNull Chain chain) throws IOException {
            Request request = chain.request();
            Transport current = transport;
            if (current == null || !shouldUseEngine(request)) {
                Response response = chain.proceed(request);
                if (request.tag(Download.class) != null) {
                    logProtocol("OkHttp", response.protocol().toString(), request.url(), response.code());
                }
                return response;
            }
            try {
                return current.execute(request, chain.connectTimeoutMillis(), chain.readTimeoutMillis(), chain.call());
            } catch (EngineStalledException stall) {
                // No response headers yet, so nothing reached the caller: retry this download on OkHttp right away.
                suspendAfterStall(System.nanoTime());
                Logger logger = DownloadService.logger();
                if (logger != null) {
                    logger.warn("HttpEngine stalled, download moved to OkHttp: " + stall.getMessage());
                }
                Response response = chain.proceed(request);
                logProtocol("OkHttp", response.protocol().toString(), request.url(), response.code());
                return response;
            }
        }
    }

    /** Maps HttpEngine's ALPN name (h3, h2, http/1.1, quic/1+spdy/3...) to the closest OkHttp protocol. */
    @NonNull
    static Protocol protocolFor(@Nullable String negotiated) {
        if (negotiated == null) {
            return Protocol.HTTP_1_1;
        }
        String value = negotiated.toLowerCase(Locale.ROOT);
        if (value.startsWith("h3") || value.startsWith("quic")) {
            return Protocol.QUIC;
        }
        if (value.equals("h2")) {
            return Protocol.HTTP_2;
        }
        if (value.equals("http/1.0")) {
            return Protocol.HTTP_1_0;
        }
        return Protocol.HTTP_1_1;
    }

    /**
     * HttpEngine always negotiates gzip/br and hands back the decoded body, but keeps the encoded headers. Drop
     * Content-Encoding and Content-Length then, as OkHttp does after transparent gzip, so callers see an unknown
     * length instead of a wrong one (the checksum still verifies the bytes).
     */
    @NonNull
    static Headers responseHeaders(@NonNull List<Map.Entry<String, String>> fields) {
        boolean decoded = false;
        for (Map.Entry<String, String> field : fields) {
            if (field.getKey() != null && field.getKey().equalsIgnoreCase("Content-Encoding")) {
                decoded = true;
                break;
            }
        }
        Headers.Builder headers = new Headers.Builder();
        for (Map.Entry<String, String> field : fields) {
            String name = field.getKey();
            if (name == null || field.getValue() == null) {
                continue;
            }
            if (decoded && (name.equalsIgnoreCase("Content-Encoding") || name.equalsIgnoreCase("Content-Length"))) {
                continue;
            }
            headers.addUnsafeNonAscii(name, field.getValue());
        }
        return headers.build();
    }

    /** Same policy as the shared client's network interceptor, for redirects the engine follows itself. */
    @Nullable
    static IOException redirectError(@Nullable String from, @Nullable String to) {
        return redirectError(from, to, DownloadService.httpsOnly, DownloadService.isAllowHttpsToHttpRedirect());
    }

    @Nullable
    static IOException redirectError(@Nullable String from, @Nullable String to, boolean httpsOnly, boolean allowHttpsToHttp) {
        HttpUrl target = to == null ? null : HttpUrl.parse(to);
        if (target == null) {
            return new IOException("Invalid redirect location");
        }
        if (httpsOnly && !target.isHttps()) {
            return new IOException(CapgoUpdater.httpsOnlyMessage(to));
        }
        HttpUrl source = from == null ? null : HttpUrl.parse(from);
        if (source != null && source.isHttps() && !target.isHttps() && !allowHttpsToHttp) {
            return new DownloadService.BlockedRedirectException();
        }
        return null;
    }

    static void logProtocol(String transportName, @Nullable String protocol, @NonNull HttpUrl url, int code) {
        Logger logger = DownloadService.logger();
        if (logger != null) {
            logger.debug(
                "Download protocol " +
                    (protocol == null || protocol.isEmpty() ? "unknown" : protocol) +
                    " via " +
                    transportName +
                    " (HTTP " +
                    code +
                    ") " +
                    url.host() +
                    url.encodedPath()
            );
        }
    }

    private static void debug(@Nullable Logger logger, String message) {
        if (logger != null) {
            logger.debug(message);
        }
    }
}
