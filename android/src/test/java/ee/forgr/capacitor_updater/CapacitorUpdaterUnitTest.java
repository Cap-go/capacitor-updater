package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.app.ApplicationExitInfo;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebView;
import androidx.appcompat.app.AppCompatActivity;
import com.getcapacitor.Bridge;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginHandle;
import io.github.g00fy2.versioncompare.Version;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Phaser;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

public class CapacitorUpdaterUnitTest {

    private static class TestableCapacitorUpdaterPlugin extends CapacitorUpdaterPlugin {

        private final ArrayList<String> notifiedEventNames = new ArrayList<>();
        private final Map<String, JSObject> notifiedEventPayloads = new HashMap<>();

        @Override
        public void notifyListeners(String eventName, JSObject data) {
            this.notifiedEventNames.add(eventName);
            this.notifiedEventPayloads.put(eventName, data);
        }

        @Override
        public void notifyListeners(String eventName, JSObject data, boolean retainUntilConsumed) {
            this.notifiedEventNames.add(eventName);
            this.notifiedEventPayloads.put(eventName, data);
        }

        boolean hasNotifiedEvent(final String eventName) {
            return this.notifiedEventNames.contains(eventName);
        }

        JSObject getNotifiedEventPayload(final String eventName) {
            return this.notifiedEventPayloads.get(eventName);
        }
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

    private static final class DirectUpdateDispatchPlugin extends TestableCapacitorUpdaterPlugin {

        private final AppCompatActivity activity = mock(AppCompatActivity.class);
        private boolean startNewThreadCalled = false;
        private boolean reloadCalled = false;

        @Override
        public AppCompatActivity getActivity() {
            return this.activity;
        }

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            this.startNewThreadCalled = true;
            function.run();
            return new Thread();
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            this.startNewThreadCalled = true;
            function.run();
            return new Thread();
        }

        @Override
        protected boolean _reload() {
            this.reloadCalled = true;
            return true;
        }
    }

    private static final class InstallNextDispatchPlugin extends TestableCapacitorUpdaterPlugin {

        private boolean startNewThreadCalled = false;
        private boolean reloadCalled = false;

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            this.startNewThreadCalled = true;
            function.run();
            return new Thread();
        }

