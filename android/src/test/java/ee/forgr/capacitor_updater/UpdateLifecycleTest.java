package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.nullable;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebView;
import androidx.appcompat.app.AppCompatActivity;
import com.getcapacitor.Bridge;
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

/** Update lifecycle regressions: rollback timing, periodic checks, download stats and events. */
public class UpdateLifecycleTest {

    private static final String DEFERRED_CHECK_CLASS = "ee.forgr.capacitor_updater.CapacitorUpdaterPlugin$DeferredNotifyAppReadyCheck";

    private static final class LifecycleCapgoUpdater extends CapgoUpdater {

        BundleInfo current = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        BundleInfo next;
        Map<String, Object> latest = new HashMap<>();
        int getLatestCalls = 0;
        int downloadBackgroundCalls = 0;
        int setErrorCalls = 0;
        final List<String> stats = Collections.synchronizedList(new ArrayList<>());
        IOException manualDownloadError;
        LifecyclePlugin plugin;

        LifecycleCapgoUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            this.getLatestCalls++;
            callback.callback(new HashMap<>(this.latest));
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.current;
        }

        @Override
        public BundleInfo getNextBundle() {
            return this.next;
        }

        @Override
        public boolean setNextBundle(final String nextId) {
            this.next = nextId == null ? null : this.next;
            return true;
        }

        @Override
        public BundleInfo getFallbackBundle() {
            return new BundleInfo(BundleInfo.ID_BUILTIN, "builtin", BundleStatus.SUCCESS, BundleInfo.DOWNLOADED_BUILTIN, "builtin");
        }

        @Override
        public BundleInfo getBundleInfo(final String id) {
            if (this.current != null && this.current.getId().equals(id)) {
                return this.current;
            }
            return new BundleInfo(id, id, BundleStatus.PENDING, new Date(), "");
        }

        @Override
        public BundleInfo getBundleInfoByName(final String version) {
            return null;
        }

        @Override
        public Boolean set(final BundleInfo bundle) {
            this.current = bundle;
            return true;
        }

        @Override
        public void setError(final BundleInfo bundle) {
            this.setErrorCalls++;
            this.current = bundle.setStatus(BundleStatus.ERROR);
        }

        @Override
        public boolean saveBundleInfo(final String id, final BundleInfo info) {
            return true;
        }

        @Override
        ResetState captureResetState() {
            return new ResetState("public", BundleInfo.ID_BUILTIN, null);
        }

        @Override
        void prepareResetStateForTransition() {}

        @Override
        void finalizeResetTransition(final String previousBundleName, final boolean internal) {}

        @Override
        public Boolean delete(final String id, final Boolean removeInfo, final boolean cancelActiveDownload) {
            return true;
        }

        @Override
        public String getCurrentBundlePath() {
            return "/tmp/capgo-bundle";
        }

        @Override
        public Boolean isUsingBuiltin() {
            return false;
        }

        @Override
        public void persistPendingStats() {}

        @Override
        public void sendStats(final String action) {
            this.stats.add(action);
        }

        @Override
        public void sendStats(
            final String action,
            final String versionName,
            final String oldVersionName,
            final Map<String, String> metadata,
            final Runnable onSent
        ) {
            this.stats.add(action);
        }

        @Override
        public void downloadBackground(
            final String url,
            final String version,
            final String sessionKey,
            final String checksum,
            final JSONArray manifest,
            final boolean setNext
        ) {
            this.downloadBackgroundCalls++;
        }

        @Override
        public BundleInfo download(final String url, final String version, final String sessionKey, final String checksum)
            throws IOException {
            if (this.manualDownloadError instanceof ReportedDownloadFailureException) {
                // What the download observer does before failing the waiting download() call.
                final JSObject ret = new JSObject();
                ret.put("version", version);
                this.plugin.notifyListeners("downloadFailed", ret);
                this.sendStats("download_fail", version);
            }
            throw this.manualDownloadError;
        }

