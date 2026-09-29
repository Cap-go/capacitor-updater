package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.CookieHandler;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.CookieJar;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

/**
 * Capacitor installs its WebView cookie manager as the process-wide {@link CookieHandler}. Plugin traffic to Capgo
 * endpoints must never read cookies from it nor write Set-Cookie responses into it.
 */
public class HttpNoCookiesTest {

    /** Stands in for Capacitor's WebView cookie manager: always offers a cookie, records every access. */
    private static final class RecordingCookieHandler extends CookieHandler {

        final AtomicInteger gets = new AtomicInteger();
        final List<String> puts = new CopyOnWriteArrayList<>();

        @Override
        public Map<String, List<String>> get(URI uri, Map<String, List<String>> requestHeaders) {
            gets.incrementAndGet();
            return Collections.singletonMap("Cookie", Collections.singletonList("webview_session=secret"));
        }

        @Override
        public void put(URI uri, Map<String, List<String>> responseHeaders) {
            puts.add(uri.toString());
        }
    }

    private static final class Recorded {

        final String requestLine;
        final Map<String, String> headers;

        Recorded(String requestLine, Map<String, String> headers) {
            this.requestLine = requestLine;
            this.headers = headers;
        }

        String header(String name) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey().equalsIgnoreCase(name)) {
                    return e.getValue();
                }
            }
            return null;
        }
    }

    private final List<Recorded> recorded = new CopyOnWriteArrayList<>();
    private ServerSocket serverSocket;
    private ExecutorService serverPool;
    private HttpUrl base;
    private CookieHandler previousHandler;
    private RecordingCookieHandler cookieHandler;

    @Before
    public void setUp() throws IOException {
        previousHandler = CookieHandler.getDefault();
        cookieHandler = new RecordingCookieHandler();
        CookieHandler.setDefault(cookieHandler);

        serverSocket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
        serverPool = Executors.newCachedThreadPool();
        serverPool.execute(() -> {
            while (!serverSocket.isClosed()) {
                try {
                    Socket socket = serverSocket.accept();
                    serverPool.execute(() -> serve(socket));
                } catch (IOException e) {
                    return;
                }
            }
        });
        base = HttpUrl.get("http://127.0.0.1:" + serverSocket.getLocalPort() + "/");
    }

    @After
    public void tearDown() throws IOException {
        CookieHandler.setDefault(previousHandler);
        serverSocket.close();
        serverPool.shutdownNow();
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1 && c != '\n') {
            if (c != '\r') {
                line.write(c);
            }
        }
        return line.toString(StandardCharsets.ISO_8859_1.name());
    }

    /** One request per connection; every response tries to set a cookie. */
    private void serve(Socket socket) {
        try (Socket s = socket) {
            InputStream in = s.getInputStream();
            String requestLine = readLine(in);
            Map<String, String> headers = new LinkedHashMap<>();
            String line;
            int length = 0;
            while (!(line = readLine(in)).isEmpty()) {
                int colon = line.indexOf(':');
                String name = line.substring(0, colon).trim();
                String value = line.substring(colon + 1).trim();
                headers.put(name, value);
                if (name.equalsIgnoreCase("Content-Length")) {
                    length = Integer.parseInt(value);
                }
            }
            for (int i = 0; i < length; i++) {
                in.read();
            }
            recorded.add(new Recorded(requestLine, headers));

            byte[] body = "{\"ok\":true}".getBytes(StandardCharsets.UTF_8);
            String range = headers.get("Range");
            String status = range != null ? "206 Partial Content" : "200 OK";
            StringBuilder head = new StringBuilder("HTTP/1.1 ").append(status).append("\r\n");
            head.append("Content-Type: application/json\r\n");
            head.append("Set-Cookie: capgo_backend=1; Path=/\r\n");
            if (range != null) {
                head.append("Content-Range: bytes 5-15/16\r\n");
            }
            head.append("Content-Length: ").append(body.length).append("\r\n");
            head.append("Connection: close\r\n\r\n");
            OutputStream out = s.getOutputStream();
            out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
            out.write(body);
            out.flush();
        } catch (IOException ignored) {
            // client went away
        }
    }

    private void assertNoCookieTraffic(int expectedRequests) {
        assertEquals(expectedRequests, recorded.size());
        for (Recorded r : recorded) {
            assertNull("Cookie header leaked on " + r.requestLine, r.header("Cookie"));
        }
        assertEquals("CookieHandler.get must never be consulted", 0, cookieHandler.gets.get());
        assertTrue("Set-Cookie must never reach the CookieHandler: " + cookieHandler.puts, cookieHandler.puts.isEmpty());
    }

    /** Control: java.net.HttpURLConnection does pick up the default CookieHandler, which is why it is not used. */
    @Test
    public void controlHttpUrlConnectionWouldLeakCookies() throws Exception {
        java.net.HttpURLConnection conn = (java.net.HttpURLConnection) base.resolve("/control").url().openConnection();
        try {
            assertEquals(200, conn.getResponseCode());
            conn.getInputStream().readAllBytes();
        } finally {
            conn.disconnect();
        }
        assertEquals("webview_session=secret", recorded.get(0).header("Cookie"));
        assertTrue(cookieHandler.gets.get() > 0);
        assertEquals(1, cookieHandler.puts.size());
    }

    @Test
    public void sharedClientUsesNoCookieJarAcrossTimeoutChanges() {
        final int original = DownloadService.httpTimeoutMs();
        try {
            assertSame(CookieJar.NO_COOKIES, DownloadService.sharedClient.cookieJar());
            DownloadService.applyHttpTimeouts(original + 1_000);
            assertSame(CookieJar.NO_COOKIES, DownloadService.sharedClient.cookieJar());
            assertSame(CookieJar.NO_COOKIES, DownloadService.sharedClient.newBuilder().build().cookieJar());
        } finally {
            DownloadService.applyHttpTimeouts(original);
        }
    }

    @Test
    public void apiCallsNeverSendOrStoreWebViewCookies() throws Exception {
        for (int i = 0; i < 2; i++) {
            Request request = new Request.Builder()
                .url(base.resolve("/updates"))
                .post(RequestBody.create("{}", MediaType.get("application/json")))
                .build();
            try (Response response = DownloadService.sharedClient.newCall(request).execute()) {
                assertEquals(200, response.code());
                assertEquals("{\"ok\":true}", response.body().string());
            }
        }

        CountDownLatch done = new CountDownLatch(1);
        DownloadService.sharedClient.newCall(new Request.Builder().url(base.resolve("/channel_self")).get().build()).enqueue(
            new Callback() {
                @Override
                public void onFailure(Call call, IOException e) {
                    done.countDown();
                }

                @Override
                public void onResponse(Call call, Response response) {
                    response.close();
                    done.countDown();
                }
            }
        );
        assertTrue(done.await(10, TimeUnit.SECONDS));

        assertNoCookieTraffic(3);
        assertTrue(recorded.get(0).header("User-Agent").startsWith("CapacitorUpdater/"));
    }

    @Test
    public void zipDownloadUsesSharedClientWithRangeAndNoCookies() throws Exception {
        try (Response response = DownloadService.executeZipRequest(base.resolve("/bundle.zip"), 0)) {
            assertEquals(200, response.code());
            assertEquals(11, response.body().contentLength());
            assertEquals("{\"ok\":true}", response.body().string());
        }
        try (Response response = DownloadService.executeZipRequest(base.resolve("/bundle.zip"), 5)) {
            assertEquals(206, response.code());
            assertEquals("bytes 5-15/16", response.header("Content-Range"));
            assertEquals("{\"ok\":true}", new String(response.body().byteStream().readAllBytes(), StandardCharsets.UTF_8));
        }

        assertNull(recorded.get(0).header("Range"));
        assertEquals("bytes=5-", recorded.get(1).header("Range"));
        assertTrue(recorded.get(1).header("User-Agent").startsWith("CapacitorUpdater/"));
        assertNoCookieTraffic(2);
    }
}