        @Override
        protected boolean _reload() {
            this.reloadCalled = true;
            return true;
        }
    }

    private static final class ReloadDispatchPlugin extends TestableCapacitorUpdaterPlugin {

        private boolean startNewThreadCalled = false;
        private boolean reloadCalled = false;

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            this.startNewThreadCalled = true;
            function.run();
            return new Thread();
        }

        @Override
        protected boolean _reload() {
            this.reloadCalled = true;
            return true;
        }
    }

    private static final class InstallNextCapgoUpdater extends CapgoUpdater {

        private BundleInfo currentBundle = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "builtin",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "builtin"
        );
        private BundleInfo nextBundle = new BundleInfo("next-bundle-id", "2.0.0", BundleStatus.PENDING, new Date(), "abc123");
        private int setCalls = 0;
        private String lastSetNextBundleId = "next-bundle-id";

        InstallNextCapgoUpdater() {
            super(null);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public BundleInfo getNextBundle() {
            return this.nextBundle;
        }

        @Override
        public Boolean set(final BundleInfo bundle) {
            this.setCalls++;
            this.currentBundle = bundle;
            return true;
        }

        @Override
        public boolean setNextBundle(final String next) {
            this.lastSetNextBundleId = next;
            this.nextBundle = next == null ? null : this.nextBundle;
            return true;
        }
    }

    private static final class ReloadCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        ReloadCapgoUpdater() {
            super(null);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public BundleInfo getNextBundle() {
            return null;
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

    private static final class NoNewVersionCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private boolean sendStatsCalled = false;
        private final boolean includeKind;

        NoNewVersionCapgoUpdater() {
            this(true);
        }

        NoNewVersionCapgoUpdater(final boolean includeKind) {
            super(null);
            this.includeKind = includeKind;
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("error", "no_new_version_available");
            if (this.includeKind) {
                response.put("kind", "up_to_date");
            }
            response.put("message", "No new version available");
            response.put("statusCode", 200);
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public void sendStats(final String action, final String versionName, final String oldVersionName) {
            this.sendStatsCalled = true;
        }
    }

    private static final class BlockedUpdateCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private boolean sendStatsCalled = false;

        BlockedUpdateCapgoUpdater() {
            super(null);
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("error", "disable_auto_update_to_major");
            response.put("kind", "blocked");
            response.put("message", "Cannot upgrade major version");
            response.put("statusCode", 200);
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public void sendStats(final String action, final String versionName, final String oldVersionName) {
            this.sendStatsCalled = true;
        }
    }

    private static final class FailedUpdateCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private boolean downloadFailStatsCalled = false;

        FailedUpdateCapgoUpdater() {
            super(null);
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("error", "response_error");
            response.put("kind", "failed");
            response.put("message", "Error getting Latest");
            response.put("statusCode", 500);
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public void sendStats(final String action, final String versionName, final String oldVersionName) {
            this.downloadFailStatsCalled = "download_fail".equals(action);
        }
    }

    private static final class ResetTrackingCapgoUpdater extends CapgoUpdater {

        private BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private BundleInfo fallbackBundle = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "builtin",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "builtin"
        );
        private BundleInfo nextBundle;
        private boolean resetCalled = false;
        private boolean prepareResetStateForTransitionCalled = false;
        private int prepareResetStateForTransitionCalls = 0;
        private boolean finalizeResetTransitionCalled = false;
        private int finalizeResetTransitionCalls = 0;
        private String finalizeResetTransitionPreviousBundleName;
        private boolean finalizeResetTransitionInternal = true;
        private boolean canSetResult = true;
        private boolean setResult = true;
        private int canSetCalls = 0;
        private int setCalls = 0;
        private boolean stagePendingReloadResult = true;
        private int stagePendingReloadCalls = 0;
        private int finalizePendingReloadCalls = 0;
        private BundleInfo finalizedPendingReloadBundle;
        private String finalizePendingReloadPreviousBundleName;
        private int restoreResetStateCalls = 0;
        private final ResetState capturedState = new ResetState("/stored/current", "fallback-id", "next-id");
        private ResetState restoredState;

        ResetTrackingCapgoUpdater() {
            super(null);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public BundleInfo getFallbackBundle() {
            return this.fallbackBundle;
        }

        @Override
        public BundleInfo getNextBundle() {
            return this.nextBundle;
        }

        @Override
        boolean canSet(final BundleInfo bundle) {
            this.canSetCalls++;
            return this.canSetResult;
        }

        @Override
        ResetState captureResetState() {
            return this.capturedState;
        }

        @Override
        void restoreResetState(final ResetState state) {
            this.restoreResetStateCalls++;
            this.restoredState = state;
        }

        @Override
        public Boolean set(final BundleInfo bundle) {
            this.setCalls++;
            return this.setResult;
        }

        @Override
        public boolean setNextBundle(final String next) {
            return true;
        }

        @Override
        boolean stagePendingReload(final BundleInfo bundle) {
            this.stagePendingReloadCalls++;
            return this.stagePendingReloadResult;
        }

        @Override
        void finalizePendingReload(final BundleInfo bundle, final String previousBundleName) {
            this.finalizePendingReloadCalls++;
            this.finalizedPendingReloadBundle = bundle;
            this.finalizePendingReloadPreviousBundleName = previousBundleName;
        }

        @Override
        public void reset(final boolean internal) {
            this.resetCalled = true;
        }

        @Override
        void prepareResetStateForTransition() {
            this.prepareResetStateForTransitionCalled = true;
            this.prepareResetStateForTransitionCalls++;
        }

        @Override
        void finalizeResetTransition(final String previousBundleName, final boolean internal) {
            this.finalizeResetTransitionCalled = true;
            this.finalizeResetTransitionCalls++;
            this.finalizeResetTransitionPreviousBundleName = previousBundleName;
            this.finalizeResetTransitionInternal = internal;
        }
    }

    private static final class ReloadBypassCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            function.run();
            return new Thread();
        }

        @Override
        protected boolean _reload() {
            return true;
        }
    }

    private static final class ReloadFailureCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        private int restoreLiveBundleStateAfterFailedReloadCalls = 0;

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            function.run();
            return new Thread();
        }

        @Override
        protected boolean _reload() {
            return false;
        }

        @Override
        protected void restoreLiveBundleStateAfterFailedReload() {
            this.restoreLiveBundleStateAfterFailedReloadCalls++;
        }
    }

    private static final class SequenceReloadCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        private final boolean[] reloadResults;
        private int reloadCallCount = 0;
        private int restoreLiveBundleStateAfterFailedReloadCalls = 0;

        SequenceReloadCapacitorUpdaterPlugin(final boolean... reloadResults) {
            this.reloadResults = reloadResults;
        }

        @Override
        protected boolean _reload() {
            final int resultIndex = Math.min(this.reloadCallCount, this.reloadResults.length - 1);
            this.reloadCallCount++;
            return this.reloadResults[resultIndex];
        }

        @Override
        protected void restoreLiveBundleStateAfterFailedReload() {
            this.restoreLiveBundleStateAfterFailedReloadCalls++;
        }
    }

    private static final class PendingReloadFinalizeCapgoUpdater extends CapgoUpdater {

        private final Map<String, BundleInfo> bundleInfos = new HashMap<>();
        private String lastStatsAction;
        private String lastStatsVersionName;
        private String lastStatsOldVersionName;

        PendingReloadFinalizeCapgoUpdater() {
            super(null);
        }

        @Override
        public BundleInfo getBundleInfo(final String id) {
            return this.bundleInfos.get(id);
        }

        @Override
        public void saveBundleInfo(final String id, final BundleInfo info) {
            this.bundleInfos.put(id, info);
        }

        @Override
        public void sendStats(final String action, final String versionName, final String oldVersionName) {
            this.lastStatsAction = action;
            this.lastStatsVersionName = versionName;
            this.lastStatsOldVersionName = oldVersionName;
        }
    }

    private static final class NoOpThreadCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            return new Thread();
        }
    }

    private static final class ConfigurableTimeoutCapacitorUpdaterPlugin extends TestableCapacitorUpdaterPlugin {

        private final long minimumPendingBundleAppReadyTimeoutMs;

        ConfigurableTimeoutCapacitorUpdaterPlugin(final long minimumPendingBundleAppReadyTimeoutMs) {
            this.minimumPendingBundleAppReadyTimeoutMs = minimumPendingBundleAppReadyTimeoutMs;
        }

        @Override
        public Thread startNewThread(final Runnable function, Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            return new Thread();
        }

        @Override
        protected long getMinimumPendingBundleAppReadyTimeoutMs() {
            return this.minimumPendingBundleAppReadyTimeoutMs;
        }
    }

    private static final class AutoResetNativeVersionCapgoUpdater extends CapgoUpdater {

        private boolean resetCalled = false;

        AutoResetNativeVersionCapgoUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void reset() {
            this.resetCalled = true;
        }

        @Override
        public void reset(final boolean internal) {
            this.resetCalled = true;
        }
    }

    private static final class FixedPathCapgoUpdater extends CapgoUpdater {

        private final String currentBundlePath;
        private final boolean usingBuiltin;
        private final BundleInfo currentBundle;

        FixedPathCapgoUpdater(final String currentBundlePath, final boolean usingBuiltin) {
            this(
                currentBundlePath,
                usingBuiltin,
                usingBuiltin
                    ? new BundleInfo(BundleInfo.ID_BUILTIN, "builtin", BundleStatus.SUCCESS, BundleInfo.DOWNLOADED_BUILTIN, "builtin")
                    : new BundleInfo("current-bundle-id", "current-bundle", BundleStatus.SUCCESS, new Date(), "current-bundle-checksum")
            );
        }

        FixedPathCapgoUpdater(final String currentBundlePath, final boolean usingBuiltin, final BundleInfo currentBundle) {
            super(null);
            this.currentBundlePath = currentBundlePath;
            this.usingBuiltin = usingBuiltin;
            this.currentBundle = currentBundle;
        }

        @Override
        public String getCurrentBundlePath() {
            return this.currentBundlePath;
        }

        @Override
        public Boolean isUsingBuiltin() {
            return this.usingBuiltin;
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }
    }

    private static Path createExistingBundleDirectory(final String prefix, final String bundleId) throws Exception {
        final Path tempDir = Files.createTempDirectory(prefix);
        tempDir.toFile().deleteOnExit();
        final Path versionsDir = tempDir.resolve("versions");
        final Path bundleDir = versionsDir.resolve(bundleId);
        Files.createDirectories(bundleDir);
        versionsDir.toFile().deleteOnExit();
        bundleDir.toFile().deleteOnExit();
        final Path indexFile = bundleDir.resolve("index.html");
        Files.createFile(indexFile);
        indexFile.toFile().deleteOnExit();
        return tempDir;
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

    private static boolean invokePrivateResetMethod(
        final CapacitorUpdaterPlugin plugin,
        final Boolean toLastSuccessful,
        final Boolean usePendingBundle
    ) throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod("_reset", Boolean.class, Boolean.class);
        method.setAccessible(true);
        return (boolean) method.invoke(plugin, toLastSuccessful, usePendingBundle);
    }

    private static boolean invokePrivateInternalResetMethod(
        final CapacitorUpdaterPlugin plugin,
        final Boolean toLastSuccessful,
        final Boolean usePendingBundle,
        final boolean internal
    ) throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod("performReset", Boolean.class, Boolean.class, boolean.class);
        method.setAccessible(true);
        return (boolean) method.invoke(plugin, toLastSuccessful, usePendingBundle, internal);
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

    private static void setPrivateField(final Object target, final String fieldName, final Object value) throws Exception {
        Class<?> current = target.getClass();
        while (current != null) {
            try {
                final Field field = current.getDeclaredField(fieldName);
                field.setAccessible(true);
                field.set(target, value);
                return;
            } catch (final NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        throw new NoSuchFieldException(fieldName);
    }

    private static Object getPrivateField(final Object target, final String fieldName) throws Exception {
        Class<?> current = target.getClass();
        while (current != null) {
            try {
                final Field field = current.getDeclaredField(fieldName);
                field.setAccessible(true);
                return field.get(target);
            } catch (final NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        throw new NoSuchFieldException(fieldName);
    }

    @Test
    public void mapsHealthExitReasonsToStatsActions() {
        assertEquals("app_crash", CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_CRASH));
        assertEquals(
            "app_crash_native",
            CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_CRASH_NATIVE)
        );
        assertEquals("app_anr", CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_ANR));
        assertEquals(
            "app_killed_low_memory",
            CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_LOW_MEMORY)
        );
        assertEquals(
            "app_killed_excessive_resource_usage",
            CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE)
        );
        assertEquals(
            "app_initialization_failure",
            CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_INITIALIZATION_FAILURE)
        );
    }

    @Test
    public void ignoresExpectedApplicationExitReasonsForStats() {
        assertNull(CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_EXIT_SELF));
        assertNull(CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_USER_REQUESTED));
        assertNull(CapacitorUpdaterPlugin.statsActionForApplicationExitReason(ApplicationExitInfo.REASON_UNKNOWN));
    }

    @Test
    public void mapsApplicationExitReasonNamesForMetadata() {
        assertEquals("crash", CapacitorUpdaterPlugin.applicationExitReasonName(ApplicationExitInfo.REASON_CRASH));
        assertEquals("anr", CapacitorUpdaterPlugin.applicationExitReasonName(ApplicationExitInfo.REASON_ANR));
        assertEquals("unknown", CapacitorUpdaterPlugin.applicationExitReasonName(-1));
    }

    @Test
    public void mapsWebViewErrorTypesToStatsActions() {
        assertEquals("webview_javascript_error", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("javascript_error"));
        assertEquals("webview_unhandled_rejection", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("unhandled_rejection"));
        assertEquals("webview_resource_error", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("resource_error"));
        assertEquals(
            "webview_security_policy_violation",
            CapacitorUpdaterPlugin.statsActionForWebViewErrorType("security_policy_violation")
        );
        assertEquals("webview_unclean_restart", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("webview_unclean_restart"));
        assertEquals("webview_render_process_gone", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("render_process_gone"));
        assertEquals("webview_javascript_error", CapacitorUpdaterPlugin.statsActionForWebViewErrorType("unknown"));
    }

    @Test
    public void buildsWebViewErrorMetadataWithUsefulFields() throws Exception {
        final JSObject data = new JSObject();
        data.put("type", "javascript_error");
        data.put("message", "boom");
        data.put("source", "app.js");
        data.put("line", "10");
        data.put("column", "20");
        data.put("stack", "x".repeat(3000));
        data.put("href", "capacitor://localhost");
        data.put("session_id", "session-1");

        final Map<String, String> metadata = CapacitorUpdaterPlugin.buildWebViewErrorMetadata(data);

        assertEquals("javascript_error", metadata.get("error_type"));
        assertEquals("boom", metadata.get("message"));
        assertEquals("app.js", metadata.get("source"));
        assertEquals("10", metadata.get("line"));
        assertEquals("20", metadata.get("column"));
        assertEquals("capacitor://localhost", metadata.get("href"));
        assertEquals("session-1", metadata.get("session_id"));
        assertEquals(2048, metadata.get("stack").length());
    }

    @Test
    public void sanitizesUrlValuesInWebViewErrorMetadata() throws Exception {
        final JSObject data = new JSObject();
        data.put("source", "https://user:pass@example.com:8443/assets/app.js?token=secret#L10");
        data.put("href", "https://example.com/users/123456/dashboard?jwt=secret#frag");
        data.put("previous_href", "app.js?token=secret#frag");

        final Map<String, String> metadata = CapacitorUpdaterPlugin.buildWebViewErrorMetadata(data);

        assertEquals("https://example.com:8443/assets/app.js", metadata.get("source"));
        assertEquals("https://example.com/users/redacted/dashboard", metadata.get("href"));
        assertEquals("app.js", metadata.get("previous_href"));
        assertFalse(metadata.get("source").contains("secret"));
        assertFalse(metadata.get("href").contains("jwt"));
    }

    @Test
    public void webViewStatsReporterScriptCapturesRuntimeAndRestartSignals() {
        final String script = CapacitorUpdaterPlugin.buildWebViewStatsReporterScript();

        assertTrue(script.contains("unhandledrejection"));
        assertTrue(script.contains("resource_error"));
        assertTrue(script.contains("securitypolicyviolation"));
        assertTrue(script.contains("webview_unclean_restart"));
        assertTrue(script.contains("reportWebViewError"));
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
    public void testGetStoredNativeBuildVersionFallsBackToLegacyKey() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final SharedPreferences prefs = mock(SharedPreferences.class);

            setPrivateField(plugin, "prefs", prefs);
            when(prefs.getString("LatestNativeBuildVersion", "")).thenReturn("");
            when(prefs.getString("LatestVersionNative", "")).thenReturn("7");

            assertEquals("7", plugin.getStoredNativeBuildVersion());
        }
    }

    @Test
    public void testPersistCurrentNativeBuildVersionWritesCurrentBuildKey() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);

            setPrivateField(plugin, "editor", editor);
            setPrivateField(plugin, "currentBuildVersion", "8");
            when(editor.putString("LatestNativeBuildVersion", "8")).thenReturn(editor);

            plugin.persistCurrentNativeBuildVersion();

            verify(editor).putString("LatestNativeBuildVersion", "8");
            verify(editor).apply();
        }
    }

    @Test
    public void testAutoResetFallsBackToLegacyNativeBuildVersionKey() throws Exception {
        final String bundleId = "legacy-bundle-id";
        final Path tempDir = createExistingBundleDirectory("capgo-autoreset", bundleId);
        final Path bundleDir = tempDir.resolve("versions").resolve(bundleId);

        final AutoResetNativeVersionCapgoUpdater updater = new AutoResetNativeVersionCapgoUpdater();
        final SharedPreferences prefs = mock(SharedPreferences.class);
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
        final BundleInfo storedBundle = new BundleInfo(bundleId, "1.0.0", BundleStatus.SUCCESS, new Date(), "checksum");

        updater.documentsDir = tempDir.toFile();
        updater.CAP_SERVER_PATH = "server-path";
        updater.prefs = prefs;
        updater.editor = editor;

        when(prefs.getString("server-path", "public")).thenReturn(bundleDir.toString());
        when(prefs.getString("server-path", null)).thenReturn(bundleDir.toString());
        when(prefs.contains(bundleId + "_info")).thenReturn(true);
        when(prefs.getString(bundleId + "_info", "")).thenReturn(storedBundle.toString());
        when(prefs.getString("LatestNativeBuildVersion", "")).thenReturn("");
        when(prefs.getString("LatestVersionNative", "")).thenReturn("7");

        updater.autoReset("8");

        assertTrue(updater.resetCalled);
    }

    @Test
    public void testAutoResetSkipsNativeBuildVersionResetWhenDisabled() throws Exception {
        final String bundleId = "legacy-bundle-id";
        final Path tempDir = createExistingBundleDirectory("capgo-autoreset-disabled", bundleId);
        final Path bundleDir = tempDir.resolve("versions").resolve(bundleId);

        final AutoResetNativeVersionCapgoUpdater updater = new AutoResetNativeVersionCapgoUpdater();
        final SharedPreferences prefs = mock(SharedPreferences.class);
        final BundleInfo storedBundle = new BundleInfo(bundleId, "1.0.0", BundleStatus.SUCCESS, new Date(), "checksum");

        updater.documentsDir = tempDir.toFile();
        updater.CAP_SERVER_PATH = "server-path";
        updater.prefs = prefs;

        when(prefs.getString("server-path", "public")).thenReturn(bundleDir.toString());
        when(prefs.getString("server-path", null)).thenReturn(bundleDir.toString());
        when(prefs.contains(bundleId + "_info")).thenReturn(true);
        when(prefs.getString(bundleId + "_info", "")).thenReturn(storedBundle.toString());
        when(prefs.getString("LatestNativeBuildVersion", "")).thenReturn("");
        when(prefs.getString("LatestVersionNative", "")).thenReturn("7");

        updater.autoReset("8", false);

        assertFalse(updater.resetCalled);
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
    public void testResetToPendingWithoutPendingBundleDoesNotResetState() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, false, true);

            assertFalse(result);
            assertFalse(updater.resetCalled);
        }
    }

    @Test
    public void testResetToPendingWithoutInstallablePendingBundleDoesNotResetState() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.nextBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");
            updater.canSetResult = false;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, false, true);

            assertFalse(result);
            assertEquals(1, updater.canSetCalls);
            assertEquals(0, updater.setCalls);
            assertFalse(updater.resetCalled);
            assertEquals(0, updater.restoreResetStateCalls);
        }
    }

    @Test
    public void testResetToPendingRestoresStateWhenSwitchFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.nextBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");
            updater.setResult = false;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, false, true);

            assertFalse(result);
            assertFalse(updater.resetCalled);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.canSetCalls);
            assertEquals(1, updater.setCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
        }
    }

    @Test
    public void testResetToPendingRestoresLiveStateWhenReloadFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadFailureCapacitorUpdaterPlugin plugin = new ReloadFailureCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.nextBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, false, true);

            assertFalse(result);
            assertFalse(updater.resetCalled);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.canSetCalls);
            assertEquals(1, updater.setCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
            assertEquals(1, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
        }
    }

    @Test
    public void testResetToPendingRestoresStateWhenBuiltinPendingReloadFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadFailureCapacitorUpdaterPlugin plugin = new ReloadFailureCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.nextBundle = new BundleInfo(
                BundleInfo.ID_BUILTIN,
                "builtin",
                BundleStatus.SUCCESS,
                BundleInfo.DOWNLOADED_BUILTIN,
                "builtin"
            );

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, false, true);

            assertFalse(result);
            assertFalse(updater.resetCalled);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.canSetCalls);
            assertEquals(0, updater.setCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
            assertEquals(1, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
        }
    }

    @Test
    public void testResetToLastSuccessfulWithoutInstallableFallbackFallsBackToBuiltin() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.fallbackBundle = new BundleInfo("fallback-id", "1.5.0", BundleStatus.SUCCESS, new Date(), "fallback");
            updater.canSetResult = false;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, true, false);

            assertTrue(result);
            assertEquals(1, updater.canSetCalls);
            assertEquals(0, updater.setCalls);
            assertFalse(updater.resetCalled);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertTrue(updater.finalizeResetTransitionCalled);
            assertEquals("1.0.0", updater.finalizeResetTransitionPreviousBundleName);
            assertFalse(updater.finalizeResetTransitionInternal);
            assertEquals(0, updater.restoreResetStateCalls);
        }
    }

    @Test
    public void testResetToLastSuccessfulRestoresStateWhenSwitchFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.fallbackBundle = new BundleInfo("fallback-id", "1.5.0", BundleStatus.SUCCESS, new Date(), "fallback");
            updater.setResult = false;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, true, false);

            assertFalse(result);
            assertFalse(updater.resetCalled);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.canSetCalls);
            assertEquals(1, updater.setCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
        }
    }

    @Test
    public void testResetToLastSuccessfulRestoresStateWhenFallbackReloadFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final SequenceReloadCapacitorUpdaterPlugin plugin = new SequenceReloadCapacitorUpdaterPlugin(false);
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.fallbackBundle = new BundleInfo("fallback-id", "1.5.0", BundleStatus.SUCCESS, new Date(), "fallback");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateResetMethod(plugin, true, false);

            assertFalse(result);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertEquals(1, updater.prepareResetStateForTransitionCalls);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.canSetCalls);
            assertEquals(1, updater.setCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
            assertEquals(1, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
        }
    }

    @Test
    public void testInternalResetToLastSuccessfulFallsBackToBuiltinWhenFallbackReloadFails() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final SequenceReloadCapacitorUpdaterPlugin plugin = new SequenceReloadCapacitorUpdaterPlugin(false, true);
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.currentBundle = new BundleInfo("current-id", "2.0.0", BundleStatus.ERROR, new Date(), "abc123");
            updater.fallbackBundle = new BundleInfo("fallback-id", "1.5.0", BundleStatus.SUCCESS, new Date(), "fallback");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivateInternalResetMethod(plugin, true, false, true);

            assertTrue(result);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertEquals(2, updater.prepareResetStateForTransitionCalls);
            assertTrue(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.finalizeResetTransitionCalls);
            assertEquals("2.0.0", updater.finalizeResetTransitionPreviousBundleName);
            assertTrue(updater.finalizeResetTransitionInternal);
            assertEquals(1, updater.canSetCalls);
            assertEquals(1, updater.setCalls);
            assertEquals(0, updater.restoreResetStateCalls);
            assertEquals(0, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
        }
    }

    @Test
    public void testFinalizePendingReloadPreservesSuccessfulBundleStatus() {
        final PendingReloadFinalizeCapgoUpdater updater = new PendingReloadFinalizeCapgoUpdater();
        final BundleInfo successfulBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.SUCCESS, new Date(), "pending");
        final BundleInfo pendingBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");
        updater.bundleInfos.put("pending-id", successfulBundle);

        updater.finalizePendingReload(pendingBundle, "1.0.0");

        assertEquals(BundleStatus.SUCCESS, updater.bundleInfos.get("pending-id").getStatus());
        assertEquals("set", updater.lastStatsAction);
        assertEquals("2.0.0", updater.lastStatsVersionName);
        assertEquals("1.0.0", updater.lastStatsOldVersionName);
    }

    @Test
    public void testReloadRestoresStateWhenPendingApplyReloadFails() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadFailureCapacitorUpdaterPlugin plugin = new ReloadFailureCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final PluginCall call = mock(PluginCall.class);
            updater.nextBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.reload(call);

            assertEquals(0, updater.setCalls);
            assertEquals(1, updater.stagePendingReloadCalls);
            assertEquals(0, updater.finalizePendingReloadCalls);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
            assertEquals(1, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
            verify(call).reject("Reload failed after applying pending bundle: 2.0.0");
        }
    }

    @Test
    public void testReloadFinalizesPendingBundleSideEffectsAfterSuccess() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final PluginCall call = mock(PluginCall.class);
            updater.nextBundle = new BundleInfo("pending-id", "2.0.0", BundleStatus.PENDING, new Date(), "pending");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.reload(call);

            assertEquals(0, updater.setCalls);
            assertEquals(1, updater.stagePendingReloadCalls);
            assertEquals(1, updater.finalizePendingReloadCalls);
            assertEquals("1.0.0", updater.finalizePendingReloadPreviousBundleName);
            assertSame(updater.nextBundle, updater.finalizedPendingReloadBundle);
            verify(call).resolve();
        }
    }

    @Test
    public void testReloadRestoresStateWhenBuiltinPendingReloadFails() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadFailureCapacitorUpdaterPlugin plugin = new ReloadFailureCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final PluginCall call = mock(PluginCall.class);
            updater.nextBundle = new BundleInfo(
                BundleInfo.ID_BUILTIN,
                "builtin",
                BundleStatus.SUCCESS,
                BundleInfo.DOWNLOADED_BUILTIN,
                "builtin"
            );

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.reload(call);

            assertEquals(0, updater.setCalls);
            assertEquals(0, updater.stagePendingReloadCalls);
            assertEquals(0, updater.finalizePendingReloadCalls);
            assertTrue(updater.prepareResetStateForTransitionCalled);
            assertFalse(updater.finalizeResetTransitionCalled);
            assertEquals(1, updater.restoreResetStateCalls);
            assertSame(updater.capturedState, updater.restoredState);
            assertEquals(1, plugin.restoreLiveBundleStateAfterFailedReloadCalls);
            verify(call).reject("Reload failed after applying pending bundle: builtin");
        }
    }

    @Test
    public void testReloadTimeoutUsesMilliseconds() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final NoOpThreadCapacitorUpdaterPlugin plugin = new NoOpThreadCapacitorUpdaterPlugin();
            final Bridge bridge = mock(Bridge.class);
            final WebView webView = mock(WebView.class);

            plugin.implementation = new FixedPathCapgoUpdater("/tmp/capgo-bundle", false);
            plugin.setLoggerForTesting(mock(Logger.class));
            plugin.setBridge(bridge);
            setPrivateField(plugin, "appReadyTimeout", 1);

            when(bridge.getWebView()).thenReturn(webView);
            when(bridge.getAppUrl()).thenReturn("https://local-app-domain.com");
            when(webView.post(any(Runnable.class))).thenReturn(true);

            final long start = System.nanoTime();
            assertFalse(plugin._reload());
            final long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);

            assertTrue("Expected millisecond timeout but reload took " + elapsedMs + "ms", elapsedMs < 900);
            verify(bridge).setServerBasePath("/tmp/capgo-bundle");
        }
    }

    @Test
    public void testReloadUsesExtendedTimeoutForPendingBundleValidation() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ConfigurableTimeoutCapacitorUpdaterPlugin plugin = new ConfigurableTimeoutCapacitorUpdaterPlugin(50);
            final Bridge bridge = mock(Bridge.class);
            final WebView webView = mock(WebView.class);
            final BundleInfo pendingBundle = new BundleInfo("pending-bundle-id", "2.0.0", BundleStatus.PENDING, new Date(), "abc123");

            plugin.implementation = new FixedPathCapgoUpdater("/tmp/capgo-bundle", false, pendingBundle);
            plugin.setLoggerForTesting(mock(Logger.class));
            plugin.setBridge(bridge);
            setPrivateField(plugin, "appReadyTimeout", 1);

            when(bridge.getWebView()).thenReturn(webView);
            when(bridge.getAppUrl()).thenReturn("https://local-app-domain.com");
            when(webView.post(any(Runnable.class))).thenReturn(true);

            final long start = System.nanoTime();
            assertFalse(plugin._reload());
            final long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);

            assertTrue("Expected pending bundle timeout extension but reload took only " + elapsedMs + "ms", elapsedMs >= 40);
            assertTrue("Expected bounded pending bundle timeout but reload took " + elapsedMs + "ms", elapsedMs < 1000);
            verify(bridge).setServerBasePath("/tmp/capgo-bundle");
        }
    }

    @Test
    public void testReloadTimeoutCleansUpPendingSemaphoreParty() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final NoOpThreadCapacitorUpdaterPlugin plugin = new NoOpThreadCapacitorUpdaterPlugin();
            final Bridge bridge = mock(Bridge.class);
            final WebView webView = mock(WebView.class);

            plugin.implementation = new FixedPathCapgoUpdater("/tmp/capgo-bundle", false);
            plugin.setLoggerForTesting(mock(Logger.class));
            plugin.setBridge(bridge);
            setPrivateField(plugin, "appReadyTimeout", 1);

            when(bridge.getWebView()).thenReturn(webView);
            when(bridge.getAppUrl()).thenReturn("https://local-app-domain.com");
            when(webView.post(any(Runnable.class))).thenReturn(true);

            assertFalse(plugin._reload());

            final Phaser semaphore = (Phaser) getPrivateField(plugin, "semaphoreReady");
            assertEquals(0, semaphore.getRegisteredParties());
        }
    }

    @Test
    public void testNotifyAppReadyWithoutPendingReloadKeepsSemaphoreReusable() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final PluginCall call = mock(PluginCall.class);
            final CapgoUpdater updater = mock(CapgoUpdater.class);
            final BundleInfo bundle = new BundleInfo("current-bundle-id", "current-bundle", BundleStatus.SUCCESS, new Date(), "checksum");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            when(updater.getCurrentBundle()).thenReturn(bundle);

            plugin.notifyAppReady(call);

            final Phaser semaphore = (Phaser) getPrivateField(plugin, "semaphoreReady");
            assertFalse(semaphore.isTerminated());
            assertEquals(0, semaphore.getRegisteredParties());
            verify(call).resolve(any(JSObject.class));
        }
    }

    @Test
    public void testInstallNextDispatchesReloadOffLifecycleThread() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final InstallNextDispatchPlugin plugin = new InstallNextDispatchPlugin();
            final InstallNextCapgoUpdater updater = new InstallNextCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final DelayUpdateUtils delayUpdateUtils = mock(DelayUpdateUtils.class);

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            when(prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]")).thenReturn("[]");
            when(delayUpdateUtils.parseDelayConditions("[]")).thenReturn(new ArrayList<>());

            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "delayUpdateUtils", delayUpdateUtils);

            invokePrivateVoidMethod(plugin, "installNext");

            assertTrue(plugin.startNewThreadCalled);
            assertTrue(plugin.reloadCalled);
            assertEquals(1, updater.setCalls);
            assertNull(updater.lastSetNextBundleId);
        }
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
    public void testNoNewVersionAvailableDoesNotNotifyDownloadFailed() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            NoNewVersionCapgoUpdater updater = new NoNewVersionCapgoUpdater();

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(plugin.hasNotifiedEvent("noNeedUpdate"));
            assertTrue(plugin.hasNotifiedEvent("updateCheckResult"));
            JSObject payload = plugin.getNotifiedEventPayload("updateCheckResult");
            assertNotNull(payload);
            assertEquals("up_to_date", payload.getString("kind"));
            assertEquals(200, payload.getInt("statusCode"));
            assertEquals("1.0.0", payload.getString("version"));
            assertFalse(plugin.hasNotifiedEvent("downloadFailed"));
            assertFalse(updater.sendStatsCalled);
        }
    }

    @Test
    public void testGetLatestRejectsLegacyErrorWithoutBackendKind() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            PluginCall call = mock(PluginCall.class);

            plugin.implementation = new NoNewVersionCapgoUpdater(false);
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.getLatest(call);

            verify(call, never()).resolve(any(JSObject.class));
            verify(call).reject("no_new_version_available");
        }
    }

    @Test
    public void testBlockedUpdateCheckDoesNotNotifyDownloadFailed() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            BlockedUpdateCapgoUpdater updater = new BlockedUpdateCapgoUpdater();

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(plugin.hasNotifiedEvent("noNeedUpdate"));
            assertTrue(plugin.hasNotifiedEvent("updateCheckResult"));
            JSObject payload = plugin.getNotifiedEventPayload("updateCheckResult");
            assertNotNull(payload);
            assertEquals("blocked", payload.getString("kind"));
            assertEquals(200, payload.getInt("statusCode"));
            assertEquals("1.0.0", payload.getString("version"));
            assertFalse(plugin.hasNotifiedEvent("downloadFailed"));
            assertFalse(updater.sendStatsCalled);
        }
    }

    @Test
    public void testFailedUpdateCheckNotifiesDownloadFailed() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            FailedUpdateCapgoUpdater updater = new FailedUpdateCapgoUpdater();

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(plugin.hasNotifiedEvent("updateCheckResult"));
            JSObject payload = plugin.getNotifiedEventPayload("updateCheckResult");
            assertNotNull(payload);
            assertEquals("failed", payload.getString("kind"));
            assertEquals(500, payload.getInt("statusCode"));
            assertEquals("1.0.0", payload.getString("version"));
            assertTrue(plugin.hasNotifiedEvent("downloadFailed"));
            assertTrue(updater.downloadFailStatsCalled);
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
    public void testScheduleDirectUpdateFinishUsesBackgroundDispatchPath() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final DirectUpdateDispatchPlugin plugin = new DirectUpdateDispatchPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final BundleInfo latest = new BundleInfo("download-id", "2.0.0", BundleStatus.SUCCESS, new Date(), "checksum");

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.scheduleDirectUpdateFinish(latest);

            assertTrue(plugin.startNewThreadCalled);
            assertTrue(plugin.reloadCalled);
            assertEquals(1, updater.setCalls);
            assertSame(plugin.activity, updater.activity);
        }
    }

    @Test
    public void testReloadUsesBackgroundDispatchPath() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadDispatchPlugin plugin = new ReloadDispatchPlugin();
            final ReloadCapgoUpdater updater = new ReloadCapgoUpdater();
            final PluginCall call = mock(PluginCall.class);

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.reload(call);

            assertTrue(plugin.startNewThreadCalled);
            assertTrue(plugin.reloadCalled);
            verify(call).resolve();
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

    @Test
    public void buildUserAgentStripsNonIsoCharacters() {
        String ua = DownloadService.buildUserAgent("com.example.тест", "1.2.3🔥", "Android 14 😊");
        assertEquals("CapacitorUpdater/1.2.3 (com.example.) android/Android 14", ua);
    }

    @Test
    public void buildUserAgentFallsBackToUnknown() {
        String ua = DownloadService.buildUserAgent("", "", "");
        assertEquals("CapacitorUpdater/unknown (unknown) android/unknown", ua);
    }

    /**
     * Regression test for: NoSuchMethodError crash on Android 8.0/8.1 (API 26/27).
     * getLongVersionCode() was introduced in API 28; the plugin must use
     * PackageInfoCompat.getLongVersionCode() to support API 24-27.
     *
     * <p>The @SuppressWarnings("deprecation") is intentional: we set PackageInfo.versionCode
     * (deprecated since API 28) directly to simulate a pre-API-28 device and verify
     * that PackageInfoCompat falls back to it correctly on older Android versions.
     */
    @Test
    @SuppressWarnings("deprecation")
    public void getVersionCodeReturnsStringVersionCodeViaPackageInfoCompat() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
            looperMock.when(Looper::myLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final PackageInfo packageInfo = new PackageInfo();
            packageInfo.versionCode = 42;

            final Method getVersionCode = CapacitorUpdaterPlugin.class.getDeclaredMethod("getVersionCode", PackageInfo.class);
            getVersionCode.setAccessible(true);
            final String result = (String) getVersionCode.invoke(plugin, packageInfo);

            assertEquals("42", result);
        }
    }
}
