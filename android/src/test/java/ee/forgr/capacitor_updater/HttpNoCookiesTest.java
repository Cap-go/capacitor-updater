package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

/**
 * Updater traffic runs in the Rust engine (its own HTTP stack), so it can never see the process-wide
 * {@link CookieHandler}. This keeps that guarantee under test end to end.
 *
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
    private String base;
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
        base = "http://127.0.0.1:" + serverSocket.getLocalPort();
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
        java.net.HttpURLConnection conn = (java.net.HttpURLConnection) new java.net.URL(base + "/control").openConnection();
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

    /** An engine with an in-memory host; statistics off. */
    private CapgoEngine engine() throws Exception {
        final java.io.File root = java.nio.file.Files.createTempDirectory("capgo-no-cookies").toFile();
        final Map<String, String> store = new java.util.concurrent.ConcurrentHashMap<>();
        final CapgoEngineHost host = new CapgoEngineHost() {
            @Override
            void log(int level, String message) {}

            @Override
            String kvGet(String key, String defaultValue) {
                return store.getOrDefault(key, defaultValue);
            }

            @Override
            boolean kvContains(String key) {
                return store.containsKey(key);
            }

            @Override
            void kvSet(String key, String value) {
                if (value == null) {
                    store.remove(key);
                } else {
                    store.put(key, value);
                }
            }

            @Override
            String kvKeysJson() {
                return new org.json.JSONArray(store.keySet()).toString();
            }

            @Override
            void emit(String event, String payloadJson) {}

            /** The local test server is plain HTTP: allow it (unanswered, the engine refuses cleartext). */
            @Override
            String hook(String name, String payloadJson) {
                return "cleartextPermitted".equals(name) ? "{\"permitted\":true}" : null;
            }
        };
        return new CapgoEngine(
            CapgoCore.input(
                "platform",
                "android",
                "appId",
                "app.capgo.test",
                "pluginVersion",
                "8.0.0",
                "versionOs",
                "15",
                "bundleRoot",
                new java.io.File(root, "versions").getAbsolutePath(),
                "statsUrl",
                "",
                "channelUrl",
                base + "/channel_self"
            ),
            host
        );
    }

    @Test
    public void apiCallsNeverSendOrStoreWebViewCookies() throws Exception {
        final CapgoEngine engine = this.engine();
        for (int i = 0; i < 2; i++) {
            final org.json.JSONObject latest = engine.call("getLatest", CapgoCore.input("updateUrl", base + "/updates"));
            assertEquals(true, latest.opt("ok"));
        }
        try {
            engine.call("listChannels", null);
        } catch (CapgoCore.Failure ignored) {
            // The body is not a channel list; only the request headers matter here.
        }

        assertNoCookieTraffic(3);
        assertTrue(recorded.get(0).header("User-Agent").startsWith("CapacitorUpdater/8.0.0 (app.capgo.test) android/"));
    }

    @Test
    public void zipDownloadNeverSendsWebViewCookies() throws Exception {
        final CapgoEngine engine = this.engine();
        try {
            engine.call(
                "download",
                CapgoCore.input(
                    "url",
                    base + "/bundle.zip",
                    "version",
                    "1.0.0",
                    "checksum",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                )
            );
        } catch (CapgoCore.Failure expected) {
            // The body is not the expected zip; only the request headers matter here.
        }
        assertTrue(recorded.size() >= 1);
        assertNull(recorded.get(0).header("Range"));
        assertTrue(recorded.get(0).header("User-Agent").startsWith("CapacitorUpdater/"));
        assertNoCookieTraffic(recorded.size());
    }
}
