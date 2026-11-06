package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.Context;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import okhttp3.Interceptor;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/** httpsOnly download gates and builtinMinimum download and activation gates. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class HttpsOnlyBuiltinMinimumTest {

    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @After
    public void tearDown() {
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(false);
    }

    private static final class StatsCapturingUpdater extends CapgoUpdater {

        final List<String> stats = new ArrayList<>();

        StatsCapturingUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void sendStats(final String action, final String versionName) {
            this.stats.add(action + ":" + versionName);
        }
    }

    // --- defaults ---

    @Test
    public void defaultsAreHttpsOnlyOnAndBuiltinMinimumOn() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        assertTrue(updater.httpsOnly);
        assertTrue(updater.builtinMinimum);
        assertTrue(DownloadService.httpsOnly);
        updater.versionBuild = "2.0.0";
        updater.runPreDownloadSecurityGates("https://example.com/a.zip", "2.0.0", null);
        assertThrows(IOException.class, () -> updater.runPreDownloadSecurityGates("https://example.com/a.zip", "1.0.0", null));
        assertThrows(IOException.class, () -> updater.runPreDownloadSecurityGates("http://example.com/a.zip", "3.0.0", null));
        assertEquals(List.of("version_below_native:1.0.0"), updater.stats);
    }

    // --- builtinMinimum ---

    @Test
    public void builtinMinimumAcceptsEqualOrHigher() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.builtinMinimum = true;
        updater.versionBuild = "1.2.3";
        updater.requireVersionNotBelowBuiltin("1.2.3");
        updater.requireVersionNotBelowBuiltin("1.2.4");
        updater.requireVersionNotBelowBuiltin("2.0.0-beta.1");
        // Prerelease at the native version is not a rollback: only major.minor.patch are compared.
        updater.requireVersionNotBelowBuiltin("1.2.3-beta.1");
        // Fourth components and build metadata are ignored.
        updater.versionBuild = "1.2.3.4";
        updater.requireVersionNotBelowBuiltin("1.2.3.3");
        updater.requireVersionNotBelowBuiltin("1.2.3+build.42");
        assertTrue(updater.stats.isEmpty());
        updater.versionBuild = "2.0.0";
        assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("1.9.9+build.42"));
    }

    @Test
    public void builtinMinimumRejectsLower() {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.builtinMinimum = true;
        updater.versionBuild = "1.2.3";
        IOException error = assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("1.2.2"));
        assertEquals("Bundle version 1.2.2 is below native version 1.2.3 (builtinMinimum)", error.getMessage());
        assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("0.9.0"));
        assertEquals(List.of("version_below_native:1.2.2", "version_below_native:0.9.0"), updater.stats);
    }

    @Test
    public void builtinMinimumSkipsUnparseableAndDisabled() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.builtinMinimum = true;
        updater.versionBuild = "1.2.3";
        updater.requireVersionNotBelowBuiltin("builtin");
        updater.requireVersionNotBelowBuiltin("");
        updater.requireVersionNotBelowBuiltin(null);
        updater.versionBuild = "";
        updater.requireVersionNotBelowBuiltin("0.0.1");
        updater.versionBuild = "dev-build";
        updater.requireVersionNotBelowBuiltin("0.0.1");
        updater.versionBuild = "1.2.3";
        updater.builtinMinimum = false;
        updater.requireVersionNotBelowBuiltin("0.0.1");
        assertTrue(updater.stats.isEmpty());
    }

    /** Creates isolated persistent updater state with the native version already upgraded to 2.0.0. */
    private StatsCapturingUpdater activationUpdater() throws IOException {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.documentsDir = this.temporaryFolder.newFolder();
        updater.CAP_SERVER_PATH = "server-path";
        updater.prefs = RuntimeEnvironment.getApplication().getSharedPreferences("activation-floor", Context.MODE_PRIVATE);
        updater.prefs.edit().clear().commit();
        updater.editor = updater.prefs.edit();
        updater.statsUrl = "";
        updater.versionBuild = "2.0.0";
        return updater;
    }

    /** Installs a real on-disk bundle and its metadata as if it survived a native upgrade. */
    private BundleInfo retainedBundle(final CapgoUpdater updater, final String id, final String version) throws IOException {
        File directory = CapgoUpdater.resolveBundleDirectory(updater.documentsDir, id);
        assertTrue(directory.mkdirs());
        Files.write(new File(directory, "index.html").toPath(), "<html></html>".getBytes(StandardCharsets.UTF_8));
        BundleInfo bundle = new BundleInfo(id, version, BundleStatus.SUCCESS, new Date(), "checksum");
        assertTrue(updater.saveBundleInfo(id, bundle));
        return bundle;
    }

    /** Rejecting manual activation leaves the running bundle, queued bundle, and queued metadata unchanged. */
    @Test
    public void manualSetRejectsRetainedOlderBundleWithoutChangingState() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo current = retainedBundle(updater, "current001", "3.0.0");
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");
        assertTrue(updater.set(current));
        assertTrue(updater.setNextBundle(retained.getId()));
        String pendingInfo = updater.prefs.getString(retained.getId() + "_info", "");

        updater.autoReset("new-native-build", false);
        assertFalse(updater.set(retained.getId()));

        assertEquals(current.getId(), updater.getCurrentBundle().getId());
        assertEquals(retained.getId(), updater.getNextBundle().getId());
        assertEquals(pendingInfo, updater.prefs.getString(retained.getId() + "_info", ""));
        assertEquals(List.of("version_below_native:1.9.9"), updater.stats);
    }

    /** Both activation overloads still install compatible retained bundles. */
    @Test
    public void manualSetAcceptsEqualAndNewerStoredBundles() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo equal = retainedBundle(updater, "equal00001", "2.0.0");
        BundleInfo newer = retainedBundle(updater, "newer00001", "2.1.0");

        assertTrue(updater.set(equal));
        assertEquals(equal.getId(), updater.getCurrentBundle().getId());
        assertTrue(updater.set(newer.getId()));
        assertEquals(newer.getId(), updater.getCurrentBundle().getId());
    }

    /** Apps can deliberately allow native-version downgrades with builtinMinimum disabled. */
    @Test
    public void manualSetAllowsOlderBundleWhenBuiltinMinimumIsDisabled() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");
        updater.builtinMinimum = false;

        assertTrue(updater.set(retained));
        assertEquals(retained.getId(), updater.getCurrentBundle().getId());
        assertTrue(updater.stats.isEmpty());
    }

    /** A rejected pending bundle cannot prevent the user from clearing it by resetting to builtin. */
    @Test
    public void builtinResetRemainsAvailableAfterRejectingAnOlderBundle() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo current = retainedBundle(updater, "current001", "3.0.0");
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");
        assertTrue(updater.set(current));
        assertTrue(updater.setNextBundle(retained.getId()));
        assertFalse(updater.set(retained));

        assertTrue(updater.set(BundleInfo.ID_BUILTIN));

        assertTrue(updater.getCurrentBundle().isBuiltin());
        assertNull(updater.getNextBundle());
    }

    /** Reload rejection preserves both the active bundle and the queued retained bundle. */
    @Test
    public void pendingReloadRejectsRetainedOlderBundleWithoutChangingState() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo current = retainedBundle(updater, "current001", "3.0.0");
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");
        assertTrue(updater.set(current));
        assertTrue(updater.setNextBundle(retained.getId()));
        String pendingInfo = updater.prefs.getString(retained.getId() + "_info", "");

        updater.autoReset("new-native-build", false);
        assertFalse(updater.stagePendingReload(updater.getNextBundle()));

        assertEquals(current.getId(), updater.getCurrentBundle().getId());
        assertEquals(retained.getId(), updater.getNextBundle().getId());
        assertEquals(pendingInfo, updater.prefs.getString(retained.getId() + "_info", ""));
        assertEquals(List.of("version_below_native:1.9.9"), updater.stats);
    }

    /** Pending reload can stage bundles at or above the current native version. */
    @Test
    public void pendingReloadAcceptsEqualAndNewerStoredBundles() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo equal = retainedBundle(updater, "equal00001", "2.0.0");
        BundleInfo newer = retainedBundle(updater, "newer00001", "2.1.0");

        assertTrue(updater.stagePendingReload(equal));
        assertEquals(equal.getId(), updater.getCurrentBundle().getId());
        assertTrue(updater.stagePendingReload(newer));
        assertEquals(newer.getId(), updater.getCurrentBundle().getId());
    }

    /** The configured opt-out applies to pending reload as well as manual activation. */
    @Test
    public void pendingReloadAllowsOlderBundleWhenBuiltinMinimumIsDisabled() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");
        updater.builtinMinimum = false;

        assertTrue(updater.stagePendingReload(retained));
        assertEquals(retained.getId(), updater.getCurrentBundle().getId());
        assertTrue(updater.stats.isEmpty());
    }

    /** Recovery can restore a previously active preview fallback even when it predates the native version. */
    @Test
    public void previewFallbackRecoveryCanRestoreAnOlderStoredBundle() throws IOException {
        StatsCapturingUpdater updater = activationUpdater();
        BundleInfo retained = retainedBundle(updater, "retained01", "1.9.9");

        assertTrue(updater.stagePreviewFallbackReload(retained));
        assertEquals(retained.getId(), updater.getCurrentBundle().getId());
        assertTrue(updater.stats.isEmpty());
    }

    // --- httpsOnly ---

    @Test
    public void updaterRejectsHttpUrlsBeforeNetwork() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.httpsOnly = true;
        IOException error = assertThrows(IOException.class, () -> updater.requireHttpsUrls("http://example.com/a.zip", null));
        assertEquals("httpsOnly is enabled and http://example.com/a.zip is not https", error.getMessage());
        updater.requireHttpsUrls("https://example.com/a.zip", null);
        JSONArray manifest = new JSONArray().put(new JSONObject().put("file_name", "a").put("download_url", "http://cdn.example/a"));
        assertThrows(IOException.class, () -> updater.requireHttpsUrls("https://example.com/a.zip", manifest));
        updater.httpsOnly = false;
        updater.requireHttpsUrls("http://example.com/a.zip", manifest);
        assertTrue(updater.stats.isEmpty());
    }

    private static Response response(String requestUrl, int code, String location) {
        Response.Builder builder = new Response.Builder()
            .request(new Request.Builder().url(requestUrl).build())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("status")
            .body(ResponseBody.create(new byte[0], null));
        if (location != null) {
            builder.header("Location", location);
        }
        return builder.build();
    }

    private static Response runNetworkInterceptor(Response upstream) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(upstream.request());
        when(chain.proceed(any(Request.class))).thenReturn(upstream);
        Interceptor interceptor = DownloadService.sharedClient.networkInterceptors().get(0);
        return interceptor.intercept(chain);
    }

    private static Response runAppInterceptor(Response upstream) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(upstream.request());
        when(chain.proceed(any(Request.class))).thenReturn(upstream);
        Interceptor interceptor = DownloadService.sharedClient.interceptors().get(0);
        return interceptor.intercept(chain);
    }

    @Test
    public void interceptorsRejectHttpWhenHttpsOnly() throws IOException {
        DownloadService.setHttpsOnly(true);
        Response plain = response("http://api.capgo.app/updates", 200, null);
        IOException network = assertThrows(IOException.class, () -> runNetworkInterceptor(plain));
        assertEquals("httpsOnly is enabled and http://api.capgo.app/updates is not https", network.getMessage());
        IOException app = assertThrows(IOException.class, () -> runAppInterceptor(plain));
        assertEquals("httpsOnly is enabled and http://api.capgo.app/updates is not https", app.getMessage());

        Response secure = response("https://api.capgo.app/updates", 200, null);
        assertEquals(secure, runNetworkInterceptor(secure));

        DownloadService.setHttpsOnly(false);
        assertEquals(plain, runNetworkInterceptor(plain));
    }

    @Test
    public void httpsOnlyOverridesAllowHttpsToHttpRedirect() throws IOException {
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(true);
        Response downgrade = response("https://api.capgo.app/a", 302, "http://example.com/bundle.zip");
        IOException error = assertThrows(IOException.class, () -> runNetworkInterceptor(downgrade));
        assertEquals("httpsOnly is enabled and http://example.com/bundle.zip is not https", error.getMessage());
    }

    @Test
    public void downloadEntryPointsRejectHttpBeforeAnyWork() {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.httpsOnly = true;
        IOException error = assertThrows(IOException.class, () -> updater.download("http://example.com/a.zip", "1.0.0", "", "abc"));
        assertEquals("httpsOnly is enabled and http://example.com/a.zip is not https", error.getMessage());
        assertThrows(IOException.class, () -> updater.downloadManifest("http://example.com/a.zip", "1.0.0", "", "abc", null));
    }

    @Test
    public void downloadEntryPointsRejectVersionBelowNative() {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.builtinMinimum = true;
        updater.versionBuild = "3.0.0";
        IOException error = assertThrows(IOException.class, () -> updater.download("https://example.com/a.zip", "2.0.0", "", "abc"));
        assertEquals("Bundle version 2.0.0 is below native version 3.0.0 (builtinMinimum)", error.getMessage());
        assertEquals(List.of("version_below_native:2.0.0"), updater.stats);
    }
}
