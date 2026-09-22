package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.SharedPreferences;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
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

    private static void configureFinishDownloadTestState(final StatsTrackingCapgoUpdater updater) {
        updater.prefs = mock(SharedPreferences.class);
        updater.editor = mock(SharedPreferences.Editor.class);
        when(updater.prefs.getString(anyString(), anyString())).thenReturn("");
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
}
