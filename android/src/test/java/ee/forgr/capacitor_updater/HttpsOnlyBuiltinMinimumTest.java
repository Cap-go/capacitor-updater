package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import okhttp3.Interceptor;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** httpsOnly and builtinMinimum download gates. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class HttpsOnlyBuiltinMinimumTest {

    @After
    public void tearDown() {
        DownloadService.setHttpsOnly(false);
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
    public void gatesAreOffByDefault() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        assertFalse(updater.httpsOnly);
        assertFalse(updater.builtinMinimum);
        assertFalse(DownloadService.httpsOnly);
        updater.versionBuild = "2.0.0";
        updater.runPreDownloadSecurityGates("http://example.com/a.zip", "1.0.0", null);
        assertTrue(updater.stats.isEmpty());
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
