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
import java.util.List;
import java.util.Locale;
import java.util.Map;
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

    private static volatile Transport transport;
    private static volatile boolean enabled = true;
    // True once the plugin or the headless worker applied the http3 config in this process.
    private static volatile boolean configured;
    private static boolean initialized;

    private Http3() {}

    /** The http3 config value, applied by plugin load and the headless worker. Wins over saved job values. */
    static void setEnabled(boolean value) {
        enabled = value;
        configured = true;
    }

    /**
     * The http3 value saved with a WorkManager job. Only used when this process has not loaded the config yet
     * (a job resumed in a fresh process), so a stale job never overrides the current config.
     */
    static void restoreSavedOption(boolean value) {
        if (!configured) {
            enabled = value;
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

    /** Test hook: forget the engine so the next init() starts over. */
    static synchronized void resetForTest() {
        transport = null;
        initialized = false;
        enabled = true;
        configured = false;
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
            request.isHttps()
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
            return current.execute(request, chain.connectTimeoutMillis(), chain.readTimeoutMillis(), chain.call());
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
