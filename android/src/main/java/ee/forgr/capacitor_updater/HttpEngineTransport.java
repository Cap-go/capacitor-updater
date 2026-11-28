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
import android.net.http.UrlRequest;
import android.net.http.UrlResponseInfo;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresExtension;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.net.ConnectException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import okhttp3.Call;
import okhttp3.Headers;
import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.Okio;

/**
 * {@link Http3.Transport} on the platform HttpEngine. Uses the UrlRequest callback API rather than the engine's
 * HttpURLConnection so every redirect hop goes through the updater's https policy, timeouts are enforced (the
 * engine ignores connect timeouts), and the negotiated protocol can be logged.
 */
@RequiresExtension(extension = Build.VERSION_CODES.S, version = 7)
final class HttpEngineTransport implements Http3.Transport {

    static final String STORAGE_DIR = "capgo_httpengine";
    // Room for Alt-Svc, QUIC server info and host cache only: DISK_NO_HTTP never stores a response body.
    private static final long STORAGE_BYTES = 1024 * 1024;
    private static final int READ_BUFFER_BYTES = 32 * 1024;
    // Poll slice so a cancelled OkHttp call (WorkManager stop) stops waiting promptly and a stall is seen within
    // 50 ms of the stall window.
    private static final long POLL_MS = 50;

    private final HttpEngine engine;
    private final Executor callbackExecutor;
    private final Liveness liveness = new Liveness();

    private HttpEngineTransport(HttpEngine engine, Executor callbackExecutor) {
        this.engine = engine;
        this.callbackExecutor = callbackExecutor;
    }

    @NonNull
    static Http3.Transport create(@NonNull Context context, @Nullable Logger logger) {
        // noBackupFilesDir: kept across launches (unlike a cache dir the OS may clear) and never restored onto
        // another device or network by Auto Backup.
        File storage = new File(context.getNoBackupFilesDir(), STORAGE_DIR);
        if (!storage.isDirectory() && !storage.mkdirs()) {
            throw new IllegalStateException("cannot create " + storage.getAbsolutePath());
        }
        HttpEngine engine = new HttpEngine.Builder(context)
            .setStoragePath(storage.getAbsolutePath())
            .setEnableHttpCache(HttpEngine.Builder.HTTP_CACHE_DISK_NO_HTTP, STORAGE_BYTES)
            .setEnableQuic(true)
            .setEnableHttp2(true)
            .build();
        ExecutorService executor = Executors.newSingleThreadExecutor((runnable) -> {
            Thread thread = new Thread(runnable, "capgo-httpengine");
            thread.setDaemon(true);
            return thread;
        });
        return new HttpEngineTransport(engine, executor);
    }

    @NonNull
    @Override
    public Response execute(@NonNull Request request, int connectTimeoutMs, int readTimeoutMs, @Nullable Call call) throws IOException {
        EngineCall engineCall = new EngineCall(request.url().toString(), call, liveness, Http3.STALL_MS);
        UrlRequest.Builder builder = engine.newUrlRequestBuilder(request.url().toString(), callbackExecutor, engineCall);
        builder.setHttpMethod("GET");
        Headers headers = request.headers();
        for (int i = 0; i < headers.size(); i++) {
            builder.addHeader(headers.name(i), headers.value(i));
        }
        UrlRequest urlRequest = builder.build();
        engineCall.start(urlRequest);
        // OkHttp: connect timeout for the connection, then read timeout for the response headers.
        UrlResponseInfo info = engineCall.awaitResponse(headerWaitBudgetMs(connectTimeoutMs, readTimeoutMs));
        String negotiated = info.getNegotiatedProtocol();
        Http3.logProtocol("HttpEngine", negotiated, request.url(), info.getHttpStatusCode());

        Headers responseHeaders = Http3.responseHeaders(info.getHeaders().getAsList());
        String contentType = responseHeaders.get("Content-Type");
        String contentLength = responseHeaders.get("Content-Length");
        long length = -1;
        if (contentLength != null) {
            try {
                length = Long.parseLong(contentLength.trim());
            } catch (NumberFormatException ignored) {}
        }
        String message = info.getHttpStatusText();
        Request finalRequest = request;
        String finalUrl = info.getUrl();
        if (finalUrl != null && !finalUrl.equals(request.url().toString())) {
            okhttp3.HttpUrl parsed = okhttp3.HttpUrl.parse(finalUrl);
            if (parsed != null) {
                finalRequest = request.newBuilder().url(parsed).build();
            }
        }
        InputStream body = engineCall.bodyStream(readTimeoutMs);
        return new Response.Builder()
            .request(finalRequest)
            .protocol(Http3.protocolFor(negotiated))
            .code(info.getHttpStatusCode())
            .message(message != null ? message : "")
            .headers(responseHeaders)
            .body(ResponseBody.create(Okio.buffer(Okio.source(body)), contentType != null ? MediaType.parse(contentType) : null, length))
            .build();
    }

    static IOException translate(@NonNull HttpException error) {
        if (error instanceof NetworkException) {
            return networkError(((NetworkException) error).getErrorCode(), error.getMessage(), error);
        }
        return new IOException("HttpEngine request failed: " + error.getMessage(), error);
    }

