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

    /** Everything that touches {@code android.net.http}: loaded only on devices that have it. */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private static final class Api34 {

        private static final Object LOCK = new Object();
        private static HttpEngine engine;
        private static boolean unavailable;

        private Api34() {}

        /** The process-wide HttpEngine, built on first use; {@code null} when it cannot be built. */
        static HttpEngine engine(final Context context) {
            synchronized (LOCK) {
                if (engine == null && !unavailable) {
                    try {
                        final Context application = context.getApplicationContext();
                        // No storage path: no disk cache and no persisted Alt-Svc / QUIC hints, so each process
                        // learns HTTP/3 from the first Alt-Svc answer of a host.
                        engine = new HttpEngine.Builder(application != null ? application : context)
                            .setEnableQuic(true)
                            .setEnableHttp2(true)
                            // The core asks for gzip (API calls) or identity (bundle files) itself.
                            .setEnableBrotli(false)
                            .setEnableHttpCache(HttpEngine.Builder.HTTP_CACHE_DISABLED, 0)
                            .build();
                    } catch (final Throwable e) {
                        unavailable = true;
                    }
                }
                return engine;
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
            final HttpEngine httpEngine = engine(context);
            if (httpEngine == null) {
                return null;
            }
            return new Exchange(sink, bodyPath, timeoutMs).run(httpEngine, method, url, headersJson, body);
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

        private final long sink;
        private final String bodyPath;
        private final long timeoutMs;
        private final CallingThreadExecutor executor = new CallingThreadExecutor();
        private FileChannel file;
        private long appended;
        private String result;
        private boolean done;
        /** Why the request was cancelled from here; null when it was not. */
        private String cancelReason;
        private String cancelMessage;
        private String protocol;

        Exchange(final long sink, final String bodyPath, final long timeoutMs) {
            this.sink = sink;
            this.bodyPath = bodyPath;
            this.timeoutMs = timeoutMs <= 0 ? 60_000 : timeoutMs;
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
