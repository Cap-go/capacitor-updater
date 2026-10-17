/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.Context;
import android.net.http.HttpEngine;
import android.net.http.HttpException;
import android.net.http.NetworkException;
import android.net.http.UploadDataProvider;
import android.net.http.UploadDataSink;
import android.net.http.UrlRequest;
import android.net.http.UrlResponseInfo;
import android.os.Build;
import android.os.ext.SdkExtensions;
import androidx.annotation.RequiresApi;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Executor;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The engine's {@code http_request} host transport on Android 14+ (API 34): {@code android.net.http.HttpEngine},
 * the platform's Cronet, with HTTP/2 and HTTP/3 (QUIC), the system proxy and connection pooling. Below API 34, or
 * when the engine cannot be built, {@link #request} returns {@code null} and the core uses its own HTTP/1.1 client.
 *
 * <p>TLS trust and pinning: the engine's own client verified chains with {@code X509TrustManagerExtensions
 * .checkServerTrusted(chain, authType, host)} on the default trust manager, which applies the app's network security
 * config (trust anchors, user CAs, per-domain {@code pin-set}). HttpEngine verifies server chains through the same
 * platform {@code X509TrustManagerExtensions} with the host name, so the same anchors and pins apply to it. The
 * cleartext policy is still checked by the core before every request.
 *
 * <p>Threading: a request runs entirely on the engine thread that called {@link #request}. That thread is the
 * request's executor: it runs the {@link UrlRequest.Callback} methods, which report to the core through the
 * {@link CapgoCoreNative} sink natives, one at a time, before {@link #request} returns.
 */
final class CapgoHttpTransport {

    private static final int READ_BUFFER_BYTES = 64 * 1024;
    /** After a cancel, how long to wait for HttpEngine to confirm it before giving up on the request. */
    private static final long CANCEL_GRACE_MS = 10_000;

    private CapgoHttpTransport() {}

    /** Whether this device has HttpEngine (API 34+, which carries the S extension 7 it needs). */
    static boolean supported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return false;
        }
        try {
            return SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 7;
        } catch (final Throwable e) {
            return false;
        }
    }

    /**
     * Sends one request (see {@code http_request} in {@code core/include/capgo_updater_core.h}). Returns the result
     * JSON ({@code {"protocol": ...}} or {@code {"error": kind, "message": ...}}), or {@code null} when nothing was
     * sent and the core must use its own client.
     */
    static String request(
        final Context context,
        final String method,
        final String url,
        final String headersJson,
        final byte[] body,
        final long timeoutMs,
        final String bodyPath,
        final long sink
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return null;
        }
        if (SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) < 7) {
            return null;
        }
        if (context == null) {
            return null;
        }
        return Api34.request(context, method, url, headersJson, body, timeoutMs, bodyPath, sink);
    }

    // ------------------------------------------------------------------------------------------------ JSON helpers

    /** Request headers from the core: a JSON array of {@code [name, value]} pairs. */
    static String[][] parseHeaders(final String headersJson) throws JSONException {
        final JSONArray pairs = new JSONArray(headersJson == null || headersJson.isEmpty() ? "[]" : headersJson);
        final String[][] headers = new String[pairs.length()][];
        for (int index = 0; index < pairs.length(); index++) {
            final JSONArray pair = pairs.getJSONArray(index);
            headers[index] = new String[] { pair.getString(0), pair.getString(1) };
        }
        return headers;
    }

    /** Response headers for the core, in order: a JSON array of {@code [name, value]} pairs. */
    static String headersJson(final List<Map.Entry<String, String>> headers) {
        final JSONArray pairs = new JSONArray();
        if (headers != null) {
            for (final Map.Entry<String, String> header : headers) {
                if (header.getKey() != null && header.getValue() != null) {
                    pairs.put(new JSONArray().put(header.getKey()).put(header.getValue()));
                }
            }
        }
        return pairs.toString();
    }

    /** {@code {"protocol": ...}} (lower case); an unknown protocol is left out. */
    static String completed(final String protocol) {
        try {
            final JSONObject result = new JSONObject();
            if (protocol != null && !protocol.isEmpty()) {
                result.put("protocol", protocol.toLowerCase(Locale.ROOT));
            }
            return result.toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    static String failed(final String kind, final String message) {
        try {
            return new JSONObject()
                .put("error", kind)
                .put("message", message == null ? kind : message)
                .toString();
        } catch (JSONException e) {
            return "{\"error\":\"network\"}";
        }
    }

    /**
     * Error kind of an HttpEngine failure: certificate and TLS errors ({@code net::ERR_CERT_*}, {@code ERR_SSL_*})
     * are {@code tls}, timeouts {@code timeout}, malformed URLs {@code invalid_url}, the rest {@code network}.
     * {@code networkErrorCode} is {@code NetworkException.getErrorCode()}, or -1 for other failures.
     */
    static String errorKind(final int networkErrorCode, final String message) {
        final String text = message == null ? "" : message;
        if (text.contains("ERR_CERT_") || text.contains("ERR_SSL_") || text.contains("ERR_BAD_SSL")) {
            return "tls";
        }
        if (text.contains("ERR_INVALID_URL") || text.contains("ERR_UNKNOWN_URL_SCHEME")) {
            return "invalid_url";
        }
        if (
            networkErrorCode == ERROR_TIMED_OUT ||
            networkErrorCode == ERROR_CONNECTION_TIMED_OUT ||
            text.contains("ERR_TIMED_OUT") ||
            text.contains("ERR_CONNECTION_TIMED_OUT")
        ) {
            return "timeout";
        }
        return "network";
    }

    /** {@code NetworkException.ERROR_TIMED_OUT} (constant of API 34, inlined so older devices never load the class). */
    static final int ERROR_TIMED_OUT = 4;
    /** {@code NetworkException.ERROR_CONNECTION_TIMED_OUT}. */
    static final int ERROR_CONNECTION_TIMED_OUT = 6;

    // ------------------------------------------------------------------------------------------------ HttpEngine

    /** Most origins given a QUIC hint in one process (each new one rebuilds the engine once). */
    static final int MAX_QUIC_HINTS = 16;

    /**
     * The HTTP/3 alternative an {@code Alt-Svc} header announces for an HTTPS origin, as {@code [host, port, altPort]}
     * of {@code HttpEngine.Builder.addQuicHint}, or {@code null}. Only {@code h3} on the same host counts.
     */
    static Object[] quicHint(final String url, final String altSvc) {
        if (altSvc == null || url == null) {
            return null;
        }
        final java.net.URI uri;
        try {
            uri = new java.net.URI(url);
        } catch (final java.net.URISyntaxException e) {
            return null;
        }
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null) {
            return null;
        }
        final int port = uri.getPort() > 0 ? uri.getPort() : 443;
        for (final String entry : altSvc.split(",")) {
            final String value = entry.trim();
            if (!value.startsWith("h3=\"")) {
                continue;
            }
            final int end = value.indexOf('"', 4);
            if (end < 0) {
                continue;
            }
            final String authority = value.substring(4, end);
            final int colon = authority.lastIndexOf(':');
            if (colon < 0 || (colon > 0 && !authority.substring(0, colon).equalsIgnoreCase(uri.getHost()))) {
                continue;
            }
            try {
                final int altPort = Integer.parseInt(authority.substring(colon + 1));
                if (altPort > 0 && altPort <= 65535) {
                    return new Object[] { uri.getHost(), port, altPort };
                }
            } catch (final NumberFormatException ignored) {
                // Not a port: skip this entry.
            }
        }
        return null;
    }

    /** {@code host:port} of an HTTPS URL (the key of a QUIC hint), or {@code null}. */
    static String httpsOrigin(final String url) {
        try {
            final java.net.URI uri = new java.net.URI(url);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null) {
                return null;
            }
            return uri.getHost() + ":" + (uri.getPort() > 0 ? uri.getPort() : 443);
        } catch (final java.net.URISyntaxException e) {
            return null;
        }
    }

    /** Everything that touches {@code android.net.http}: loaded only on devices that have it. */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private static final class Api34 {

        /** One built HttpEngine, the origins it was given a QUIC hint for, and the requests it still carries. */
        static final class Lease {

            final HttpEngine engine;
            final java.util.Set<String> hinted;
            int inFlight;
            boolean retired;

            Lease(final HttpEngine engine, final java.util.Set<String> hinted) {
                this.engine = engine;
                this.hinted = hinted;
            }
        }

        /** Learned QUIC hints, kept across launches: one {@code host port altPort} line each. */
        private static final String HINTS_FILE = "capgo_quic_hints";
        private static final Object LOCK = new Object();
        private static Lease current;
        private static boolean unavailable;
        private static boolean loaded;
        /** Origin ({@code host:port}) to its hint {@code [host, port, altPort]}. */
        private static final java.util.LinkedHashMap<String, Object[]> hints = new java.util.LinkedHashMap<>();
        private static boolean rebuild;

        private Api34() {}

        private static java.io.File hintsFile(final Context context) {
            return new java.io.File(context.getNoBackupFilesDir(), HINTS_FILE);
        }

        /** Caller holds LOCK. */
        private static void load(final Context context) {
            if (loaded) {
                return;
            }
            loaded = true;
            final java.io.File file = hintsFile(context);
            if (!file.isFile()) {
                return;
            }
            try (
                java.io.BufferedReader reader = new java.io.BufferedReader(
                    new java.io.InputStreamReader(new java.io.FileInputStream(file), java.nio.charset.StandardCharsets.UTF_8)
                )
            ) {
                String line;
                while ((line = reader.readLine()) != null && hints.size() < MAX_QUIC_HINTS) {
                    final String[] parts = line.trim().split(" ");
                    if (parts.length != 3) {
                        continue;
                    }
                    try {
                        final Object[] hint = { parts[0], Integer.parseInt(parts[1]), Integer.parseInt(parts[2]) };
                        hints.put(parts[0] + ":" + parts[1], hint);
                    } catch (final NumberFormatException ignored) {
                        // A damaged line: skipped.
                    }
                }
            } catch (final IOException ignored) {
                // No hints: origins are learned again from their Alt-Svc answers.
            }
        }

        /** Caller holds LOCK. Best effort: a lost write only costs one HTTP/2 answer per origin. */
        private static void save(final Context context) {
            final StringBuilder text = new StringBuilder();
            for (final Object[] hint : hints.values()) {
                text.append(hint[0]).append(' ').append(hint[1]).append(' ').append(hint[2]).append('\n');
            }
            final java.io.File file = hintsFile(context);
            final java.io.File temp = new java.io.File(file.getPath() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(temp)) {
                out.write(text.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
            } catch (final IOException e) {
                temp.delete();
                return;
            }
            if (!temp.renameTo(file)) {
                temp.delete();
            }
        }

        /**
         * HttpEngine moves an origin to HTTP/3 only for new connections: a host first reached over HTTP/2 keeps that
         * connection even once its {@code Alt-Svc} announced HTTP/3. So an HTTPS origin announcing HTTP/3 gets a QUIC
         * hint, kept for the next launches, and the next request builds a new engine that starts with QUIC (its TCP
         * attempt waits briefly and takes over when QUIC fails). The old engine shuts down once its requests end.
         */
        static void learn(final Context context, final Object[] hint) {
            synchronized (LOCK) {
                load(context);
                final String origin = hint[0] + ":" + hint[1];
                if (!hints.containsKey(origin) && hints.size() < MAX_QUIC_HINTS) {
                    hints.put(origin, hint);
                    rebuild = true;
                    save(context);
                }
            }
        }

        /** A hinted origin still answered without HTTP/3 (UDP blocked, QUIC gone): not hinted on the next launch. */
        static void forget(final Context context, final String origin) {
            synchronized (LOCK) {
                if (hints.remove(origin) != null) {
                    save(context);
                }
            }
        }

        /** No storage path: HttpEngine keeps no disk cache and no state of its own between launches. */
        private static HttpEngine build(final Context context) {
            final HttpEngine.Builder builder = new HttpEngine.Builder(context)
                .setEnableQuic(true)
                .setEnableHttp2(true)
                // The core asks for gzip (API calls) or identity (bundle files) itself.
                .setEnableBrotli(false)
                .setEnableHttpCache(HttpEngine.Builder.HTTP_CACHE_DISABLED, 0);
            for (final Object[] hint : hints.values()) {
                builder.addQuicHint((String) hint[0], (Integer) hint[1], (Integer) hint[2]);
            }
            return builder.build();
        }

        /** The engine for one request ({@link #release} it after); {@code null} when HttpEngine cannot be built. */
        static Lease acquire(final Context context) {
            synchronized (LOCK) {
                if (unavailable) {
                    return null;
                }
                load(context);
                if (current == null || rebuild) {
                    rebuild = false;
                    try {
                        final Lease previous = current;
                        current = new Lease(build(context), new java.util.HashSet<>(hints.keySet()));
                        if (previous != null) {
                            previous.retired = true;
                            shutdownIfIdle(previous);
                        }
                    } catch (final Throwable e) {
                        if (current == null) {
                            unavailable = true;
                            return null;
                        }
                        // Keep the engine that works.
                    }
                }
                current.inFlight++;
                return current;
            }
        }

        static void release(final Lease lease) {
            synchronized (LOCK) {
                lease.inFlight--;
                shutdownIfIdle(lease);
            }
        }

        /** Caller holds LOCK. */
        private static void shutdownIfIdle(final Lease lease) {
            if (lease.retired && lease.inFlight == 0) {
                try {
                    lease.engine.shutdown();
                } catch (final RuntimeException ignored) {
                    // Still busy (a callback in flight): it is released with the process.
                }
            }
        }

        static String request(
            final Context context,
            final String method,
            final String url,
            final String headersJson,
            final byte[] body,
            final long timeoutMs,
            final String bodyPath,
            final long sink
        ) {
            final Context application = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            final Lease lease = acquire(application);
            if (lease == null) {
                return null;
            }
            try {
                return new Exchange(application, lease, sink, bodyPath, timeoutMs, url).run(lease.engine, method, url, headersJson, body);
            } finally {
                release(lease);
            }
        }
    }

    /** Runs the {@link UrlRequest} callbacks on the calling thread. */
    private static final class CallingThreadExecutor implements Executor {

        final LinkedBlockingQueue<Runnable> queue = new LinkedBlockingQueue<>();

        @Override
        public void execute(final Runnable command) {
            queue.add(command);
        }
    }

    /** The request body, read on the calling thread. */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private static final class BytesUpload extends UploadDataProvider {

        private final byte[] bytes;
        private int position;

        BytesUpload(final byte[] bytes) {
            this.bytes = bytes;
        }

        @Override
        public long getLength() {
            return bytes.length;
        }

        @Override
        public void read(final UploadDataSink sink, final ByteBuffer buffer) {
            final int count = Math.min(buffer.remaining(), bytes.length - position);
            buffer.put(bytes, position, count);
            position += count;
            sink.onReadSucceeded(false);
        }

        @Override
        public void rewind(final UploadDataSink sink) {
            position = 0;
            sink.onRewindSucceeded();
        }
    }

    /** State of one request; touched only by the calling thread (it is the executor). */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private static final class Exchange implements UrlRequest.Callback {

        /** cancelReason of a redirect handed to the core: the request ends as completed. */
        private static final String REDIRECT = "redirect";

        private final Context context;
        private final Api34.Lease lease;
        private final long sink;
        private final String bodyPath;
        private final long timeoutMs;
        private final String url;
        private final CallingThreadExecutor executor = new CallingThreadExecutor();
        private FileChannel file;
        private long appended;
        private String result;
        private boolean done;
        /** Why the request was cancelled from here; null when it was not. */
        private String cancelReason;
        private String cancelMessage;
        private String protocol;

        Exchange(
            final Context context,
            final Api34.Lease lease,
            final long sink,
            final String bodyPath,
            final long timeoutMs,
            final String url
        ) {
            this.context = context;
            this.lease = lease;
            this.sink = sink;
            this.bodyPath = bodyPath;
            this.timeoutMs = timeoutMs <= 0 ? 60_000 : timeoutMs;
            this.url = url;
        }

        /**
         * An HTTPS origin reached without HTTP/3 that announces it gets a QUIC hint for the next engine; a hinted origin
         * that still answered without HTTP/3 loses its hint for the next launches.
         */
        private void learnAltSvc(final UrlResponseInfo info) {
            final String negotiated = info.getNegotiatedProtocol();
            if (negotiated != null && (negotiated.startsWith("h3") || negotiated.contains("quic"))) {
                return;
            }
            final String origin = httpsOrigin(url);
            if (origin == null) {
                return;
            }
            if (lease.hinted.contains(origin)) {
                Api34.forget(context, origin);
                return;
            }
            for (final Map.Entry<String, String> header : info.getHeaders().getAsList()) {
                if ("alt-svc".equalsIgnoreCase(header.getKey())) {
                    final Object[] hint = quicHint(url, header.getValue());
                    if (hint != null) {
                        Api34.learn(context, hint);
                        return;
                    }
                }
            }
        }

        String run(final HttpEngine engine, final String method, final String url, final String headersJson, final byte[] body) {
            final UrlRequest request;
            try {
                final UrlRequest.Builder builder = engine
                    .newUrlRequestBuilder(url, executor, this)
                    .setHttpMethod(method)
                    .setCacheDisabled(true)
                    .setPriority(UrlRequest.REQUEST_PRIORITY_HIGHEST);
                for (final String[] header : parseHeaders(headersJson)) {
                    builder.addHeader(header[0], header[1]);
                }
                if (body != null) {
                    builder.setUploadDataProvider(new BytesUpload(body), executor);
                }
                request = builder.build();
                request.start();
            } catch (final JSONException | IllegalArgumentException e) {
                return failed("invalid_url", "Invalid request: " + e.getMessage());
            } catch (final RuntimeException e) {
                return failed("network", e.getMessage());
            }
            boolean interrupted = false;
            long cancelDeadline = 0;
            while (!done) {
                final long wait = cancelDeadline > 0 ? Math.max(1, cancelDeadline - System.currentTimeMillis()) : timeoutMs;
                Runnable next;
                try {
                    next = executor.queue.poll(wait, TimeUnit.MILLISECONDS);
                } catch (final InterruptedException e) {
                    interrupted = true;
                    cancel(request, "cancelled", "Request interrupted");
                    if (cancelDeadline == 0) {
                        cancelDeadline = System.currentTimeMillis() + CANCEL_GRACE_MS;
                    }
                    continue;
                }
                if (next != null) {
                    try {
                        next.run();
                    } catch (final RuntimeException e) {
                        cancel(request, "network", e.getMessage());
                    }
                } else if (cancelReason == null) {
                    // Idle timeout: nothing moved for timeoutMs.
                    cancel(request, "timeout", "The request timed out (no progress for " + timeoutMs + " ms)");
                } else if (System.currentTimeMillis() >= cancelDeadline) {
                    // HttpEngine never confirmed the cancel: stop waiting for it.
                    finish(REDIRECT.equals(cancelReason) ? completed(protocol) : failed(cancelReason, cancelMessage));
                }
                if (cancelReason != null && cancelDeadline == 0) {
                    cancelDeadline = System.currentTimeMillis() + CANCEL_GRACE_MS;
                }
            }
            closeFile();
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
            return result;
        }

        private void cancel(final UrlRequest request, final String reason, final String message) {
            if (cancelReason == null) {
                cancelReason = reason;
                cancelMessage = message;
            }
            request.cancel();
        }

        private void finish(final String outcome) {
            closeFile();
            if (!done) {
                result = outcome;
                done = true;
            }
        }

        private void closeFile() {
            if (file != null) {
                try {
                    file.close();
                } catch (final IOException ignored) {
                    // Nothing more is written.
                }
                file = null;
            }
        }

        private static String headersOf(final UrlResponseInfo info) {
            return headersJson(info.getHeaders() == null ? null : info.getHeaders().getAsList());
        }

        @Override
        public void onRedirectReceived(final UrlRequest request, final UrlResponseInfo info, final String newLocationUrl) {
            // The core follows redirects itself (count limit, HTTPS -> HTTP guard): the 3xx is its response and
            // it declines the body. HttpEngine never follows one (no followRedirect()).
            protocol = info.getNegotiatedProtocol();
            CapgoCoreNative.httpHead(sink, info.getHttpStatusCode(), headersOf(info));
            cancel(request, REDIRECT, null);
        }

        @Override
        public void onResponseStarted(final UrlRequest request, final UrlResponseInfo info) {
            protocol = info.getNegotiatedProtocol();
            learnAltSvc(info);
            if (CapgoCoreNative.httpHead(sink, info.getHttpStatusCode(), headersOf(info)) != 0) {
                cancel(request, "cancelled", "Request cancelled");
                return;
            }
            if (bodyPath != null) {
                try {
                    // The core prepared the file (truncated, or kept for a resume): append to it.
                    file = new FileOutputStream(bodyPath, true).getChannel();
                } catch (final IOException e) {
                    cancel(request, "io", e.getMessage());
                    return;
                }
            }
            request.read(ByteBuffer.allocateDirect(READ_BUFFER_BYTES));
        }

        @Override
        public void onReadCompleted(final UrlRequest request, final UrlResponseInfo info, final ByteBuffer buffer) {
            buffer.flip();
            final int status;
            if (file == null) {
                status = CapgoCoreNative.httpData(sink, buffer, buffer.position(), buffer.remaining());
            } else {
                try {
                    while (buffer.hasRemaining()) {
                        appended += file.write(buffer);
                    }
                } catch (final IOException e) {
                    cancel(request, "io", e.getMessage());
                    return;
                }
                status = CapgoCoreNative.httpProgress(sink, appended);
            }
            if (status != 0) {
                cancel(request, "cancelled", "Request cancelled");
                return;
            }
            buffer.clear();
            request.read(buffer);
        }

        @Override
        public void onSucceeded(final UrlRequest request, final UrlResponseInfo info) {
            finish(completed(info.getNegotiatedProtocol()));
        }

        @Override
        public void onFailed(final UrlRequest request, final UrlResponseInfo info, final HttpException error) {
            if (cancelReason != null && !REDIRECT.equals(cancelReason)) {
                // A failure we caused first (write error, timeout, core cancel).
                finish(failed(cancelReason, cancelMessage != null ? cancelMessage : error.getMessage()));
                return;
            }
            final int code = error instanceof NetworkException ? ((NetworkException) error).getErrorCode() : -1;
            finish(failed(errorKind(code, error.getMessage()), error.getMessage()));
        }

        @Override
        public void onCanceled(final UrlRequest request, final UrlResponseInfo info) {
            if (REDIRECT.equals(cancelReason)) {
                finish(completed(protocol));
            } else {
                finish(
                    failed(cancelReason == null ? "cancelled" : cancelReason, cancelMessage == null ? "Request cancelled" : cancelMessage)
                );
            }
        }
    }
}
