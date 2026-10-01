package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.content.Context;
import android.content.SharedPreferences;
import com.getcapacitor.PluginMethod;
import java.lang.ref.WeakReference;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/** The Rust engine driven through the JNI host exactly like the plugin does: load, hooks, methods, events. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class EngineHostTest {

    /** Methods that stay native (Play Store in-app updates). */
    private static final Set<String> NATIVE_METHODS = Set.of(
        "getAppUpdateInfo",
        "openAppStore",
        "performImmediateUpdate",
        "startFlexibleUpdate",
        "completeFlexibleUpdate"
    );

    private final List<String> hooks = new CopyOnWriteArrayList<>();
    private final List<String> events = new CopyOnWriteArrayList<>();
    private CapgoEngine engine;
    private SharedPreferences prefs;

    @Before
    public void setUp() throws Exception {
        final Context context = RuntimeEnvironment.getApplication();
        this.prefs = context.getSharedPreferences("CapWebViewSettings", Context.MODE_PRIVATE);
        final CapgoUpdater updater = new CapgoUpdater(
            context,
            this.prefs,
            new Logger("EngineHostTest", new Logger.Options(Logger.LogLevel.silent)),
            new CapgoUpdater.Listener() {
                @Override
                public void onEvent(final String event, final String payloadJson) {
                    events.add(event);
                }

                @Override
                public String onHook(final String name, final String payloadJson) {
                    hooks.add(name + " " + payloadJson);
                    return "applyBundle".equals(name) ? "{\"ok\":true,\"guard\":true}" : null;
                }
            }
        );
        this.engine = updater.createEngine(
            CapgoCore.input(
                "appId",
                "app.capgo.test",
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
            ),
            "serverBasePath"
        );
    }

    private JSONObject load(final JSONObject config) throws Exception {
        final JSONObject nativeInfo = CapgoCore.input(
            "versionName",
            "1.0.0",
            "versionCode",
            "10",
            "noBackupDir",
            RuntimeEnvironment.getApplication().getNoBackupFilesDir().getAbsolutePath(),
            "reloadWaitsForAppReady",
            true,
            "pendingBundleMinAppReadyTimeoutMs",
            30000,
            "previousExits",
            new JSONArray()
        );
        return this.engine.call("pluginLoad", CapgoCore.input("config", config, "native", nativeInfo));
    }

    private JSONObject method(final String name, final JSONObject args) throws Exception {
        return this.engine.call("pluginMethod", CapgoCore.input("name", name, "args", args));
    }

    @Test
    public void everyEngineMethodIsAPluginMethod() throws Exception {
        final Set<String> engineMethods = new TreeSet<>();
        final JSONArray names = this.engine.callArray("pluginMethods", null);
        for (int index = 0; index < names.length(); index++) {
            engineMethods.add(names.getString(index));
        }
        final Set<String> pluginMethods = new TreeSet<>();
        for (final Method method : CapacitorUpdaterPlugin.class.getDeclaredMethods()) {
            if (method.isAnnotationPresent(PluginMethod.class) && !NATIVE_METHODS.contains(method.getName())) {
                pluginMethods.add(method.getName());
            }
        }
        assertEquals(engineMethods, pluginMethods);
    }

    @Test
    public void loadCallsHostHooksThroughJni() throws Exception {
        final JSONObject loaded = this.load(
            CapgoCore.input("autoUpdate", false, "statsUrl", "", "keepUrlPathAfterReload", true, "shakeMenu", true)
        );
        assertEquals("app.capgo.test", loaded.getString("appId"));
        assertEquals("builtin", loaded.getJSONObject("bundle").getString("id"));
        assertTrue(this.hooks.toString(), this.hooks.contains("keepUrlPath {\"enabled\":true}"));
        assertTrue(
            this.hooks.toString(),
            this.hooks.stream().anyMatch((hook) -> hook.startsWith("shakeMenu {") && hook.contains("\"enabled\":true"))
        );
    }

    @Test
    public void methodsResolveAndRejectThroughJni() throws Exception {
        this.load(CapgoCore.input("autoUpdate", false, "statsUrl", ""));
        final JSONObject current = method("current", new JSONObject());
        assertEquals("1.0.0", current.getJSONObject("resolve").getString("native"));
        assertEquals("builtin", current.getJSONObject("resolve").getJSONObject("bundle").getString("id"));
        assertEquals("Next called without id", method("next", new JSONObject()).getJSONObject("reject").getString("message"));
        assertEquals("SETCHANNEL_INVALID_PARAMS", method("setChannel", new JSONObject()).getJSONObject("reject").getString("code"));
        assertTrue(method("getNextBundle", new JSONObject()).isNull("resolve"));
    }

    @Test
    public void engineDataIsStoredInSharedPreferences() throws Exception {
        this.load(CapgoCore.input("autoUpdate", false, "statsUrl", "", "persistCustomId", true));
        method("setCustomId", CapgoCore.input("customId", "user-1"));
        assertEquals("user-1", this.prefs.getString("CapacitorUpdater.customId", null));
    }

    @Test
    public void legacyBooleanPreferencesAreReadByTheEngine() throws Exception {
        // Previous plugin versions stored preview flags as booleans.
        this.prefs.edit().putBoolean("CapacitorUpdater.previewSession", true).commit();
        final JSONObject loaded = this.load(CapgoCore.input("autoUpdate", false, "statsUrl", "", "allowPreview", true));
        assertTrue(loaded.getBoolean("previewSession"));
    }

    @Test
    public void updateCycleEmitsEventsFromEngineThreads() throws Exception {
        this.load(CapgoCore.input("updateUrl", "http://127.0.0.1:1/updates", "statsUrl", "", "appReadyTimeout", 1000));
        method("notifyAppReady", new JSONObject());
        this.engine.call("appForeground", null);
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8);
        while (!this.events.contains("updateCheckResult") && System.nanoTime() < deadline) {
            Thread.sleep(20);
        }
        assertTrue(this.events.toString(), this.events.contains("updateCheckResult"));
    }

    // ---- call order -------------------------------------------------------------------------------

    private EngineMethodLanes lanes() throws Exception {
        final EngineMethodLanes lanes = new EngineMethodLanes();
        lanes.setDetachedMethods(this.engine.callArray("detachedPluginMethods", null));
        return lanes;
    }

    /** Calls JavaScript does not await run in call order, like Capacitor's plugin thread ran them. */
    @Test
    public void quickMethodsRunInCallOrder() throws Exception {
        this.load(CapgoCore.input("autoUpdate", false, "statsUrl", ""));
        final EngineMethodLanes lanes = this.lanes();
        final int rounds = 200;
        final Boolean[] seen = new Boolean[rounds];
        final CountDownLatch done = new CountDownLatch(rounds);
        for (int round = 0; round < rounds; round++) {
            final int index = round;
            final boolean enabled = round % 2 == 0;
            lanes.submit("setShakeMenu", () -> call("setShakeMenu", CapgoCore.input("enabled", enabled)), () -> {});
            lanes.submit(
                "isShakeMenuEnabled",
                () -> {
                    seen[index] = call("isShakeMenuEnabled", new JSONObject()).optJSONObject("resolve").optBoolean("enabled");
                    done.countDown();
                },
                () -> {}
            );
        }
        assertTrue(done.await(10, TimeUnit.SECONDS));
        for (int round = 0; round < rounds; round++) {
            assertEquals("round " + round, round % 2 == 0, seen[round]);
        }
        lanes.shutdown();
    }

    /** reset waits for notifyAppReady from the new page: it runs off the lane, so notifyAppReady is not stuck behind it. */
    @Test
    public void reloadingMethodsDoNotBlockNotifyAppReady() throws Exception {
        this.load(CapgoCore.input("autoUpdate", false, "statsUrl", "", "appReadyTimeout", 8000));
        method("notifyAppReady", new JSONObject());
        final EngineMethodLanes lanes = this.lanes();
        assertTrue(lanes.isDetached("reset"));
        assertTrue(lanes.isDetached("set"));
        assertTrue(lanes.isDetached("reload"));
        final long appliedBefore = this.hooks
            .stream()
            .filter((hook) -> hook.startsWith("applyBundle "))
            .count();
        final List<String> finished = new CopyOnWriteArrayList<>();
        final AtomicReference<JSONObject> reset = new AtomicReference<>();
        final CountDownLatch done = new CountDownLatch(3);
        final long started = System.nanoTime();
        lanes.submit(
            "reset",
            () -> {
                reset.set(call("reset", new JSONObject()));
                finished.add("reset");
                done.countDown();
            },
            () -> {}
        );
        // The reloaded page confirms itself.
        lanes.submit(
            "notifyAppReady",
            () -> {
                final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
                while (
                    this.hooks
                        .stream()
                        .filter((hook) -> hook.startsWith("applyBundle "))
                        .count() == appliedBefore
                ) {
                    if (System.nanoTime() > deadline) {
                        break;
                    }
                    sleepQuietly();
                }
                final String applied = this.hooks
                    .stream()
                    .filter((hook) -> hook.startsWith("applyBundle "))
                    .reduce((a, b) -> b)
                    .orElse("");
                final long generation = parse(applied.substring("applyBundle ".length())).optLong("readyGeneration");
                call("notifyAppReady", CapgoCore.input("loadGeneration", generation));
                finished.add("notifyAppReady");
                done.countDown();
            },
            () -> {}
        );
        lanes.submit(
            "current",
            () -> {
                call("current", new JSONObject());
                finished.add("current");
                done.countDown();
            },
            () -> {}
        );
        assertTrue(done.await(6, TimeUnit.SECONDS));
        assertTrue("reset resolved: " + reset.get(), reset.get().has("resolve"));
        assertTrue("well before the 8 s appReadyTimeout", System.nanoTime() - started < TimeUnit.SECONDS.toNanos(5));
        // reset was called first but only finishes once the lane delivered notifyAppReady.
        assertEquals("notifyAppReady", finished.get(0));
        assertEquals(Set.of("notifyAppReady", "current", "reset"), Set.copyOf(finished));
        lanes.shutdown();
    }

    private JSONObject call(final String name, final JSONObject args) {
        try {
            return method(name, args);
        } catch (final Exception e) {
            throw new AssertionError(e);
        }
    }

    private static JSONObject parse(final String json) {
        try {
            return new JSONObject(json);
        } catch (final org.json.JSONException e) {
            throw new AssertionError(e);
        }
    }

    private static void sleepQuietly() {
        try {
            Thread.sleep(5);
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** The engine holds its host through a JNI global ref: only close() lets the plugin (and Activity) go. */
    @Test
    public void closeReleasesTheHost() throws Exception {
        final WeakReference<?>[] listener = new WeakReference<?>[1];
        final CapgoEngine owned = this.engineWithListener(listener);
        final CapgoEngine shared = this.engine;
        this.engine = owned;
        this.load(CapgoCore.input("autoUpdate", true, "periodCheckDelay", 600, "statsUrl", "", "updateUrl", "http://127.0.0.1:9/updates"));
        this.engine = shared;
        collectGarbage();
        assertNotNull("held by the engine while it is open", listener[0].get());
        owned.close();
        // GC is never guaranteed by one request: keep asking under allocation pressure until the
        // reference clears (normally the first attempt) or a generous deadline passes.
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
        while (listener[0].get() != null && System.nanoTime() < deadline) {
            collectGarbage();
        }
        assertNull("released after close()", listener[0].get());
        try {
            owned.call("pluginMethods", null);
            fail("calls after close() must fail");
        } catch (final CapgoCore.Failure expected) {
            assertEquals("internal", expected.code);
        }
    }

    private CapgoEngine engineWithListener(final WeakReference<?>[] out) {
        final Context context = RuntimeEnvironment.getApplication();
        final CapgoUpdater.Listener listener = new CapgoUpdater.Listener() {
            @Override
            public void onEvent(final String event, final String payloadJson) {}

            @Override
            public String onHook(final String name, final String payloadJson) {
                return null;
            }
        };
        out[0] = new WeakReference<>(listener);
        final CapgoUpdater updater = new CapgoUpdater(
            context,
            this.prefs,
            new Logger("EngineHostTest", new Logger.Options(Logger.LogLevel.silent)),
            listener
        );
        return updater.createEngine(
            CapgoCore.input(
                "appId",
                "app.capgo.test",
                "pluginVersion",
                "8.0.0",
                "versionBuild",
                "1.0.0",
                "versionCode",
                "10",
                "versionOs",
                "15",
                "deviceId",
                "device-2"
            ),
            "serverBasePath"
        );
    }

    private static void collectGarbage() throws InterruptedException {
        // Short-lived garbage makes the collector run even when an explicit request is ignored.
        byte[][] pressure = new byte[16][];
        for (int index = 0; index < pressure.length; index++) {
            pressure[index] = new byte[1024 * 1024];
        }
        pressure = null;
        System.gc();
        System.runFinalization();
        Thread.sleep(20);
    }
}
