package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.net.http.UrlRequest;
import android.net.http.UrlResponseInfo;
import java.io.IOException;
import java.io.InputStream;
import java.net.SocketTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.AbstractMap.SimpleEntry;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE, sdk = 34)
public class Http3Test {

    private static final String FILE_URL = "https://cdn.example.com/1.0.0/files/main.js";

    /** Records what reached the engine path instead of opening a real HttpEngine. */
    static final class FakeTransport implements Http3.Transport {

        final List<Request> requests = new ArrayList<>();
        int connectTimeoutMs;
        int readTimeoutMs;

        @Override
        public Response execute(Request request, int connectTimeoutMs, int readTimeoutMs, okhttp3.Call call) {
            requests.add(request);
            this.connectTimeoutMs = connectTimeoutMs;
            this.readTimeoutMs = readTimeoutMs;
            return new Response.Builder()
                .request(request)
                .protocol(Protocol.QUIC)
                .code(200)
                .message("OK")
                .body(ResponseBody.create("engine", MediaType.get("text/plain")))
                .build();
        }
    }

    private Context context;

    @Before
    public void setUp() {
        Http3.resetForTest();
        context = RuntimeEnvironment.getApplication();
    }

    @After
    public void tearDown() {
        Http3.resetForTest();
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(false);
    }

    private static Request download(String url) {
        return Http3.markDownload(new Request.Builder().url(url)).build();
    }

