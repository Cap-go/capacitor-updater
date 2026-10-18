package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import androidx.work.Data;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.file.Files;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;

public class ManifestNetworkReliabilityTest {

    @Test
    public void transientFailureRetriesOnlyTheFileAndVerifiesBytes() throws Exception {
        runManifest(503, 2, true);
    }

    @Test
    public void truncatedBodyResumesOnlyMissingBytes() throws Exception {
        runManifest(-1, 2, true);
    }

    @Test
    public void permanentFailureDoesNotRetry() throws Exception {
        runManifest(404, 1, false);
        runManifest(429, 1, false);
    }

    @Test
    public void tlsAndLocalFileFailuresArePermanent() {
        assertFalse(DownloadService.isRetryableManifestError(new javax.net.ssl.SSLHandshakeException("certificate")));
        assertFalse(DownloadService.isRetryableManifestError(new IOException("disk full")));
        assertTrue(DownloadService.isRetryableManifestError(new java.net.SocketTimeoutException("timeout")));
    }

    @Test
    public void immutableCacheSurvivesBundleDeletionAndReplacement() throws Exception {
        File root = Files.createTempDirectory("capgo-cache-link").toFile();
        try {
            File source = new File(root, "bundle.js");
            File cache = new File(root, "cache/app.js");
            File restored = new File(root, "restored.js");
            byte[] original = "verified content".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            Files.write(source.toPath(), original);
            File alias = new File(root, "alias.js");
            Files.createSymbolicLink(alias.toPath(), source.toPath());
            DownloadService.linkOrCopyImmutableFile(alias, cache);
            assertTrue(source.delete());
            assertArrayEquals(original, Files.readAllBytes(cache.toPath()));
            DownloadService.linkOrCopyImmutableFile(cache, restored);
            DownloadService.writeFileAtomic(restored, new java.io.ByteArrayInputStream(new byte[] { 1 }), null);
            assertArrayEquals(original, Files.readAllBytes(cache.toPath()));
        } finally {
            try (java.util.stream.Stream<java.nio.file.Path> files = Files.walk(root.toPath())) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach((file) -> file.toFile().delete());
            }
        }
    }

    @Test
    public void checksumReadErrorsNeverProduceAPartialDigest() throws Exception {
        java.io.InputStream failed = new java.io.InputStream() {
            int reads;

            public int read() throws IOException {
                if (++reads > 1) throw new IOException("storage read failed");
                return 1;
            }
        };
        assertThrows(IOException.class, () -> CryptoCipher.calcChecksumOrThrow(failed));
    }

    private void runManifest(int firstStatus, int expectedRequests, boolean success) throws Exception {
        File root = Files.createTempDirectory("capgo-manifest-retry").toFile();
        byte[] body = "<html>recovered</html>".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        AtomicInteger requests = new AtomicInteger();
        ServerSocket server = new ServerSocket(0, 8, java.net.InetAddress.getLoopbackAddress());
        Thread responder = new Thread(() -> {
            while (!server.isClosed()) {
                try (Socket socket = server.accept()) {
                    java.io.BufferedReader input = new java.io.BufferedReader(new java.io.InputStreamReader(socket.getInputStream()));
                    String line;
                    int offset = 0;
                    while ((line = input.readLine()) != null && !line.isEmpty()) {
                        if (line.startsWith("Range: bytes=")) offset = Integer.parseInt(line.substring(13, line.length() - 1));
                    }
                    boolean first = requests.incrementAndGet() == 1;
                    boolean truncated = first && firstStatus == -1;
                    int status = truncated ? 200 : first ? firstStatus : offset > 0 ? 206 : 200;
                    byte[] response = truncated
                        ? java.util.Arrays.copyOf(body, 10)
                        : status == 200 || status == 206
                          ? java.util.Arrays.copyOfRange(body, offset, body.length)
                          : new byte[0];
                    java.io.OutputStream output = socket.getOutputStream();
                    output.write(
                        (
                            "HTTP/1.1 " +
                            status +
                            " test\r\nContent-Length: " +
                            (truncated ? body.length : response.length) +
                            "\r\nConnection: close\r\n\r\n"
                        ).getBytes(java.nio.charset.StandardCharsets.US_ASCII)
                    );
                    output.write(response);
                    output.flush();
                } catch (IOException error) {
                    return;
                }
            }
        });
        responder.start();
        try {
            Logger logger = mock(Logger.class);
            DownloadService.setLogger(logger);
            CryptoCipher.setLogger(logger);
            Context context = mock(Context.class);
            when(context.getCacheDir()).thenReturn(root);
            DownloadService worker = mock(DownloadService.class, CALLS_REAL_METHODS);
            doReturn(context).when(worker).getApplicationContext();
            doReturn(new Data.Builder().putString(DownloadService.VERSION, "retry-test").build()).when(worker).getInputData();
            doReturn(false).when(worker).isStopped();
            File target = new File(root, "index.html");
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            digest.update(body);
            String hash = CryptoCipher.digestToHex(digest);
            Method method = DownloadService.class.getDeclaredMethod(
                "downloadAndVerify",
                String.class,
                File.class,
                File.class,
                String.class,
                String.class,
                String.class,
                boolean.class,
                String.class
            );
            method.setAccessible(true);
            try {
                method.invoke(
                    worker,
                    "http://127.0.0.1:" + server.getLocalPort() + "/file",
                    target,
                    null,
                    hash,
                    "",
                    "",
                    false,
                    "index.html"
                );
                assertTrue(success);
                assertArrayEquals(body, Files.readAllBytes(target.toPath()));
            } catch (InvocationTargetException error) {
                if (success) throw error;
                assertFalse(target.exists());
            }
            assertEquals(expectedRequests, requests.get());
        } finally {
            server.close();
            responder.join(2000);
            try (java.util.stream.Stream<java.nio.file.Path> files = Files.walk(root.toPath())) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach((file) -> file.toFile().delete());
            }
        }
    }
}
