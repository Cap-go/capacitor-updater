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

import android.content.SharedPreferences;
import com.getcapacitor.PluginConfig;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class HeadlessUpdateTest {

    @After
    public void resetInstanceFlag() {
        CapacitorUpdaterPlugin.instanceLoaded = false;
    }

    private static PluginConfig config(final String autoUpdate, final boolean autoUpdateBool, final String directUpdate) throws Exception {
        final PluginConfig config = mock(PluginConfig.class);
        when(config.getString("autoUpdate", null)).thenReturn(autoUpdate);
        when(config.getBoolean("autoUpdate", true)).thenReturn(autoUpdateBool);
        final JSONObject raw = new JSONObject();
        if (directUpdate != null) {
            raw.put("directUpdate", directUpdate);
        }
        when(config.getConfigJSON()).thenReturn(raw);
        return config;
    }

    @Test
    public void autoUpdateModeMatchesThePluginConfig() throws Exception {
        assertEquals("onlyDownload", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("onlyDownload", true, null), null));
        assertEquals("off", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("false", true, null), null));
        assertEquals("atBackground", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, true, null), null));
        assertEquals("atInstall", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("atInstall", true, null), null));
        assertEquals("off", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, false, null), null));
    }

    @Test
    public void removedDirectUpdateConfigIsIgnoredWithAnError() throws Exception {
        final Logger logger = mock(Logger.class);
        assertEquals("atBackground", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config(null, true, "atInstall"), logger));
        verify(logger).error(CapacitorUpdaterPlugin.REMOVED_DIRECT_UPDATE_CONFIG_MESSAGE);

        final Logger quietLogger = mock(Logger.class);
        assertEquals("always", CapacitorUpdaterPlugin.autoUpdateModeFromConfig(config("always", true, null), quietLogger));
        verify(quietLogger, never()).error(CapacitorUpdaterPlugin.REMOVED_DIRECT_UPDATE_CONFIG_MESSAGE);
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
}
