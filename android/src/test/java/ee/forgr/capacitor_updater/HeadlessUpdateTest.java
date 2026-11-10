package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import com.getcapacitor.PluginConfig;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONArray;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public class HeadlessUpdateTest {

    @After
    public void resetInstanceFlag() {
        CapacitorUpdaterPlugin.instanceLoaded = false;
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(false);
        DownloadService.setLogger(null);
        DownloadWorkerManager.setLogger(null);
    }

    private static PluginConfig config(final String autoUpdate, final boolean autoUpdateBool, final String directUpdate) {
        final PluginConfig config = mock(PluginConfig.class);
        when(config.getString("autoUpdate", null)).thenReturn(autoUpdate);
        when(config.getBoolean("autoUpdate", true)).thenReturn(autoUpdateBool);
        when(config.getString("directUpdate", null)).thenReturn(directUpdate);
        when(config.getBoolean("directUpdate", false)).thenReturn(false);
        return config;
    }

    @Test
    public void autoUpdateModeMatchesThePluginConfig() {
        assertEquals("onlyDownload", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("onlyDownload", true, null), null));
        assertEquals("off", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("false", true, null), null));
        assertEquals("atBackground", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, true, null), null));
        assertEquals("atInstall", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, true, "atInstall"), null));
        assertEquals("off", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, false, null), null));
    }

    private static CapgoUpdater updaterWithDelays(final String delays) {
        final CapgoUpdater updater = mock(CapgoUpdater.class);
        final SharedPreferences prefs = mock(SharedPreferences.class);
        when(prefs.getString(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES, "[]")).thenReturn(delays);
        updater.prefs = prefs;
        return updater;
    }

    @Test
    public void installsTheBundleWhenNoUiRuns() {
        final CapgoUpdater updater = updaterWithDelays("[]");
        final BundleInfo bundle = new BundleInfo("id1", "1.0.1", BundleStatus.PENDING, "", "");
        when(updater.set(bundle)).thenReturn(true);

        assertTrue(HeadlessUpdateWorker.applyIfNoUi(updater, bundle, new Logger("test")));
        verify(updater).setNextBundle(null);
    }

    @Test
    public void keepsTheBundleAsNextWhenThePluginRuns() {
        CapacitorUpdaterPlugin.instanceLoaded = true;
        final CapgoUpdater updater = updaterWithDelays("[]");
        final BundleInfo bundle = new BundleInfo("id1", "1.0.1", BundleStatus.PENDING, "", "");

        assertFalse(HeadlessUpdateWorker.applyIfNoUi(updater, bundle, new Logger("test")));
        verify(updater, never()).set(any(BundleInfo.class));
    }

    @Test
    public void keepsTheBundleAsNextWhenDelayConditionsAreSet() {
        final CapgoUpdater updater = updaterWithDelays("[{\"kind\":\"kill\"}]");
        final BundleInfo bundle = new BundleInfo("id1", "1.0.1", BundleStatus.PENDING, "", "");

        assertFalse(HeadlessUpdateWorker.applyIfNoUi(updater, bundle, new Logger("test")));
        verify(updater, never()).set(any(BundleInfo.class));
    }

    @Test
    public void readsTheManifestFromTheUpdateResponse() throws Exception {
        final Map<String, Object> latest = new HashMap<>();
        assertNull(HeadlessUpdateWorker.manifestOf(latest));
        latest.put("manifest", new JSONArray("[{\"file_name\":\"a.js\"}]"));
        assertEquals(1, HeadlessUpdateWorker.manifestOf(latest).length());
        latest.put("manifest", "[{\"file_name\":\"a.js\"},{\"file_name\":\"b.js\"}]");
        assertEquals(2, HeadlessUpdateWorker.manifestOf(latest).length());
    }

    @Test
    public void detectsAPendingNativeUpdate() {
        final SharedPreferences prefs = mock(SharedPreferences.class);
        when(prefs.getString("LatestNativeBuildVersion", "")).thenReturn("41");
        assertTrue(HeadlessUpdateWorker.nativeBuildChanged(prefs, "42"));
        assertFalse(HeadlessUpdateWorker.nativeBuildChanged(prefs, "41"));

        final SharedPreferences fresh = mock(SharedPreferences.class);
        when(fresh.getString("LatestNativeBuildVersion", "")).thenReturn("");
        when(fresh.getString("LatestVersionNative", "")).thenReturn("");
        assertFalse(HeadlessUpdateWorker.nativeBuildChanged(fresh, "42"));
    }

    @Test
    public void configureMirrorsDownloadSecurityFlagsFromPluginConfig() throws Exception {
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(false);
        final PluginConfig config = mockHeadlessPluginConfig();
        when(config.getBoolean("allowHttpsToHttpRedirect", false)).thenReturn(true);
        when(config.getBoolean("httpsOnly", true)).thenReturn(false);
        when(config.getBoolean("builtinMinimum", false)).thenReturn(true);
        final Logger headlessLogger = new Logger("headless-config-test");
        final CapgoUpdater updater = new CapgoUpdater(headlessLogger);
        invokeHeadlessConfigureWith("headless-config-test", config, headlessLogger, updater);

        assertTrue(updater.builtinMinimum);
        assertFalse(updater.httpsOnly);
        assertFalse(DownloadService.httpsOnly);
        assertTrue(DownloadService.isAllowHttpsToHttpRedirect());
    }

    @Test
    public void builtinMinimumSkipsExistingBundleBelowNativeInHeadlessPath() {
        final CapgoUpdater updater = new CapgoUpdater(new Logger("test"));
        updater.builtinMinimum = true;
        updater.versionBuild = "2.0.0";
        final Logger logger = new Logger("test");
        assertTrue(HeadlessUpdateWorker.builtinMinimumBlocksExistingBundle(updater, "1.0.0", logger));
        assertFalse(HeadlessUpdateWorker.builtinMinimumBlocksExistingBundle(updater, "2.0.0", logger));
    }

    @Test
    public void builtinMinimumBlocksExistingBundleRejectsOversizedCoreBelowNative() {
        final CapgoUpdater updater = new CapgoUpdater(new Logger("test"));
        updater.builtinMinimum = true;
        updater.versionBuild = "2.0.0";
        final Logger logger = new Logger("test");
        assertTrue(HeadlessUpdateWorker.builtinMinimumBlocksExistingBundle(updater, "1.9223372036854775808.0", logger));
        assertFalse(HeadlessUpdateWorker.builtinMinimumBlocksExistingBundle(updater, "9223372036854775808.0.0", logger));
    }

    @Test
    public void configureInitializesDownloadLoggerWhenUnset() throws Exception {
        DownloadService.setLogger(null);
        DownloadWorkerManager.setLogger(null);
        final Logger headlessLogger = new Logger("configure-logger-test");
        invokeHeadlessConfigure("headless-logger-test", headlessLogger);
        org.junit.Assert.assertSame(headlessLogger, DownloadService.getLogger());
        org.junit.Assert.assertSame(headlessLogger, DownloadWorkerManager.getLogger());
    }

    @Test
    public void configureInitializesWorkerManagerLoggerWhenServiceAlreadySet() throws Exception {
        final Logger preset = new Logger("preset-service");
        DownloadService.setLogger(preset);
        DownloadWorkerManager.setLogger(null);
        final Logger headlessLogger = new Logger("configure-partial-logger-test");
        invokeHeadlessConfigure("headless-partial-logger-test", headlessLogger);
        org.junit.Assert.assertSame(preset, DownloadService.getLogger());
        org.junit.Assert.assertSame(headlessLogger, DownloadWorkerManager.getLogger());
    }

    private static void invokeHeadlessConfigure(final String prefsName, final Logger headlessLogger) throws Exception {
        final CapgoUpdater updater = new CapgoUpdater(headlessLogger);
        invokeHeadlessConfigureWith(prefsName, mockHeadlessPluginConfig(), headlessLogger, updater);
    }

    private static void invokeHeadlessConfigureWith(
        final String prefsName,
        final PluginConfig config,
        final Logger headlessLogger,
        final CapgoUpdater updater
    ) throws Exception {
        final Context context = RuntimeEnvironment.getApplication();
        final SharedPreferences prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE);
        final PackageInfo packageInfo = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);

        final Method configure = HeadlessUpdateWorker.class.getDeclaredMethod(
            "configure",
            CapgoUpdater.class,
            Context.class,
            PluginConfig.class,
            SharedPreferences.class,
            PackageInfo.class,
            String.class,
            Logger.class
        );
        configure.setAccessible(true);
        configure.invoke(null, updater, context, config, prefs, packageInfo, "42", headlessLogger);
    }

    private static PluginConfig mockHeadlessPluginConfig() {
        final PluginConfig config = mock(PluginConfig.class);
        when(config.getString("publicKey", "")).thenReturn("");
        when(config.getBoolean("allowHttpsToHttpRedirect", false)).thenReturn(false);
        when(config.getBoolean("httpsOnly", true)).thenReturn(true);
        when(config.getBoolean("builtinMinimum", false)).thenReturn(false);
        when(config.getBoolean("persistModifyUrl", false)).thenReturn(false);
        when(config.getString("statsUrl", CapacitorUpdaterPlugin.statsUrlDefault)).thenReturn(CapacitorUpdaterPlugin.statsUrlDefault);
        when(config.getString("channelUrl", CapacitorUpdaterPlugin.channelUrlDefault)).thenReturn(CapacitorUpdaterPlugin.channelUrlDefault);
        when(config.getString("defaultChannel", "")).thenReturn("");
        when(config.getBoolean("persistCustomId", false)).thenReturn(false);
        when(config.getInt("responseTimeout", 20)).thenReturn(20);
        when(config.getString("version", "2.0.0")).thenReturn("2.0.0");
        when(config.getString("appId", "app")).thenReturn("app");
        return config;
    }
}