        int statCount(final String action) {
            int count = 0;
            synchronized (this.stats) {
                for (final String stat : this.stats) {
                    if (action.equals(stat)) {
                        count++;
                    }
                }
            }
            return count;
        }
    }

    private static final class LifecyclePlugin extends CapacitorUpdaterPlugin {

        final List<String> events = Collections.synchronizedList(new ArrayList<>());
        final Map<String, JSObject> payloads = Collections.synchronizedMap(new HashMap<>());
        boolean runRollbackChecks = true;
        boolean stubReload = true;

        @Override
        public void notifyListeners(final String eventName, final JSObject data) {
            this.events.add(eventName);
            this.payloads.put(eventName, data);
        }

        @Override
        public void notifyListeners(final String eventName, final JSObject data, final boolean retainUntilConsumed) {
            this.notifyListeners(eventName, data);
        }

        @Override
        public Thread startNewThread(final Runnable function, final Number waitTime) {
            return this.startNewThread(function);
        }

        @Override
        public Thread startNewThread(final Runnable function) {
            if (!this.runRollbackChecks && DEFERRED_CHECK_CLASS.equals(function.getClass().getName())) {
                return new Thread();
            }
            function.run();
            return new Thread();
        }

        @Override
        public AppCompatActivity getActivity() {
            return null;
        }

        @Override
        protected long getMinimumPendingBundleAppReadyTimeoutMs() {
            return 1;
        }

        @Override
        protected boolean _reload() {
            return this.stubReload || super._reload();
        }

        @Override
        boolean isVersionDownloadInProgress(final String version) {
            return false;
        }

        int count(final String eventName) {
            int count = 0;
            synchronized (this.events) {
                for (final String event : this.events) {
                    if (eventName.equals(event)) {
                        count++;
                    }
                }
            }
            return count;
        }

        String appReadyStatus() {
            final JSObject payload = this.payloads.get("appReady");
            return payload == null ? null : payload.getString("status");
        }
    }

    private MockedStatic<Looper> looperMock;
    private MockedConstruction<Handler> handlerMock;
    private MockedStatic<CapConfig> capConfigMock;
    private LifecyclePlugin plugin;
    private LifecycleCapgoUpdater updater;

    @Before
    public void setUp() throws Exception {
        this.looperMock = mockStatic(Looper.class);
        this.looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
        this.handlerMock = mockConstruction(Handler.class);
        final CapConfig capConfig = mock(CapConfig.class);
        this.capConfigMock = mockStatic(CapConfig.class);
        this.capConfigMock.when(() -> CapConfig.loadDefault(any())).thenReturn(capConfig);

        this.plugin = new LifecyclePlugin();
        this.updater = new LifecycleCapgoUpdater();
        this.updater.plugin = this.plugin;
        this.plugin.implementation = this.updater;
        this.plugin.setLoggerForTesting(mock(Logger.class));

        final SharedPreferences prefs = mock(SharedPreferences.class);
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class, RETURNS_SELF);
        when(prefs.edit()).thenReturn(editor);
        when(prefs.getString(anyString(), nullable(String.class))).thenAnswer((invocation) -> invocation.getArgument(1));
        final DelayUpdateUtils delayUpdateUtils = mock(DelayUpdateUtils.class);
        when(delayUpdateUtils.parseDelayConditions(anyString())).thenReturn(new ArrayList<>());
        setField("prefs", prefs);
        setField("editor", editor);
        setField("delayUpdateUtils", delayUpdateUtils);
        setField("updateUrl", "https://example.com/updates");
        setField("appReadyTimeout", 1);
    }

    @After
    public void tearDown() {
        this.capConfigMock.close();
        this.handlerMock.close();
        this.looperMock.close();
    }

    private void setField(final String name, final Object value) throws Exception {
        final Field field = CapacitorUpdaterPlugin.class.getDeclaredField(name);
        field.setAccessible(true);
        field.set(this.plugin, value);
    }

    private Object getField(final String name) throws Exception {
        final Field field = CapacitorUpdaterPlugin.class.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(this.plugin);
    }

    private void enableAutoUpdate() {
        this.plugin.setAutoUpdateModeForTesting("atBackground");
    }

    /** Runs a rollback check whose sleep already expired (what a frozen app sees at thaw). */
    private void runExpiredRollbackCheck() throws Exception {
        final Constructor<?> constructor = Class.forName(DEFERRED_CHECK_CLASS).getDeclaredConstructor(
            CapacitorUpdaterPlugin.class,
            long.class
        );
        constructor.setAccessible(true);
        ((Runnable) constructor.newInstance(this.plugin, 0L)).run();
    }

    private void invokeBackgroundDownload() throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod("backgroundDownload");
        method.setAccessible(true);
        method.invoke(this.plugin);
    }

    private void latestResponse(final String version) {
        this.updater.latest.put("version", version);
        this.updater.latest.put("url", "https://example.com/update.zip");
        this.updater.latest.put("checksum", "abc123");
    }

    // Bug: Android froze the app in background, the rollback timer expired during the freeze and rolled
    // the new bundle back at thaw, before appMovedToForeground could re-arm it.
    @Test
    public void rollbackCheckWaitsForTheNextForegroundWhileInBackground() throws Exception {
        this.updater.current = new BundleInfo("bundle-2", "2.0.0", BundleStatus.PENDING, new Date(), "abc");

        this.plugin.appMovedToBackground();
        this.runExpiredRollbackCheck();

        assertFalse(this.plugin.events.contains("updateFailed"));
        assertEquals(0, this.updater.setErrorCalls);
        assertEquals("bundle-2", this.updater.current.getId());

        // The next foreground arms a fresh check, which still rolls back a page that never confirmed.
        this.plugin.appMovedToForeground();

        assertTrue(this.plugin.events.contains("updateFailed"));
        assertEquals(1, this.updater.setErrorCalls);
    }

    @Test
    public void rollbackCheckStillRunsInForeground() throws Exception {
        this.updater.current = new BundleInfo("bundle-2", "2.0.0", BundleStatus.PENDING, new Date(), "abc");

        this.runExpiredRollbackCheck();

        assertTrue(this.plugin.events.contains("updateFailed"));
        assertEquals(1, this.updater.setErrorCalls);
    }

    // Bug: the install at background waited appReadyTimeout (30 s for a pending bundle) for a page that
    // cannot run while frozen, then reported failure and kept the bundle queued as next.
    @Test
    public void backgroundInstallDoesNotWaitForTheFrozenPage() throws Exception {
        final Bridge bridge = mock(Bridge.class);
        final WebView webView = mock(WebView.class);
        when(bridge.getWebView()).thenReturn(webView);
        when(bridge.getAppUrl()).thenReturn("https://local-app-domain.com");
        when(webView.post(any(Runnable.class))).thenReturn(true);
        this.plugin.setBridge(bridge);
        this.plugin.stubReload = false;
        this.plugin.runRollbackChecks = false;
        setField("appReadyTimeout", 5000);
        this.updater.current = new BundleInfo(BundleInfo.ID_BUILTIN, "builtin", BundleStatus.SUCCESS, BundleInfo.DOWNLOADED_BUILTIN, "");
        this.updater.next = new BundleInfo("bundle-2", "2.0.0", BundleStatus.PENDING, new Date(), "abc");

        final long start = System.nanoTime();
        this.plugin.appMovedToBackground();
        final long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);

        assertTrue("Background install waited " + elapsedMs + "ms for notifyAppReady", elapsedMs < 2000);
        assertTrue(this.plugin.events.contains("set"));
        assertEquals("bundle-2", this.updater.current.getId());
        assertNull(this.updater.next);
        // The next appReady waits for the new page to confirm itself.
        assertTrue((boolean) getField("pendingNotifyAppReadyWait"));
    }

    // Bug: compared the latest version with BundleInfo.toString(), so every tick downloaded again.
    @Test
    public void periodicCheckDoesNotDownloadTheCurrentVersion() {
        this.enableAutoUpdate();
        latestResponse("1.0.0");

        this.plugin.runPeriodicUpdateCheck();

        assertEquals(1, this.updater.getLatestCalls);
        assertEquals(0, this.updater.downloadBackgroundCalls);
    }

    @Test
    public void periodicCheckDownloadsANewVersion() {
        this.enableAutoUpdate();
        latestResponse("2.0.0");

        this.plugin.runPeriodicUpdateCheck();

        assertEquals(2, this.updater.getLatestCalls);
        assertEquals(1, this.updater.downloadBackgroundCalls);
    }

    @Test
    public void periodicCheckReportsErrorResponsesWithoutDownloading() {
        this.enableAutoUpdate();
        this.updater.latest.put("error", "no_new_version_available");
        this.updater.latest.put("kind", "up_to_date");

        this.plugin.runPeriodicUpdateCheck();

        assertEquals(1, this.updater.getLatestCalls);
        assertEquals(0, this.updater.downloadBackgroundCalls);
        assertEquals("up_to_date", this.plugin.payloads.get("updateCheckResult").getString("kind"));
    }

    // Bug: lastNotifiedStatPercent stayed at 100 after the first download of the process.
    @Test
    public void downloadProgressStatsRestartForEachDownload() {
        for (final int percent : new int[] { 0, 5, 50, 100 }) {
            this.plugin.notifyDownload("first", percent);
        }
        for (final int percent : new int[] { 0, 5, 20, 50, 55, 100 }) {
            this.plugin.notifyDownload("second", percent);
        }

        assertEquals(2, this.updater.statCount("download_50"));
        assertEquals(1, this.updater.statCount("download_20"));
        assertEquals(2, this.updater.statCount("download_complete"));
    }

    // Bug: the store refused these downloads silently, so the launch never got appReady.
    @Test
    public void autoUpdateMissingSessionKeyEndsTheCycle() throws Exception {
        this.enableAutoUpdate();
        this.updater.publicKey = "public-key";
        latestResponse("2.0.0");

        invokeBackgroundDownload();

        assertEquals(0, this.updater.downloadBackgroundCalls);
        assertEquals("Session key required when public key is present", this.plugin.appReadyStatus());
        assertEquals(1, this.plugin.count("downloadFailed"));
        assertEquals(1, this.updater.statCount("session_key_required"));
    }

    @Test
    public void autoUpdateMissingChecksumEndsTheCycle() throws Exception {
        this.enableAutoUpdate();
        latestResponse("2.0.0");
        this.updater.latest.remove("checksum");

        invokeBackgroundDownload();

        assertEquals(0, this.updater.downloadBackgroundCalls);
        assertEquals("Checksum required", this.plugin.appReadyStatus());
        assertEquals(1, this.plugin.count("downloadFailed"));
        assertEquals(1, this.updater.statCount("checksum_required"));
    }

    @Test
    public void autoUpdateDownloadStartsWhenGatesPass() throws Exception {
        this.enableAutoUpdate();
        latestResponse("2.0.0");

        invokeBackgroundDownload();

        assertEquals(1, this.updater.downloadBackgroundCalls);
        assertFalse(this.plugin.events.contains("appReady"));
    }

    // Bug: a download merely in progress was reported to JS as appReady "disabled".
    @Test
    public void foregroundDuringADownloadDoesNotReportAutoUpdateDisabled() throws Exception {
        this.enableAutoUpdate();
        this.plugin.runRollbackChecks = false;
        final Thread running = new Thread(() -> {
            try {
                Thread.sleep(5000);
            } catch (final InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        });
        running.start();
        try {
            setField("backgroundDownloadTask", running);
            setField("downloadStartTimeMs", System.currentTimeMillis());

            this.plugin.appMovedToForeground();

            assertFalse(this.plugin.events.contains("appReady"));
            assertEquals(0, this.updater.getLatestCalls);
        } finally {
            running.interrupt();
        }
    }

    @Test
    public void foregroundWithAutoUpdateOffReportsDisabled() {
        this.plugin.runRollbackChecks = false;

        this.plugin.appMovedToForeground();

        assertEquals("disabled", this.plugin.appReadyStatus());
    }

    // Bug: returned "preview_session" (not in the TS union) and never "unavailable" when auto update is off.
    @Test
    public void triggerUpdateCheckIsUnavailableWhenAutoUpdateIsDisabled() {
        assertEquals("unavailable", this.plugin.triggerBackgroundUpdateCheck());
        assertEquals(0, this.updater.getLatestCalls);
    }

    @Test
    public void triggerUpdateCheckIsUnavailableDuringAPreviewSession() {
        this.enableAutoUpdate();
        this.plugin.previewSessionEnabled = true;

        assertEquals("unavailable", this.plugin.triggerBackgroundUpdateCheck());
        assertEquals(0, this.updater.getLatestCalls);
    }

    @Test
    public void triggerUpdateCheckQueuesWhenAutoUpdateIsEnabled() {
        this.enableAutoUpdate();
        latestResponse("1.0.0");

        assertEquals("queued", this.plugin.triggerBackgroundUpdateCheck());
        assertEquals(1, this.updater.getLatestCalls);
    }

    private PluginCall manualDownloadCall() {
        final PluginCall call = mock(PluginCall.class);
        when(call.getString("url")).thenReturn("https://example.com/update.zip");
        when(call.getString("version")).thenReturn("2.0.0");
        when(call.getString("sessionKey", "")).thenReturn("");
        when(call.getString("checksum", "")).thenReturn("abc123");
        when(call.getData()).thenReturn(new JSObject());
        return call;
    }

    // Bug: a failed manual download sent downloadFailed and download_fail from the updater and again
    // from the plugin.
    @Test
    public void manualDownloadFailureReportedByTheUpdaterIsEmittedOnce() {
        this.updater.manualDownloadError = new CapgoUpdater.ReportedDownloadFailureException("Download failed with status: error");

        this.plugin.download(manualDownloadCall());

        assertEquals(1, this.plugin.count("downloadFailed"));
        assertEquals(1, this.updater.statCount("download_fail"));
    }

    @Test
    public void manualDownloadFailureBeforeTheDownloadIsEmittedOnce() {
        this.updater.manualDownloadError = new IOException("Network error");

        this.plugin.download(manualDownloadCall());

        assertEquals(1, this.plugin.count("downloadFailed"));
        assertEquals(1, this.updater.statCount("download_fail"));
    }
}
