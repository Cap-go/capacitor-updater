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
import java.io.IOException;
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
import org.json.JSONArray;
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
    public void checksumCleanupPreservesReportedManualDownloadFailure() throws Exception {
        assertSelfCleanupReportsFailure(false, true);
    }

    @Test
    public void sessionKeyCleanupPreservesReportedManualDownloadFailure() throws Exception {
        assertSelfCleanupReportsFailure(true, true);
    }

    @Test
    public void checksumCleanupCompletesAutomaticFailureReporting() throws Exception {
        assertSelfCleanupReportsFailure(false, false);
    }

    private void assertSelfCleanupReportsFailure(final boolean invalidSessionKey, final boolean manual) throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater updater = updater(root, store);
        final String dest = "download.zip";
        final String checksum = "0".repeat(64);
        Files.write(root.resolve(dest), "invalid bundle".getBytes(StandardCharsets.UTF_8));
        CryptoCipher.setLogger(mock(Logger.class));
        if (invalidSessionKey) updater.publicKey = "configured-public-key";
        if (!manual) assertTrue(updater.saveBundleInfo(ID, new BundleInfo(ID, VERSION, BundleStatus.DOWNLOADING, new Date(), "")));
        try (ObserverHarness harness = new ObserverHarness(updater, !manual)) {
            doReturn(harness.context).when(updater).context();
            doReturn(null).when(updater).getPreviewFallbackBundle();
            doReturn(null).when(updater).getNextBundle();
            doReturn(ID, dest).when(updater).randomString();
            harness.downloads.when(() -> DownloadWorkerManager.cancelVersionDownloadAndAwait(harness.context, VERSION)).thenReturn(true);
            final Runnable completion = () -> {
                harness.complete(WorkInfo.State.SUCCEEDED, dest, false, invalidSessionKey ? "invalid" : "", checksum);
                harness.tasks.remove(0).run();
            };
            if (manual) {
                harness.onEnqueue = completion;
                final CapgoUpdater.ReportedDownloadFailureException error = assertThrows(
                    CapgoUpdater.ReportedDownloadFailureException.class,
                    () -> updater.download("https://example.com/update.zip", VERSION, invalidSessionKey ? "iv:session-key" : "", checksum)
                );
                assertEquals("Download failed with status: error", error.getMessage());
                verify(updater, never()).backgroundDownloadSettled(any(), anyString(), any());
            } else {
                completion.run();
                verify(updater, times(1)).backgroundDownloadSettled(any(), anyString(), any());
            }
            verify(updater, times(1)).notifyListeners(eq("downloadFailed"), anyMap());
            verify(updater, times(1)).sendStats("download_fail");
            verify(updater, times(1)).sendStats("finish_download_fail", VERSION);
            verify(updater, times(1)).sendStats(invalidSessionKey ? "session_key_required" : "checksum_fail");
            assertFalse("Failed verification must not restore deleted metadata", store.containsKey(ID + "_info"));
            assertFalse(Files.exists(root.resolve("versions").resolve(ID)));
            assertFalse("Failed verification must remove its temporary archive", Files.exists(root.resolve(dest)));
            verify(updater, never()).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
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
    public void interruptedZipWaiterDoesNotReleaseLaunchOnCancellation() throws Exception {
        assertInterruptedWaiterKeepsManualOrigin(false, WorkInfo.State.CANCELLED, false);
    }

    @Test
    public void interruptedManifestWaiterDoesNotReleaseLaunchOnCancellation() throws Exception {
        assertInterruptedWaiterKeepsManualOrigin(true, WorkInfo.State.CANCELLED, false);
    }

    @Test
    public void interruptedManualWaiterDoesNotReleaseLaunchOnFailure() throws Exception {
        assertInterruptedWaiterKeepsManualOrigin(false, WorkInfo.State.FAILED, false);
    }

    @Test
    public void interruptedManualWaiterDoesNotReleaseLaunchOnSuccess() throws Exception {
        assertInterruptedWaiterKeepsManualOrigin(true, WorkInfo.State.SUCCEEDED, false);
    }

    @Test
    public void invalidatedCompletionRetainsInterruptedManualOrigin() throws Exception {
        assertInterruptedWaiterKeepsManualOrigin(true, WorkInfo.State.SUCCEEDED, true);
    }

    private void assertInterruptedWaiterKeepsManualOrigin(final boolean manifest, final WorkInfo.State state, final boolean deleted)
        throws Exception {
        final Path root = temporary.newFolder().toPath();
        final CapgoUpdater updater = updater(root, new ConcurrentHashMap<>());
        try (ObserverHarness harness = new ObserverHarness(updater, false)) {
            doReturn(harness.context).when(updater).context();
            doReturn(ID, "download.zip").when(updater).randomString();
            harness.onEnqueue = () -> Thread.currentThread().interrupt();
            final IOException error;
            try {
                error = assertThrows(IOException.class, () -> {
                    if (manifest) {
                        updater.downloadManifest("https://example.com/update", VERSION, "", "", new JSONArray());
                    } else {
                        updater.download("https://example.com/update.zip", VERSION, "", "0".repeat(64));
                    }
                });
            } finally {
                Thread.interrupted();
            }
            assertTrue(error.toString(), error.getCause() instanceof InterruptedException);
            if (state == WorkInfo.State.SUCCEEDED) {
                final Path staging = root.resolve(harness.enqueuedDest);
                Files.createDirectories(staging);
                Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
            }
            if (deleted) assertTrue(updater.delete(ID, true, false));
            harness.complete(state, harness.enqueuedDest, manifest, "", "");
            while (!harness.tasks.isEmpty()) harness.tasks.remove(0).run();
            verify(updater, never()).backgroundDownloadSettled(any(), anyString(), any());
            if (state == WorkInfo.State.SUCCEEDED && !deleted) {
                assertTrue(Files.exists(root.resolve("versions").resolve(ID).resolve("index.html")));
            }
        }
    }

    @Test
    public void deletionDuringEnqueueCancelsNewTaggedWork() throws Exception {
        assertEnqueueCancellation(true);
    }

    @Test
    public void normalEnqueueDoesNotCancelTaggedWork() throws Exception {
        assertEnqueueCancellation(false);
    }

    private void assertEnqueueCancellation(final boolean deleted) throws Exception {
        final CapgoUpdater updater = updater(temporary.newFolder().toPath(), new ConcurrentHashMap<>());
        bundle(updater, ID);
        final List<String> events = new ArrayList<>();
        try (ObserverHarness harness = new ObserverHarness(updater, false)) {
            doReturn(harness.context).when(updater).context();
            harness.downloads
                .when(() -> DownloadWorkerManager.cancelVersionDownloadAndAwait(harness.context, VERSION))
                .thenAnswer((inv) -> {
                    events.add("cancel-existing");
                    return true;
                });
            harness.onEnqueue = () -> {
                if (deleted) {
                    try {
                        assertTrue(updater.delete(ID, true, true));
                    } catch (IOException error) {
                        throw new AssertionError(error);
                    }
                }
                events.add("enqueued");
            };
            doAnswer((inv) -> {
                events.add("cancel-new");
                return null;
            })
                .when(harness.manager)
                .cancelAllWorkByTag(ID);
            harness.start(updater);
            assertEquals(deleted ? List.of("cancel-existing", "enqueued", "cancel-new") : List.of("enqueued"), events);
            harness.complete(WorkInfo.State.CANCELLED, harness.enqueuedDest, false, "", "");
            while (!harness.tasks.isEmpty()) harness.tasks.remove(0).run();
            verify(updater, times(1)).backgroundDownloadSettled(any(), anyString(), any());
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

    @Test
    public void finalizationCannotOverwriteInterruptedDeletionMarker() throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater downloader = updater(root, store);
        assertTrue(plugin.saveBundleInfo(ID, new BundleInfo(ID, VERSION, BundleStatus.DOWNLOADING, new Date(), "")));
        final Path staging = root.resolve("capgo_manifest_registry001");
        Files.createDirectories(staging);
        Files.write(staging.resolve("index.html"), "downloaded".getBytes(StandardCharsets.UTF_8));
        final CountDownLatch beforeWrite = new CountDownLatch(1);
        final CountDownLatch releaseWrite = new CountDownLatch(1);
        final CountDownLatch deletionFinished = new CountDownLatch(1);
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        final AtomicReference<Boolean> deleted = new AtomicReference<>();
        doAnswer((inv) -> {
            beforeWrite.countDown();
            assertTrue(releaseWrite.await(5, TimeUnit.SECONDS));
            return inv.callRealMethod();
        })
            .when(downloader)
            .saveBundleInfo(eq(ID), isNull());
        doAnswer((inv) -> {
            assertTrue(deletionFinished.await(5, TimeUnit.SECONDS));
            return null;
        })
            .when(downloader)
            .notifyDownload(ID, 100);
        final Thread deletion = new Thread(() -> {
            try {
                // Interrupt the wait to exercise the same marker restoration as its timeout.
                Thread.currentThread().interrupt();
                deleted.set(plugin.delete(ID, true, false));
            } catch (Throwable error) {
                failure.set(error);
            } finally {
                deletionFinished.countDown();
            }
        });
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
                assertTrue(beforeWrite.await(2, TimeUnit.SECONDS));
                deletion.start();
                awaitBlockedOrFinished(deletion, finalization, deletionFinished);
            } finally {
                releaseWrite.countDown();
                finalization.join(5000);
                deletion.join(5000);
            }
            assertFalse(finalization.isAlive());
            assertFalse(deletion.isAlive());
            assertNull(failure.get());
            assertEquals(Boolean.FALSE, deleted.get());
            assertEquals(BundleStatus.DELETING, plugin.getBundleInfo(ID).getStatus());
            assertFalse(plugin.set(ID));
            assertFalse(plugin.setNextBundle(ID));
            assertTrue("A later retry can finish the deletion", plugin.delete(ID, true, false));
            assertFalse(Files.exists(root.resolve("versions").resolve(ID)));
            verify(downloader, never()).directUpdateFinish(any(BundleInfo.class), any(CapgoUpdater.BackgroundDownloadContext.class));
        }
    }

    @Test
    public void builtinRollbackSkipsDeletedTarget() throws Exception {
        assertBuiltinRollbackTarget("deleted");
    }

    @Test
    public void builtinRollbackSkipsMissingTarget() throws Exception {
        assertBuiltinRollbackTarget("missing");
    }

    @Test
    public void builtinRollbackSkipsDeletingTarget() throws Exception {
        assertBuiltinRollbackTarget("deleting");
    }

    @Test
    public void builtinRollbackSkipsActiveDeletionWithRewrittenMetadata() throws Exception {
        assertBuiltinRollbackTarget("active");
    }

    @Test
    public void builtinRollbackRestoresAvailableTarget() throws Exception {
        assertBuiltinRollbackTarget("available");
    }

    private void assertBuiltinRollbackTarget(final String state) throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater deleting = updater(root, store);
        bundle(plugin, ID);
        bundle(plugin, "bundleA001");
        assertTrue(plugin.set(ID));
        plugin.setSuccess(plugin.getCurrentBundle(), false);
        final CapgoUpdater.ResetState previous = plugin.captureResetState();
        plugin.prepareBuiltinTransition();
        assertTrue(plugin.setNextBundle("bundleA001"));
        if ("deleted".equals(state)) {
            assertTrue(deleting.delete(ID, true, false));
        } else if ("missing".equals(state)) {
            Files.delete(root.resolve("versions").resolve(ID).resolve("index.html"));
            Files.delete(root.resolve("versions").resolve(ID));
        } else if ("deleting".equals(state)) {
            assertTrue(deleting.saveBundleInfo(ID, deleting.getBundleInfo(ID).setStatus(BundleStatus.DELETING)));
        }
        if ("active".equals(state)) {
            doAnswer((inv) -> {
                assertTrue(deleting.saveBundleInfo(ID, deleting.getBundleInfo(ID).setStatus(BundleStatus.PENDING)));
                plugin.restoreResetStatePreservingNextBundle(previous);
                return inv.callRealMethod();
            })
                .when(deleting)
                .deleteDirectory(any(File.class));
            assertTrue(deleting.delete(ID, true, false));
        } else {
            plugin.restoreResetStatePreservingNextBundle(previous);
        }
        final boolean available = "available".equals(state);
        assertEquals(available ? previous.currentBundlePath : "public", plugin.getCurrentBundlePath());
        assertEquals(available ? ID : BundleInfo.ID_BUILTIN, plugin.getCurrentBundle().getId());
        assertEquals(available ? previous.fallbackBundleId : BundleInfo.ID_BUILTIN, plugin.getFallbackBundle().getId());
        assertEquals("Rollback must preserve the newer queue", "bundleA001", plugin.getNextBundle().getId());
    }

    @Test
    public void rollbackRestorationExcludesConcurrentDeletion() throws Exception {
        final Path root = temporary.newFolder().toPath();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoUpdater plugin = updater(root, store);
        final CapgoUpdater deleting = updater(root, store);
        bundle(plugin, ID);
        bundle(plugin, "bundleA001");
        assertTrue(plugin.set(ID));
        final CapgoUpdater.ResetState previous = plugin.captureResetState();
        plugin.prepareBuiltinTransition();
        assertTrue(plugin.setNextBundle("bundleA001"));
        final CountDownLatch restoring = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch deletionFinished = new CountDownLatch(1);
        final AtomicReference<Boolean> deleted = new AtomicReference<>();
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        doAnswer((inv) -> {
            final Object next = inv.callRealMethod();
            restoring.countDown();
            assertTrue(release.await(5, TimeUnit.SECONDS));
            return next;
        })
            .when(plugin)
            .getNextBundle();
        final Thread restoration = new Thread(() -> {
            try {
                plugin.restoreResetStatePreservingNextBundle(previous);
            } catch (Throwable error) {
                failure.set(error);
            }
        });
        final Thread deletion = new Thread(() -> {
            try {
                deleted.set(deleting.delete(ID, true, false));
            } catch (Throwable error) {
                failure.set(error);
            } finally {
                deletionFinished.countDown();
            }
        });
        try {
            restoration.start();
            assertTrue(restoring.await(2, TimeUnit.SECONDS));
            deletion.start();
            awaitBlockedOrFinished(deletion, restoration, deletionFinished);
        } finally {
            release.countDown();
            restoration.join(5000);
            deletion.join(5000);
        }
        assertFalse(restoration.isAlive());
        assertFalse(deletion.isAlive());
        assertNull(failure.get());
        assertEquals(Boolean.FALSE, deleted.get());
        assertTrue(Files.exists(root.resolve("versions").resolve(ID).resolve("index.html")));
        assertEquals(ID, plugin.getCurrentBundle().getId());
        assertEquals("bundleA001", plugin.getNextBundle().getId());
    }

    private static void awaitBlockedOrFinished(final Thread contender, final Thread owner, final CountDownLatch finished) throws Exception {
        // Management APIs are available on the test JVM, but absent from Android's compile stubs.
        final Object threads = Class.forName("java.lang.management.ManagementFactory").getMethod("getThreadMXBean").invoke(null);
        final Method getInfo = Class.forName("java.lang.management.ThreadMXBean").getMethod("getThreadInfo", long.class);
        final Class<?> infoClass = Class.forName("java.lang.management.ThreadInfo");
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (System.nanoTime() < deadline) {
            if (finished.getCount() == 0) return;
            final Object info = getInfo.invoke(threads, contender.threadId());
            if (
                info != null &&
                infoClass.getMethod("getThreadState").invoke(info) == Thread.State.BLOCKED &&
                (long) infoClass.getMethod("getLockOwnerId").invoke(info) == owner.threadId()
            ) return;
            java.util.concurrent.locks.LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(1));
        }
        fail("Competing operation neither completed nor reached the paused operation's monitor");
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

        final Context context = mock(Context.class);
        final WorkManager manager = mock(WorkManager.class);
        final List<Runnable> tasks = new ArrayList<>();
        final AtomicReference<Observer<List<WorkInfo>>> observer = new AtomicReference<>();
        final MockedStatic<WorkManager> managers = mockStatic(WorkManager.class);
        Runnable onEnqueue;
        String enqueuedDest;
        final MockedStatic<DownloadWorkerManager> downloads = mockStatic(DownloadWorkerManager.class, (inv) -> {
            if (inv.getMethod().getName().equals("enqueueDownload")) {
                enqueuedDest = inv.getArgument(4);
                if (onEnqueue != null) onEnqueue.run();
            }
            return RETURNS_DEFAULTS.answer(inv);
        });

        ObserverHarness(final CapgoUpdater updater) throws Exception {
            this(updater, true);
        }

        @SuppressWarnings("unchecked")
        ObserverHarness(final CapgoUpdater updater, final boolean observeImmediately) throws Exception {
            when(context.getApplicationContext()).thenReturn(context);
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
            if (observeImmediately) observe.invoke(
                updater,
                context,
                ID,
                VERSION,
                true,
                new CapgoUpdater.BackgroundDownloadContext(0, true)
            );
        }

        void start(final CapgoUpdater updater) throws Exception {
            final Method download = CapgoUpdater.class.getDeclaredMethod(
                "download",
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                JSONArray.class,
                boolean.class,
                CapgoUpdater.BackgroundDownloadContext.class
            );
            download.setAccessible(true);
            download.invoke(
                updater,
                ID,
                "https://example.com/update.zip",
                "download.zip",
                VERSION,
                "",
                "",
                null,
                true,
                new CapgoUpdater.BackgroundDownloadContext(0, true)
            );
        }

        void succeed(final String dest) {
            this.complete(WorkInfo.State.SUCCEEDED, dest);
        }

        void complete(final WorkInfo.State state, final String dest) {
            this.complete(state, dest, true, "", "");
        }

        void complete(
            final WorkInfo.State state,
            final String dest,
            final boolean manifest,
            final String sessionKey,
            final String checksum
        ) {
            final WorkInfo work = mock(WorkInfo.class);
            when(work.getState()).thenReturn(state);
            when(work.getProgress()).thenReturn(Data.EMPTY);
            when(work.getOutputData()).thenReturn(
                new Data.Builder()
                    .putString(DownloadService.VERSION, VERSION)
                    .putString(DownloadService.FILEDEST, dest)
                    .putBoolean(DownloadService.IS_MANIFEST, manifest)
                    .putString(DownloadService.SESSIONKEY, sessionKey)
                    .putString(DownloadService.CHECKSUM, checksum)
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
