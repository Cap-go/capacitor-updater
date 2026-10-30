package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;

import androidx.work.Data;
import com.google.common.util.concurrent.ListenableFuture;
import java.io.File;
import java.io.OutputStream;
import java.lang.reflect.Field;
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

    @Test
    public void singleFileDownloadEmitsOnePercentGranularityBetweenTenAndSeventy() throws Exception {
        DownloadService.setHttpsOnly(false);
        File root = Files.createTempDirectory("capgo-zip-progress").toFile();
        byte[] payload = new byte[512 * 1024];
        ServerSocket server = new ServerSocket(0, 4, InetAddress.getLoopbackAddress());
        Thread responder = new Thread(() -> {
            try (Socket socket = server.accept()) {
                OutputStream out = socket.getOutputStream();
                String headers =
                    "HTTP/1.1 200 OK\r\nContent-Length: " +
                    payload.length +
                    "\r\nConnection: close\r\n\r\n";
                out.write(headers.getBytes(StandardCharsets.US_ASCII));
                int chunk = 16 * 1024;
                for (int offset = 0; offset < payload.length; offset += chunk) {
                    out.write(payload, offset, Math.min(chunk, payload.length - offset));
                    out.flush();
                }
            } catch (Exception ignored) {}
        });
        responder.start();
        try {
            DownloadService.setLogger(mock(Logger.class));
            DownloadService worker = mock(DownloadService.class, CALLS_REAL_METHODS);
            Field lastProgressField = DownloadService.class.getDeclaredField("lastProgressPercent");
            lastProgressField.setAccessible(true);
            lastProgressField.setInt(worker, -1);

            List<Integer> writes = new ArrayList<>();
            doAnswer((call) -> {
                Data value = call.getArgument(0);
                writes.add(value.getInt(DownloadService.PERCENT, -1));
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
                String.class
            );
            singleFileDownload.setAccessible(true);
            singleFileDownload.invoke(
                worker,
                "http://127.0.0.1:" + server.getLocalPort() + "/bundle.zip",
                "bundle-id",
                root.getAbsolutePath(),
                "bundle.zip",
                "1.0.0",
                ""
            );

            boolean sawNonMultipleOfTen = writes.stream().anyMatch((p) -> p > 10 && p < 70 && p % 10 != 0);
            assertEquals(true, sawNonMultipleOfTen);
            assertEquals(Integer.valueOf(70), writes.get(writes.size() - 1));
        } finally {
            DownloadService.setHttpsOnly(true);
            server.close();
            try (Stream<java.nio.file.Path> files = Files.walk(root.toPath())) {
                files.sorted(Comparator.reverseOrder()).forEach((file) -> file.toFile().delete());
            }
        }
    }
}
