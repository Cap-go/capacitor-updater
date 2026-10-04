package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.SharedPreferences;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.BeforeClass;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/**
 * Decrypts bundles encrypted by the real Capgo CLI (native-contract-tests/cli, written by
 * scripts/generate-cli-crypto-fixtures.mjs) through the same CryptoCipher calls as finishDownload.
 */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CliCryptoFixtureTest {

    @Rule
    public TemporaryFolder temp = new TemporaryFolder();

    @BeforeClass
    public static void setUpClass() {
        CryptoCipher.setLogger(new Logger("CliCryptoFixtureTest", new Logger.Options(Logger.LogLevel.silent)));
    }

    private static JSONObject fixture(Path dir) throws Exception {
        return new JSONObject(new String(Files.readAllBytes(dir.resolve("cli-crypto.json")), StandardCharsets.UTF_8));
    }

    private static Path fixtureDir() throws IOException {
        Path current = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (current != null) {
            Path candidate = current.resolve("native-contract-tests/cli");
            if (Files.exists(candidate.resolve("cli-crypto.json"))) {
                return candidate;
            }
            current = current.getParent();
        }
        throw new IOException("native-contract-tests/cli/cli-crypto.json not found");
    }

    @Test
    public void everyCliEncryptedBundleDecryptsToItsZip() throws Exception {
        Path dir = fixtureDir();
        JSONObject fixture = fixture(dir);
        String publicKey = fixture.getString("publicKey");
        JSONArray bundles = fixture.getJSONArray("bundles");
        assertTrue("fixture has bundles", bundles.length() > 0);

        for (int index = 0; index < bundles.length(); index++) {
            JSONObject bundle = bundles.getJSONObject(index);
            String id = bundle.getString("id");
            byte[] expectedZip = Files.readAllBytes(dir.resolve(bundle.getString("zip")));
            File downloaded = temp.newFile(id + ".zip");
            Files.copy(dir.resolve(bundle.getString("encrypted")), downloaded.toPath(), StandardCopyOption.REPLACE_EXISTING);

            // finishDownload: decrypt the file, decrypt the checksum, compare with the file's SHA-256.
            String sessionKey = bundle.getString("ivSessionKey");
            assertTrue(id, CryptoCipher.isValidSessionKey(sessionKey));
            CryptoCipher.decryptFile(downloaded, publicKey, sessionKey);
            String expectedChecksum = CryptoCipher.decryptChecksum(bundle.getString("checksum"), publicKey);

            assertArrayEquals(id + ": decrypted bytes", expectedZip, Files.readAllBytes(downloaded.toPath()));
            assertEquals(id + ": decrypted checksum", bundle.getString("sha256"), expectedChecksum);
            assertEquals(id + ": file checksum", expectedChecksum, CryptoCipher.calcChecksum(downloaded));
        }
    }

    @Test
    public void finishDownloadInstallsEveryCliEncryptedBundle() throws Exception {
        Path dir = fixtureDir();
        JSONObject fixture = fixture(dir);
        CapgoUpdater updater = new CapgoUpdater(mock(Logger.class)) {
            @Override
            public void sendStats(final String action) {}
        };
        updater.prefs = mock(SharedPreferences.class);
        updater.editor = mock(SharedPreferences.Editor.class);
        when(updater.prefs.getString(anyString(), anyString())).thenReturn("");
        updater.setPublicKey(fixture.getString("publicKey"));
        updater.documentsDir = temp.newFolder("documents");

        JSONArray bundles = fixture.getJSONArray("bundles");
        for (int index = 0; index < bundles.length(); index++) {
            JSONObject bundle = bundles.getJSONObject(index);
            String id = bundle.getString("id");
            String dest = id + "-download";
            Files.copy(dir.resolve(bundle.getString("encrypted")), updater.documentsDir.toPath().resolve(dest));

            boolean installed = updater.finishDownload(
                id,
                dest,
                "1.0.0",
                bundle.getString("ivSessionKey"),
                bundle.getString("checksum"),
                false,
                false
            );

            assertTrue(id + ": finishDownload", installed);
            // Every file the CLI zipped is installed with the same content.
            File bundleDir = CapgoUpdater.resolveBundleDirectory(updater.documentsDir, id);
            JSONArray files = bundle.getJSONArray("files");
            assertTrue(id + ": bundle has files", files.length() > 0);
            for (int fileIndex = 0; fileIndex < files.length(); fileIndex++) {
                JSONObject file = files.getJSONObject(fileIndex);
                File installedFile = new File(bundleDir, file.getString("path"));
                assertEquals(id + ": " + file.getString("path"), file.getString("sha256"), CryptoCipher.calcChecksum(installedFile));
            }
        }
    }
}
