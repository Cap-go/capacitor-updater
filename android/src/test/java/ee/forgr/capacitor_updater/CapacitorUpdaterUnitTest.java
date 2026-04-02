package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.os.Handler;
import android.os.Looper;
import com.getcapacitor.Bridge;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import io.github.g00fy2.versioncompare.Version;
import java.lang.reflect.Method;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

public class CapacitorUpdaterUnitTest {

    private static class TestableCapacitorUpdaterPlugin extends CapacitorUpdaterPlugin {

        @Override
        public void notifyListeners(String eventName, JSObject data) {}

        @Override
        public void notifyListeners(String eventName, JSObject data, boolean retainUntilConsumed) {}
    }

    private static final class ImmediateThreadCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        private boolean versionDownloadInProgress = false;

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            function.run();
            return new Thread();
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            function.run();
            return new Thread();
        }

        @Override
        boolean isVersionDownloadInProgress(final String version) {
            return this.versionDownloadInProgress;
        }
    }

    private static final class FreshDownloadCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private BundleInfo existingLatestBundle;
        private BooleanSupplier consumedStateSupplier = () -> false;
        private BooleanSupplier directUpdateStateSupplier = () -> false;
        private boolean downloadBackgroundCalled = false;
        private boolean consumedWhenDownloadStarted = false;
        private boolean directUpdateWhenDownloadStarted = false;

        FreshDownloadCapgoUpdater() {
            super(null);
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("version", "2.0.0");
            response.put("url", "https://example.com/update.zip");
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public BundleInfo getBundleInfoByName(final String version) {
            return this.existingLatestBundle;
        }

        @Override
        public void downloadBackground(
            final String url,
            final String version,
            final String sessionKey,
            final String checksum,
            final JSONArray manifest
        ) {
            this.downloadBackgroundCalled = true;
            this.consumedWhenDownloadStarted = this.consumedStateSupplier.getAsBoolean();
            this.directUpdateWhenDownloadStarted = this.directUpdateStateSupplier.getAsBoolean();
        }
    }

    private static void invokeBackgroundDownload(final CapacitorUpdaterPlugin plugin) throws Exception {
        final Method backgroundDownload = CapacitorUpdaterPlugin.class.getDeclaredMethod("backgroundDownload");
        backgroundDownload.setAccessible(true);
        backgroundDownload.invoke(plugin);
    }

    private static void invokePrivateVoidMethod(final CapacitorUpdaterPlugin plugin, final String methodName) throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod(methodName);
        method.setAccessible(true);
        method.invoke(plugin);
    }

    private static void invokePrivateSplashMethod(
        final CapacitorUpdaterPlugin plugin,
        final String methodName,
        final JSObject options,
        final int retriesRemaining,
        final int requestToken
    ) throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod(
            "invokeSplashScreenPluginMethod",
            String.class,
            JSObject.class,
            Integer.TYPE,
            Integer.TYPE
        );
        method.setAccessible(true);
        method.invoke(plugin, methodName, options, retriesRemaining, requestToken);
    }

    // BundleInfo Tests

    @Test
    public void testBundleInfoInitialization() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.PENDING, new Date(), "abc123");

        assertEquals("test-id", bundleInfo.getId());
        assertEquals("1.0.0", bundleInfo.getVersionName());
        assertEquals(BundleStatus.PENDING, bundleInfo.getStatus());
        assertEquals("abc123", bundleInfo.getChecksum());
    }

    @Test
    public void testBundleInfoBuiltin() {
        BundleInfo bundleInfo = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "1.0.0",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "abc123"
        );

        assertTrue(bundleInfo.isBuiltin());
        assertFalse(bundleInfo.isUnknown());
    }

    @Test
    public void testBundleInfoUnknown() {
        BundleInfo bundleInfo = new BundleInfo(
            BundleInfo.VERSION_UNKNOWN,
            "1.0.0",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "abc123"
        );

        assertTrue(bundleInfo.isUnknown());
        assertFalse(bundleInfo.isBuiltin());
    }

    @Test
    public void testBundleInfoErrorStatus() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.ERROR, new Date(), "abc123");

        assertTrue(bundleInfo.isErrorStatus());
        assertFalse(bundleInfo.isDeleted());
    }

    @Test
    public void testBundleInfoDeleted() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.DELETED, new Date(), "abc123");

        assertTrue(bundleInfo.isDeleted());
        assertFalse(bundleInfo.isErrorStatus());
    }

    @Test
    public void testBundleInfoIsDownloaded() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        assertTrue(bundleInfo.isDownloaded());

        BundleInfo builtinBundle = new BundleInfo(BundleInfo.ID_BUILTIN, "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        assertFalse(builtinBundle.isDownloaded());
    }

    @Test
    public void testBundleInfoSetters() {
        BundleInfo original = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        BundleInfo withNewChecksum = original.setChecksum("new-checksum");
        assertEquals("new-checksum", withNewChecksum.getChecksum());
        assertEquals("test-id", withNewChecksum.getId());

        BundleInfo withNewId = original.setId("new-id");
        assertEquals("new-id", withNewId.getId());
        assertEquals("abc123", withNewId.getChecksum());

        BundleInfo withNewStatus = original.setStatus(BundleStatus.ERROR);
        assertEquals(BundleStatus.ERROR, withNewStatus.getStatus());
    }

    @Test
    public void testBundleInfoCopyConstructor() {
        BundleInfo original = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        BundleInfo copy = new BundleInfo(original);

        assertEquals(original.getId(), copy.getId());
        assertEquals(original.getVersionName(), copy.getVersionName());
        assertEquals(original.getStatus(), copy.getStatus());
        assertEquals(original.getChecksum(), copy.getChecksum());
    }

    // BundleStatus Tests

    @Test
    public void testBundleStatusToString() {
        assertEquals("success", BundleStatus.SUCCESS.toString());
        assertEquals("error", BundleStatus.ERROR.toString());
        assertEquals("pending", BundleStatus.PENDING.toString());
        assertEquals("deleted", BundleStatus.DELETED.toString());
        assertEquals("downloading", BundleStatus.DOWNLOADING.toString());
    }

    @Test
    public void testBundleStatusFromString() {
        assertEquals(BundleStatus.SUCCESS, BundleStatus.fromString("success"));
        assertEquals(BundleStatus.ERROR, BundleStatus.fromString("error"));
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString("pending"));
        assertEquals(BundleStatus.DELETED, BundleStatus.fromString("deleted"));
        assertEquals(BundleStatus.DOWNLOADING, BundleStatus.fromString("downloading"));

        // Test null/empty string returns PENDING
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString(null));
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString(""));

        // Test invalid string returns null
        assertNull(BundleStatus.fromString("invalid"));
    }

    // Version Comparison Tests

    @Test
    public void testVersionComparison() {
        Version version1 = new Version("1.0.0");
        Version version2 = new Version("1.0.1");
        Version version3 = new Version("2.0.0");
        Version version4 = new Version("1.0.0");

        assertTrue(version1.isLowerThan(version2));
        assertTrue(version2.isLowerThan(version3));
        assertTrue(version1.isEqual(version4));
        assertFalse(version3.isLowerThan(version1));
    }

    @Test
    public void testVersionIsAtLeast() {
        Version version1 = new Version("1.0.0");
        Version version2 = new Version("1.0.1");

        assertTrue(version2.isAtLeast("1.0.0"));
        assertTrue(version2.isAtLeast("1.0.1"));
        assertFalse(version1.isAtLeast("1.0.1"));
    }

    // Edge Cases Tests

    @Test
    public void testBundleInfoWithNullValues() {
        BundleInfo bundleInfo = new BundleInfo(null, null, null, (String) null, null);

        assertNotNull(bundleInfo.getId());
        assertNotNull(bundleInfo.getStatus());
        assertNotNull(bundleInfo.getChecksum());
    }

    @Test
    public void testLargeDataHandling() {
        // Create a large string
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 10000; i++) {
            sb.append("test-data-");
        }
        String largeData = sb.toString();

        BundleInfo bundleInfo = new BundleInfo("test-id", largeData, BundleStatus.SUCCESS, new Date(), largeData);

        assertNotNull(bundleInfo);
        assertEquals(largeData, bundleInfo.getVersionName());
        assertEquals(largeData, bundleInfo.getChecksum());
    }

    @Test
    public void testBuildUserAgentUsesUnknownForNullOrEmptyValues() {
        assertEquals("CapacitorUpdater/unknown (unknown) android/unknown", DownloadService.buildUserAgent("", null, ""));
    }

    @Test
    public void testBuildUserAgentMatchesExpectedAndroidFormat() {
        assertEquals(
            "CapacitorUpdater/8.43.9 (app.capgo.test) android/16",
            DownloadService.buildUserAgent("app.capgo.test", "8.43.9", "16")
        );
    }

    @Test
    public void testShouldResetForForeignBundleWhenPathIsSetButBundleIsNotStored() {
        assertTrue(CapgoUpdater.shouldResetForForeignBundle("/data/user/0/app/files/versions/abc123", false, false));
    }

    @Test
    public void testShouldNotResetForForeignBundleWhenBundleIsBuiltin() {
        assertFalse(CapgoUpdater.shouldResetForForeignBundle("public", true, false));
    }

    @Test
    public void testShouldNotResetForForeignBundleWhenBundleIsStored() {
        assertFalse(CapgoUpdater.shouldResetForForeignBundle("/data/user/0/app/files/versions/abc123", false, true));
    }

    @Test
    public void testGetBundleInfoBuiltinReturnsVersionBuildWhenPresent() {
        CapgoUpdater updater = new CapgoUpdater(null);
        updater.versionBuild = "1.2.3";

        BundleInfo bundleInfo = updater.getBundleInfo(BundleInfo.ID_BUILTIN);

        assertEquals(BundleInfo.ID_BUILTIN, bundleInfo.getId());
        assertEquals("1.2.3", bundleInfo.getVersionName());
        assertEquals(BundleStatus.SUCCESS, bundleInfo.getStatus());
    }

    @Test
    public void testGetBundleInfoBuiltinHandlesNullVersionBuild() {
        CapgoUpdater updater = new CapgoUpdater(null);
        updater.versionBuild = null;

        BundleInfo bundleInfo = updater.getBundleInfo(BundleInfo.ID_BUILTIN);

        assertEquals(BundleInfo.ID_BUILTIN, bundleInfo.getId());
        assertEquals(BundleInfo.ID_BUILTIN, bundleInfo.getVersionName());
        assertEquals(BundleStatus.SUCCESS, bundleInfo.getStatus());
    }

    @Test
    public void testShouldConsumeOnLaunchDirectUpdateForOnLaunchAttempt() {
        assertTrue(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate("onLaunch", true));
    }

    @Test
    public void testShouldNotConsumeOnLaunchDirectUpdateForNonLaunchAttempt() {
        assertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate("onLaunch", false));
    }

    @Test
    public void testShouldNotConsumeOnLaunchDirectUpdateForOtherModes() {
        assertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate("always", true));
        assertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate("atInstall", true));
        assertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate("false", true));
    }

    @Test
    public void testOnLaunchCompletionConsumesWindowWithoutClearingInFlightDirectUpdate() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            plugin.implementation = new CapgoUpdater(null);
            plugin.implementation.directUpdate = true;
            plugin.configureDirectUpdateModeForTesting("onLaunch", false);
            plugin.setLoggerForTesting(mock(Logger.class));

            BundleInfo current = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

            assertTrue(plugin.shouldUseDirectUpdateForTesting());
            assertFalse(plugin.hasConsumedOnLaunchDirectUpdateForTesting());

            plugin.completeBackgroundTaskForTesting(current, true);

            assertTrue(plugin.hasConsumedOnLaunchDirectUpdateForTesting());
            assertFalse(plugin.shouldUseDirectUpdateForTesting());
            assertTrue(plugin.implementation.directUpdate);
        }
    }

    @Test
    public void testOnLaunchFreshDownloadConsumesWindowBeforeDownloadStarts() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            FreshDownloadCapgoUpdater updater = new FreshDownloadCapgoUpdater();

            plugin.implementation = updater;
            plugin.configureDirectUpdateModeForTesting("onLaunch", false);
            plugin.setLoggerForTesting(mock(Logger.class));
            updater.consumedStateSupplier = plugin::hasConsumedOnLaunchDirectUpdateForTesting;
            updater.directUpdateStateSupplier = () -> Boolean.TRUE.equals(plugin.implementation.directUpdate);

            assertTrue(plugin.shouldUseDirectUpdateForTesting());
            assertFalse(plugin.hasConsumedOnLaunchDirectUpdateForTesting());

            invokeBackgroundDownload(plugin);

            assertTrue(updater.downloadBackgroundCalled);
            assertTrue(updater.consumedWhenDownloadStarted);
            assertTrue(updater.directUpdateWhenDownloadStarted);
            assertTrue(plugin.hasConsumedOnLaunchDirectUpdateForTesting());
            assertFalse(plugin.shouldUseDirectUpdateForTesting());
            assertTrue(plugin.implementation.directUpdate);
        }
    }

    @Test
    public void testInFlightDirectUpdateIsNotClearedByFollowUpForegroundCheck() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            FreshDownloadCapgoUpdater updater = new FreshDownloadCapgoUpdater();
            updater.existingLatestBundle = new BundleInfo("download-id", "2.0.0", BundleStatus.DOWNLOADING, new Date(), "next-checksum");

            plugin.implementation = updater;
            plugin.implementation.directUpdate = true;
            plugin.configureDirectUpdateModeForTesting("onLaunch", true);
            plugin.versionDownloadInProgress = true;
            plugin.setLoggerForTesting(mock(Logger.class));
            updater.directUpdateStateSupplier = () -> Boolean.TRUE.equals(plugin.implementation.directUpdate);

            invokeBackgroundDownload(plugin);

            assertTrue(updater.downloadBackgroundCalled);
            assertTrue(updater.directUpdateWhenDownloadStarted);
            assertTrue(plugin.implementation.directUpdate);
            assertFalse(plugin.shouldUseDirectUpdateForTesting());
        }
    }

    @Test
    public void testStaleDirectUpdateFlagIsClearedBeforeRetryingStaleDownloadingBundle() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            FreshDownloadCapgoUpdater updater = new FreshDownloadCapgoUpdater();

            plugin.implementation = updater;
            plugin.implementation.directUpdate = true;
            plugin.configureDirectUpdateModeForTesting("onLaunch", true);
            updater.existingLatestBundle = new BundleInfo("stale-download-id", "2.0.0", BundleStatus.DOWNLOADING, new Date(), "checksum");
            plugin.setLoggerForTesting(mock(Logger.class));
            updater.directUpdateStateSupplier = () -> Boolean.TRUE.equals(plugin.implementation.directUpdate);

            assertFalse(plugin.shouldUseDirectUpdateForTesting());

            invokeBackgroundDownload(plugin);

            assertTrue(updater.downloadBackgroundCalled);
            assertFalse(updater.directUpdateWhenDownloadStarted);
            assertFalse(plugin.implementation.directUpdate);
            assertFalse(plugin.shouldUseDirectUpdateForTesting());
        }
    }

    @Test
    public void testHideSplashscreenInvokesSplashPluginWithoutMessageHandler() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            final Looper mainLooper = mock(Looper.class);
            looperMock.when(Looper::getMainLooper).thenReturn(mainLooper);
            looperMock.when(Looper::myLooper).thenReturn(mainLooper);

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final Bridge bridge = mock(Bridge.class);
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);

            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.setBridge(bridge);
            plugin.setLoggerForTesting(mock(Logger.class));

            invokePrivateVoidMethod(plugin, "hideSplashscreenInternal");

            final ArgumentCaptor<PluginCall> callCaptor = ArgumentCaptor.forClass(PluginCall.class);
            verify(splashScreenPlugin).invoke(eq("hide"), callCaptor.capture());
            callCaptor.getValue().resolve();
            assertEquals(PluginCall.CALLBACK_ID_DANGLING, callCaptor.getValue().getCallbackId());
            assertEquals("hide", callCaptor.getValue().getMethodName());
        }
    }

    @Test
    public void testShowSplashscreenDisablesPluginAutoHide() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            final Looper mainLooper = mock(Looper.class);
            looperMock.when(Looper::getMainLooper).thenReturn(mainLooper);
            looperMock.when(Looper::myLooper).thenReturn(mainLooper);

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final Bridge bridge = mock(Bridge.class);
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);

            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.setBridge(bridge);
            plugin.setLoggerForTesting(mock(Logger.class));

            invokePrivateVoidMethod(plugin, "showSplashscreenNow");

            final ArgumentCaptor<PluginCall> callCaptor = ArgumentCaptor.forClass(PluginCall.class);
            verify(splashScreenPlugin).invoke(eq("show"), callCaptor.capture());
            callCaptor.getValue().resolve();
            assertEquals(Boolean.FALSE, callCaptor.getValue().getBoolean("autoHide"));
            assertEquals("show", callCaptor.getValue().getMethodName());
        }
    }

    @Test
    public void testStaleSplashscreenRetryTokenSkipsInvocation() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            final Looper mainLooper = mock(Looper.class);
            looperMock.when(Looper::getMainLooper).thenReturn(mainLooper);
            looperMock.when(Looper::myLooper).thenReturn(mainLooper);

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final Bridge bridge = mock(Bridge.class);
            final PluginHandle splashScreenPlugin = mock(PluginHandle.class);

            when(bridge.getPlugin("SplashScreen")).thenReturn(splashScreenPlugin);

            plugin.setBridge(bridge);
            plugin.setLoggerForTesting(mock(Logger.class));

            invokePrivateVoidMethod(plugin, "showSplashscreenNow");
            assertFalse(plugin.isCurrentSplashscreenInvocationTokenForTesting(0));

            invokePrivateSplashMethod(plugin, "hide", new JSObject(), 1, 0);

            verify(splashScreenPlugin, never()).invoke(eq("hide"), any(PluginCall.class));
        }
    }
}
