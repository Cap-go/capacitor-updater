package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;

import android.content.Context;
import android.content.SharedPreferences;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.Date;
import java.util.UUID;
import java.util.stream.Stream;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public class SetNextBundleTest {

    private static final String SERVER_PATH_KEY = "serverPath";

    private Path tempDir;
    private CapgoUpdater updater;

    @Before
    public void setUp() throws IOException {
        final Context context = RuntimeEnvironment.getApplication();
        final SharedPreferences prefs = context.getSharedPreferences("set-next-" + UUID.randomUUID(), Context.MODE_PRIVATE);

        this.tempDir = Files.createTempDirectory("set-next-bundle-test");
        this.updater = new CapgoUpdater(mock(Logger.class));
        this.updater.prefs = prefs;
        this.updater.editor = prefs.edit();
        this.updater.documentsDir = this.tempDir.toFile();
        this.updater.noBackupDir = this.tempDir.toFile();
        this.updater.CAP_SERVER_PATH = SERVER_PATH_KEY;
    }

    @After
    public void tearDown() throws IOException {
        if (this.updater != null) {
            this.updater.shutdown();
        }
        if (this.tempDir != null && Files.exists(this.tempDir)) {
            try (Stream<Path> paths = Files.walk(this.tempDir)) {
                paths.sorted(Comparator.reverseOrder()).forEach((path) -> path.toFile().delete());
            }
        }
    }

    @Test
    public void setNextBundleDoesNotQueueCurrentBundle() throws IOException {
        final BundleInfo current = installBundle("current-id", "1.0.1", BundleStatus.SUCCESS);
        setCurrentBundle(current);

        assertTrue(this.updater.setNextBundle(current.getId()));

        assertNull(this.updater.getNextBundle());
        assertEquals(BundleStatus.SUCCESS, this.updater.getCurrentBundle().getStatus());
    }

    @Test
    public void setNextBundleStillQueuesDifferentBundle() throws IOException {
        final BundleInfo current = installBundle("current-id", "1.0.1", BundleStatus.SUCCESS);
        final BundleInfo next = installBundle("next-id", "1.0.2", BundleStatus.SUCCESS);
        setCurrentBundle(current);

        assertTrue(this.updater.setNextBundle(next.getId()));

        assertEquals(next.getId(), this.updater.getNextBundle().getId());
        assertEquals(BundleStatus.PENDING, this.updater.getNextBundle().getStatus());
        assertEquals(BundleStatus.SUCCESS, this.updater.getCurrentBundle().getStatus());
    }

    private BundleInfo installBundle(final String id, final String version, final BundleStatus status) throws IOException {
        final Path bundleDirectory = this.tempDir.resolve("versions").resolve(id);
        Files.createDirectories(bundleDirectory);
        Files.createFile(bundleDirectory.resolve("index.html"));
        final BundleInfo bundle = new BundleInfo(id, version, status, new Date(), "checksum-" + id);
        assertTrue(this.updater.saveBundleInfo(id, bundle));
        return bundle;
    }

    private void setCurrentBundle(final BundleInfo bundle) {
        final String path = this.tempDir.resolve("versions").resolve(bundle.getId()).toString();
        assertTrue(this.updater.editor.putString(SERVER_PATH_KEY, path).commit());
    }
}
