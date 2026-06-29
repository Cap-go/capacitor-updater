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
import com.getcapacitor.CapConfig;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginConfig;
import com.getcapacitor.PluginHandle;
import io.github.g00fy2.versioncompare.Version;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Phaser;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
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

    private static final class StatsIgnoringCapgoUpdater extends CapgoUpdater {

        StatsIgnoringCapgoUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void sendStats(final String action) {}
    }

    private static final class FreshDownloadCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private BundleInfo existingLatestBundle;
        private BooleanSupplier consumedStateSupplier = () -> false;
        private BooleanSupplier directUpdateStateSupplier = () -> false;
        private boolean downloadBackgroundCalled = false;
        private boolean downloadBackgroundSetNext = true;
        private boolean consumedWhenDownloadStarted = false;
        private boolean directUpdateWhenDownloadStarted = false;
        private boolean setNextBundleCalled = false;
        private String lastSetNextBundleId;
        private java.util.function.Consumer<String> updateAvailableNotifier = (version) -> {};

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
            this.downloadBackground(url, version, sessionKey, checksum, manifest, true);
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
            this.downloadBackgroundCalled = true;
            this.downloadBackgroundSetNext = setNext;
            this.consumedWhenDownloadStarted = this.consumedStateSupplier.getAsBoolean();
            this.directUpdateWhenDownloadStarted = this.directUpdateStateSupplier.getAsBoolean();
            this.updateAvailableNotifier.accept(version);
        }

        @Override
        public boolean setNextBundle(final String next) {
            this.setNextBundleCalled = true;
            this.lastSetNextBundleId = next;
            return true;
        }
    }

    private static final class BuiltinLatestCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle;
        private final BundleInfo builtinBundle = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "builtin",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "builtin"
        );
        private boolean setNextBundleCalled = false;
        private String lastSetNextBundleId;

        BuiltinLatestCapgoUpdater() {
            this(new BundleInfo("current-id", "2.0.0", BundleStatus.SUCCESS, new Date(), "abc123"));
        }

        BuiltinLatestCapgoUpdater(final BundleInfo currentBundle) {
            super(null);
            this.currentBundle = currentBundle;
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("version", "builtin");
            callback.callback(response);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
        }

        @Override
        public BundleInfo getBundleInfo(final String id) {
            if (BundleInfo.ID_BUILTIN.equals(id)) {
                return this.builtinBundle;
            }
            return this.currentBundle;
        }

        @Override
        public boolean setNextBundle(final String next) {
            this.setNextBundleCalled = true;
            this.lastSetNextBundleId = next;
            return true;
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

    private static final class BreakingNoUrlCapgoUpdater extends CapgoUpdater {

        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private boolean downloadFailStatsCalled = false;

        BreakingNoUrlCapgoUpdater() {
            super(null);
        }

        @Override
        public void getLatest(final String updateUrl, final String channel, final Callback callback) {
            final Map<String, Object> response = new HashMap<>();
            response.put("version", "1.0.17");
            response.put("breaking", true);
            response.put("message", "store_update_required");
            response.put("statusCode", 200);
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
        private final List<BundleInfo> listedBundles = new ArrayList<>();
        private BundleInfo fallbackBundle = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "builtin",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "builtin"
        );
        private BundleInfo nextBundle;
        private BundleInfo previewFallbackBundle;
        private BundleInfo stagedPreviewFallbackBundle;
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
        private boolean stagePreviewFallbackReloadResult = true;
        private int stagePreviewFallbackReloadCalls = 0;
        private int finalizePendingReloadCalls = 0;
        private BundleInfo finalizedPendingReloadBundle;
        private String finalizePendingReloadPreviousBundleName;
        private int setPreviewFallbackBundleCalls = 0;
        private String lastPreviewFallbackBundle;
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
        public List<BundleInfo> list(final boolean rawList) {
            return this.listedBundles;
        }

        @Override
        public BundleInfo getPreviewFallbackBundle() {
            return this.previewFallbackBundle;
        }

        @Override
        public BundleInfo getBundleInfo(final String id) {
            if (BundleInfo.ID_BUILTIN.equals(id)) {
                return new BundleInfo(BundleInfo.ID_BUILTIN, "builtin", BundleStatus.SUCCESS, BundleInfo.DOWNLOADED_BUILTIN, "builtin");
            }
            if (this.currentBundle != null && this.currentBundle.getId().equals(id)) {
                return this.currentBundle;
            }
            if (this.fallbackBundle != null && this.fallbackBundle.getId().equals(id)) {
                return this.fallbackBundle;
            }
            if (this.previewFallbackBundle != null && this.previewFallbackBundle.getId().equals(id)) {
                return this.previewFallbackBundle;
            }
            return new BundleInfo(id, id, BundleStatus.PENDING, new Date(), "");
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
        boolean stagePreviewFallbackReload(final BundleInfo bundle) {
            this.stagePreviewFallbackReloadCalls++;
            this.stagedPreviewFallbackBundle = bundle;
            return this.stagePreviewFallbackReloadResult;
        }

        @Override
        public boolean setPreviewFallbackBundle(final String fallback) {
            this.setPreviewFallbackBundleCalls++;
            this.lastPreviewFallbackBundle = fallback;
            if (fallback == null) {
                this.previewFallbackBundle = null;
            }
            return true;
        }

        @Override
        public Boolean delete(final String id, final Boolean removeInfo) {
            return true;
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

        @Override
        protected boolean reloadWithoutWaitingForAppReady() {
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
        protected boolean reloadWithoutWaitingForAppReady() {
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
        protected boolean reloadWithoutWaitingForAppReady() {
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
        private final BundleInfo currentBundle = new BundleInfo("current-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");
        private String lastStatsAction;
        private String lastStatsVersionName;
        private final List<String> sentStatsActions = new ArrayList<>();
        private final List<Map<String, String>> sentStatsMetadata = new ArrayList<>();
        private String lastStatsOldVersionName;
        private Map<String, String> lastStatsMetadata;
        private boolean acknowledgeStats = true;

        PendingReloadFinalizeCapgoUpdater() {
            super(null);
        }

        @Override
        public BundleInfo getCurrentBundle() {
            return this.currentBundle;
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
            this.sentStatsActions.add(action);
            this.sentStatsMetadata.add(null);
            this.lastStatsAction = action;
            this.lastStatsVersionName = versionName;
            this.lastStatsOldVersionName = oldVersionName;
            this.lastStatsMetadata = null;
        }

        @Override
        public void sendStats(
            final String action,
            final String versionName,
            final String oldVersionName,
            final Map<String, String> metadata
        ) {
            this.sentStatsActions.add(action);
            this.sentStatsMetadata.add(metadata);
            this.lastStatsAction = action;
            this.lastStatsVersionName = versionName;
            this.lastStatsOldVersionName = oldVersionName;
            this.lastStatsMetadata = metadata;
        }

        @Override
        public void sendStats(
            final String action,
            final String versionName,
            final String oldVersionName,
            final Map<String, String> metadata,
            final Runnable onSent
        ) {
            this.sendStats(action, versionName, oldVersionName, metadata);
            if (this.acknowledgeStats && onSent != null) {
                onSent.run();
            }
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

    private static Path createZipWithEntry(final String entryName) throws Exception {
        final Path zipPath = Files.createTempFile("capgo-zip-path", ".zip");
        zipPath.toFile().deleteOnExit();
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(zipPath))) {
            zip.putNextEntry(new ZipEntry(entryName));
            zip.write("owned".getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }
        return zipPath;
    }

    private static File invokeUnzip(final CapgoUpdater updater, final String id, final Path zipPath, final String dest) throws Exception {
        final Method method = CapgoUpdater.class.getDeclaredMethod("unzip", String.class, File.class, String.class);
        method.setAccessible(true);
        try {
            return (File) method.invoke(updater, id, zipPath.toFile(), dest);
        } catch (InvocationTargetException e) {
            final Throwable cause = e.getCause();
            if (cause instanceof IOException) {
                throw (IOException) cause;
            }
            if (cause instanceof RuntimeException) {
                throw (RuntimeException) cause;
            }
            throw e;
        }
    }

    private static void invokeBackgroundDownload(final CapacitorUpdaterPlugin plugin) throws Exception {
        final Method backgroundDownload = CapacitorUpdaterPlugin.class.getDeclaredMethod("backgroundDownload");
        backgroundDownload.setAccessible(true);
        backgroundDownload.invoke(plugin);
    }

    private static FreshDownloadCapgoUpdater configureOnlyDownloadBackgroundDownload(final ImmediateThreadCapacitorUpdaterPlugin plugin) {
        final FreshDownloadCapgoUpdater updater = new FreshDownloadCapgoUpdater();

        plugin.implementation = updater;
        plugin.setAutoUpdateModeForTesting("onlyDownload");
        plugin.setLoggerForTesting(mock(Logger.class));
        updater.updateAvailableNotifier = (version) -> {
            final JSObject ret = new JSObject();
            final BundleInfo downloaded = new BundleInfo("downloaded-id", version, BundleStatus.PENDING, new Date(), "checksum");
            ret.put("bundle", InternalUtils.mapToJSObject(downloaded.toJSONMap()));
            plugin.notifyListeners("updateAvailable", ret);
        };

        return updater;
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

    private static boolean invokePrivatePreviewFallbackResetMethod(final CapacitorUpdaterPlugin plugin) throws Exception {
        final Method method = CapacitorUpdaterPlugin.class.getDeclaredMethod("resetToPreviewFallbackBundle");
        method.setAccessible(true);
        return (boolean) method.invoke(plugin);
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
    public void pluginMethodsDoNotExposeApplicationExitInfoToReflection() {
        final String applicationExitInfoClassName = ApplicationExitInfo.class.getName();
        for (final Method method : CapacitorUpdaterPlugin.class.getDeclaredMethods()) {
            assertFalse(exposesApplicationExitInfoType(method.getReturnType(), applicationExitInfoClassName));
            for (final Class<?> parameterType : method.getParameterTypes()) {
                assertFalse(exposesApplicationExitInfoType(parameterType, applicationExitInfoClassName));
            }
        }
    }

    private static boolean exposesApplicationExitInfoType(final Class<?> type, final String applicationExitInfoClassName) {
        Class<?> currentType = type;
        while (currentType.isArray()) {
            currentType = currentType.getComponentType();
        }
        return applicationExitInfoClassName.equals(currentType.getName());
    }

    @Test
    public void listChannelsResponseKeepsNumericChannelIds() throws Exception {
        final Map<String, Object> result = CapgoUpdater.parseListChannelsResponse(
            "[{\"id\":123,\"name\":\"Production\",\"public\":true,\"allow_self_set\":true}]"
        );

        final Object channelsValue = result.get("channels");
        assertTrue(channelsValue instanceof List<?>);
        final Object channelValue = ((List<?>) channelsValue).get(0);
        assertTrue(channelValue instanceof Map<?, ?>);
        final Object id = ((Map<?, ?>) channelValue).get("id");
        assertTrue(id instanceof Number);
        assertEquals(123, ((Number) id).intValue());
    }

    @Test
    public void listChannelsResponseRejectsStringChannelIds() {
        assertThrows(JSONException.class, () ->
            CapgoUpdater.parseListChannelsResponse("[{\"id\":\"123\",\"name\":\"Production\",\"public\":true,\"allow_self_set\":true}]")
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
        assertEquals(
            "webview_content_process_terminated",
            CapacitorUpdaterPlugin.statsActionForWebViewErrorType("web_content_process_terminated")
        );
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
        final String scheme = "https";
        final String host = "example.com";
        final String userInfo = String.join(":", "user", "value") + "@";
        final String sourceQuery = "cache=123";
        final String hrefQuery = "debug=true";
        final JSObject data = new JSObject();
        data.put("source", scheme + "://" + userInfo + host + ":8443/assets/app.js?" + sourceQuery + "#L10");
        data.put("href", scheme + "://" + host + "/users/123456/dashboard?" + hrefQuery + "#frag");
        data.put("previous_href", "app.js?" + sourceQuery + "#frag");

        final Map<String, String> metadata = CapacitorUpdaterPlugin.buildWebViewErrorMetadata(data);

        assertEquals(scheme + "://" + host + ":8443/assets/app.js", metadata.get("source"));
        assertEquals(scheme + "://" + host + "/users/redacted/dashboard", metadata.get("href"));
        assertEquals("app.js", metadata.get("previous_href"));
        assertFalse(metadata.get("source").contains(sourceQuery));
        assertFalse(metadata.get("href").contains(hrefQuery));
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
    public void testGetBackgroundRunnerLabelFromConfigExtractsLabel() {
        final String config =
            "{\"plugins\":{\"BackgroundRunner\":{\"label\":\"com.example.runner\",\"src\":\"runner.js\",\"autoStart\":true}}}";

        assertEquals("com.example.runner", CapgoUpdater.getBackgroundRunnerLabelFromConfig(config));
    }

    @Test
    public void testGetBackgroundRunnerLabelFromConfigReturnsNullWhenMissing() {
        final String config = "{\"plugins\":{\"CapacitorUpdater\":{\"autoUpdate\":true}}}";

        assertNull(CapgoUpdater.getBackgroundRunnerLabelFromConfig(config));
    }

    @Test
    public void testGetBackgroundRunnerLabelFromConfigReturnsNullForBlankLabel() {
        final String config = "{\"plugins\":{\"BackgroundRunner\":{\"label\":\"  \",\"src\":\"runner.js\"}}}";

        assertNull(CapgoUpdater.getBackgroundRunnerLabelFromConfig(config));
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
    public void testReportNativeVersionStatsPersistsFirstSnapshotWithoutEvent() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final PendingReloadFinalizeCapgoUpdater updater = new PendingReloadFinalizeCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);

            plugin.implementation = updater;
            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "editor", editor);
            when(prefs.getString("CapacitorUpdater.lastVersionOs", "")).thenReturn("");
            when(prefs.getString("CapacitorUpdater.lastVersionBuild", "")).thenReturn("");
            when(prefs.getString("CapacitorUpdater.lastVersionCode", "")).thenReturn("");

            plugin.reportNativeVersionStatsIfChanged("1.0.0", "100", "14");

            assertTrue(updater.sentStatsActions.isEmpty());
            verify(editor).putString("CapacitorUpdater.lastVersionOs", "14");
            verify(editor).putString("CapacitorUpdater.lastVersionBuild", "1.0.0");
            verify(editor).putString("CapacitorUpdater.lastVersionCode", "100");
            verify(editor).apply();
        }
    }

    @Test
    public void testReportNativeVersionStatsSendsChangedOsAndNativeVersionEvents() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final PendingReloadFinalizeCapgoUpdater updater = new PendingReloadFinalizeCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);

            plugin.implementation = updater;
            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "editor", editor);
            when(prefs.getString("CapacitorUpdater.lastVersionOs", "")).thenReturn("13");
            when(prefs.getString("CapacitorUpdater.lastVersionBuild", "")).thenReturn("1.0.0");
            when(prefs.getString("CapacitorUpdater.lastVersionCode", "")).thenReturn("100");

            plugin.reportNativeVersionStatsIfChanged("1.1.0", "101", "14");

            assertEquals(List.of("os_version_changed", "native_app_version_changed"), updater.sentStatsActions);
            assertEquals("13", updater.sentStatsMetadata.get(0).get("previous_version_os"));
            assertEquals("14", updater.sentStatsMetadata.get(0).get("current_version_os"));
            assertEquals("1.0.0", updater.sentStatsMetadata.get(1).get("previous_version_build"));
            assertEquals("1.1.0", updater.sentStatsMetadata.get(1).get("current_version_build"));
            assertEquals("100", updater.sentStatsMetadata.get(1).get("previous_version_code"));
            assertEquals("101", updater.sentStatsMetadata.get(1).get("current_version_code"));
            verify(editor).putString("CapacitorUpdater.lastVersionOs", "14");
            verify(editor).putString("CapacitorUpdater.lastVersionBuild", "1.1.0");
            verify(editor).putString("CapacitorUpdater.lastVersionCode", "101");
            verify(editor, times(2)).apply();
        }
    }

    @Test
    public void testReportNativeVersionStatsKeepsChangedSnapshotPendingUntilStatsAck() throws Exception {
        try (MockedStatic<Looper> looperMock = mockStatic(Looper.class)) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final PendingReloadFinalizeCapgoUpdater updater = new PendingReloadFinalizeCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
            updater.acknowledgeStats = false;

            plugin.implementation = updater;
            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "editor", editor);
            when(prefs.getString("CapacitorUpdater.lastVersionOs", "")).thenReturn("13");
            when(prefs.getString("CapacitorUpdater.lastVersionBuild", "")).thenReturn("1.0.0");
            when(prefs.getString("CapacitorUpdater.lastVersionCode", "")).thenReturn("100");

            plugin.reportNativeVersionStatsIfChanged("1.1.0", "101", "14");

            assertEquals(List.of("os_version_changed", "native_app_version_changed"), updater.sentStatsActions);
            verify(editor, never()).putString("CapacitorUpdater.lastVersionOs", "14");
            verify(editor, never()).putString("CapacitorUpdater.lastVersionBuild", "1.1.0");
            verify(editor, never()).putString("CapacitorUpdater.lastVersionCode", "101");
            verify(editor, never()).apply();
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
    public void testPeriodCheckDelayZeroDisablesPeriodicChecks() {
        assertEquals(0, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(0));
    }

    @Test
    public void testPeriodCheckDelayNegativeDisablesPeriodicChecks() {
        assertEquals(0, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(-1));
    }

    @Test
    public void testPeriodCheckDelayBelowMinimumClampsToTenMinutes() {
        assertEquals(600_000, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(1));
        assertEquals(600_000, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(599));
    }

    @Test
    public void testPeriodCheckDelayAtMinimumIsAllowed() {
        assertEquals(600_000, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(600));
    }

    @Test
    public void testPeriodCheckDelayAboveMinimumIsPreserved() {
        assertEquals(3_600_000, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(3600));
    }

    @Test
    public void testPeriodCheckDelayOverflowClampsToMaxInt() {
        assertEquals(Integer.MAX_VALUE, CapacitorUpdaterPlugin.normalizedPeriodCheckDelayMs(Integer.MAX_VALUE));
    }

    @Test
    public void testCheckRevertSkipsRollbackDuringPreviewSession() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.currentBundle = new BundleInfo("preview-id", "preview", BundleStatus.PENDING, new Date(), "preview");

            plugin.implementation = updater;
            plugin.previewSessionEnabled = true;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokePrivateVoidMethod(plugin, "checkRevert");

            assertFalse(updater.resetCalled);
            assertFalse(plugin.hasNotifiedEvent("updateFailed"));
        }
    }

    @Test
    public void testCheckRevertSkipsRollbackDuringPreviewTransition() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.currentBundle = new BundleInfo("preview-id", "preview", BundleStatus.PENDING, new Date(), "preview");
            updater.previewSession = true;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokePrivateVoidMethod(plugin, "checkRevert");

            assertFalse(updater.resetCalled);
            assertFalse(plugin.hasNotifiedEvent("updateFailed"));
        }
    }

    @Test
    public void testTriggerUpdateCheckSkipsDuringPreviewSession() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            plugin.implementation = new ResetTrackingCapgoUpdater();
            plugin.previewSessionEnabled = true;
            plugin.setLoggerForTesting(mock(Logger.class));
            setPrivateField(plugin, "updateUrl", "https://example.com/updates");

            assertEquals("preview_session", plugin.triggerBackgroundUpdateCheck());
        }
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
    public void testLeavePreviewUsesBuiltinWhenPreviewFallbackIsMissing() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            updater.currentBundle = new BundleInfo("preview-id", "preview", BundleStatus.SUCCESS, new Date(), "preview");
            updater.previewFallbackBundle = null;

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            final boolean result = invokePrivatePreviewFallbackResetMethod(plugin);

            assertTrue(result);
            assertEquals(1, updater.stagePreviewFallbackReloadCalls);
            assertEquals(BundleInfo.ID_BUILTIN, updater.stagedPreviewFallbackBundle.getId());
            assertTrue(updater.finalizeResetTransitionCalled);
            assertEquals("preview", updater.finalizeResetTransitionPreviousBundleName);
            assertFalse(updater.finalizeResetTransitionInternal);
            assertEquals(0, updater.restoreResetStateCalls);
        }
    }

    @Test
    public void testLeavePreviewFromShakeMenuKeepsPreviewGuardUntilAppReady() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ReloadBypassCapacitorUpdaterPlugin plugin = new ReloadBypassCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
            final Bridge bridge = mock(Bridge.class);
            final CapConfig capConfig = mock(CapConfig.class);
            final PluginConfig pluginConfig = mock(PluginConfig.class);
            final PluginHandle handle = mock(PluginHandle.class);

            updater.currentBundle = new BundleInfo("preview-id", "preview", BundleStatus.SUCCESS, new Date(), "preview");
            updater.previewFallbackBundle = new BundleInfo("fallback-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "fallback");
            updater.previewSession = true;
            plugin.implementation = updater;
            plugin.previewSessionEnabled = true;
            plugin.setLoggerForTesting(mock(Logger.class));
            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "editor", editor);
            setPrivateField(plugin, "bridge", bridge);
            plugin.setPluginHandle(handle);

            when(handle.getId()).thenReturn("CapacitorUpdater");
            when(bridge.getConfig()).thenReturn(capConfig);
            when(capConfig.getPluginConfiguration("CapacitorUpdater")).thenReturn(pluginConfig);
            when(pluginConfig.getString(anyString(), nullable(String.class))).thenAnswer((invocation) -> invocation.getArgument(1));
            when(pluginConfig.getBoolean(anyString(), anyBoolean())).thenAnswer((invocation) -> invocation.getArgument(1));
            when(prefs.getString(anyString(), nullable(String.class))).thenAnswer((invocation) -> invocation.getArgument(1));
            when(prefs.getBoolean(anyString(), anyBoolean())).thenAnswer((invocation) -> invocation.getArgument(1));
            when(editor.remove(anyString())).thenReturn(editor);

            assertTrue(plugin.leavePreviewSessionFromShakeMenu());
            assertFalse(plugin.hasActivePreviewSession());
            assertTrue(updater.previewSession);
            assertEquals(1, updater.stagePreviewFallbackReloadCalls);
            assertEquals("fallback-id", updater.stagedPreviewFallbackBundle.getId());
            assertTrue(updater.finalizeResetTransitionCalled);
            assertEquals("preview", updater.finalizeResetTransitionPreviousBundleName);
            assertEquals(0, updater.restoreResetStateCalls);
            assertNull(updater.lastPreviewFallbackBundle);
            assertTrue(updater.setPreviewFallbackBundleCalls > 0);
        }
    }

    @Test
    public void testPreviewMenuListsStoredPreviewsAndCleansMissingBundles() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final TestableCapacitorUpdaterPlugin plugin = new TestableCapacitorUpdaterPlugin();
            final ResetTrackingCapgoUpdater updater = new ResetTrackingCapgoUpdater();
            final SharedPreferences prefs = mock(SharedPreferences.class);
            final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
            final String previewsKey = "CapacitorUpdater.previewSessions";
            final BundleInfo current = new BundleInfo("preview-current", "2.0.0", BundleStatus.SUCCESS, new Date(), "current");
            final BundleInfo other = new BundleInfo("preview-other", "1.5.0", BundleStatus.SUCCESS, new Date(), "other");
            final String sessions = new JSONObject()
                .put(
                    "preview-current",
                    new JSONObject()
                        .put("name", "Current preview")
                        .put("source", "qr")
                        .put("createdAt", "2026-01-01T00:00:00.000Z")
                        .put("updatedAt", "2026-01-02T00:00:00.000Z")
                        .put("lastUsedAt", "2026-01-03T00:00:00.000Z")
                )
                .put(
                    "preview-other",
                    new JSONObject()
                        .put("name", "Other preview")
                        .put("createdAt", "2026-01-01T00:00:00.000Z")
                        .put("updatedAt", "2026-01-01T00:00:00.000Z")
                        .put("lastUsedAt", "2026-01-02T00:00:00.000Z")
                )
                .put("missing-preview", new JSONObject().put("name", "Missing preview").put("lastUsedAt", "2026-01-04T00:00:00.000Z"))
                .toString();

            updater.currentBundle = current;
            updater.listedBundles.add(current);
            updater.listedBundles.add(other);
            plugin.implementation = updater;
            plugin.previewSessionEnabled = true;
            plugin.setLoggerForTesting(mock(Logger.class));
            setPrivateField(plugin, "prefs", prefs);
            setPrivateField(plugin, "editor", editor);

            when(prefs.getString(eq(previewsKey), nullable(String.class))).thenReturn(sessions);
            when(editor.putString(eq(previewsKey), anyString())).thenReturn(editor);

            final JSArray previews = plugin.previewMenuPreviews();

            assertEquals(2, previews.length());
            final JSONObject first = previews.getJSONObject(0);
            assertEquals("preview-current", first.getString("id"));
            assertEquals("Current preview", first.getString("name"));
            assertEquals("qr", first.getString("source"));
            assertTrue(first.getBoolean("isActive"));

            final JSONObject second = previews.getJSONObject(1);
            assertEquals("preview-other", second.getString("id"));
            assertFalse(second.getBoolean("isActive"));

            final ArgumentCaptor<String> cleanedSessions = ArgumentCaptor.forClass(String.class);
            verify(editor).putString(eq(previewsKey), cleanedSessions.capture());
            assertFalse(new JSONObject(cleanedSessions.getValue()).has("missing-preview"));
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
    public void testOnlyDownloadModeDownloadsWithoutSchedulingOrDirectUpdate() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final FreshDownloadCapgoUpdater updater = configureOnlyDownloadBackgroundDownload(plugin);

            plugin.implementation.directUpdate = true;
            updater.directUpdateStateSupplier = () -> Boolean.TRUE.equals(plugin.implementation.directUpdate);

            assertFalse(plugin.shouldUseDirectUpdateForTesting());

            invokeBackgroundDownload(plugin);

            assertTrue(updater.downloadBackgroundCalled);
            assertFalse(updater.downloadBackgroundSetNext);
            assertFalse(updater.setNextBundleCalled);
            assertNull(updater.lastSetNextBundleId);
            assertFalse(updater.directUpdateWhenDownloadStarted);
            assertFalse(plugin.implementation.directUpdate);
            assertTrue(plugin.hasNotifiedEvent("updateAvailable"));
        }
    }

    @Test
    public void testOnlyDownloadModeDoesNotScheduleExistingDownloadedBundle() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final FreshDownloadCapgoUpdater updater = configureOnlyDownloadBackgroundDownload(plugin);
            updater.existingLatestBundle = new BundleInfo("downloaded-id", "2.0.0", BundleStatus.PENDING, new Date(), "checksum");

            invokeBackgroundDownload(plugin);

            assertFalse(updater.downloadBackgroundCalled);
            assertFalse(updater.setNextBundleCalled);
            assertNull(updater.lastSetNextBundleId);
            assertTrue(plugin.hasNotifiedEvent("updateAvailable"));
            assertFalse(plugin.hasNotifiedEvent("noNeedUpdate"));

            final JSObject completionPayload = plugin.getNotifiedEventPayload("appReady");
            final JSONObject completionBundle = completionPayload.getJSONObject("bundle");
            assertEquals(updater.currentBundle.getId(), completionBundle.getString("id"));
        }
    }

    @Test
    public void testOnlyDownloadModeBuiltinNotifiesUpdateAvailableWithoutScheduling() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final BuiltinLatestCapgoUpdater updater = new BuiltinLatestCapgoUpdater();

            plugin.implementation = updater;
            plugin.setAutoUpdateModeForTesting("onlyDownload");
            plugin.setLoggerForTesting(mock(Logger.class));

            assertFalse(plugin.shouldUseDirectUpdateForTesting());

            invokeBackgroundDownload(plugin);

            assertFalse(updater.setNextBundleCalled);
            assertNull(updater.lastSetNextBundleId);
            assertTrue(plugin.hasNotifiedEvent("updateAvailable"));

            final JSObject updatePayload = plugin.getNotifiedEventPayload("updateAvailable");
            final JSONObject updateBundle = updatePayload.getJSONObject("bundle");
            assertEquals(BundleInfo.ID_BUILTIN, updateBundle.getString("id"));
            assertFalse(plugin.hasNotifiedEvent("noNeedUpdate"));
        }
    }

    @Test
    public void testOnlyDownloadModeBuiltinDoesNotNotifyWhenBuiltinIsCurrent() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            final ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            final BundleInfo current = new BundleInfo(
                BundleInfo.ID_BUILTIN,
                "builtin",
                BundleStatus.SUCCESS,
                BundleInfo.DOWNLOADED_BUILTIN,
                "builtin"
            );
            final BuiltinLatestCapgoUpdater updater = new BuiltinLatestCapgoUpdater(current);

            plugin.implementation = updater;
            plugin.setAutoUpdateModeForTesting("onlyDownload");
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertFalse(updater.setNextBundleCalled);
            assertNull(updater.lastSetNextBundleId);
            assertFalse(plugin.hasNotifiedEvent("updateAvailable"));
            assertTrue(plugin.hasNotifiedEvent("noNeedUpdate"));
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
    public void testBreakingNoUrlUpdateCheckNotifiesBreakingListeners() throws Exception {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            BreakingNoUrlCapgoUpdater updater = new BreakingNoUrlCapgoUpdater();

            plugin.implementation = updater;
            plugin.setLoggerForTesting(mock(Logger.class));

            invokeBackgroundDownload(plugin);

            assertTrue(plugin.hasNotifiedEvent("breakingAvailable"));
            assertTrue(plugin.hasNotifiedEvent("majorAvailable"));
            assertEquals("1.0.17", plugin.getNotifiedEventPayload("breakingAvailable").getString("version"));
            assertEquals("1.0.17", plugin.getNotifiedEventPayload("majorAvailable").getString("version"));
            assertTrue(plugin.hasNotifiedEvent("downloadFailed"));
            assertTrue(updater.downloadFailStatsCalled);
        }
    }

    @Test
    public void testGetLatestBreakingResponseNotifiesBreakingListeners() {
        try (
            MockedStatic<Looper> looperMock = mockStatic(Looper.class);
            MockedConstruction<Handler> ignored = mockConstruction(Handler.class)
        ) {
            looperMock.when(Looper::getMainLooper).thenReturn(mock(Looper.class));

            ImmediateThreadCapacitorUpdaterPlugin plugin = new ImmediateThreadCapacitorUpdaterPlugin();
            PluginCall call = mock(PluginCall.class);

            plugin.implementation = new BreakingNoUrlCapgoUpdater();
            plugin.setLoggerForTesting(mock(Logger.class));

            plugin.getLatest(call);

            assertTrue(plugin.hasNotifiedEvent("breakingAvailable"));
            assertTrue(plugin.hasNotifiedEvent("majorAvailable"));
            assertEquals("1.0.17", plugin.getNotifiedEventPayload("breakingAvailable").getString("version"));
            assertEquals("1.0.17", plugin.getNotifiedEventPayload("majorAvailable").getString("version"));
            verify(call).reject("store_update_required");
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
            assertEquals(0, updater.setCalls);
            assertEquals(1, updater.stagePendingReloadCalls);
            assertEquals(1, updater.finalizePendingReloadCalls);
            assertSame(latest, updater.finalizedPendingReloadBundle);
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
    public void testZipEntryRejectsSiblingPrefixPathTraversal() throws Exception {
        final Path documentsDir = Files.createTempDirectory("capgo-zip-path");
        documentsDir.toFile().deleteOnExit();
        final Path zipPath = createZipWithEntry("../bundle-evil/pwned.txt");
        final Path escapedPath = documentsDir.resolve("bundle-evil").resolve("pwned.txt");

        final CapgoUpdater updater = new StatsIgnoringCapgoUpdater();
        updater.documentsDir = documentsDir.toFile();

        assertThrows(IOException.class, () -> invokeUnzip(updater, "bundle-id", zipPath, "bundle"));
        assertFalse(Files.exists(escapedPath));
    }

    @Test
    public void testManifestTargetRejectsPathTraversalAfterBrotliSuffixIsRemoved() throws Exception {
        final Path documentsDir = Files.createTempDirectory("capgo-manifest-path");
        documentsDir.toFile().deleteOnExit();
        final Path destFolder = documentsDir.resolve("bundle");
        Files.createDirectories(destFolder);

        assertThrows(IOException.class, () -> DownloadService.resolveManifestTargetFile(destFolder.toFile(), "../bundle-evil/app.js.br"));
        assertFalse(Files.exists(documentsDir.resolve("bundle-evil")));
    }

    @Test
    public void testManifestTargetAllowsNestedBrotliFileInsideBundle() throws Exception {
        final Path documentsDir = Files.createTempDirectory("capgo-manifest-valid");
        documentsDir.toFile().deleteOnExit();
        final Path destFolder = documentsDir.resolve("bundle");
        Files.createDirectories(destFolder);

        final File resolved = DownloadService.resolveManifestTargetFile(destFolder.toFile(), "assets/app.js.br");

        assertEquals(destFolder.resolve("assets").resolve("app.js").toFile().getCanonicalFile(), resolved);
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

    @Test
    public void persistDefaultChannelFromResponseStoresServerChannel() {
        final CapgoUpdater updater = new CapgoUpdater(mock(Logger.class));
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
        when(editor.putString("CapacitorUpdater.defaultChannel", "company-a")).thenReturn(editor);

        updater.persistDefaultChannelFromResponse(" company-a ", editor, "CapacitorUpdater.defaultChannel");

        assertEquals("company-a", updater.defaultChannel);
        verify(editor).putString("CapacitorUpdater.defaultChannel", "company-a");
        verify(editor).apply();
    }

    @Test
    public void persistDefaultChannelFromResponseIgnoresBuiltinVersionName() {
        final CapgoUpdater updater = new CapgoUpdater(mock(Logger.class));
        final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
        updater.defaultChannel = "stable";

        updater.persistDefaultChannelFromResponse("builtin", editor, "CapacitorUpdater.defaultChannel");

        assertEquals("stable", updater.defaultChannel);
        verify(editor, never()).putString(anyString(), anyString());
        verify(editor, never()).apply();
    }

    @Test
    public void installSourceForInstallerPackageMapsKnownStores() {
        assertEquals("google_play", CapgoUpdater.installSourceForInstallerPackage("com.android.vending"));
        assertEquals("amazon_appstore", CapgoUpdater.installSourceForInstallerPackage("com.amazon.venezia"));
        assertEquals("samsung_galaxy_store", CapgoUpdater.installSourceForInstallerPackage("com.sec.android.app.samsungapps"));
        assertEquals("huawei_appgallery", CapgoUpdater.installSourceForInstallerPackage("com.huawei.appmarket"));
    }

    @Test
    public void installSourceForInstallerPackageHandlesUnknownAndMissingInstallers() {
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage(null));
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage(" "));
        assertEquals("", CapgoUpdater.installSourceForInstallerPackage("com.example.sideload"));
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

    @Test
    public void normalizeShakeMenuGestureSupportsThreeFingerPinch() {
        assertEquals(CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_SHAKE, CapacitorUpdaterPlugin.normalizedShakeMenuGesture(null));
        assertEquals(CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_SHAKE, CapacitorUpdaterPlugin.normalizedShakeMenuGesture("shake"));
        assertEquals(CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_SHAKE, CapacitorUpdaterPlugin.normalizedShakeMenuGesture("unknown"));
        assertEquals(
            CapacitorUpdaterPlugin.SHAKE_MENU_GESTURE_THREE_FINGER_PINCH,
            CapacitorUpdaterPlugin.normalizedShakeMenuGesture("threeFingerPinch")
        );
        assertTrue(CapacitorUpdaterPlugin.isSupportedShakeMenuGesture("shake"));
        assertTrue(CapacitorUpdaterPlugin.isSupportedShakeMenuGesture("threeFingerPinch"));
        assertFalse(CapacitorUpdaterPlugin.isSupportedShakeMenuGesture(" "));
        assertFalse(CapacitorUpdaterPlugin.isSupportedShakeMenuGesture("pinch"));
    }
}
