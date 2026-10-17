package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.AbstractMap;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

/**
 * The host transport binding ({@code CapgoEngineHost.httpRequest} and the {@code CapgoCoreNative.http*} sink
 * natives) against the loaded core, with a Java transport standing in for HttpEngine (Robolectric cannot run it).
 */
public class HttpTransportBindingTest {

    /** A host whose transport answers from Java and records what the engine asked. */
    private static class TransportHost extends CapgoEngineHost {

        final Map<String, String> store = new ConcurrentHashMap<>();
        final List<String> requests = new CopyOnWriteArrayList<>();
        final List<String> logs = new CopyOnWriteArrayList<>();
        final Map<String, byte[]> files = new ConcurrentHashMap<>();
        volatile String latestJson = "{}";
        volatile int headReply = -1;
        volatile long requestThread;
        volatile long sinkThread;

        @Override
        void log(final int level, final String message) {
            logs.add(message);
        }

        @Override
        String kvGet(final String key, final String defaultValue) {
            return store.getOrDefault(key, defaultValue);
        }

        @Override
        boolean kvContains(final String key) {
            return store.containsKey(key);
        }

        @Override
        void kvSet(final String key, final String value) {
            if (value == null) {
                store.remove(key);
            } else {
                store.put(key, value);
            }
        }

        @Override
        String kvKeysJson() {
            return new JSONArray(store.keySet()).toString();
        }

        @Override
        void emit(final String event, final String payloadJson) {}

        @Override
        String hook(final String name, final String payloadJson) {
            if ("cleartextPermitted".equals(name)) {
                return "{\"permitted\":true}";
            }
            return null;
        }

        @Override
        String httpRequest(
            final String method,
            final String url,
            final String headersJson,
            final byte[] body,
            final long timeoutMs,
            final String bodyPath,
            final long sink
        ) {
            requestThread = Thread.currentThread().getId();
            requests.add(method + " " + url + " " + headersJson + " " + (bodyPath != null) + " " + timeoutMs);
            try {
                final byte[] payload = bodyPath != null ? files.get(url) : latestJson.getBytes(StandardCharsets.UTF_8);
                final String headers = new JSONArray()
                    .put(new JSONArray().put("Content-Length").put(String.valueOf(payload.length)))
                    .toString();
                headReply = CapgoCoreNative.httpHead(sink, 200, headers);
                sinkThread = Thread.currentThread().getId();
                if (headReply != 0) {
                    return CapgoHttpTransport.failed("cancelled", "Request cancelled");
                }
                if (bodyPath == null) {
                    final ByteBuffer buffer = ByteBuffer.allocateDirect(payload.length + 8);
                    buffer.position(8);
                    buffer.put(payload);
                    if (CapgoCoreNative.httpData(sink, buffer, 8, payload.length) != 0) {
                        return CapgoHttpTransport.failed("cancelled", "Request cancelled");
                    }
                } else {
                    try (FileOutputStream out = new FileOutputStream(bodyPath, true)) {
                        out.write(payload);
                    }
                    if (CapgoCoreNative.httpProgress(sink, payload.length) != 0) {
                        return CapgoHttpTransport.failed("cancelled", "Request cancelled");
                    }
                }
                return CapgoHttpTransport.completed("h3");
            } catch (final Exception e) {
                return CapgoHttpTransport.failed("io", e.getMessage());
            }
        }
    }

    private static CapgoEngine engine(final TransportHost host, final File root) throws Exception {
        return new CapgoEngine(
            CapgoCore.input(
                "platform",
                "android",
                "appId",
                "app.capgo.transport",
                "bundleRoot",
                new File(root, "versions").getAbsolutePath(),
                "storageRoot",
                root.getAbsolutePath()
            ),
            host
        );
    }

    private static byte[] zip(final String index) throws Exception {
        final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(bytes)) {
            zip.putNextEntry(new ZipEntry("index.html"));
            zip.write(index.getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }
        return bytes.toByteArray();
    }

    private static String sha256(final byte[] bytes) throws Exception {
        final StringBuilder hex = new StringBuilder();
        for (final byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            hex.append(String.format("%02x", value));
        }
        return hex.toString();
    }

    @Test
    public void zipBodiesAreWrittenByTheHostAndProgressReachesTheEngine() throws Exception {
        final File root = Files.createTempDirectory("capgo-transport").toFile();
        final TransportHost host = new TransportHost();
        final byte[] bundle = zip("<html>via host</html>");
        host.files.put("https://cdn.test/b.zip", bundle);
        final CapgoEngine engine = engine(host, root);
        try {
            final JSONObject installed = engine.call(
                "download",
                CapgoCore.input("url", "https://cdn.test/b.zip", "version", "2.0.0", "checksum", sha256(bundle))
            );
            assertEquals("pending", installed.getString("status"));
            final File index = new File(new File(new File(root, "versions"), installed.getString("id")), "index.html");
            assertEquals("<html>via host</html>", new String(Files.readAllBytes(index.toPath()), StandardCharsets.UTF_8));
            assertEquals(0, host.headReply);
            assertEquals("the sink is called on the request thread", host.requestThread, host.sinkThread);
            final String request = host.requests.get(0);
            assertTrue(request, request.startsWith("GET https://cdn.test/b.zip [[\"User-Agent\""));
            assertTrue(request, request.contains("[\"Accept-Encoding\",\"identity\"]"));
            assertTrue(request, request.endsWith(" true 60000"));
            assertTrue(host.logs.toString(), host.logs.contains("System HTTP transport: h3 with cdn.test"));
        } finally {
            engine.close();
            deleteRecursively(root);
        }
    }

