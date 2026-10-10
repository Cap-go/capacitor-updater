package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.arch.core.executor.testing.InstantTaskExecutorRule;
import androidx.lifecycle.MutableLiveData;
import androidx.work.Data;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Instant;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.AbstractExecutorService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedStatic;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class ManifestStagingCleanupTest {

    @Rule
    public final InstantTaskExecutorRule instantTaskExecutorRule = new InstantTaskExecutorRule();

    private static ExecutorService directExecutor() {
        return new AbstractExecutorService() {
            @Override
            public void shutdown() {}

            @Override
            public List<Runnable> shutdownNow() {
                return Collections.emptyList();
            }

            @Override
            public boolean isShutdown() {
                return false;
            }

            @Override
            public boolean isTerminated() {
                return false;
            }

            @Override
            public boolean awaitTermination(final long timeout, final TimeUnit unit) {
                return true;
            }

            @Override
            public void execute(final Runnable command) {
                command.run();
            }
        };
    }

    private static void setIoExecutor(final CapgoUpdater updater, final ExecutorService executor) throws Exception {
        final Field ioField = CapgoUpdater.class.getDeclaredField("io");
        ioField.setAccessible(true);
        ioField.set(updater, executor);
    }

    private static final class PrefsHarness {

        final CapgoUpdater updater;
        final Map<String, String> store;

        private PrefsHarness(final CapgoUpdater updater, final Map<String, String> store) {
            this.updater = updater;
            this.store = store;
        }
    }

    private static PrefsHarness updaterWithPrefs(final Path documentsDir) {
        final CapgoUpdater updater = new CapgoUpdater(mock(Logger.class));
        updater.documentsDir = documentsDir.toFile();
        updater.CAP_SERVER_PATH = "server-path";
        final Map<String, String> store = new HashMap<>();
        final SharedPreferences prefs = mock(SharedPreferences.class);
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
        updater.prefs = prefs;
        updater.editor = editor;
        when(prefs.getAll()).thenAnswer((invocation) -> {
            final Map<String, Object> all = new HashMap<>();
            all.putAll(store);
            return all;
        });
        when(prefs.getString(any(String.class), any())).thenAnswer((inv) -> store.getOrDefault(inv.getArgument(0), inv.getArgument(1)));
        when(prefs.contains(any(String.class))).thenAnswer((inv) -> store.containsKey(inv.getArgument(0)));
        when(editor.putString(any(String.class), any(String.class))).thenAnswer((inv) -> {
            store.put(inv.getArgument(0), inv.getArgument(1));
            return editor;
        });
        when(editor.remove(any(String.class))).thenAnswer((inv) -> {
            store.remove(inv.getArgument(0));
            return editor;
        });
        when(editor.commit()).thenReturn(true);
        when(prefs.getString("server-path", "public")).thenReturn("public");
        when(prefs.getString("pastVersion", BundleInfo.ID_BUILTIN)).thenReturn(BundleInfo.ID_BUILTIN);
        when(prefs.getString("nextVersion", null)).thenReturn(null);
        when(prefs.getString("previewFallbackVersion", null)).thenReturn(null);
        return new PrefsHarness(updater, store);
    }

    private static void markDownloadingManifestDest(final PrefsHarness harness, final String bundleId, final String dest) {
        harness.store.put(bundleId + "_info", new BundleInfo(bundleId, "1.0.0", BundleStatus.DOWNLOADING, new Date(), "").toString());
        harness.store.put(bundleId + CapgoUpdater.MANIFEST_DEST_SUFFIX, dest);
    }

    @Test
    public void cleanupOrphanedManifestStagingFoldersPreservesInFlightFolder() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-inflight-staging");
        tempDir.toFile().deleteOnExit();
        final String activeDest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "inFlight01";
        final Path activeStaging = tempDir.resolve(activeDest);
        Files.createDirectories(activeStaging.resolve("assets"));
        final Path orphanStaging = tempDir.resolve(CapgoUpdater.MANIFEST_STAGING_PREFIX + "orphanFl01");
        Files.createDirectories(orphanStaging);

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        markDownloadingManifestDest(harness, "downldId01", activeDest);

        harness.updater.cleanupOrphanedManifestStagingFolders(null);

        assertTrue("In-flight manifest staging must survive cleanup", Files.exists(activeStaging));
        assertFalse("Orphan manifest staging should be removed", Files.exists(orphanStaging));
    }

    @Test
    public void cleanupPreservesManifestDestsForCurrentNextAndFallbackDownloads() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-protected-staging");
        tempDir.toFile().deleteOnExit();
        final String currentDest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "currentDl01";
        final String nextDest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "nextDown01";
        final String fallbackDest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "fallback01";
        for (final String dest : List.of(currentDest, nextDest, fallbackDest)) {
            Files.createDirectories(tempDir.resolve(dest));
        }

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        markDownloadingManifestDest(harness, "currentId01", currentDest);
        markDownloadingManifestDest(harness, "nextId0001", nextDest);
        markDownloadingManifestDest(harness, "fallback01", fallbackDest);

        harness.updater.cleanupOrphanedManifestStagingFolders(null);

        assertTrue(Files.exists(tempDir.resolve(currentDest)));
        assertTrue(Files.exists(tempDir.resolve(nextDest)));
        assertTrue(Files.exists(tempDir.resolve(fallbackDest)));
    }

    @Test
    public void deleteManifestStagingTreeUnlinksSymlinkWithoutDeletingTarget() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-symlink-staging");
        tempDir.toFile().deleteOnExit();
        final Path external = tempDir.resolve("external_data");
        Files.createDirectories(external);
        final Path externalFile = external.resolve("keep.txt");
        Files.write(externalFile, "keep".getBytes(StandardCharsets.UTF_8));

        final Path staging = tempDir.resolve(CapgoUpdater.MANIFEST_STAGING_PREFIX + "symLink0001");
        Files.createDirectories(staging);
        Files.createSymbolicLink(staging.resolve("assets"), external);

        CapgoUpdater.deleteManifestStagingFolderAt(tempDir.toFile(), staging.getFileName().toString(), mock(Logger.class));

        assertFalse(Files.exists(staging));
        assertTrue("Symlink target must remain intact", Files.exists(externalFile));
    }

    @Test
    public void deleteManifestStagingFolderAtRefusesPathTraversalDest() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-traversal");
        tempDir.toFile().deleteOnExit();
        final Path outside = Files.createTempDirectory("capgo-outside");
        outside.toFile().deleteOnExit();
        Files.write(outside.resolve("secret.txt"), "secret".getBytes(StandardCharsets.UTF_8));

        CapgoUpdater.deleteManifestStagingFolderAt(tempDir.toFile(), "../" + outside.getFileName() + "/secret.txt", mock(Logger.class));

        assertTrue("Traversal dest must not delete files outside documents dir", Files.exists(outside.resolve("secret.txt")));
    }

    @Test
    public void cleanupLegacyBareStagingRequiresOldFolder() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-legacy-age");
        tempDir.toFile().deleteOnExit();
        final Path freshLegacy = tempDir.resolve("freshLeg01");
        Files.createDirectories(freshLegacy);
        Files.write(freshLegacy.resolve("index.html"), "<html></html>".getBytes(StandardCharsets.UTF_8));

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        harness.updater.cleanupOrphanedManifestStagingFolders(null);

        assertTrue("Fresh legacy-like folder must not be deleted without age gate", Files.exists(freshLegacy));

        Files.setLastModifiedTime(freshLegacy, FileTime.from(Instant.now().minusSeconds(25 * 3600)));
        harness.updater.cleanupOrphanedManifestStagingFolders(null);

        assertFalse("Stale legacy staging should be deleted after age gate", Files.exists(freshLegacy));
    }

    @Test
    public void finishDownloadManifestFailureDeletesStagingFolder() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-finish-fail");
        tempDir.toFile().deleteOnExit();
        final String bundleId = "finishFail";
        final String dest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "finishFl01";
        final Path staging = tempDir.resolve(dest);
        Files.createDirectories(staging);

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        final Path bundleDir = tempDir.resolve("versions").resolve(bundleId);
        Files.createDirectories(bundleDir.getParent());

        assertFalse(harness.updater.finishDownload(bundleId, dest, "2.0.0", "", "", false, true));
        assertFalse("Manifest staging folder must be removed after finishDownload failure", Files.exists(staging));
    }

    @Test
    public void cleanupAfterDownloadFailedRemovesManifestStaging() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-failed-cleanup");
        tempDir.toFile().deleteOnExit();
        final String dest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "failedSt01";
        Files.createDirectories(tempDir.resolve(dest));

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        harness.updater.cleanupManifestStagingAfterDownloadFailed("bundleFail", dest, true);

        assertFalse(Files.exists(tempDir.resolve(dest)));
    }

    @Test
    public void cleanupAfterDownloadCancelledRemovesManifestStaging() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-cancel-cleanup");
        tempDir.toFile().deleteOnExit();
        final String dest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "cancelSt01";
        Files.createDirectories(tempDir.resolve(dest));

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        harness.store.put("bundleCan1" + CapgoUpdater.MANIFEST_DEST_SUFFIX, dest);

        harness.updater.cleanupManifestStagingAfterDownloadCancelled("bundleCan1");

        assertFalse(Files.exists(tempDir.resolve(dest)));
    }

    @Test
    public void observeWorkProgressFailedManifestRemovesStagingFolder() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-work-failed");
        tempDir.toFile().deleteOnExit();
        final String bundleId = "workFailed";
        final String dest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "workFail01";
        Files.createDirectories(tempDir.resolve(dest));

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        setIoExecutor(harness.updater, directExecutor());

        final Context appContext = mock(Context.class);
        when(appContext.getApplicationContext()).thenReturn(appContext);
        harness.updater.appContext = appContext;

        final MutableLiveData<List<WorkInfo>> liveData = new MutableLiveData<>();
        final WorkInfo workInfo = mock(WorkInfo.class);
        final Data failedData = new Data.Builder()
            .putString(DownloadService.FILEDEST, dest)
            .putString(DownloadService.VERSION, "3.0.0")
            .putBoolean(DownloadService.IS_MANIFEST, true)
            .putString(DownloadService.ERROR, "download_fail")
            .build();
        when(workInfo.getState()).thenReturn(WorkInfo.State.FAILED);
        when(workInfo.getOutputData()).thenReturn(failedData);
        when(workInfo.getProgress()).thenReturn(Data.EMPTY);

        try (
            MockedStatic<WorkManager> workManagerStatic = mockStatic(WorkManager.class);
            MockedStatic<DownloadWorkerManager> downloadWorkerStatic = mockStatic(DownloadWorkerManager.class)
        ) {
            downloadWorkerStatic
                .when(() -> DownloadWorkerManager.cancelBundleDownload(any(Context.class), any(String.class), any(String.class)))
                .thenAnswer((invocation) -> null);
            final WorkManager workManager = mock(WorkManager.class);
            workManagerStatic.when(() -> WorkManager.getInstance(any(Context.class))).thenReturn(workManager);
            when(workManager.getWorkInfosByTagLiveData(bundleId)).thenReturn(liveData);

            final Method observe = CapgoUpdater.class.getDeclaredMethod(
                "observeWorkProgress",
                Context.class,
                String.class,
                String.class,
                boolean.class
            );
            observe.setAccessible(true);
            observe.invoke(harness.updater, appContext, bundleId, "3.0.0", false);

            ShadowLooper.idleMainLooper();
            liveData.setValue(List.of(workInfo));
            ShadowLooper.idleMainLooper();
        }

        assertFalse("FAILED work progress must delete manifest staging", Files.exists(tempDir.resolve(dest)));
    }

    @Test
    public void observeWorkProgressCancelledManifestRemovesStagingFolder() throws Exception {
        final Path tempDir = Files.createTempDirectory("capgo-work-cancel");
        tempDir.toFile().deleteOnExit();
        final String bundleId = "workCan001";
        final String dest = CapgoUpdater.MANIFEST_STAGING_PREFIX + "workCan001";
        Files.createDirectories(tempDir.resolve(dest));

        final PrefsHarness harness = updaterWithPrefs(tempDir);
        setIoExecutor(harness.updater, directExecutor());
        harness.store.put(bundleId + CapgoUpdater.MANIFEST_DEST_SUFFIX, dest);

        final Context appContext = mock(Context.class);
        when(appContext.getApplicationContext()).thenReturn(appContext);
        harness.updater.appContext = appContext;

        final MutableLiveData<List<WorkInfo>> liveData = new MutableLiveData<>();
        final WorkInfo workInfo = mock(WorkInfo.class);
        when(workInfo.getState()).thenReturn(WorkInfo.State.CANCELLED);
        when(workInfo.getProgress()).thenReturn(Data.EMPTY);

        try (MockedStatic<WorkManager> workManagerStatic = mockStatic(WorkManager.class)) {
            final WorkManager workManager = mock(WorkManager.class);
            workManagerStatic.when(() -> WorkManager.getInstance(any(Context.class))).thenReturn(workManager);
            when(workManager.getWorkInfosByTagLiveData(bundleId)).thenReturn(liveData);

            final Method observe = CapgoUpdater.class.getDeclaredMethod(
                "observeWorkProgress",
                Context.class,
                String.class,
                String.class,
                boolean.class
            );
            observe.setAccessible(true);
            observe.invoke(harness.updater, appContext, bundleId, "4.0.0", false);

            ShadowLooper.idleMainLooper();
            liveData.setValue(List.of(workInfo));
            ShadowLooper.idleMainLooper();
        }

        assertFalse("CANCELLED work progress must delete manifest staging", Files.exists(tempDir.resolve(dest)));
    }
}