    /**
     * Maps HttpEngine network errors onto the java.net exceptions OkHttp throws for the same failure, so the
     * download retry logic ({@link DownloadService#isRetryableManifestError}) treats them the same way.
     * TLS and any other engine error stay a plain IOException, which is not retried.
     */
    @NonNull
    static IOException networkError(int errorCode, @Nullable String message, @Nullable Throwable cause) {
        String text = "HttpEngine request failed: " + message;
        IOException mapped;
        switch (errorCode) {
            case NetworkException.ERROR_HOSTNAME_NOT_RESOLVED:
                mapped = new UnknownHostException(text);
                break;
            case NetworkException.ERROR_TIMED_OUT:
            case NetworkException.ERROR_CONNECTION_TIMED_OUT:
                mapped = new SocketTimeoutException(text);
                break;
            case NetworkException.ERROR_CONNECTION_REFUSED:
                mapped = new ConnectException(text);
                break;
            case NetworkException.ERROR_INTERNET_DISCONNECTED:
            case NetworkException.ERROR_NETWORK_CHANGED:
            case NetworkException.ERROR_CONNECTION_CLOSED:
            case NetworkException.ERROR_CONNECTION_RESET:
            case NetworkException.ERROR_ADDRESS_UNREACHABLE:
            case NetworkException.ERROR_QUIC_PROTOCOL_FAILED:
                mapped = new SocketException(text);
                break;
            default:
                return new IOException(text, cause);
        }
        if (cause != null) {
            mapped.initCause(cause);
        }
        return mapped;
    }

    /** Longest wait for response headers, whatever the configured timeouts add up to (AGENTS.md: 10 minutes max). */
    static final long MAX_HEADER_WAIT_MS = 600_000;

    /** OkHttp waits connect timeout then read timeout for headers; the engine has one wait, so it gets the sum, capped. */
    static long headerWaitBudgetMs(int connectTimeoutMs, int readTimeoutMs) {
        // 0 means no timeout in OkHttp.
        if (connectTimeoutMs <= 0 || readTimeoutMs <= 0) {
            return 0;
        }
        return Math.min(MAX_HEADER_WAIT_MS, (long) connectTimeoutMs + (long) readTimeoutMs);
    }

    /** Last time any request on the shared engine got a callback: one engine, one picture of whether it is alive. */
    static final class Liveness {

        private final AtomicLong lastNanos = new AtomicLong();
        // False until the first callback: a new engine has not proven it is alive, so nothing can stall yet.
        private volatile boolean seen;

        void mark() {
            lastNanos.set(System.nanoTime());
            seen = true;
        }

        boolean seen() {
            return seen;
        }

        long lastNanos() {
            return lastNanos.get();
        }
    }

    /** Bridges the engine callbacks to a blocking response and body stream. */
    static final class EngineCall implements UrlRequest.Callback {

        private static final Object SUCCEEDED = new Object();

        private static final class Started {

            final UrlResponseInfo info;

            Started(UrlResponseInfo info) {
                this.info = info;
            }
        }

        private static final class ReadDone {

            final ByteBuffer buffer;

            ReadDone(ByteBuffer buffer) {
                this.buffer = buffer;
            }
        }

        private static final class Failed {

            final IOException error;

            Failed(IOException error) {
                this.error = error;
            }
        }

        private final BlockingQueue<Object> events = new LinkedBlockingQueue<>();
        private final String url;

        @Nullable
        private final Call call;

        private volatile UrlRequest request;
        private volatile String currentUrl;
        private volatile IOException redirectError;

        private final Liveness liveness;
        private final long stallNanos;

        EngineCall(String url, @Nullable Call call) {
            this(url, call, new Liveness(), Http3.STALL_MS);
        }

        EngineCall(String url, @Nullable Call call, @NonNull Liveness liveness, long stallMs) {
            this.url = url;
            this.currentUrl = url;
            this.call = call;
            this.liveness = liveness;
            this.stallNanos = TimeUnit.MILLISECONDS.toNanos(stallMs);
        }

        void start(UrlRequest urlRequest) {
            this.request = urlRequest;
            urlRequest.start();
        }

        @Override
        public void onRedirectReceived(@NonNull UrlRequest urlRequest, @NonNull UrlResponseInfo info, @NonNull String newLocationUrl) {
            liveness.mark();
            IOException error = Http3.redirectError(currentUrl, newLocationUrl);
            if (error != null) {
                redirectError = error;
                urlRequest.cancel();
                return;
            }
            currentUrl = newLocationUrl;
            urlRequest.followRedirect();
        }

        @Override
        public void onResponseStarted(@NonNull UrlRequest urlRequest, @NonNull UrlResponseInfo info) {
            liveness.mark();
            events.offer(new Started(info));
        }

        @Override
        public void onReadCompleted(@NonNull UrlRequest urlRequest, @NonNull UrlResponseInfo info, @NonNull ByteBuffer byteBuffer) {
            liveness.mark();
            events.offer(new ReadDone(byteBuffer));
        }