    @Test
    public void apiBodiesComeBackThroughDirectBuffers() throws Exception {
        final File root = Files.createTempDirectory("capgo-transport").toFile();
        final TransportHost host = new TransportHost();
        host.latestJson = new JSONObject().put("version", "9.9.9").put("message", "from the host").toString();
        final CapgoEngine engine = engine(host, root);
        try {
            final JSONObject latest = engine.call("getLatest", CapgoCore.input("updateUrl", "https://api.test/updates"));
            assertEquals(latest.toString(), "9.9.9", latest.getString("version"));
            final String request = host.requests.get(0);
            assertTrue(request, request.startsWith("POST https://api.test/updates "));
            assertTrue(request, request.contains("[\"Accept-Encoding\",\"gzip\"]"));
        } finally {
            engine.close();
            deleteRecursively(root);
        }
    }

    @Test
    public void sinkNativesCancelWithoutASink() {
        assertEquals(1, CapgoCoreNative.httpHead(0, 200, "[]"));
        assertEquals(1, CapgoCoreNative.httpData(0, ByteBuffer.allocateDirect(4), 0, 4));
        assertEquals(1, CapgoCoreNative.httpProgress(0, 0));
    }

    @Test
    public void headersRoundTripAsNameValuePairs() throws Exception {
        final String[][] parsed = CapgoHttpTransport.parseHeaders("[[\"User-Agent\",\"ua\"],[\"Range\",\"bytes=5-\"]]");
        assertArrayEquals(new String[] { "User-Agent", "ua" }, parsed[0]);
        assertArrayEquals(new String[] { "Range", "bytes=5-" }, parsed[1]);
        assertEquals(0, CapgoHttpTransport.parseHeaders(null).length);
        try {
            CapgoHttpTransport.parseHeaders("{\"a\":1}");
            fail("not an array of pairs");
        } catch (final org.json.JSONException expected) {
            // The request is refused before anything is sent.
        }
        final List<Map.Entry<String, String>> response = Arrays.asList(
            new AbstractMap.SimpleEntry<>("Content-Length", "10"),
            new AbstractMap.SimpleEntry<>("set-cookie", "a=1"),
            new AbstractMap.SimpleEntry<>("set-cookie", "b=2")
        );
        assertEquals(
            "[[\"Content-Length\",\"10\"],[\"set-cookie\",\"a=1\"],[\"set-cookie\",\"b=2\"]]",
            CapgoHttpTransport.headersJson(response)
        );
        assertEquals("[]", CapgoHttpTransport.headersJson(null));
    }

    @Test
    public void resultsFollowTheTransportContract() throws Exception {
        assertEquals("h3", new JSONObject(CapgoHttpTransport.completed("h3")).getString("protocol"));
        assertEquals("http/1.1", new JSONObject(CapgoHttpTransport.completed("HTTP/1.1")).getString("protocol"));
        assertTrue(new JSONObject(CapgoHttpTransport.completed("")).isNull("protocol"));
        final JSONObject failed = new JSONObject(CapgoHttpTransport.failed("timeout", "slow"));
        assertEquals("timeout", failed.getString("error"));
        assertEquals("slow", failed.getString("message"));
    }

    @Test
    public void httpEngineErrorsMapToTransportKinds() {
        final String prefix = "Exception in CronetUrlRequest: net::";
        assertEquals("tls", CapgoHttpTransport.errorKind(11, prefix + "ERR_CERT_AUTHORITY_INVALID, ErrorCode=11"));
        assertEquals("tls", CapgoHttpTransport.errorKind(11, prefix + "ERR_SSL_PROTOCOL_ERROR"));
        assertEquals("timeout", CapgoHttpTransport.errorKind(CapgoHttpTransport.ERROR_TIMED_OUT, prefix + "ERR_TIMED_OUT"));
        assertEquals("timeout", CapgoHttpTransport.errorKind(CapgoHttpTransport.ERROR_CONNECTION_TIMED_OUT, "connect"));
        assertEquals("invalid_url", CapgoHttpTransport.errorKind(-1, prefix + "ERR_INVALID_URL"));
        assertEquals("network", CapgoHttpTransport.errorKind(1, prefix + "ERR_NAME_NOT_RESOLVED"));
        assertEquals("network", CapgoHttpTransport.errorKind(-1, null));
    }

    @Test
    public void theDefaultHostHasNoTransport() {
        final CapgoEngineHost host = new TransportHost() {
            @Override
            String httpRequest(
                final String method,
                final String url,
                final String headersJson,
                final byte[] body,
                final long timeoutMs,
                final String bodyPath,
                final long sink
            ) {
                return null;
            }
        };
        assertNull(host.httpRequest("GET", "https://a.test/", "[]", null, 1000, null, 0));
        assertNull(
            new CapgoEngineHost() {
                @Override
                void log(final int level, final String message) {}

                @Override
                String kvGet(final String key, final String defaultValue) {
                    return defaultValue;
                }

                @Override
                boolean kvContains(final String key) {
                    return false;
                }

                @Override
                void kvSet(final String key, final String value) {}

                @Override
                String kvKeysJson() {
                    return "[]";
                }

                @Override
                void emit(final String event, final String payloadJson) {}
            }.httpRequest("GET", "https://a.test/", "[]", null, 1000, null, 0)
        );
    }

    private static void deleteRecursively(final File file) {
        final File[] children = file.listFiles();
        if (children != null) {
            for (final File child : children) {
                deleteRecursively(child);
            }
        }
        // Best effort: the engine may still be finishing background work in the temporary folder.
        file.delete();
    }
}
