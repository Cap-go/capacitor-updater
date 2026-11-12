package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import androidx.lifecycle.LiveData;
import androidx.lifecycle.Observer;
import androidx.work.Data;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.mockito.MockedStatic;

public class BundleDeletionCoordinationTest {

    private static final String ID = "bundleB002";
    private static final String VERSION = "2.0.0";

    @Rule
    public TemporaryFolder temporary = new TemporaryFolder();

    private CapgoUpdater updater(final Path root, final Map<String, String> store) throws Exception {
        final CapgoUpdater updater = spy(new CapgoUpdater(mock(Logger.class)));
        updater.documentsDir = root.toFile();
        updater.CAP_SERVER_PATH = "server-path";
        updater.prefs = mock(SharedPreferences.class);
        updater.editor = mock(SharedPreferences.Editor.class);
        when(updater.prefs.edit()).thenReturn(updater.editor);
        when(updater.prefs.contains(anyString())).thenAnswer((inv) -> store.containsKey(inv.getArgument(0)));
        when(updater.prefs.getString(anyString(), any())).thenAnswer((inv) -> store.getOrDefault(inv.getArgument(0), inv.getArgument(1)));
        when(updater.editor.putString(anyString(), anyString())).thenAnswer((inv) -> {
            store.put(inv.getArgument(0), inv.getArgument(1));
            return updater.editor;
        });
        when(updater.editor.remove(anyString())).thenAnswer((inv) -> {
            store.remove(inv.getArgument(0));
            return updater.editor;
        });
        when(updater.editor.commit()).thenReturn(true);
        doReturn(null).when(updater).context();
        doNothing().when(updater).notifyDownload(anyString(), anyInt());
        return updater;
    }

    private void bundle(final CapgoUpdater updater, final String id) throws Exception {
        final Path folder = updater.documentsDir.toPath().resolve("versions").resolve(id);
        Files.createDirectories(folder);
        Files.write(folder.resolve("index.html"), "existing".getBytes(StandardCharsets.UTF_8));
        assertTrue(updater.saveBundleInfo(id, new BundleInfo(id, VERSION, BundleStatus.PENDING, new Date(), "")));
    }