        @Override
        public void onSucceeded(@NonNull UrlRequest urlRequest, @NonNull UrlResponseInfo info) {
            liveness.mark();
            events.offer(SUCCEEDED);
        }

        @Override
        public void onFailed(@NonNull UrlRequest urlRequest, @Nullable UrlResponseInfo info, @NonNull HttpException error) {
            liveness.mark();
            events.offer(new Failed(translate(error)));
        }

        @Override
        public void onCanceled(@NonNull UrlRequest urlRequest, @Nullable UrlResponseInfo info) {
            IOException error = redirectError;
            events.offer(new Failed(error != null ? error : new IOException("Canceled")));
        }

        /**
         * Next callback event, or null on timeout (0 waits forever). Cancels the request when OkHttp's call is.
         * Throws {@link Http3.EngineStalledException} when the whole engine went silent for the stall window: always
         * while waiting for headers (the caller can still retry on OkHttp) if the engine was busy just before, and
         * while reading a body only once a stall is already confirmed, so a slow single body never trips it.
         */
        @Nullable
        private Object next(long timeoutMs, boolean waitingForHeaders) throws IOException {
            long start = System.nanoTime();
            long deadline = timeoutMs > 0 ? start + TimeUnit.MILLISECONDS.toNanos(timeoutMs) : Long.MAX_VALUE;
            try {
                while (true) {
                    if (call != null && call.isCanceled()) {
                        cancel();
                        throw new IOException("Canceled");
                    }
                    checkStall(start, waitingForHeaders);
                    long remainingMs = timeoutMs > 0 ? TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()) : POLL_MS;
                    if (remainingMs <= 0) {
                        return null;
                    }
                    Object event = events.poll(Math.min(POLL_MS, remainingMs), TimeUnit.MILLISECONDS);
                    if (event != null) {
                        return event;
                    }
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                cancel();
                throw new InterruptedIOException("interrupted");
            }
        }

        private void checkStall(long waitStartNanos, boolean waitingForHeaders) throws Http3.EngineStalledException {
            long now = System.nanoTime();
            boolean seen = liveness.seen();
            long last = seen ? liveness.lastNanos() : waitStartNanos;
            // Headers: only when the engine was busy right before this wait, since the first request of a process,
            // or a lone one after a quiet period, pays a full handshake that can take longer on a slow network.
            boolean armed = waitingForHeaders ? seen && last - (waitStartNanos - stallNanos) >= 0 : Http3.isSuspended(now);
            long silentSince = last - waitStartNanos >= 0 ? last : waitStartNanos;
            if (armed && now - silentSince >= stallNanos) {
                cancel();
                throw new Http3.EngineStalledException(
                    "HttpEngine made no progress for " + TimeUnit.NANOSECONDS.toMillis(now - silentSince) + " ms on " + url
                );
            }
        }

        UrlResponseInfo awaitResponse(long timeoutMs) throws IOException {
            Object event = next(timeoutMs, true);
            if (event instanceof Started) {
                return ((Started) event).info;
            }
            if (event instanceof Failed) {
                throw ((Failed) event).error;
            }
            cancel();
            throw new SocketTimeoutException("HttpEngine timeout waiting for response headers from " + url);
        }

        InputStream bodyStream(int readTimeoutMs) {
            return new BodyStream(readTimeoutMs);
        }

        void cancel() {
            UrlRequest current = request;
            if (current != null && !current.isDone()) {
                current.cancel();
            }
        }

        private final class BodyStream extends InputStream {

            private final int readTimeoutMs;
            private final ByteBuffer buffer = ByteBuffer.allocateDirect(READ_BUFFER_BYTES);
            private boolean done;
            private boolean closed;

            BodyStream(int readTimeoutMs) {
                this.readTimeoutMs = readTimeoutMs;
                buffer.limit(0);
            }

            @Override
            public int read() throws IOException {
                byte[] one = new byte[1];
                int n = read(one, 0, 1);
                return n == -1 ? -1 : one[0] & 0xff;
            }

            @Override
            public int read(@NonNull byte[] target, int offset, int length) throws IOException {
                if (closed) {
                    throw new IOException("closed");
                }
                if (length == 0) {
                    return 0;
                }
                while (!buffer.hasRemaining()) {
                    if (done) {
                        return -1;
                    }
                    buffer.clear();
                    request.read(buffer);
                    Object event = next(readTimeoutMs, false);
                    if (event instanceof ReadDone) {
                        buffer.flip();
                    } else if (event == SUCCEEDED) {
                        done = true;
                        buffer.limit(0);
                    } else if (event instanceof Failed) {
                        done = true;
                        buffer.limit(0);
                        throw ((Failed) event).error;
                    } else {
                        done = true;
                        buffer.limit(0);
                        cancel();
                        throw new SocketTimeoutException("HttpEngine read timeout");
                    }
                }
                int count = Math.min(length, buffer.remaining());
                buffer.get(target, offset, count);
                return count;
            }

            @Override
            public int available() {
                return buffer.remaining();
            }

            @Override
            public void close() {
                if (closed) {
                    return;
                }
                closed = true;
                if (!done) {
                    cancel();
                }
            }
        }
    }
}
