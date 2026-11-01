package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;

import java.io.File;
import java.nio.file.Files;
import java.util.Collections;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import okhttp3.HttpUrl;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.SocketPolicy;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.mockito.ArgumentCaptor;

public class StatsBatchFailureDiagnosticsTest {

    private MockWebServer server;
    private File documentsDir;

    @Before
    public void setUp() throws Exception {
        DownloadService.setHttpsOnly(false);
        CapgoUpdater.configureStatsFlushForTests(null, false);
        CapgoUpdater.stubStatsFailureElapsedRealtimeForTests(true);
        server = new MockWebServer();
        server.start();
        documentsDir = Files.createTempDirectory("capgo-stats-failure-diagnostics").toFile();
    }

    @After
    public void tearDown() throws Exception {
        CapgoUpdater.resetStatsFlushForTests();
        DownloadService.setHttpsOnly(true);
        server.shutdown();
    }

    @Test
    public void transientHttpFailureMessageIncludesStatusAndElapsedMs() {
        final String message = StatsBatchFailureDiagnostics.formatFailureMessage(
            "Error sending stats batch",
            "https://plugin.capgo.app",
            "504",
            123L
        );
        assertTrue(message.startsWith("Error sending stats batch"));
        assertEquals("Error sending stats batch destination=https://plugin.capgo.app status=504 elapsedMs=123", message);
    }

    @Test
    public void transportFailureUsesUnavailableStatus() {
        final String message = StatsBatchFailureDiagnostics.formatFailureMessage(
            "Failed to send stats batch",
            "https://plugin.capgo.app",
            StatsBatchFailureDiagnostics.STATUS_UNAVAILABLE,
            50L
        );
        assertEquals("Failed to send stats batch destination=https://plugin.capgo.app status=unavailable elapsedMs=50", message);
    }

    @Test
    public void safeDestinationStripsUserInfoQueryFragmentAndPath() {
        final HttpUrl url = HttpUrl.parse("https://user:secret@example.com:8443/api/stats?token=abc#frag");
        assertEquals("https://example.com:8443", StatsBatchFailureDiagnostics.safeDestinationUrl(url));
    }

    @Test
    public void safeDestinationBracketsIpv6Host() {
        final HttpUrl url = HttpUrl.parse("https://[::1]:8443/stats");
        assertEquals("https://[::1]:8443", StatsBatchFailureDiagnostics.safeDestinationUrl(url));
    }

    @Test
    public void safeDestinationUsesFinalOriginAfterNonCircularRedirect() throws Exception {
        final MockWebServer redirectTarget = new MockWebServer();
        redirectTarget.start();
        try {
            server.enqueue(
                new MockResponse().setResponseCode(302).addHeader("Location", redirectTarget.url("/v2/stats/device-abc").toString())
            );
            redirectTarget.enqueue(new MockResponse().setResponseCode(500));

            final String logged = flushStatsAndCaptureError(server.url("/initial/stats/device-xyz?token=secret").toString());

            assertEquals("Error sending stats batch destination=" + serverOrigin(redirectTarget) + " status=500 elapsedMs=0", logged);
        } finally {
            redirectTarget.shutdown();
        }
    }

