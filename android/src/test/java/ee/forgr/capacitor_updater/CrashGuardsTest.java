package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.util.Log;
import androidx.work.Configuration;
import androidx.work.Constraints;
import androidx.work.ListenableWorker;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import androidx.work.testing.SynchronousExecutor;
import androidx.work.testing.TestWorkerBuilder;
import androidx.work.testing.WorkManagerTestInitHelper;
import com.getcapacitor.Bridge;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.plugin.WebView;
import java.lang.reflect.Field;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.Mockito;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/** The plugin degrades instead of crashing the app: launch failures, throwing tasks, a pending close, bad values. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CrashGuardsTest {

    private final ExecutorService threads = Executors.newCachedThreadPool();
    private Context context;

    @Before
    public void setUp() {
        this.context = RuntimeEnvironment.getApplication();
        WorkManagerTestInitHelper.initializeTestWorkManager(
            this.context,
            new Configuration.Builder().setMinimumLoggingLevel(Log.DEBUG).setExecutor(new SynchronousExecutor()).build()
        );
        CapgoEngineHolder.reset();
    }

    @After
    public void tearDown() {
        CapgoCoreNative.setLoadErrorForTesting(null);
        CapgoEngineHolder.reset();
        this.threads.shutdownNow();
    }

    private static Logger silentLogger() {
        return new Logger("CrashGuardsTest", new Logger.Options(Logger.LogLevel.silent));
    }

    private static JSONObject identity(final String appId) {
        return CapgoCore.input(
            "appId",
            appId,
            "pluginVersion",
            "8.0.0",
            "versionBuild",
            "1.0.0",
            "versionCode",
            "10",
            "versionOs",
            "15",
            "deviceId",
            "device-1"
        );
    }

    private JSONObject loadInput(final JSONObject config) {
        return CapgoCore.input(
            "config",
            config,
            "native",
            CapgoCore.input(
                "versionName",
                "1.0.0",
                "versionCode",
                "10",
                "noBackupDir",
                this.context.getNoBackupFilesDir().getAbsolutePath(),
                "previousExits",
                new JSONArray()
            )
        );
    }

    private CapgoUpdater updater(final SharedPreferences prefs) {
        return new CapgoUpdater(
            this.context,
            prefs,
            silentLogger(),
            new CapgoUpdater.Listener() {
                @Override
                public void onEvent(final String event, final String payloadJson) {}

                @Override
                public String onHook(final String name, final String payloadJson) {
                    return null;
                }
            }
        );
    }

    private SharedPreferences prefs() {
        final SharedPreferences prefs = this.context.getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Context.MODE_PRIVATE);
        prefs.edit().clear().commit();
        return prefs;
    }

    private static CapacitorUpdaterPlugin plugin() {
        final CapacitorUpdaterPlugin plugin = new CapacitorUpdaterPlugin();
        plugin.setLoggerForTesting(silentLogger());
        return plugin;
    }

    private static String rejectionOf(final CapacitorUpdaterPlugin plugin) {
        final JSONObject reject = plugin.runEngineMethod("getLatest", new JSONObject()).optJSONObject("reject");
        return reject == null ? null : reject.optString("message");
    }

    // ---- 1. native core that cannot load ---------------------------------------------------------

    @Test
    public void aCoreLibraryThatCannotLoadDisablesThePluginInsteadOfCrashing() throws Exception {
        CapgoCoreNative.setLoadErrorForTesting(new UnsatisfiedLinkError("simulated: no libcapgo_updater_core.so"));
        assertFalse(CapgoCoreNative.isAvailable());
        final CapacitorUpdaterPlugin plugin = plugin();
        final CapgoUpdater updater = mock(CapgoUpdater.class);

        assertNull(plugin.startEngine(updater, identity("app.capgo.test"), this.loadInput(new JSONObject())));
        verify(updater, never()).createEngine(any(), any());
        assertTrue(rejectionOf(plugin), rejectionOf(plugin).contains("failed to load"));
        // Every engine creation path refuses instead of calling a missing native method.
        assertThrows(IllegalStateException.class, () -> new CapgoEngine(new JSONObject(), mock(CapgoEngineHost.class)));
    }

    @Test
    public void aBackgroundDownloadWithoutTheCoreLibraryFailsTheJob() throws Exception {
        // The plugin ran once: the worker configuration is persisted.
        final CapgoEngine engine = this.updater(this.prefs()).createEngine(identity("app.capgo.test"), "serverBasePath");
        engine.close();
        CapgoCoreNative.setLoadErrorForTesting(new UnsatisfiedLinkError("simulated"));

        assertNull(CapgoUpdater.createWorkerEngine(this.context));
        final CapgoDownloadWorker worker = TestWorkerBuilder.from(this.context, CapgoDownloadWorker.class, new SynchronousExecutor())
            .setInputData(new androidx.work.Data.Builder().putString(CapgoDownloadWorker.KEY_ID, "abc").build())
            .build();
        assertEquals(ListenableWorker.Result.failure(), worker.doWork());
    }

    @Test
    public void anEngineCreationLinkageErrorDisablesThePlugin() {
        final CapacitorUpdaterPlugin plugin = plugin();
        final CapgoUpdater updater = mock(CapgoUpdater.class);
        when(updater.createEngine(any(), any())).thenThrow(new UnsatisfiedLinkError("simulated"));
        assertNull(plugin.startEngine(updater, identity("app.capgo.test"), this.loadInput(new JSONObject())));
        assertTrue(rejectionOf(plugin).contains("failed to load"));
    }

    // ---- 2. pluginLoad failures ------------------------------------------------------------------

    @Test
    public void anInvalidPublicKeyStillStopsThePluginLoad() throws Exception {
        final CapacitorUpdaterPlugin plugin = plugin();
        final RuntimeException thrown = assertThrows(RuntimeException.class, () ->
            plugin.startEngine(
                this.updater(this.prefs()),
                identity("app.capgo.test"),
                this.loadInput(CapgoCore.input("publicKey", "-----BEGIN RSA PUBLIC KEY-----\nnot a key\n-----END RSA PUBLIC KEY-----"))
            )
        );
        assertEquals("invalid_public_key", ((CapgoCore.Failure) thrown.getCause()).code);
        assertTrue(rejectionOf(plugin).contains("failed to load"));
    }

    @Test
    public void aMissingAppIdStillStopsThePluginLoad() throws Exception {
        final CapgoEngine engine = mock(CapgoEngine.class);
        when(engine.call(eq("pluginLoad"), any())).thenThrow(new CapgoCore.Failure("missing_app_id", "appId is missing"));
        final CapgoUpdater updater = mock(CapgoUpdater.class);
        when(updater.createEngine(any(), any())).thenReturn(engine);
        final CapacitorUpdaterPlugin plugin = plugin();

        assertThrows(RuntimeException.class, () -> plugin.startEngine(updater, identity("app.capgo.test"), new JSONObject()));
        verify(engine, timeout(5000)).close();
    }

    @Test
    public void anyOtherPluginLoadFailureDisablesThePlugin() throws Exception {
        final CapgoEngine engine = mock(CapgoEngine.class);
        when(engine.call(eq("pluginLoad"), any())).thenThrow(new CapgoCore.Failure("internal", "storage unavailable"));
        final CapgoUpdater updater = mock(CapgoUpdater.class);
        when(updater.createEngine(any(), any())).thenReturn(engine);
        final CapacitorUpdaterPlugin plugin = plugin();

        assertNull(plugin.startEngine(updater, identity("app.capgo.test"), new JSONObject()));
        // The engine is released and never reached by methods.
        verify(engine, timeout(5000)).close();
        assertTrue(rejectionOf(plugin).contains("failed to load"));
        verify(engine, never()).call(eq("pluginMethod"), any());
    }

    // ---- 4. openAppStore -------------------------------------------------------------------------

    @Test
    public void openAppStoreRejectsWhenTheStoreCannotBeStarted() {
        final Context context = mock(Context.class);
        when(context.getPackageName()).thenReturn("app.capgo.test");
        doThrow(new SecurityException("Permission Denial")).when(context).startActivity(any(Intent.class));
        final Bridge bridge = mock(Bridge.class);
        when(bridge.getContext()).thenReturn(context);
        final CapacitorUpdaterPlugin plugin = plugin();
        plugin.setBridge(bridge);
        final PluginCall call = mock(PluginCall.class);

        plugin.openAppStore(call);

        verify(call).reject(Mockito.contains("Permission Denial"));
        verify(call, never()).resolve();
    }

    // ---- 5. method lanes and settle --------------------------------------------------------------

    @Test
    public void aThrowingMethodIsRejectedAndTheLanesGoOn() throws Exception {
        final EngineMethodLanes lanes = new EngineMethodLanes();
        lanes.setDetachedMethods(new JSONArray().put("detached"));
        final List<Throwable> failures = new CopyOnWriteArrayList<>();
        final AtomicBoolean uncaught = new AtomicBoolean();
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> uncaught.set(true));
        try {
            lanes.submit(
                "serial",
                () -> {
                    throw new IllegalStateException("serial boom");
                },
                () -> {},
                failures::add
            );
            lanes.submit(
                "detached",
                () -> {
                    throw new IllegalStateException("detached boom");
                },
                () -> {},
                failures::add
            );
            final CountDownLatch next = new CountDownLatch(1);
            final long start = System.nanoTime();
            lanes.submit("serial", next::countDown, () -> {});
            assertTrue(next.await(5, TimeUnit.SECONDS));
            // The lane did not wait out its hold limit for the detached method that threw.
            assertTrue(System.nanoTime() - start < TimeUnit.MILLISECONDS.toNanos(EngineMethodLanes.DEFAULT_LANE_HOLD_LIMIT_MS));
            assertEquals(2, failures.size());
            assertFalse(uncaught.get());
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous);
            lanes.shutdown();
        }
    }

    @Test
    public void aRejectionThatThrowsDoesNotReachTheCaller() {
        final EngineMethodLanes lanes = new EngineMethodLanes();
        lanes.shutdown();
        lanes.submit(
            "serial",
            () -> {},
            () -> {
                throw new IllegalStateException("bridge gone");
            }
        );
    }

    @Test
    public void settleNeverThrows() throws Exception {
        final PluginCall call = mock(PluginCall.class);
        doThrow(new IllegalStateException("bridge gone")).when(call).resolve(any(JSObject.class));
        CapacitorUpdaterPlugin.settle(call, new JSONObject("{\"resolve\":{\"id\":\"x\"}}"));
        verify(call).reject(Mockito.contains("bridge gone"));

        final PluginCall broken = mock(PluginCall.class);
        doThrow(new IllegalStateException("bridge gone")).when(broken).resolve();
        doThrow(new IllegalStateException("bridge gone")).when(broken).reject(anyString());
        CapacitorUpdaterPlugin.settle(broken, new JSONObject("{\"resolve\":null}"));

        final PluginCall empty = mock(PluginCall.class);
        CapacitorUpdaterPlugin.settle(empty, null);
        verify(empty).reject(anyString());
    }

    // ---- 6. stop calls never queue behind a pending close ------------------------------------------

    @Test
    public void stoppingADownloadDoesNotWaitBehindAPendingClose() throws Exception {
        final AtomicBoolean armed = new AtomicBoolean();
        final CountDownLatch blocked = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final SharedPreferences prefs = mock(SharedPreferences.class);
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class, Mockito.RETURNS_SELF);
        when(editor.commit()).thenReturn(true);
        when(prefs.edit()).thenReturn(editor);
        when(prefs.getAll()).thenAnswer((invocation) -> Collections.emptyMap());
        // The first preference read after arming blocks: the engine call stays running (like a long download).
        when(prefs.getString(anyString(), any())).thenAnswer((invocation) -> {
            if (armed.compareAndSet(true, false)) {
                blocked.countDown();
                release.await(10, TimeUnit.SECONDS);
            }
            return invocation.getArgument(1);
        });
        when(prefs.contains(anyString())).thenAnswer((invocation) -> {
            if (armed.compareAndSet(true, false)) {
                blocked.countDown();
                release.await(10, TimeUnit.SECONDS);
            }
            return false;
        });
        final CapgoEngine engine = this.updater(prefs).createEngine(identity("app.capgo.test"), "serverBasePath");
        armed.set(true);
        final Future<?> running = this.threads.submit(() -> engine.call("pluginLoad", this.loadInput(new JSONObject())));
        try {
            assertTrue("an engine call is running", blocked.await(10, TimeUnit.SECONDS));
            final Future<?> closing = this.threads.submit(engine::close);
            final Field field = CapgoEngine.class.getDeclaredField("lock");
            field.setAccessible(true);
            final ReentrantReadWriteLock lock = (ReentrantReadWriteLock) field.get(engine);
            final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (!lock.hasQueuedThreads()) {
                assertTrue("close() waits", System.nanoTime() < deadline);
                Thread.sleep(5);
            }
            // A plain call queues behind the waiting close() (the stall)...
            final Future<?> plain = this.threads.submit(() -> engine.call("stopScheduledDownload", CapgoCore.input("id", "job")));
            Thread.sleep(300);
            assertFalse(plain.isDone());
            // ...the stop path does not.
            final Future<JSONObject> stop = this.threads.submit(() ->
                engine.callWithoutWaitingForClose("stopScheduledDownload", CapgoCore.input("id", "job"))
            );
            assertNotNull(stop.get(2, TimeUnit.SECONDS));
            assertFalse(closing.isDone());

            release.countDown();
            closing.get(10, TimeUnit.SECONDS);
            running.get(10, TimeUnit.SECONDS);
            // Closed now: both paths fail as closed instead of reaching a freed engine.
            assertThrows(java.util.concurrent.ExecutionException.class, () -> plain.get(10, TimeUnit.SECONDS));
            assertThrows(CapgoCore.Failure.class, () ->
                engine.callWithoutWaitingForClose("stopScheduledDownload", CapgoCore.input("id", "job"))
            );
        } finally {
            release.countDown();
        }
    }

    // ---- 8. device id stored with another type ---------------------------------------------------

    @Test
    public void aLegacyDeviceIdOfAnotherTypeIsReplaced() {
        final SharedPreferences prefs = this.prefs();
        prefs.edit().putInt("appUUID", 42).commit();
        final String deviceId = DeviceIdHelper.getOrCreateDeviceId(this.context, prefs);
        assertEquals(deviceId, UUID.fromString(deviceId).toString());
        assertEquals(deviceId, prefs.getString("appUUID", null));
        // A string one is kept.
        prefs.edit().putString("appUUID", "ABCDEF00-0000-4000-8000-000000000000").commit();
        assertEquals("abcdef00-0000-4000-8000-000000000000", DeviceIdHelper.readLegacyDeviceId(prefs).toLowerCase());
    }

    // ---- 10. legacy download work is cancelled off the main thread --------------------------------

    @Test
    public void legacyDownloadWorkIsStillCancelled() throws Exception {
        final OneTimeWorkRequest legacy = new OneTimeWorkRequest.Builder(CapgoDownloadWorker.class)
            .setConstraints(new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .addTag("capacitor_updater_download")
            .build();
        final WorkManager workManager = WorkManager.getInstance(this.context);
        workManager.enqueue(legacy).getResult().get(5, TimeUnit.SECONDS);
        final CapgoEngine engine = this.updater(this.prefs()).createEngine(identity("app.capgo.test"), "serverBasePath");
        try {
            final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (workManager.getWorkInfoById(legacy.getId()).get().getState() != WorkInfo.State.CANCELLED) {
                assertTrue("legacy work cancelled", System.nanoTime() < deadline);
                Thread.sleep(10);
            }
        } finally {
            engine.close();
        }
    }

    // ---- 11. logger ------------------------------------------------------------------------------

    @Test
    public void loggingAtTheSilentLevelDoesNotThrow() {
        final Logger logger = new Logger("CrashGuardsTest", new Logger.Options(Logger.LogLevel.debug));
        logger.logAtLevel(Logger.LogLevel.silent, "nothing");
        logger.logAtLevel("silent", "nothing");
    }
}
