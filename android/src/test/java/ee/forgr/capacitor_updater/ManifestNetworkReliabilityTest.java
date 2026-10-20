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
    public void resumeWithWrongRangeStartRestartsWithCleanGet() throws Exception {
        // Truncated, then a 206 that starts at the wrong offset: discard it and fetch the whole file.
        runManifest(-1, 3, true, false, "wrong");
    }

    @Test
    public void resumeAnsweredFromByteZeroReplacesThePartial() throws Exception {
        runManifest(-1, 2, true, false, "zero");
    }

    @Test
    public void unsatisfiableRangeOnCorruptPartialRestartsWithCleanGet() throws Exception {
        // A full-length but corrupt partial gets 416, fails verification, then a clean GET installs.
        runManifest(-2, 2, true, false, "correct");
    }

    @Test
    public void storageFailureAfterResumeStaysPermanent() throws Exception {
        // A complete partial gets 416, then the install cannot write: no clean GET, no retry.
        runManifest(-3, 1, false, false, "correct");
    }

    @Test
    public void lateWriteToSharedPartialNeverReachesInstalledFile() throws Exception {
        // Another download of the same file shares the partial name and may still write after this one installs.
        runManifest(200, 1, true, true, "correct");
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
        runManifest(firstStatus, expectedRequests, success, false, "correct");
    }

    // firstStatus: an HTTP status for the first response, -1 for a truncated 200, -2 for a pre-seeded corrupt
    // full-length partial answered with 416. rangeMode controls the Content-Range start of a resumed 206.
    private void runManifest(int firstStatus, int expectedRequests, boolean success, boolean holdPartialOpen, String rangeMode)
        throws Exception {
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
                    int rangeStart = "zero".equals(rangeMode) ? 0 : "wrong".equals(rangeMode) ? offset + 3 : offset;
                    int status;
                    if ((firstStatus == -2 || firstStatus == -3) && offset > 0) status = 416;
                    else if (truncated) status = 200;
                    else if (first && firstStatus >= 0) status = firstStatus;
                    else status = offset > 0 ? 206 : 200;
                    byte[] response = truncated
                        ? java.util.Arrays.copyOf(body, 10)
                        : status == 206
                          ? java.util.Arrays.copyOfRange(body, Math.min(rangeStart, body.length), body.length)
                          : status == 200
                            ? body
                            : new byte[0];
                    String range =
                        status == 206 ? "Content-Range: bytes " + rangeStart + "-" + (body.length - 1) + "/" + body.length + "\r\n" : "";
                    java.io.OutputStream output = socket.getOutputStream();
                    output.write(
                        (
                            "HTTP/1.1 " +
                            status +
                            " test\r\n" +
                            range +
                            "Content-Length: " +
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
            doReturn(new Data.Builder().putString(DownloadService.VERSION, "retry-test").putString(DownloadService.ID, "retry-id").build())
                .when(worker)
                .getInputData();
            doReturn(false).when(worker).isStopped();
            File target = new File(root, "index.html");
            if (firstStatus == -3) {
                File readOnly = new File(root, "read-only");
                assertTrue(readOnly.mkdirs());
                assertTrue(readOnly.setWritable(false));
                target = new File(readOnly, "index.html");
            }
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            digest.update(body);
            String hash = CryptoCipher.digestToHex(digest);
            Method method = DownloadService.class.getDeclaredMethod(
                "downloadAndVerify",
                String.class,
                File.class,
                File.class,
                String.class,
                CryptoCipher.DecryptionSession.class,
                boolean.class,
                String.class
            );
            method.setAccessible(true);
            java.io.FileOutputStream heldPartial = null;
            File partial = DownloadService.manifestPartialFile(new File(root, "capgo_downloads"), "retry-id", hash, "index.html");
            if (holdPartialOpen || firstStatus == -2 || firstStatus == -3) {
                assertTrue(partial.getParentFile().mkdirs() || partial.getParentFile().isDirectory());
                assertTrue(partial.createNewFile());
            }
            if (firstStatus == -2) {
                byte[] corrupt = body.clone();
                corrupt[0] ^= 1;
                Files.write(partial.toPath(), corrupt);
            }
            if (firstStatus == -3) Files.write(partial.toPath(), body);
            if (holdPartialOpen) heldPartial = new java.io.FileOutputStream(partial, true);
            try {
                method.invoke(
                    worker,
                    "http://127.0.0.1:" + server.getLocalPort() + "/file",
                    target,
                    null,
                    hash,
                    new CryptoCipher.DecryptionSession("", ""),
                    false,
                    "index.html"
                );
                assertTrue(success);
                assertArrayEquals(body, Files.readAllBytes(target.toPath()));
                if (heldPartial != null) {
                    heldPartial.write("late bytes".getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    heldPartial.close();
                    assertArrayEquals(body, Files.readAllBytes(target.toPath()));
                }
            } catch (InvocationTargetException error) {
                if (success) throw error;
                assertFalse(target.exists());
            }
            assertEquals(expectedRequests, requests.get());
        } finally {
            new File(root, "read-only").setWritable(true);
            server.close();
            responder.join(2000);
            try (java.util.stream.Stream<java.nio.file.Path> files = Files.walk(root.toPath())) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach((file) -> file.toFile().delete());
            }
        }
    }
}