    @Test
    public void deletionClaimRejectsOtherInstanceActivationAndQueue() throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater headless = updater(root.resolve("."), store);
        bundle(plugin, ID);
        doAnswer((inv) -> {
            assertTrue(headless.saveBundleInfo(ID, headless.getBundleInfo(ID).setStatus(BundleStatus.PENDING)));
            assertFalse("Headless queueing must see the plugin's deletion claim", headless.setNextBundle(ID));
            assertFalse(headless.stagePendingReload(headless.getBundleInfo(ID)));
            assertFalse(headless.stagePreviewFallbackReload(headless.getBundleInfo(ID)));
            assertFalse(headless.set(ID));
            return inv.callRealMethod();
        })
            .when(plugin)
            .deleteDirectory(any(File.class));
        assertTrue(plugin.delete(ID, true, false));
        assertNull(headless.getNextBundle());
        assertFalse(Files.exists(root.resolve("versions").resolve(ID)));
    }

    @Test
    public void deletionClaimDoesNotBlockSameIdInDifferentStorage() throws Exception {
        final CapgoUpdater first = updater(temporary.newFolder().toPath(), new ConcurrentHashMap<>());
        final CapgoUpdater other = updater(temporary.newFolder().toPath(), new ConcurrentHashMap<>());
        bundle(first, ID);
        bundle(other, ID);
        doAnswer((inv) -> {
            assertTrue(other.setNextBundle(ID));
            return inv.callRealMethod();
        })
            .when(first)
            .deleteDirectory(any(File.class));
        assertTrue(first.delete(ID, true, false));
        assertEquals(ID, other.getNextBundle().getId());
    }

    @Test
    public void deletionInvalidatesQueuedSuccessInSameInstance() throws Exception {
        assertQueuedSuccessInvalidated(false, false);
    }

    @Test
    public void deletionInvalidatesQueuedSuccessInOtherInstance() throws Exception {
        assertQueuedSuccessInvalidated(true, false);
    }

    @Test
    public void deletionInvalidatesQueuedFailure() throws Exception {
        assertQueuedSuccessInvalidated(true, true);
    }

    private void assertQueuedSuccessInvalidated(final boolean separate, final boolean failed) throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater downloader = separate ? updater(root, store) : plugin;
        bundle(plugin, ID);
        final Path staging = root.resolve("capgo_manifest_staging001");
        Files.createDirectories(staging);
        Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
        try (ObserverHarness harness = new ObserverHarness(downloader)) {
            harness.complete(failed ? WorkInfo.State.FAILED : WorkInfo.State.SUCCEEDED, staging.getFileName().toString());
            assertEquals(1, harness.tasks.size());
            assertTrue(plugin.delete(ID, true, false));
            harness.tasks.remove(0).run();
            assertFalse(
                "A terminal task queued before deletion must not recreate the folder",
                Files.exists(root.resolve("versions").resolve(ID))
            );
            assertFalse("A terminal task must not recreate bundle metadata", store.containsKey(ID + "_info"));
            assertFalse("Cancelled finalization must remove its manifest staging directory", Files.exists(staging));
            assertNull(plugin.getNextBundle());
            verify(downloader, never()).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
        }
    }

    @Test
    public void completionWithoutDeletionStillFinalizesAndDispatches() throws Exception {
        final Path root = temporary.newFolder().toPath();
        final CapgoUpdater updater = updater(root, new ConcurrentHashMap<>());
        assertTrue(updater.saveBundleInfo(ID, new BundleInfo(ID, VERSION, BundleStatus.DOWNLOADING, new Date(), "")));
        final Path staging = root.resolve("capgo_manifest_success001");
        Files.createDirectories(staging);
        Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
        try (ObserverHarness harness = new ObserverHarness(updater)) {
            harness.succeed(staging.getFileName().toString());
            harness.tasks.remove(0).run();
            assertTrue(Files.exists(root.resolve("versions").resolve(ID).resolve("index.html")));
            assertEquals(BundleStatus.PENDING, updater.getBundleInfo(ID).getStatus());
            verify(updater).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
        }
    }

    @Test
    public void workManagerCancellationReleasesReadinessBeforeQueuedCleanup() throws Exception {
        final CapgoUpdater updater = updater(temporary.newFolder().toPath(), new ConcurrentHashMap<>());
        bundle(updater, ID);
        try (ObserverHarness harness = new ObserverHarness(updater)) {
            harness.complete(WorkInfo.State.CANCELLED, "unused");
            assertEquals(1, harness.tasks.size());
            verify(updater).backgroundDownloadSettled(
                any(BundleInfo.class),
                anyString(),
                any(CapgoUpdater.BackgroundDownloadContext.class)
            );
            harness.tasks.remove(0).run();
            verify(updater, times(1)).backgroundDownloadSettled(
                any(BundleInfo.class),
                anyString(),
                any(CapgoUpdater.BackgroundDownloadContext.class)
            );
        }
    }

    @Test
    public void observerRegisteredAfterDeletionCannotReviveBundle() throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater updater = updater(root, store);
        bundle(updater, ID);
        assertTrue(updater.delete(ID, true, false));
        final Path staging = root.resolve("capgo_manifest_lateReg001");
        Files.createDirectories(staging);
        Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
        try (ObserverHarness harness = new ObserverHarness(updater)) {
            harness.succeed(staging.getFileName().toString());
            harness.tasks.remove(0).run();
            assertFalse(Files.exists(root.resolve("versions").resolve(ID)));
            assertFalse(store.containsKey(ID + "_info"));
            verify(updater, never()).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
        }
    }

    @Test
    public void deletionWaitsForRunningFinalizationWithoutBlockingOtherBundles() throws Exception {
        assertRunningFinalizationSettles(false);
    }

    @Test
    public void interruptedDeletionRetryStillWaitsForRunningFinalization() throws Exception {
        assertRunningFinalizationSettles(true);
    }

    private void assertRunningFinalizationSettles(final boolean interrupt) throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater downloader = updater(root, store);
        bundle(plugin, ID);
        Files.delete(root.resolve("versions").resolve(ID).resolve("index.html"));
        Files.delete(root.resolve("versions").resolve(ID));
        assertTrue(plugin.saveBundleInfo(ID, plugin.getBundleInfo(ID).setStatus(BundleStatus.DOWNLOADING)));
        bundle(plugin, "bundleA001");
        final Path staging = root.resolve("capgo_manifest_running001");
        Files.createDirectories(staging);
        Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
        final CountDownLatch finalizing = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch deletionAdmitted = new CountDownLatch(1);
        final CountDownLatch deletionFinished = new CountDownLatch(1);
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        final AtomicReference<Boolean> deleted = new AtomicReference<>();
        doAnswer((inv) -> {
            finalizing.countDown();
            assertTrue(release.await(5, TimeUnit.SECONDS));
            return null;
        })
            .when(downloader)
            .notifyDownload(ID, 91);
        doAnswer((inv) -> {
            final boolean saved = (boolean) inv.callRealMethod();
            final BundleInfo info = inv.getArgument(1);
            if (info != null && info.isDeleting()) {
                deletionAdmitted.countDown();
            }
            return saved;
        })
            .when(plugin)
            .saveBundleInfo(eq(ID), any());
        final Thread deletion = new Thread(() -> {
            try {
                deleted.set(plugin.delete(ID, true, false));
            } catch (Throwable error) {
                failure.set(error);
            } finally {
                deletionFinished.countDown();
            }
        });
        final AtomicReference<Thread> retry = new AtomicReference<>();
        final CountDownLatch retryFinished = new CountDownLatch(1);
        try (ObserverHarness harness = new ObserverHarness(downloader)) {
            harness.succeed(staging.getFileName().toString());
            final Runnable task = harness.tasks.remove(0);
            final Thread finalization = new Thread(() -> {
                try {
                    task.run();
                } catch (Throwable error) {
                    failure.set(error);
                }
            });
            try {
                finalization.start();
                assertTrue(finalizing.await(2, TimeUnit.SECONDS));
                deletion.start();
                assertTrue(deletionAdmitted.await(2, TimeUnit.SECONDS));
                assertFalse(
                    "Deletion must settle admitted finalization before removing its files",
                    deletionFinished.await(200, TimeUnit.MILLISECONDS)
                );
                assertTrue(
                    "Unrelated staging must not wait on finalization",
                    plugin.stagePendingReload(plugin.getBundleInfo("bundleA001"))
                );
                if (interrupt) {
                    deletion.interrupt();
                    assertTrue(deletionFinished.await(2, TimeUnit.SECONDS));
                    assertEquals(Boolean.FALSE, deleted.get());
                    assertTrue(plugin.getBundleInfo(ID).isDeleting());
                    retry.set(
                        new Thread(() -> {
                            try {
                                deleted.set(plugin.delete(ID, true, false));
                            } catch (Throwable error) {
                                failure.set(error);
                            } finally {
                                retryFinished.countDown();
                            }
                        })
                    );
                    retry.get().start();
                    assertFalse("Retry must retain the running task's coordination", retryFinished.await(200, TimeUnit.MILLISECONDS));
                }
            } finally {
                release.countDown();
                finalization.join(3000);
                deletion.join(3000);
                if (retry.get() != null) retry.get().join(3000);
            }
            assertFalse(finalization.isAlive());
            assertFalse(deletion.isAlive());
            assertNull(failure.get());
            assertEquals(Boolean.TRUE, deleted.get());
            assertFalse(Files.exists(root.resolve("versions").resolve(ID)));
            assertFalse(store.containsKey(ID + "_info"));
            verify(downloader, never()).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
        }
    }

    private static void field(final CapgoUpdater updater, final String name, final Object value) throws Exception {
        final Field field = CapgoUpdater.class.getDeclaredField(name);
        field.setAccessible(true);
        field.set(updater, value);
    }

    private static final class ObserverHarness implements AutoCloseable {

        final List<Runnable> tasks = new ArrayList<>();
        final AtomicReference<Observer<List<WorkInfo>>> observer = new AtomicReference<>();
        final MockedStatic<WorkManager> managers = mockStatic(WorkManager.class);
        final MockedStatic<DownloadWorkerManager> downloads = mockStatic(DownloadWorkerManager.class);

        @SuppressWarnings("unchecked")
        ObserverHarness(final CapgoUpdater updater) throws Exception {
            final Context context = mock(Context.class);
            when(context.getApplicationContext()).thenReturn(context);
            final WorkManager manager = mock(WorkManager.class);
            managers.when(() -> WorkManager.getInstance(context)).thenReturn(manager);
            final LiveData<List<WorkInfo>> live = mock(LiveData.class);
            when(manager.getWorkInfosByTagLiveData(ID)).thenReturn(live);
            doAnswer((inv) -> {
                observer.set(inv.getArgument(0));
                return null;
            })
                .when(live)
                .observeForever(any());
            final Handler handler = mock(Handler.class);
            doAnswer((inv) -> {
                inv.<Runnable>getArgument(0).run();
                return true;
            })
                .when(handler)
                .post(any(Runnable.class));
            field(updater, "mainHandler", handler);
            final ExecutorService io = mock(ExecutorService.class);
            doAnswer((inv) -> {
                tasks.add(inv.getArgument(0));
                return null;
            })
                .when(io)
                .execute(any(Runnable.class));
            field(updater, "io", io);
            final Method observe = CapgoUpdater.class.getDeclaredMethod(
                "observeWorkProgress",
                Context.class,
                String.class,
                String.class,
                boolean.class,
                CapgoUpdater.BackgroundDownloadContext.class
            );
            observe.setAccessible(true);
            observe.invoke(updater, context, ID, VERSION, true, new CapgoUpdater.BackgroundDownloadContext(0, true));
        }

        void succeed(final String dest) {
            this.complete(WorkInfo.State.SUCCEEDED, dest);
        }

        void complete(final WorkInfo.State state, final String dest) {
            final WorkInfo work = mock(WorkInfo.class);
            when(work.getState()).thenReturn(state);
            when(work.getProgress()).thenReturn(Data.EMPTY);
            when(work.getOutputData()).thenReturn(
                new Data.Builder()
                    .putString(DownloadService.VERSION, VERSION)
                    .putString(DownloadService.FILEDEST, dest)
                    .putBoolean(DownloadService.IS_MANIFEST, true)
                    .putString(DownloadService.SESSIONKEY, "")
                    .putString(DownloadService.CHECKSUM, "")
                    .build()
            );
            observer.get().onChanged(List.of(work));
        }

        @Override
        public void close() {
            downloads.close();
            managers.close();
        }
    }
}
