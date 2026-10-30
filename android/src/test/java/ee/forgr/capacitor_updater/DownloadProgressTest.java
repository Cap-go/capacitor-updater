package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;

import androidx.work.Data;
import com.google.common.util.concurrent.ListenableFuture;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import java.util.stream.Stream;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class DownloadProgressTest {

    @Test
    public void repeatedOrLatePercentagesDoNotWriteWorkManagerProgressAgain() throws Exception {
        DownloadService worker = mock(DownloadService.class, CALLS_REAL_METHODS);
        List<Integer> writes = new ArrayList<>();
        doAnswer((call) -> {
            Data value = call.getArgument(0);
            writes.add(value.getInt(DownloadService.PERCENT, -1));
            return mock(ListenableFuture.class);
        })
            .when(worker)
            .setProgressAsync(any(Data.class));
        Method update = DownloadService.class.getDeclaredMethod("setProgress", int.class);
        update.setAccessible(true);
        for (int percent : new int[] { 10, 10, 9, 11, 11, 70 }) update.invoke(worker, percent);
        assertEquals(Arrays.asList(10, 11, 70), writes);
    }

    /** Verifies that single-file zip downloads emit 1%-granularity progress updates between 10% and 70%. */
    @Test
    public void singleFileDownloadEmitsOnePercentGranularityBetweenTenAndSeventy() throws Exception {
        DownloadService.setHttpsOnly(false);
        File root = Files.createTempDirectory("capgo-zip-progress").toFile();
        int stepBytes = 400;
        byte[] payload = new byte[100 * stepBytes];
        Semaphore progressAck = new Semaphore(0);
        AtomicBoolean ackTimedOut = new AtomicBoolean(false);
        ServerSocket server = new ServerSocket(0, 4, InetAddress.getLoopbackAddress());
        Thread responder = new Thread(() -> {
            try (Socket socket = server.accept()) {
                BufferedReader input = new BufferedReader(
                    new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII)
                );
                String line;
                while ((line = input.readLine()) != null && !line.isEmpty()) {}
                OutputStream out = socket.getOutputStream();
                String headers =
                    "HTTP/1.1 200 OK\r\nContent-Length: " +
                    payload.length +
                    "\r\nConnection: close\r\n\r\n";
                out.write(headers.getBytes(StandardCharsets.US_ASCII));
                int sent = 0;
                for (int pct = 10; pct <= 70; pct++) {
                    int targetSent = pct * stepBytes + 1;
                    out.write(payload, sent, targetSent - sent);
                    out.flush();
                    sent = targetSent;
                    if (!progressAck.tryAcquire(5, TimeUnit.SECONDS)) {
                        ackTimedOut.set(true);
                        return;
                    }
                }
                out.write(payload, sent, payload.length - sent);
                out.flush();
            } catch (Exception ignored) {}
        });
        responder.start();
        try {
            DownloadService.setLogger(mock(Logger.class));
            DownloadService worker = mock(DownloadService.class, CALLS_REAL_METHODS);
            doReturn(Data.EMPTY).when(worker).getInputData();
            doReturn(false).when(worker).isStopped();
            Field lastProgressField = DownloadService.class.getDeclaredField("lastProgressPercent");
            lastProgressField.setAccessible(true);
            lastProgressField.setInt(worker, -1);

            List<Integer> writes = new ArrayList<>();
            doAnswer((call) -> {
                Data value = call.getArgument(0);
                writes.add(value.getInt(DownloadService.PERCENT, -1));
                progressAck.release();
                return mock(ListenableFuture.class);
            })
                .when(worker)
                .setProgressAsync(any(Data.class));

            Method singleFileDownload = DownloadService.class.getDeclaredMethod(
                "handleSingleFileDownload",
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class
            );
            singleFileDownload.setAccessible(true);
            try {
                singleFileDownload.invoke(
                    worker,
                    "http://127.0.0.1:" + server.getLocalPort() + "/bundle.zip",
                    "bundle-id",
                    root.getAbsolutePath(),
                    "bundle.zip",
                    "1.0.0",
                    "",
                    "sha256-checksum",
                    ""
                );
            } catch (InvocationTargetException error) {
                assertFalse("Timed out waiting for progress acknowledgement", ackTimedOut.get());
                throw error;
            }

            assertFalse("Timed out waiting for progress acknowledgement", ackTimedOut.get());
            List<Integer> expected = IntStream.rangeClosed(10, 70).boxed().collect(Collectors.toList());
            assertEquals(expected, writes);
        } finally {
            DownloadService.setHttpsOnly(true);
            server.close();
            responder.join(2000);
            try (Stream<java.nio.file.Path> files = Files.walk(root.toPath())) {
                files.sorted(Comparator.reverseOrder()).forEach((file) -> file.toFile().delete());
            }
        }
    }
}
