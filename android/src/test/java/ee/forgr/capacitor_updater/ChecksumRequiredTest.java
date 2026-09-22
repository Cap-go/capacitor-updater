package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.json.JSONArray;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class ChecksumRequiredTest {

    private static final class StatsTrackingCapgoUpdater extends CapgoUpdater {

        private final List<String> sentStatsActions = new ArrayList<>();

        StatsTrackingCapgoUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void sendStats(final String action) {
            this.sentStatsActions.add(action);
        }

        List<String> getSentStatsActions() {
            return this.sentStatsActions;
        }
    }

    private static final class AutoUpdateChecksumCapgoUpdater extends StatsTrackingCapgoUpdater {

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("version", "2.0.0");
            response.put("url", "https://example.com/update.zip");
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc");
        }
    }

    private static final class ImmediateThreadCapacitorUpdaterPlugin extends CapacitorUpdaterPlugin {

        @Override
        public Thread startNewThread(final Runnable function) {
            function.run();
            return new Thread();
        }
    }

    private static void invokeBackgroundDownload(final CapacitorUpdaterPlugin plugin) throws Exception {
        final Method backgroundDownload = CapacitorUpdaterPlugin.class.getDeclaredMethod("backgroundDownload");
        backgroundDownload.setAccessible(true);
        backgroundDownload.invoke(plugin);
    }

    @BeforeClass
    public static void setUpClass() {
        CryptoCipher.setLogger(new Logger("ChecksumRequiredTest", new Logger.Options(Logger.LogLevel.silent)));
    }

    private static void configureFinishDownloadTestState(final StatsTrackingCapgoUpdater updater) {
        updater.prefs = mock(SharedPreferences.class);
        updater.editor = mock(SharedPreferences.Editor.class);
        when(updater.prefs.getString(anyString(), anyString())).thenReturn("");
    }

    private static Path createZipWithEntry(final String entryName) throws Exception {
        final Path zipPath = Files.createTempFile("capgo-checksum-zip", ".zip");
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(zipPath))) {
            zip.putNextEntry(new ZipEntry(entryName));
            zip.write("owned".getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }
        return zipPath;
    }

    private static void invokeDownloadBundle(
        final CapacitorUpdaterPlugin plugin,
        final String url,
        final String version,
        final String sessionKey,
        final String checksum,
        final JSONArray manifest
    ) throws Exception {
        final Method downloadBundle = CapacitorUpdaterPlugin.class.getDeclaredMethod(
            "downloadBundle",
            String.class,
            String.class,
            String.class,
            String.class,
            JSONArray.class
        );
        downloadBundle.setAccessible(true);
        downloadBundle.invoke(plugin, url, version, sessionKey, checksum, manifest);
    }

    @Test
    public void finishDownloadRejectsZipWhenChecksumMissing() throws Exception {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        configureFinishDownloadTestState(updater);
        final Path tempDir = Files.createTempDirectory("capgo-checksum-missing");
        updater.documentsDir = tempDir.toFile();
        final String dest = "bundle.zip";
        Files.write(tempDir.resolve(dest), "plaintext".getBytes(StandardCharsets.UTF_8));

        final boolean success = updater.finishDownload("bundle-id", dest, "1.0.0", "", "", false, false);

        assertFalse(success);
        assertTrue(updater.getSentStatsActions().contains("checksum_required"));
    }

    @Test
    public void finishDownloadRejectsZipWhenChecksumMismatch() throws Exception {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        configureFinishDownloadTestState(updater);
        final Path tempDir = Files.createTempDirectory("capgo-checksum-mismatch");
        updater.documentsDir = tempDir.toFile();
        final String dest = "bundle.zip";
        Files.write(tempDir.resolve(dest), "plaintext".getBytes(StandardCharsets.UTF_8));

        final boolean success = updater.finishDownload(
            "bundle-id",
            dest,
            "1.0.0",
            "",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            false,
            false
        );

        assertFalse(success);
        assertTrue(updater.getSentStatsActions().contains("checksum_fail"));
    }

    @Test
    public void finishDownloadAcceptsZipWhenChecksumMatches() throws Exception {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        configureFinishDownloadTestState(updater);
        final Path tempDir = Files.createTempDirectory("capgo-checksum-valid");
        updater.documentsDir = tempDir.toFile();
        final Path zipPath = createZipWithEntry("index.html");
        final String dest = "bundle.zip";
        Files.copy(zipPath, tempDir.resolve(dest));
        final String expectedChecksum = CryptoCipher.calcChecksum(tempDir.resolve(dest).toFile());

        final boolean success = updater.finishDownload("bundle-id", dest, "1.0.0", "", expectedChecksum, false, false);

        assertTrue(success);
        assertFalse(updater.getSentStatsActions().contains("checksum_required"));
        assertFalse(updater.getSentStatsActions().contains("checksum_fail"));
    }

    @Test
    public void downloadRejectsWhenChecksumMissing() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();

        try {
            updater.download("https://example.com/update.zip", "1.0.0", "", "");
            fail("Expected IOException when checksum is missing");
        } catch (IOException e) {
            // expected
        }

        assertTrue(updater.getSentStatsActions().contains("checksum_required"));
    }

    @Test
    public void downloadBundleRejectsWhenChecksumMissing() throws Exception {
        final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        plugin.implementation = updater;
        plugin.setLoggerForTesting(mock(Logger.class));

        try {
            invokeDownloadBundle(plugin, "https://example.com/update.zip", "1.0.0", "", "", null);
            fail("Expected IOException when checksum is missing");
        } catch (InvocationTargetException e) {
            assertTrue(e.getCause() instanceof IOException);
        }

        assertTrue(updater.getSentStatsActions().contains("checksum_required"));
    }

    @Test
    public void downloadBackgroundDoesNotStartWhenChecksumMissing() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();

        updater.downloadBackground("https://example.com/update.zip", "1.0.0", "", "", null);

        assertTrue(updater.getSentStatsActions().contains("checksum_required"));
    }

    @Test
    public void autoUpdateBackgroundDownloadRejectsWhenChecksumMissing() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final AutoUpdateChecksumCapgoUpdater updater = new AutoUpdateChecksumCapgoUpdater();

            plugin.implementation = updater;
            plugin.setAutoUpdateModeForTesting("onlyDownload");
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(updater.getSentStatsActions().contains("checksum_required"));
        }
    }
}