    @Test
    public void statsBatchHttp500LogsExactFailureLine() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(500));

        final String logged = flushStatsAndCaptureError(server.url("/stats/tenant-123?sig=secret").toString());

        assertEquals("Error sending stats batch destination=" + serverOrigin() + " status=500 elapsedMs=0", logged);
    }

    @Test
    public void statsBatchConnectionFailureLogsExactFailureLine() throws Exception {
        server.enqueue(new MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START));

        final String logged = flushStatsAndCaptureError(server.url("/stats/tenant-123").toString());

        assertEquals("Failed to send stats batch destination=" + serverOrigin() + " status=unavailable elapsedMs=0", logged);
    }

    @Test
    public void transientStatsFailureRetries504() throws Exception {
        final java.lang.reflect.Method method = CapgoUpdater.class.getDeclaredMethod("isTransientStatsFailure", int.class);
        method.setAccessible(true);
        assertTrue((Boolean) method.invoke(null, 504));
        assertFalse((Boolean) method.invoke(null, 404));

        server.enqueue(new MockResponse().setResponseCode(504));

        final Logger logger = mock(Logger.class);
        final CountDownLatch latch = new CountDownLatch(1);
        doAnswer((invocation) -> {
            latch.countDown();
            return null;
        })
            .when(logger)
            .error(anyString());

        final CapgoUpdater updater = new CapgoUpdater(logger);
        updater.documentsDir = documentsDir;
        updater.statsUrl = server.url("/stats/retry-504").toString();
        updater.httpsOnly = false;
        updater.enqueuePendingStatsEventForTests("diagnostics_probe");
        updater.flushStatsQueueForTests();

        assertTrue("stats flush callback", latch.await(10, TimeUnit.SECONDS));
        verify(logger, timeout(10_000)).error(anyString());

        final ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(logger).error(captor.capture());
        assertEquals(
            "Error sending stats batch destination=" + serverOrigin() + " status=504 elapsedMs=0",
            captor.getValue()
        );
        assertEquals(1, updater.pendingStatsCount());
        assertEquals("diagnostics_probe", updater.pendingStatsActionsForTests().get(0));
    }

    @Test
    public void statsBatchHttp504RequeuesPendingEventAndLogsFailure() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(504));

        final StatsFlushHarness harness = flushStatsHarness(server.url("/stats/tenant-123?sig=secret").toString());

        assertEquals(
            "Error sending stats batch destination=" + serverOrigin() + " status=504 elapsedMs=0",
            lastCapturedError(harness.logger)
        );
        assertEquals(Collections.singletonList("diagnostics_probe"), harness.updater.pendingStatsActionsForTests());
    }

    @Test
    public void statsBatchCircularRedirectLogsSanitizedOriginOnTransportFailure() throws Exception {
        for (int i = 0; i < 25; i++) {
            server.enqueue(
                new MockResponse().setResponseCode(302).addHeader("Location", server.url("/loop/device-abc?token=secret").toString())
            );
        }

        final StatsFlushHarness harness = flushStatsHarness(server.url("/start/stats/device-xyz?token=secret").toString());

        assertEquals(
            "Failed to send stats batch destination=" + serverOrigin() + " status=unavailable elapsedMs=0",
            lastCapturedError(harness.logger)
        );
    }

    private String flushStatsAndCaptureError(final String statsUrl) throws Exception {
        return lastCapturedError(flushStatsHarness(statsUrl).logger);
    }

    private StatsFlushHarness flushStatsHarness(final String statsUrl) throws Exception {
        final Logger logger = mock(Logger.class);
        final CountDownLatch latch = new CountDownLatch(1);
        doAnswer((invocation) -> {
            latch.countDown();
            return null;
        })
            .when(logger)
            .error(anyString());

        final CapgoUpdater updater = new CapgoUpdater(logger);
        updater.documentsDir = documentsDir;
        updater.statsUrl = statsUrl;
        updater.httpsOnly = false;
        updater.enqueuePendingStatsEventForTests("diagnostics_probe");
        updater.flushStatsQueueForTests();

        assertTrue("stats flush callback", latch.await(10, TimeUnit.SECONDS));
        verify(logger, timeout(10_000)).error(anyString());

        return new StatsFlushHarness(updater, logger);
    }

    private String lastCapturedError(final Logger logger) {
        final ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(logger).error(captor.capture());
        return captor.getValue();
    }

    private static final class StatsFlushHarness {

        private final CapgoUpdater updater;
        private final Logger logger;

        private StatsFlushHarness(final CapgoUpdater updater, final Logger logger) {
            this.updater = updater;
            this.logger = logger;
        }
    }

    private String serverOrigin() {
        return serverOrigin(server);
    }

    private static String serverOrigin(final MockWebServer mockWebServer) {
        return "http://" + mockWebServer.getHostName() + ":" + mockWebServer.getPort();
    }
}
