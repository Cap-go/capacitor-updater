package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class WebsiteModeUpdaterTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private static final class MemoryStore implements WebsiteModeUpdater.Store {

        final Map<String, Object> values = new HashMap<>();

        @Override
        public String getString(String key, String fallback) {
            final Object v = values.get(key);
            return v instanceof String ? (String) v : fallback;
        }

        @Override
        public long getLong(String key, long fallback) {
            final Object v = values.get(key);
            return v instanceof Long ? (Long) v : fallback;
        }

        @Override
        public void putString(String key, String value) {
            values.put(key, value);
        }

        @Override
        public void putLong(String key, long value) {
            values.put(key, value);
        }
    }

    private static final class FakeSite implements WebsiteModeUpdater.Fetcher {

        final Map<String, WebsiteModeUpdater.FetchResponse> responses = new HashMap<>();
        final List<String> requested = new ArrayList<>();

        void put(String url, String body, String contentType) {
            responses.put(url, new WebsiteModeUpdater.FetchResponse(200, body.getBytes(StandardCharsets.UTF_8), contentType));
        }

        @Override
        public WebsiteModeUpdater.FetchResponse fetch(URL url) {
            requested.add(url.toString());
            final WebsiteModeUpdater.FetchResponse response = responses.get(url.toString());
            return response != null ? response : new WebsiteModeUpdater.FetchResponse(404, new byte[0], "text/plain");
        }
    }

    private static List<String> urls(List<WebsiteModeUpdater.Asset> assets) {
        final List<String> result = new ArrayList<>();
        for (WebsiteModeUpdater.Asset asset : assets) {
            result.add(asset.url.toString());
        }
        return result;
    }

    // ---- Response parsing ----

    @Test
    public void parsesAllowedWebsiteResponse() {
        final WebsiteModeUpdater.LiveResponse res = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":true,\"mode\":\"website\",\"website_url\":\"https://app.example.com/\",\"check_interval_seconds\":600,\"extra\":1}"
        );
        assertNotNull(res);
        assertTrue(res.allowed);
        assertTrue(res.isWebsiteUpdateAllowed());
        assertFalse(res.isCapgoMode());
        assertEquals("https://app.example.com/", res.websiteUrl);
        assertEquals("", res.downloadBaseUrl);
        assertEquals(600L, res.checkIntervalSeconds);
    }

    @Test
    public void parsesDeniedAndCapgoResponses() {
        final WebsiteModeUpdater.LiveResponse upgrade = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":false,\"mode\":\"website\",\"reason\":\"need_plan_upgrade\"}"
        );
        assertNotNull(upgrade);
        assertFalse(upgrade.isWebsiteUpdateAllowed());
        assertEquals("need_plan_upgrade", upgrade.reason);

        final WebsiteModeUpdater.LiveResponse capgo = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":false,\"mode\":\"capgo\",\"reason\":\"full_capgo\"}"
        );
        assertNotNull(capgo);
        assertTrue(capgo.isCapgoMode());
        assertFalse(capgo.isWebsiteUpdateAllowed());

        final WebsiteModeUpdater.LiveResponse notFound = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":false,\"reason\":\"app_not_found\"}"
        );
        assertNotNull(notFound);
        assertFalse(notFound.isCapgoMode());
        assertFalse(notFound.isWebsiteUpdateAllowed());
    }

    @Test
    public void parsesDownloadBaseUrlAndClampsInterval() {
        final WebsiteModeUpdater.LiveResponse res = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":true,\"mode\":\"website\",\"website_url\":\"https://app.example.com/\",\"download_base_url\":\"https://cdn.example.com/site\",\"check_interval_seconds\":99999999}"
        );
        assertNotNull(res);
        assertEquals("https://cdn.example.com/site", res.downloadBaseUrl);
        assertEquals(WebsiteModeUpdater.MAX_CHECK_INTERVAL_SECONDS, res.checkIntervalSeconds);
    }

    @Test
    public void rejectsInvalidOrInsecureResponses() {
        assertNull(WebsiteModeUpdater.LiveResponse.parse("not json"));
        assertNull(WebsiteModeUpdater.LiveResponse.parse(""));
        final WebsiteModeUpdater.LiveResponse http = WebsiteModeUpdater.LiveResponse.parse(
            "{\"allowed\":true,\"mode\":\"website\",\"website_url\":\"http://app.example.com/\"}"
        );
        assertNotNull(http);
        assertFalse(http.isWebsiteUpdateAllowed());
    }

    @Test
    public void liveCheckUrlOnlySendsAppId() {
        assertEquals(
            "https://plugin.capgo.app/website_live?app_id=com.example.app",
            WebsiteModeUpdater.buildLiveCheckUrl(WebsiteModeUpdater.DEFAULT_WEBSITE_LIVE_URL, "com.example.app")
        );
        assertNull(WebsiteModeUpdater.buildLiveCheckUrl("not a url", "com.example.app"));
        assertNull(WebsiteModeUpdater.buildLiveCheckUrl("http://plugin.example.com/website_live", "com.example.app"));
        assertEquals(
            "http://localhost:8788/website_live?app_id=com.example.app",
            WebsiteModeUpdater.buildLiveCheckUrl("http://localhost:8788/website_live", "com.example.app")
        );
    }

    @Test
    public void requiresWebsiteServedFromRoot() throws Exception {
        assertTrue(WebsiteModeUpdater.isRootWebsiteUrl(new java.net.URL("https://app.example.com")));
        assertTrue(WebsiteModeUpdater.isRootWebsiteUrl(new java.net.URL("https://app.example.com/")));
        assertTrue(WebsiteModeUpdater.isRootWebsiteUrl(new java.net.URL("https://app.example.com/index.html")));
        assertFalse(WebsiteModeUpdater.isRootWebsiteUrl(new java.net.URL("https://example.com/app/")));
    }

    @Test
    public void comparesOrigins() throws Exception {
        assertTrue(
            WebsiteModeUpdater.isSameOrigin(new java.net.URL("https://a.example.com/x"), new java.net.URL("https://A.example.com:443/y"))
        );
        assertFalse(
            WebsiteModeUpdater.isSameOrigin(new java.net.URL("https://a.example.com/x"), new java.net.URL("https://evil.example.com/x"))
        );
        assertFalse(
            WebsiteModeUpdater.isSameOrigin(new java.net.URL("https://a.example.com/x"), new java.net.URL("http://a.example.com/x"))
        );
    }

    // ---- Version id ----

    @Test
    public void versionIdIsDeterministicSha256Prefix() {
        final byte[] html = "<html></html>".getBytes(StandardCharsets.UTF_8);
        final String version = WebsiteModeUpdater.versionForEntryHtml(html);
        assertEquals("web-" + WebsiteModeUpdater.sha256Hex(html).substring(0, 12), version);
        assertEquals(16, version.length());
        assertEquals(version, WebsiteModeUpdater.versionForEntryHtml(html.clone()));
        assertFalse(version.equals(WebsiteModeUpdater.versionForEntryHtml("<html> </html>".getBytes(StandardCharsets.UTF_8))));
        assertEquals("web-e3b0c44298fc", WebsiteModeUpdater.versionForEntryHtml(new byte[0]));
    }

    // ---- Asset discovery ----

    @Test
    public void discoversSameOriginMarkupAssets() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final String html =
            "<script type=module src=\"/assets/index-abc.js\"></script>" +
            "<link rel=stylesheet href='/assets/index-abc.css'>" +
            "<img srcset=\"/img/a.png 1x, /img/b.png 2x\">" +
            "<script src=\"https://cdn.other.com/x.js\"></script>" +
            "<a href=\"#top\"></a><img src=\"data:image/png;base64,AA\">";
        final List<WebsiteModeUpdater.Asset> assets = WebsiteModeUpdater.discoverMarkupAssets(html, root, root, true);
        final List<String> found = urls(assets);
        assertTrue(found.contains("https://app.example.com/assets/index-abc.js"));
        assertTrue(found.contains("https://app.example.com/assets/index-abc.css"));
        assertTrue(found.contains("https://app.example.com/img/a.png"));
        assertTrue(found.contains("https://app.example.com/img/b.png"));
        assertFalse(found.contains("https://cdn.other.com/x.js"));
        for (WebsiteModeUpdater.Asset asset : assets) {
            final boolean code = asset.url.getPath().endsWith(".js") || asset.url.getPath().endsWith(".css");
            assertEquals(code, asset.required);
        }
    }

    @Test
    public void discoversCssUrlsRelativeToStylesheet() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final URL css = new URL("https://app.example.com/assets/index.css");
        final String text = "@import \"theme.css\"; .a{background:url(../img/bg.png)} .b{src:url('/fonts/x.woff2?v=1#iefix')}";
        final List<String> found = urls(WebsiteModeUpdater.discoverMarkupAssets(text, css, root, false));
        assertTrue(found.contains("https://app.example.com/assets/theme.css"));
        assertTrue(found.contains("https://app.example.com/img/bg.png"));
        assertTrue(found.contains("https://app.example.com/fonts/x.woff2?v=1"));
    }

    @Test
    public void discoversJavaScriptChunksModuleAndBaseRelative() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final URL js = new URL("https://app.example.com/assets/index.js");
        final String text = "import(\"./About-1.js\");const m=[\"assets/Home-2.js\",\"assets/Home-2.css\"];fetch('/data/x.json')";
        final List<String> found = urls(WebsiteModeUpdater.discoverJavaScriptAssets(text, js, root));
        assertTrue(found.contains("https://app.example.com/assets/About-1.js"));
        assertTrue(found.contains("https://app.example.com/assets/Home-2.js"));
        assertTrue(found.contains("https://app.example.com/assets/assets/Home-2.js"));
        assertTrue(found.contains("https://app.example.com/data/x.json"));
    }

    @Test
    public void localPathRejectsTraversal() throws Exception {
        assertEquals("index.html", WebsiteModeUpdater.localPath(new URL("https://app.example.com/")));
        assertEquals("docs/index.html", WebsiteModeUpdater.localPath(new URL("https://app.example.com/docs/")));
        assertEquals("assets/a b.js", WebsiteModeUpdater.localPath(new URL("https://app.example.com/assets/a%20b.js?x=1")));
        assertThrows(IOException.class, () -> WebsiteModeUpdater.localPath(new URL("https://app.example.com/a/%2e%2e/b.js")));
        assertThrows(IOException.class, () -> WebsiteModeUpdater.localPath(new URL("https://app.example.com/a/%2Fetc.js")));
    }

    @Test
    public void rebaseKeepsPathOnDownloadBase() throws Exception {
        final URL asset = new URL("https://app.example.com/assets/a.js?v=2");
        assertEquals(asset, WebsiteModeUpdater.rebase(asset, null));
        assertEquals(
            "https://cdn.example.com/site/assets/a.js?v=2",
            WebsiteModeUpdater.rebase(asset, new URL("https://cdn.example.com/site/")).toString()
        );
    }

    // ---- Download ----

    @Test
    public void downloadsWebsiteIntoFolder() throws Exception {
        final FakeSite site = new FakeSite();
        final String html =
            "<html><script type=module src=\"/assets/index.js\"></script><link rel=stylesheet href=\"/assets/index.css\"><link rel=icon href=\"/missing.ico\"></html>";
        site.put("https://app.example.com/assets/index.js", "import('./chunk.js');const d=['assets/chunk.css']", "application/javascript");
        site.put("https://app.example.com/assets/chunk.js", "export const a=1", "text/javascript");
        site.put("https://app.example.com/assets/chunk.css", ".a{}", "text/css");
        site.put("https://app.example.com/assets/index.css", ".b{background:url(./bg.png)}", "text/css");
        site.put("https://app.example.com/assets/bg.png", "PNG", "image/png");

        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final File dir = tmp.newFolder("site");
        final int files = updater.downloadWebsite(html.getBytes(StandardCharsets.UTF_8), new URL("https://app.example.com/"), null, dir);

        assertEquals(6, files);
        assertEquals(html, new String(Files.readAllBytes(new File(dir, "index.html").toPath()), StandardCharsets.UTF_8));
        assertTrue(new File(dir, "assets/index.js").isFile());
        assertTrue(new File(dir, "assets/chunk.js").isFile());
        assertTrue(new File(dir, "assets/chunk.css").isFile());
        assertTrue(new File(dir, "assets/bg.png").isFile());
        assertFalse(new File(dir, "missing.ico").exists());
    }

    @Test
    public void downloadFailsWhenRequiredScriptIsMissing() throws Exception {
        final FakeSite site = new FakeSite();
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<script src=\"/assets/gone.js\"></script>".getBytes(StandardCharsets.UTF_8);
        assertThrows(IOException.class, () ->
            updater.downloadWebsite(html, new URL("https://app.example.com/"), null, tmp.newFolder("broken"))
        );
    }

    @Test
    public void downloadUsesDownloadBaseUrl() throws Exception {
        final FakeSite site = new FakeSite();
        site.put("https://cdn.example.com/v1/assets/index.js", "1", "application/javascript");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<script src=\"/assets/index.js\"></script>".getBytes(StandardCharsets.UTF_8);
        final File dir = tmp.newFolder("cdn");
        updater.downloadWebsite(html, new URL("https://app.example.com/"), new URL("https://cdn.example.com/v1"), dir);
        assertTrue(new File(dir, "assets/index.js").isFile());
        assertTrue(site.requested.contains("https://cdn.example.com/v1/assets/index.js"));
    }

    @Test
    public void fetchLiveResponseCallsEndpointWithAppId() throws Exception {
        final FakeSite site = new FakeSite();
        site.put(
            "https://plugin.capgo.app/website_live?app_id=com.example.app",
            "{\"allowed\":true,\"mode\":\"website\",\"website_url\":\"https://app.example.com/\"}",
            "application/json"
        );
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        assertTrue(updater.fetchLiveResponse("com.example.app").isWebsiteUpdateAllowed());
        assertThrows(IOException.class, () -> updater.fetchLiveResponse("unknown.app"));
    }

    // ---- State ----

    @Test
    public void throttlesUsingCheckInterval() {
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, new FakeSite(), new MemoryStore());
        assertFalse(updater.isThrottled(1_000L));
        updater.recordCheck(
            1_000L,
            WebsiteModeUpdater.LiveResponse.parse("{\"allowed\":true,\"mode\":\"website\",\"check_interval_seconds\":600}")
        );
        assertTrue(updater.isThrottled(1_000L + 599_000L));
        assertFalse(updater.isThrottled(1_000L + 600_000L));
        assertFalse(updater.isThrottled(500L));
        assertFalse(updater.lastKnownModeIsCapgo());
        updater.recordCheck(2_000L, WebsiteModeUpdater.LiveResponse.parse("{\"allowed\":false,\"mode\":\"capgo\"}"));
        assertFalse(updater.isThrottled(2_001L));
        assertTrue(updater.lastKnownModeIsCapgo());
    }

    @Test
    public void remembersFailedWebsiteVersions() {
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, new FakeSite(), new MemoryStore());
        updater.markFailedVersion("web-aaaaaaaaaaaa");
        updater.markFailedVersion("1.0.0");
        assertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa"));
        assertFalse(updater.isFailedVersion("1.0.0"));
        for (int i = 0; i < WebsiteModeUpdater.MAX_FAILED_VERSIONS + 5; i++) {
            updater.markFailedVersion(String.format("web-%012d", i));
        }
        assertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa"));
        assertTrue(updater.isFailedVersion(String.format("web-%012d", WebsiteModeUpdater.MAX_FAILED_VERSIONS + 4)));
    }
}
