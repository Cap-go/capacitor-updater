package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.app.ApplicationExitInfo;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.Handler;
import android.os.Looper;
import android.webkit.RenderProcessGoneDetail;
import com.getcapacitor.Bridge;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.json.JSONObject;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

/** Glue that stays in Java: bridge result mapping, hooks, events, splash screen, scripts and reflection safety. */
public class CapacitorUpdaterUnitTest {

    private static class RecordingPlugin extends CapacitorUpdaterPlugin {

        final List<String> events = new ArrayList<>();
        final Map<String, Boolean> retained = new HashMap<>();
        final Map<String, JSObject> payloads = new HashMap<>();

        @Override
        public void notifyListeners(final String eventName, final JSObject data, final boolean retainUntilConsumed) {
            this.events.add(eventName);
            this.retained.put(eventName, retainUntilConsumed);
            this.payloads.put(eventName, data);
        }
    }

    /** Runs {@code body} with the current thread as the main looper (hooks run inline). */
    private interface MainThreadBody {
        void run(RecordingPlugin plugin, Bridge bridge) throws Exception;
    }

    private static void onMainThread(final MainThreadBody body) throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            final Looper mainLooper = mock(Looper.class);
            looperMock.when(Looper::getMainLooper).thenReturn(mainLooper);
            looperMock.when(Looper::myLooper).thenReturn(mainLooper);
            final RecordingPlugin plugin = new RecordingPlugin();
            final Bridge bridge = mock(Bridge.class);
            plugin.setBridge(bridge);
            plugin.setLoggerForTesting(mock(Logger.class));
            body.run(plugin, bridge);
        }
    }

    // ---- bridge results --------------------------------------------------------------------------

    @Test
    public void settleResolvesEngineObjects() throws Exception {
        final PluginCall call = mock(PluginCall.class);
        CapacitorUpdaterPlugin.settle(call, new JSONObject("{\"resolve\":{\"bundle\":{\"id\":\"builtin\"},\"native\":\"1.0.0\"}}"));
        final ArgumentCaptor<JSObject> captor = ArgumentCaptor.forClass(JSObject.class);
        verify(call).resolve(captor.capture());
        assertEquals("1.0.0", captor.getValue().getString("native"));
        assertEquals("builtin", captor.getValue().getJSONObject("bundle").getString("id"));
    }

    @Test
    public void settleResolvesNullAsVoid() throws Exception {
        final PluginCall call = mock(PluginCall.class);
        CapacitorUpdaterPlugin.settle(call, new JSONObject("{\"resolve\":null}"));
        verify(call).resolve();
        verify(call, never()).reject(anyString(), anyString(), any(), any());
    }

    @Test
    public void settleRejectsWithCodeAndData() throws Exception {
        final PluginCall call = mock(PluginCall.class);
        CapacitorUpdaterPlugin.settle(
            call,
            new JSONObject(
                "{\"reject\":{\"message\":\"private\",\"code\":\"SETCHANNEL_FAILED\",\"data\":{\"error\":\"channel_self_set_not_allowed\"}}}"
            )
        );
        final ArgumentCaptor<JSObject> data = ArgumentCaptor.forClass(JSObject.class);
        verify(call).reject(eq("private"), eq("SETCHANNEL_FAILED"), isNull(), data.capture());
        assertEquals("channel_self_set_not_allowed", data.getValue().getString("error"));
    }

    @Test
    public void settleRejectsWithoutCode() throws Exception {
        final PluginCall call = mock(PluginCall.class);
        CapacitorUpdaterPlugin.settle(call, new JSONObject("{\"reject\":{\"message\":\"Reset failed\"}}"));
        verify(call).reject(eq("Reset failed"), isNull(), isNull(), isNull());
    }

    // ---- events ----------------------------------------------------------------------------------

    @Test
    public void eventsAreForwardedAndRetainedForLateListeners() throws Exception {
        onMainThread((plugin, bridge) -> {
            plugin.forwardEvent("set", "{\"bundle\":{\"id\":\"abc\"},\"__retainUntilConsumed\":true}");
            plugin.forwardEvent("download", "{\"percent\":50}");
            plugin.forwardEvent("updateAvailable", "{\"bundle\":{\"id\":\"def\"}}");
            plugin.forwardEvent("statsSent", "{\"callbackId\":\"x\"}");
            assertEquals(List.of("set", "download", "updateAvailable"), plugin.events);
            assertTrue(plugin.retained.get("set"));
            assertFalse(plugin.payloads.get("set").has("__retainUntilConsumed"));
            assertFalse(plugin.retained.get("download"));
            // Only the engine decides: updateAvailable is retained only when flagged.
            assertFalse(plugin.retained.get("updateAvailable"));
            assertEquals(50, plugin.payloads.get("download").getInt("percent"));
        });
    }

    // ---- hooks -----------------------------------------------------------------------------------

    @Test
    public void applyBundleWithoutWebViewFails() throws Exception {
        onMainThread((plugin, bridge) -> {
            final String reply = plugin.handleHook("applyBundle", "{\"path\":\"/x\",\"isBuiltin\":false,\"readyGeneration\":1}");
            assertFalse(new JSONObject(reply).getBoolean("ok"));
        });
    }

    @Test
    public void unhandledHooksAnswerNull() throws Exception {
        onMainThread((plugin, bridge) -> {
            assertNull(plugin.handleHook("backgroundTask", "{\"action\":\"begin\",\"name\":\"x\"}"));
            assertNull(plugin.handleHook("excludeFromBackup", "{\"path\":\"/x\"}"));
            assertNull(plugin.handleHook("unknown", "{}"));
        });
    }

    @Test
    public void shakeMenuHookUpdatesState() throws Exception {
        onMainThread((plugin, bridge) -> {
            plugin.handleHook("shakeMenu", "{\"enabled\":true,\"channelSelector\":true,\"gesture\":\"threeFingerPinch\"}");
            assertTrue(plugin.shakeMenuEnabled);
            assertTrue(plugin.shakeChannelSelectorEnabled);
            assertEquals(CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_THREE_FINGER_PINCH, plugin.shakeMenuGesture);
            plugin.handleHook("shakeMenu", "{\"enabled\":false,\"channelSelector\":false,\"gesture\":\"shake\"}");
            assertFalse(plugin.shakeMenuEnabled);
            assertFalse(plugin.shakeChannelSelectorEnabled);
        });
    }

    @Test
    public void previewNoticeIsNotShownWithoutActivity() throws Exception {
        onMainThread((plugin, bridge) -> {
            assertFalse(new JSONObject(plugin.handleHook("previewNotice", "{\"gesture\":\"shake\"}")).getBoolean("shown"));
        });
    }

    // ---- splash screen ---------------------------------------------------------------------------

    @Test
    public void splashHideInvokesSplashPluginWithoutMessageHandler() throws Exception {
        onMainThread((plugin, bridge) -> {
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);
            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.handleHook("splash", "{\"action\":\"hide\"}");

            final ArgumentCaptor<PluginCall> callCaptor = ArgumentCaptor.forClass(PluginCall.class);
            verify(splashScreenPlugin).invoke(eq("hide"), callCaptor.capture());
            callCaptor.getValue().resolve();
            assertEquals(PluginCall.CALLBACK_ID_DANGLING, callCaptor.getValue().getCallbackId());
            assertEquals("hide", callCaptor.getValue().getMethodName());
        });
    }

    @Test
    public void splashShowDisablesPluginAutoHide() throws Exception {
        onMainThread((plugin, bridge) -> {
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);
            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.handleHook("splash", "{\"action\":\"show\"}");

            final ArgumentCaptor<PluginCall> callCaptor = ArgumentCaptor.forClass(PluginCall.class);
            verify(splashScreenPlugin).invoke(eq("show"), callCaptor.capture());
            callCaptor.getValue().resolve();
            assertEquals(Boolean.FALSE, callCaptor.getValue().getBoolean("autoHide"));
        });
    }

    @Test
    public void staleSplashscreenRetryTokenSkipsInvocation() throws Exception {
        onMainThread((plugin, bridge) -> {
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);
            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.handleHook("splash", "{\"action\":\"show\"}");
            assertFalse(plugin.isCurrentSplashscreenInvocationTokenForTesting(0));

            final Method invoke = CapacitorUpdaterPlugin.class.getDeclaredMethod(
                "invokeSplashScreenPluginMethod",
                String.class,
                JSObject.class,
                int.class,
                int.class
            );
            invoke.setAccessible(true);
            invoke.invoke(plugin, "hide", new JSObject(), 1, 0);

            verify(splashScreenPlugin, never()).invoke(eq("hide"), any(PluginCall.class));
        });
    }

    // ---- injected scripts ------------------------------------------------------------------------

    @Test
    public void webViewStatsReporterScriptCapturesRuntimeAndRestartSignals() {
        final String script = CapacitorUpdaterPlugin.buildWebViewStatsReporterScript();
        assertTrue(script.contains("unhandledrejection"));
        assertTrue(script.contains("resource_error"));
        assertTrue(script.contains("securitypolicyviolation"));
        assertTrue(script.contains("webview_unclean_restart"));
        assertTrue(script.contains("webview_dom_content_loaded"));
        assertTrue(script.contains("reportWebViewError"));
    }

    // ---- JavaScript logging ----------------------------------------------------------------------

    /** {@code disableJSLogging} keeps native logs out of the WebView console (the logger never gets the bridge). */
    @Test
    public void disabledJavaScriptLoggingNeverForwardsLogsToTheWebView() throws Exception {
        for (final boolean enabled : new boolean[] { false, true }) {
            onMainThread((plugin, bridge) -> {
                when(bridge.getWebView()).thenReturn(mock(android.webkit.WebView.class));
                final Logger logger = mock(Logger.class);
                plugin.setLoggerForTesting(logger);
                final java.lang.reflect.Field jsLogging = CapacitorUpdaterPlugin.class.getDeclaredField("jsLoggingEnabled");
                jsLogging.setAccessible(true);
                jsLogging.setBoolean(plugin, enabled);
                final Method ensureBridgeSet = CapacitorUpdaterPlugin.class.getDeclaredMethod("ensureBridgeSet");
                ensureBridgeSet.setAccessible(true);

                assertEquals(enabled, ensureBridgeSet.invoke(plugin));
                verify(logger, times(enabled ? 1 : 0)).setBridge(bridge);
            });
        }
    }

    // ---- reflection safety -----------------------------------------------------------------------

    /** Capacitor reflects every plugin method: types missing on old Android versions must not appear in signatures. */
    @Test
    public void pluginMethodsDoNotExposeNewPlatformTypesToReflection() {
        final List<String> forbidden = List.of(ApplicationExitInfo.class.getName(), RenderProcessGoneDetail.class.getName());
        for (final Method method : CapacitorUpdaterPlugin.class.getDeclaredMethods()) {
            assertFalse(method.toString(), forbidden.contains(componentType(method.getReturnType()).getName()));
            for (final Class<?> parameterType : method.getParameterTypes()) {
                assertFalse(method.toString(), forbidden.contains(componentType(parameterType).getName()));
            }
        }
    }

    private static Class<?> componentType(final Class<?> type) {
        Class<?> current = type;
        while (current.isArray()) {
            current = current.getComponentType();
        }
        return current;
    }

    /**
     * Regression test for NoSuchMethodError on Android 8.0/8.1 (API 26/27): getLongVersionCode() is API 28, so the
     * plugin uses PackageInfoCompat, which falls back to the deprecated versionCode field.
     */
    @Test
    @SuppressWarnings("deprecation")
    public void getVersionCodeUsesPackageInfoCompat() throws Exception {
        final PackageInfo packageInfo = new PackageInfo();
        packageInfo.versionCode = 42;
        final Method getVersionCode = CapacitorUpdaterPlugin.class.getDeclaredMethod("getVersionCode", PackageInfo.class);
        getVersionCode.setAccessible(true);
        assertEquals("42", getVersionCode.invoke(null, packageInfo));
    }

    // ---- CapgoUpdater (engine host) ----------------------------------------------------------------

    @Test
    public void preferencesStoredWithLegacyTypesAreReadAsStrings() {
        final SharedPreferences prefs = mock(SharedPreferences.class);
        when(prefs.getString(eq("CapacitorUpdater.previewSession"), any())).thenThrow(new ClassCastException("Boolean"));
        when(prefs.getString(eq("CapacitorUpdater.lastReportedAppExitTimestamp"), any())).thenThrow(new ClassCastException("Long"));
        when(prefs.getString(eq("missing"), any())).thenReturn("fallback");
        final Map<String, Object> all = new HashMap<>();
        all.put("CapacitorUpdater.previewSession", Boolean.TRUE);
        all.put("CapacitorUpdater.lastReportedAppExitTimestamp", 1700000000000L);
        doReturn(all).when(prefs).getAll();

        assertEquals("true", CapgoUpdater.readPreference(prefs, "CapacitorUpdater.previewSession", null));
        assertEquals("1700000000000", CapgoUpdater.readPreference(prefs, "CapacitorUpdater.lastReportedAppExitTimestamp", null));
        assertEquals("fallback", CapgoUpdater.readPreference(prefs, "missing", "fallback"));
    }

    @Test
    public void tlsAuthTypeFollowsTheLeafKey() {
        assertEquals("ECDHE_ECDSA", CapgoEngineHost.authType(leafWithKey("EC")));
        assertEquals("ECDHE_RSA", CapgoEngineHost.authType(leafWithKey("RSA")));
        assertEquals("GENERIC", CapgoEngineHost.authType(leafWithKey("Ed25519")));
    }

    private static java.security.cert.X509Certificate leafWithKey(final String algorithm) {
        final java.security.PublicKey key = mock(java.security.PublicKey.class);
        when(key.getAlgorithm()).thenReturn(algorithm);
        final java.security.cert.X509Certificate leaf = mock(java.security.cert.X509Certificate.class);
        when(leaf.getPublicKey()).thenReturn(key);
        return leaf;
    }

    @Test
    public void preferencesKeepTheTypesEarlierVersionsRead() {
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
        CapgoUpdater.putPreference(editor, "CapacitorUpdater.previewSession", "true");
        CapgoUpdater.putPreference(editor, "CapacitorUpdater.defaultChannelInstallMarkerCreated", "false");
        CapgoUpdater.putPreference(editor, "BACKGROUND_TIMESTAMP_KEY_CAPGO", "1700000000000");
        CapgoUpdater.putPreference(editor, "CapacitorUpdater.lastReportedAppExitTimestamp", "not-a-number");
        CapgoUpdater.putPreference(editor, "CapacitorUpdater.defaultChannel", "beta");
        verify(editor).putBoolean("CapacitorUpdater.previewSession", true);
        verify(editor).putBoolean("CapacitorUpdater.defaultChannelInstallMarkerCreated", false);
        verify(editor).putLong("BACKGROUND_TIMESTAMP_KEY_CAPGO", 1700000000000L);
        verify(editor).putString("CapacitorUpdater.lastReportedAppExitTimestamp", "not-a-number");
        verify(editor).putString("CapacitorUpdater.defaultChannel", "beta");
    }

    @Test
    public void backgroundRunnerLabelIsReadFromConfig() {
        assertEquals(
            "com.example.runner",
            CapgoUpdater.getBackgroundRunnerWorkConfigFromConfig(
                "{\"plugins\":{\"BackgroundRunner\":{\"label\":\"com.example.runner\",\"src\":\"runner.js\",\"autoStart\":true}}}"
            ).label
        );
        assertNull(CapgoUpdater.getBackgroundRunnerWorkConfigFromConfig("{\"plugins\":{\"CapacitorUpdater\":{\"autoUpdate\":true}}}"));
        assertNull(
            CapgoUpdater.getBackgroundRunnerWorkConfigFromConfig(
                "{\"plugins\":{\"BackgroundRunner\":{\"label\":\"  \",\"src\":\"runner.js\"}}}"
            )
        );
        assertNull(CapgoUpdater.getBackgroundRunnerWorkConfigFromConfig(""));
    }

    @Test
    public void backgroundRunnerScheduleFieldsAreParsed() {
        final CapgoUpdater.BackgroundRunnerWorkConfig parsed = CapgoUpdater.getBackgroundRunnerWorkConfigFromConfig(
            "{\"plugins\":{\"BackgroundRunner\":{\"label\":\"com.example.runner\",\"src\":\"runner.js\",\"event\":\"myEvent\",\"autoStart\":true,\"repeat\":true,\"interval\":15}}}"
        );
        assertNotNull(parsed);
        assertEquals("com.example.runner", parsed.label);
        assertEquals("runner.js", parsed.src);
        assertEquals("myEvent", parsed.event);
        assertTrue(parsed.autoStart);
        assertTrue(parsed.repeat);
        assertEquals(15, parsed.interval);
    }

    @Test
    public void installSourceMapsKnownStores() {
        assertEquals("google_play", CapgoUpdater.installSourceForInstallerPackage("com.android.vending"));
        assertEquals("amazon_appstore", CapgoUpdater.installSourceForInstallerPackage("com.amazon.venezia"));
        assertEquals("samsung_galaxy_store", CapgoUpdater.installSourceForInstallerPackage("com.sec.android.app.samsungapps"));
        assertEquals("huawei_appgallery", CapgoUpdater.installSourceForInstallerPackage("com.huawei.appmarket"));
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage(null));
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage(" "));
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage("com.example.sideload"));
    }
}