    /** Runs the interceptor with a chain whose proceed() is the OkHttp path. */
    private static Response intercept(Request request, AtomicInteger okHttpCalls) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(request);
        when(chain.connectTimeoutMillis()).thenReturn(1234);
        when(chain.readTimeoutMillis()).thenReturn(5678);
        when(chain.proceed(any(Request.class))).thenAnswer((invocation) -> {
            okHttpCalls.incrementAndGet();
            return new Response.Builder()
                .request(invocation.getArgument(0))
                .protocol(Protocol.HTTP_2)
                .code(200)
                .message("OK")
                .body(ResponseBody.create("okhttp", MediaType.get("text/plain")))
                .build();
        });
        return new Http3.EngineInterceptor().intercept(chain);
    }

    private FakeTransport initWith(int sdkInt, int extension) {
        FakeTransport fake = new FakeTransport();
        Http3.init(context, null, sdkInt, extension, (ctx, logger) -> fake);
        return fake;
    }

    @Test
    public void httpEngineAvailabilityFollowsApiLevelAndSExtension() {
        assertTrue(Http3.isHttpEngineAvailable(34, 0));
        assertTrue(Http3.isHttpEngineAvailable(36, 0));
        assertTrue(Http3.isHttpEngineAvailable(31, 7));
        assertTrue(Http3.isHttpEngineAvailable(33, 13));
        assertFalse(Http3.isHttpEngineAvailable(33, 6));
        assertFalse(Http3.isHttpEngineAvailable(30, 13));
        assertFalse(Http3.isHttpEngineAvailable(24, 0));
    }

    @Test
    public void taggedHttpsDownloadsUseTheEngineWithTheChainTimeouts() throws Exception {
        FakeTransport fake = initWith(34, 0);
        AtomicInteger okHttp = new AtomicInteger();
        Request request = Http3.markDownload(new Request.Builder().url(FILE_URL).header("Range", "bytes=10-")).build();

        try (Response response = intercept(request, okHttp)) {
            assertEquals("engine", response.body().string());
            assertEquals(Protocol.QUIC, response.protocol());
        }
        assertEquals(0, okHttp.get());
        assertEquals(1, fake.requests.size());
        assertEquals("bytes=10-", fake.requests.get(0).header("Range"));
        assertEquals(1234, fake.connectTimeoutMs);
        assertEquals(5678, fake.readTimeoutMs);
    }

    @Test
    public void olderDevicesNeverBuildTheEngineAndStayOnOkHttp() throws Exception {
        AtomicInteger factoryCalls = new AtomicInteger();
        Http3.init(context, null, 33, 6, (ctx, logger) -> {
            factoryCalls.incrementAndGet();
            return new FakeTransport();
        });
        assertEquals(0, factoryCalls.get());
        assertNull(Http3.transport());

        AtomicInteger okHttp = new AtomicInteger();
        try (Response response = intercept(download(FILE_URL), okHttp)) {
            assertEquals("okhttp", response.body().string());
        }
        assertEquals(1, okHttp.get());
    }

    @Test
    public void engineStartupFailureFallsBackToOkHttp() throws Exception {
        Http3.init(context, null, 34, 0, (ctx, logger) -> {
            throw new IllegalStateException("no engine");
        });
        assertNull(Http3.transport());
        AtomicInteger okHttp = new AtomicInteger();
        try (Response response = intercept(download(FILE_URL), okHttp)) {
            assertEquals("okhttp", response.body().string());
        }
        assertEquals(1, okHttp.get());

        // A device that reports the extension but cannot link the classes.
        Http3.resetForTest();
        Http3.init(context, null, 34, 0, (ctx, logger) -> {
            throw new NoClassDefFoundError("android/net/http/HttpEngine");
        });
        assertNull(Http3.transport());
    }

    @Test
    public void engineIsBuiltOncePerProcess() {
        AtomicInteger factoryCalls = new AtomicInteger();
        Http3.TransportFactory factory = (ctx, logger) -> {
            factoryCalls.incrementAndGet();
            return new FakeTransport();
        };
        Http3.init(context, null, 34, 0, factory);
        Http3.init(context, null, 34, 0, factory);
        assertEquals(1, factoryCalls.get());
        assertNotNull(Http3.transport());
    }

    @Test
    public void apiCallsBodiesAndPlainHttpStayOnOkHttp() throws Exception {
        FakeTransport fake = initWith(34, 0);
        List<Request> requests = List.of(
            // Untagged GET: update check / channel list style calls.
            new Request.Builder()
                .url("https://api.capgo.app/channel_self")
                .build(),
            // Tagged but with a body.
            Http3.markDownload(
                new Request.Builder().url(FILE_URL).post(RequestBody.create("{}", MediaType.get("application/json")))
            ).build(),
            // Tagged plain http: a local dev server, and HTTP/3 needs TLS anyway.
            download("http://127.0.0.1:3192/bundle.zip")
        );
        AtomicInteger okHttp = new AtomicInteger();
        for (Request request : requests) {
            intercept(request, okHttp).close();
        }
        assertEquals(requests.size(), okHttp.get());
        assertTrue(fake.requests.isEmpty());
    }

    @Test
    public void http3FalseKeepsDownloadsOnOkHttp() throws Exception {
        FakeTransport fake = initWith(34, 0);
        Http3.setEnabled(false);
        AtomicInteger okHttp = new AtomicInteger();
        intercept(download(FILE_URL), okHttp).close();
        assertEquals(1, okHttp.get());
        assertTrue(fake.requests.isEmpty());
    }

    @Test
    public void disabledAtInitDoesNotBuildTheEngine() {
        Http3.setEnabled(false);
        AtomicInteger factoryCalls = new AtomicInteger();
        Http3.init(context, null, 34, 0, (ctx, logger) -> {
            factoryCalls.incrementAndGet();
            return new FakeTransport();
        });
        assertEquals(0, factoryCalls.get());
        assertNull(Http3.transport());
    }

    @Test
    public void zipAndManifestRequestsOnTheSharedClientReachTheEngine() throws Exception {
        FakeTransport fake = initWith(34, 0);
        try (Response response = DownloadService.executeZipRequest(HttpUrl.get("https://cdn.example.com/bundle.zip"), 42)) {
            assertEquals("engine", response.body().string());
        }
        assertEquals(1, fake.requests.size());
        Request sent = fake.requests.get(0);
        assertEquals("bytes=42-", sent.header("Range"));
        assertTrue(sent.header("User-Agent").startsWith("CapacitorUpdater/"));
        // The zip client keeps its 60s floor.
        assertTrue(fake.readTimeoutMs >= 60_000);
    }

    @Test
    public void protocolNamesMapToOkHttpProtocols() {
        assertEquals(Protocol.QUIC, Http3.protocolFor("h3"));
        assertEquals(Protocol.QUIC, Http3.protocolFor("h3-29"));
        assertEquals(Protocol.QUIC, Http3.protocolFor("quic/1+spdy/3"));
        assertEquals(Protocol.HTTP_2, Http3.protocolFor("h2"));
        assertEquals(Protocol.HTTP_1_0, Http3.protocolFor("http/1.0"));
        assertEquals(Protocol.HTTP_1_1, Http3.protocolFor("http/1.1"));
        assertEquals(Protocol.HTTP_1_1, Http3.protocolFor(""));
        assertEquals(Protocol.HTTP_1_1, Http3.protocolFor(null));
    }

    @Test
    public void decodedBodiesDropContentEncodingAndLength() {
        List<Map.Entry<String, String>> encoded = List.of(
            new SimpleEntry<>("content-encoding", "br"),
            new SimpleEntry<>("Content-Length", "3"),
            new SimpleEntry<>("Content-Type", "text/javascript"),
            new SimpleEntry<>("alt-svc", "h3=\":443\"")
        );
        okhttp3.Headers headers = Http3.responseHeaders(encoded);
        assertNull(headers.get("Content-Encoding"));
        assertNull(headers.get("Content-Length"));
        assertEquals("text/javascript", headers.get("Content-Type"));
        assertEquals("h3=\":443\"", headers.get("Alt-Svc"));

        okhttp3.Headers plain = Http3.responseHeaders(
            List.of(new SimpleEntry<>("Content-Length", "7"), new SimpleEntry<>("Content-Range", "bytes 10-16/17"))
        );
        assertEquals("7", plain.get("Content-Length"));
        assertEquals("bytes 10-16/17", plain.get("Content-Range"));
    }

    @Test
    public void engineRedirectsFollowTheSamePolicyAsTheNetworkInterceptor() {
        assertNull(Http3.redirectError("https://a.example/x", "https://b.example/y", true, false));
        IOException httpsOnly = Http3.redirectError("https://a.example/x", "http://b.example/y", true, true);
        assertNotNull(httpsOnly);
        assertTrue(httpsOnly.getMessage().contains("httpsOnly"));
        assertTrue(
            Http3.redirectError("https://a.example/x", "http://b.example/y", false, false) instanceof
                DownloadService.BlockedRedirectException
        );
        assertNull(Http3.redirectError("https://a.example/x", "http://b.example/y", false, true));
        assertNotNull(Http3.redirectError("https://a.example/x", "not a url", false, true));
    }

    // EngineCall: the callback bridge, driven the way HttpEngine drives it.

    private static UrlResponseInfo info() {
        return mock(UrlResponseInfo.class);
    }

    @Test
    public void engineCallStreamsTheBodyAcrossReads() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        byte[][] chunks = { "hello ".getBytes(StandardCharsets.UTF_8), "h3".getBytes(StandardCharsets.UTF_8) };
        AtomicInteger reads = new AtomicInteger();
        doAnswer((invocation) -> {
            call.onResponseStarted(request, info);
            return null;
        })
            .when(request)
            .start();
        doAnswer((invocation) -> {
            ByteBuffer buffer = invocation.getArgument(0);
            int index = reads.getAndIncrement();
            if (index < chunks.length) {
                buffer.put(chunks[index]);
                call.onReadCompleted(request, info, buffer);
            } else {
                call.onSucceeded(request, info);
            }
            return null;
        })
            .when(request)
            .read(any(ByteBuffer.class));

        call.start(request);
        assertSame(info, call.awaitResponse(1000));
        try (InputStream body = call.bodyStream(1000)) {
            assertEquals("hello h3", new String(body.readAllBytes(), StandardCharsets.UTF_8));
        }
        verify(request, never()).cancel();
    }

    @Test
    public void engineCallTimesOutWaitingForHeadersAndCancels() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        call.start(request);
        try {
            call.awaitResponse(300);
            fail("expected a timeout");
        } catch (SocketTimeoutException expected) {
            verify(request).cancel();
        }
    }

    @Test
    public void engineCallBlocksRedirectsTheUpdaterWouldRefuse() throws Exception {
        DownloadService.setHttpsOnly(true);
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        doAnswer((invocation) -> {
            call.onCanceled(request, info);
            return null;
        })
            .when(request)
            .cancel();
        call.start(request);
        call.onRedirectReceived(request, info, "http://evil.example/bundle.zip");
        verify(request, never()).followRedirect();
        try {
            call.awaitResponse(1000);
            fail("expected the redirect to be refused");
        } catch (IOException expected) {
            assertTrue(expected.getMessage(), expected.getMessage().contains("httpsOnly"));
        }

        HttpEngineTransport.EngineCall allowed = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest allowedRequest = mock(UrlRequest.class);
        allowed.start(allowedRequest);
        allowed.onRedirectReceived(allowedRequest, info, "https://cdn2.example.com/bundle.zip");
        verify(allowedRequest).followRedirect();
    }

    @Test
    public void closingTheBodyEarlyCancelsTheRequest() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        call.start(request);
        call.onResponseStarted(request, info);
        call.awaitResponse(1000);
        call.bodyStream(1000).close();
        verify(request).cancel();
    }

    @Test
    public void engineFailuresSurfaceAsIOExceptions() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        AtomicReference<ByteBuffer> pending = new AtomicReference<>();
        doAnswer((invocation) -> {
            pending.set(invocation.getArgument(0));
            call.onFailed(request, info, mock(android.net.http.HttpException.class));
            return null;
        })
            .when(request)
            .read(any(ByteBuffer.class));
        call.start(request);
        call.onResponseStarted(request, info);
        call.awaitResponse(1000);
        try (InputStream body = call.bodyStream(1000)) {
            body.read();
            fail("expected the failure to propagate");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().startsWith("HttpEngine request failed"));
        }
        assertNotNull(pending.get());
    }

    @Test
    public void engineNetworkErrorsKeepTheDownloadRetryContract() {
        int[] retryable = {
            android.net.http.NetworkException.ERROR_CONNECTION_RESET,
            android.net.http.NetworkException.ERROR_CONNECTION_CLOSED,
            android.net.http.NetworkException.ERROR_NETWORK_CHANGED,
            android.net.http.NetworkException.ERROR_INTERNET_DISCONNECTED,
            android.net.http.NetworkException.ERROR_ADDRESS_UNREACHABLE,
            android.net.http.NetworkException.ERROR_QUIC_PROTOCOL_FAILED,
            android.net.http.NetworkException.ERROR_TIMED_OUT,
            android.net.http.NetworkException.ERROR_CONNECTION_TIMED_OUT,
            android.net.http.NetworkException.ERROR_CONNECTION_REFUSED,
            android.net.http.NetworkException.ERROR_HOSTNAME_NOT_RESOLVED
        };
        for (int code : retryable) {
            IOException mapped = HttpEngineTransport.networkError(code, "net error " + code, null);
            assertTrue("code " + code + " -> " + mapped, DownloadService.isRetryableManifestError(mapped));
        }
        assertTrue(
            HttpEngineTransport.networkError(android.net.http.NetworkException.ERROR_TIMED_OUT, "t", null) instanceof SocketTimeoutException
        );
        assertTrue(
            HttpEngineTransport.networkError(android.net.http.NetworkException.ERROR_HOSTNAME_NOT_RESOLVED, "h", null) instanceof
                java.net.UnknownHostException
        );
        // TLS failures and anything else the engine reports as ERROR_OTHER are not retried.
        assertFalse(
            DownloadService.isRetryableManifestError(
                HttpEngineTransport.networkError(android.net.http.NetworkException.ERROR_OTHER, "cert", null)
            )
        );
    }

    @Test
    public void connectionResetAfterPartialProgressIsRetryable() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        android.net.http.NetworkException reset = mock(android.net.http.NetworkException.class);
        when(reset.getErrorCode()).thenReturn(android.net.http.NetworkException.ERROR_CONNECTION_RESET);
        when(reset.getMessage()).thenReturn("net::ERR_CONNECTION_RESET");
        AtomicInteger reads = new AtomicInteger();
        doAnswer((invocation) -> {
            ByteBuffer buffer = invocation.getArgument(0);
            if (reads.getAndIncrement() == 0) {
                buffer.put("partial".getBytes(StandardCharsets.UTF_8));
                call.onReadCompleted(request, info, buffer);
            } else {
                call.onFailed(request, info, reset);
            }
            return null;
        })
            .when(request)
            .read(any(ByteBuffer.class));
        call.start(request);
        call.onResponseStarted(request, info);
        call.awaitResponse(1000);
        InputStream body = call.bodyStream(1000);
        byte[] first = new byte[7];
        assertEquals(7, body.read(first, 0, 7));
        assertEquals("partial", new String(first, StandardCharsets.UTF_8));
        try {
            body.read();
            fail("expected the reset to propagate");
        } catch (IOException expected) {
            assertTrue(expected instanceof java.net.SocketException);
            assertTrue(DownloadService.isRetryableManifestError(expected));
            assertSame(reset, expected.getCause());
        }
    }

    private DownloadService worker(androidx.work.Data input) {
        androidx.work.WorkerParameters params = mock(androidx.work.WorkerParameters.class);
        when(params.getInputData()).thenReturn(input);
        return new DownloadService(context, params);
    }

    @Test
    public void resumedWorkerRestoresTheHttp3OptionSavedWithTheJob() {
        // Engine already set up, so doWork's init() does not try to build a real HttpEngine.
        initWith(34, 0);
        androidx.work.Data disabled = new androidx.work.Data.Builder()
            .putBoolean(DownloadService.IS_MANIFEST, true)
            .putBoolean(DownloadService.HTTP3, false)
            .build();
        // Fresh process, no config loaded yet: the saved value applies.
        worker(disabled).doWork();
        assertFalse(Http3.isEnabled());

        // Jobs saved by an older plugin version have no http3 key: keep the current value.
        Http3.resetForTest();
        initWith(34, 0);
        worker(new androidx.work.Data.Builder().putBoolean(DownloadService.IS_MANIFEST, true).build()).doWork();
        assertTrue(Http3.isEnabled());
    }

    @Test
    public void loadedConfigWinsOverAStaleJobValue() {
        initWith(34, 0);
        // Plugin load read http3: false, then a job saved before the app update (http3 true) runs.
        Http3.setEnabled(false);
        androidx.work.Data staleEnabled = new androidx.work.Data.Builder()
            .putBoolean(DownloadService.IS_MANIFEST, true)
            .putBoolean(DownloadService.HTTP3, true)
            .build();
        worker(staleEnabled).doWork();
        assertFalse(Http3.isEnabled());

        // And the other way round.
        Http3.setEnabled(true);
        worker(
            new androidx.work.Data.Builder().putBoolean(DownloadService.IS_MANIFEST, true).putBoolean(DownloadService.HTTP3, false).build()
        ).doWork();
        assertTrue(Http3.isEnabled());
    }

    // Stall guard: HttpEngine's QUIC session can go silent mid-burst and the engine only notices after 6 to 40 s.

    @Test
    public void busyEngineThatGoesSilentStallsWithinTheWindowAndCancels() throws Exception {
        HttpEngineTransport.Liveness liveness = new HttpEngineTransport.Liveness();
        liveness.mark();
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null, liveness, 100);
        UrlRequest request = mock(UrlRequest.class);
        call.start(request);
        long start = System.nanoTime();
        try {
            call.awaitResponse(10_000);
            fail("expected a stall");
        } catch (Http3.EngineStalledException expected) {
            long elapsedMs = (System.nanoTime() - start) / 1_000_000;
            assertTrue("stall seen after " + elapsedMs + " ms", elapsedMs >= 100 && elapsedMs < 1000);
            verify(request).cancel();
        }
    }

    @Test
    public void firstRequestOnANewEngineKeepsTheNormalTimeout() throws Exception {
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null, new HttpEngineTransport.Liveness(), 100);
        UrlRequest request = mock(UrlRequest.class);
        call.start(request);
        try {
            call.awaitResponse(500);
            fail("expected a timeout");
        } catch (SocketTimeoutException expected) {
            assertFalse("the first handshake of a process is not a stall", expected instanceof Http3.EngineStalledException);
        }
    }

    @Test
    public void loneRequestAfterAQuietPeriodKeepsTheNormalTimeout() throws Exception {
        HttpEngineTransport.Liveness liveness = new HttpEngineTransport.Liveness();
        liveness.mark();
        Thread.sleep(250);
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null, liveness, 100);
        UrlRequest request = mock(UrlRequest.class);
        call.start(request);
        try {
            call.awaitResponse(500);
            fail("expected a timeout");
        } catch (SocketTimeoutException expected) {
            assertFalse("a slow first handshake is not a stall", expected instanceof Http3.EngineStalledException);
        }
    }

    @Test
    public void progressOnOtherRequestsKeepsAWaitingRequestOnTheEngine() throws Exception {
        HttpEngineTransport.Liveness liveness = new HttpEngineTransport.Liveness();
        liveness.mark();
        HttpEngineTransport.EngineCall call = new HttpEngineTransport.EngineCall(FILE_URL, null, liveness, 100);
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();
        Thread others = new Thread(() -> {
            try {
                for (int i = 0; i < 10; i++) {
                    Thread.sleep(40);
                    liveness.mark();
                }
                call.onResponseStarted(request, info);
            } catch (InterruptedException ignored) {}
        });
        call.start(request);
        others.start();
        assertSame(info, call.awaitResponse(5000));
        others.join();
        verify(request, never()).cancel();
    }

    @Test
    public void bodyReadsOnlyTripOnceAStallIsConfirmed() throws Exception {
        HttpEngineTransport.Liveness liveness = new HttpEngineTransport.Liveness();
        UrlRequest request = mock(UrlRequest.class);
        UrlResponseInfo info = info();

        HttpEngineTransport.EngineCall slow = new HttpEngineTransport.EngineCall(FILE_URL, null, liveness, 100);
        slow.start(request);
        slow.onResponseStarted(request, info);
        slow.awaitResponse(1000);
        try (InputStream body = slow.bodyStream(400)) {
            body.read();
            fail("expected the read timeout");
        } catch (SocketTimeoutException expected) {
            assertFalse("a slow body alone is not a stall", expected instanceof Http3.EngineStalledException);
        }

        Http3.suspendAfterStall(System.nanoTime());
        HttpEngineTransport.EngineCall stuck = new HttpEngineTransport.EngineCall(FILE_URL, null, liveness, 100);
        UrlRequest stuckRequest = mock(UrlRequest.class);
        stuck.start(stuckRequest);
        stuck.onResponseStarted(stuckRequest, info);
        stuck.awaitResponse(1000);
        try (InputStream body = stuck.bodyStream(10_000)) {
            body.read();
            fail("expected a stall");
        } catch (Http3.EngineStalledException expected) {
            assertTrue(DownloadService.isRetryableManifestError(expected));
        }
    }

    @Test
    public void stalledEngineMovesTheDownloadToOkHttpAndCoolsDown() throws Exception {
        AtomicInteger engineCalls = new AtomicInteger();
        Http3.init(context, null, 34, 0, (ctx, logger) -> (request, connectTimeoutMs, readTimeoutMs, call) -> {
            engineCalls.incrementAndGet();
            throw new Http3.EngineStalledException("no progress");
        });
        AtomicInteger okHttp = new AtomicInteger();
        Response first = intercept(download(FILE_URL), okHttp);
        assertEquals(Protocol.HTTP_2, first.protocol());
        assertEquals(1, engineCalls.get());
        assertEquals(1, okHttp.get());
        assertTrue(Http3.isSuspended(System.nanoTime()));

        Response second = intercept(download(FILE_URL), okHttp);
        assertEquals("cooldown skips the engine", 1, engineCalls.get());
        assertEquals(2, okHttp.get());
        assertEquals(Protocol.HTTP_2, second.protocol());
        long later = System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(Http3.STALL_COOLDOWN_MS + 1);
        assertFalse("the engine is used again after the cooldown", Http3.isSuspended(later));
    }

    @Test
    public void headerWaitBudgetAddsTheTimeoutsAndCapsAtTenMinutes() {
        assertEquals(15_000, HttpEngineTransport.headerWaitBudgetMs(5_000, 10_000));
        assertEquals("two 360 s timeouts must not wait 720 s", 600_000, HttpEngineTransport.headerWaitBudgetMs(360_000, 360_000));
        assertEquals(600_000, HttpEngineTransport.headerWaitBudgetMs(600_000, 1));
        assertEquals(600_000, HttpEngineTransport.headerWaitBudgetMs(Integer.MAX_VALUE, Integer.MAX_VALUE));
        assertEquals("0 keeps meaning no timeout, like OkHttp", 0, HttpEngineTransport.headerWaitBudgetMs(0, 10_000));
        assertEquals(0, HttpEngineTransport.headerWaitBudgetMs(10_000, 0));
    }
}
