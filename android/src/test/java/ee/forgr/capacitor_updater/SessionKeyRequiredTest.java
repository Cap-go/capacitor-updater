package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
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
public class SessionKeyRequiredTest {

    private static String fixturePublicKey;

    @BeforeClass
    public static void setUpClass() throws Exception {
        CryptoCipher.setLogger(new Logger("SessionKeyRequiredTest", new Logger.Options(Logger.LogLevel.silent)));
        Path contractFile = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (contractFile != null) {
            Path candidate = contractFile.resolve("native-contract-tests/crypto-rsa.json");
            if (Files.exists(candidate)) {
                fixturePublicKey = new org.json.JSONObject(new String(Files.readAllBytes(candidate), StandardCharsets.UTF_8)).getString(
                    "publicKeyPem"
                );
                return;
            }
            contractFile = contractFile.getParent();
        }
        throw new IOException("native-contract-tests/crypto-rsa.json not found");
    }

    private static class StatsTrackingCapgoUpdater extends CapgoUpdater {

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

    private static final class AutoUpdateSessionKeyCapgoUpdater extends StatsTrackingCapgoUpdater {

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

    private static final class PendingBundleAutoUpdateCapgoUpdater extends StatsTrackingCapgoUpdater {

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("version", "2.0.0");
            response.put("url", "https://example.com/update.zip");
            response.put("checksum", "abc123");
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc");
        }

        @Override
        public BundleInfo getBundleInfoByName(final String versionName) {
            if ("2.0.0".equals(versionName)) {
                return new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "abc123");
            }
            return null;
        }
    }

    private static final class ImmediateThreadCapacitorUpdaterPlugin extends CapacitorUpdaterPlugin {

        @Override
        public Thread startNewThread(final Runnable function) {
            function.run();
            return new Thread();
        }
    }

    private static void configureFinishDownloadTestState(final StatsTrackingCapgoUpdater updater) {
        updater.prefs = mock(SharedPreferences.class);
        updater.editor = mock(SharedPreferences.Editor.class);
        when(updater.prefs.getString(anyString(), anyString())).thenReturn("");
    }

    private static void invokeBackgroundDownload(final CapacitorUpdaterPlugin plugin) throws Exception {
        final Method backgroundDownload = CapacitorUpdaterPlugin.class.getDeclaredMethod("backgroundDownload");
        backgroundDownload.setAccessible(true);
        backgroundDownload.invoke(plugin);
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
    public void finishDownloadRejectsManifestWhenSessionKeyMissing() throws Exception {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        configureFinishDownloadTestState(updater);
        updater.setPublicKey(fixturePublicKey);
        updater.documentsDir = Files.createTempDirectory("capgo-session-key-manifest").toFile();

        final boolean success = updater.finishDownload("bundle-id", "dest", "1.0.0", "", "checksum", false, true);

        assertFalse(success);
        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void finishDownloadRejectsZipWhenSessionKeyMissing() throws Exception {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        configureFinishDownloadTestState(updater);
        updater.setPublicKey(fixturePublicKey);
        final Path tempDir = Files.createTempDirectory("capgo-session-key-zip");
        updater.documentsDir = tempDir.toFile();
        final String dest = "bundle.zip";
        Files.write(tempDir.resolve(dest), "plaintext".getBytes(StandardCharsets.UTF_8));

        final boolean success = updater.finishDownload("bundle-id", dest, "1.0.0", "", "checksum", false, false);

        assertFalse(success);
        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void downloadRejectsWhenSessionKeyMissing() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);

        try {
            updater.download("https://example.com/update.zip", "1.0.0", "", "checksum");
            fail("Expected IOException when session key is missing");
        } catch (IOException e) {
            assertEquals("Session key required when public key is present", e.getMessage());
        }

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    @Test
    public void isValidSessionKeyRejectsEmptyComponents() {
        assertFalse(CryptoCipher.isValidSessionKey(null));
        assertFalse(CryptoCipher.isValidSessionKey(""));
        assertFalse(CryptoCipher.isValidSessionKey(":"));
        assertFalse(CryptoCipher.isValidSessionKey("abc:"));
        assertFalse(CryptoCipher.isValidSessionKey(":xyz"));
        assertFalse(CryptoCipher.isValidSessionKey("invalid-format"));
        assertTrue(CryptoCipher.isValidSessionKey("abc:def"));
    }

    @Test
    public void downloadRejectsWhenSessionKeyHasEmptyComponents() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);

        try {
            updater.download("https://example.com/update.zip", "1.0.0", "abc:", "checksum");
            fail("Expected IOException when session key has empty components");
        } catch (IOException e) {
            assertEquals("Session key required when public key is present", e.getMessage());
        }

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    public void downloadRejectsWhenSessionKeyFormatInvalid() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);

        try {
            updater.download("https://example.com/update.zip", "1.0.0", "invalid-format", "checksum");
            fail("Expected IOException when session key format is invalid");
        } catch (IOException e) {
            assertEquals("Session key required when public key is present", e.getMessage());
        }

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void downloadManifestRejectsWhenSessionKeyMissing() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);
        final JSONArray manifest = new JSONArray();

        try {
            updater.downloadManifest("https://example.com/update.zip", "1.0.0", "", "checksum", manifest);
            fail("Expected IOException when session key is missing");
        } catch (IOException e) {
            assertEquals("Session key required when public key is present", e.getMessage());
        }

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void downloadBackgroundDoesNotStartWhenSessionKeyMissing() {
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);

        updater.downloadBackground("https://example.com/update.zip", "1.0.0", "", "checksum", null);

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void downloadBundleRejectsWhenSessionKeyMissing() throws Exception {
        final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
        final StatsTrackingCapgoUpdater updater = new StatsTrackingCapgoUpdater();
        updater.setPublicKey(fixturePublicKey);
        plugin.implementation = updater;
        plugin.setLoggerForTesting(mock(Logger.class));

        try {
            invokeDownloadBundle(plugin, "https://example.com/update.zip", "1.0.0", "", "checksum", null);
            fail("Expected IOException when session key is missing");
        } catch (InvocationTargetException e) {
            assertTrue(e.getCause() instanceof IOException);
            assertEquals("Session key required when public key is present", e.getCause().getMessage());
        }

        assertTrue(updater.getSentStatsActions().contains("session_key_required"));
    }

    @Test
    public void autoUpdateRejectsMissingSessionKeyWhenPendingBundleExists() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final PendingBundleAutoUpdateCapgoUpdater updater = new PendingBundleAutoUpdateCapgoUpdater();
            updater.setPublicKey(fixturePublicKey);

            plugin.implementation = updater;
            plugin.setAutoUpdateModeForTesting("onlyDownload");
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(updater.getSentStatsActions().contains("session_key_required"));
        }
    }

    @Test
    public void autoUpdateBackgroundDownloadRejectsWhenSessionKeyMissing() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final AutoUpdateSessionKeyCapgoUpdater updater = new AutoUpdateSessionKeyCapgoUpdater();
            updater.setPublicKey(fixturePublicKey);

            plugin.implementation = updater;
            plugin.setAutoUpdateModeForTesting("onlyDownload");
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(updater.getSentStatsActions().contains("session_key_required"));
        }
    }
}
