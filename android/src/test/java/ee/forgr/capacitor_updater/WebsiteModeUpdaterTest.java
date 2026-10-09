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
        final Map<String, Boolean> bypassCache = new HashMap<>();
        final Map<String, IOException> errors = new HashMap<>();

        void put(String url, String body, String contentType) {
            put(url, 200, body, contentType);
        }

        void put(String url, int status, String body, String contentType) {
            responses.put(url, new WebsiteModeUpdater.FetchResponse(status, body.getBytes(StandardCharsets.UTF_8), contentType));
        }

        @Override
        public WebsiteModeUpdater.FetchResponse fetch(URL url, boolean bypass) throws IOException {
            requested.add(url.toString());
            bypassCache.put(url.toString(), bypass);
            if (errors.containsKey(url.toString())) {
                throw errors.get(url.toString());
            }
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
    public void floorsCheckIntervalAtFiveMinutes() {
        assertEquals(300L, WebsiteModeUpdater.LiveResponse.parse("{\"allowed\":true,\"mode\":\"website\"}").checkIntervalSeconds);
        assertEquals(
            300L,
            WebsiteModeUpdater.LiveResponse.parse(
                "{\"allowed\":true,\"mode\":\"website\",\"check_interval_seconds\":0}"
            ).checkIntervalSeconds
        );
        assertEquals(
            300L,
            WebsiteModeUpdater.LiveResponse.parse(
                "{\"allowed\":true,\"mode\":\"website\",\"check_interval_seconds\":299}"
            ).checkIntervalSeconds
        );
        assertEquals(
            301L,
            WebsiteModeUpdater.LiveResponse.parse(
                "{\"allowed\":true,\"mode\":\"website\",\"check_interval_seconds\":301}"
            ).checkIntervalSeconds
        );
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
    public void versionIdHashesWebsiteUrlAndEntryHtml() throws Exception {
        final URL site = new URL("https://app.example.com/");
        final byte[] html = "<html></html>".getBytes(StandardCharsets.UTF_8);
        final String version = WebsiteModeUpdater.versionForWebsite(site, html);
        // sha256("https://app.example.com/\n<html></html>"), identical on iOS.
        assertEquals("web-1fa8d47e9e84", version);
        assertEquals(version, WebsiteModeUpdater.versionForWebsite(new URL("HTTPS://App.Example.com:443"), html.clone()));
        assertFalse(version.equals(WebsiteModeUpdater.versionForWebsite(site, "<html> </html>".getBytes(StandardCharsets.UTF_8))));
        assertFalse(version.equals(WebsiteModeUpdater.versionForWebsite(new URL("https://new.example.com/"), html)));
        assertEquals(
            "https://app.example.com:8443/index.html?a=1",
            WebsiteModeUpdater.normalizedWebsiteUrl(new URL("https://APP.example.com:8443/index.html?a=1#x"))
        );
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
            "<a href=\"#top\"></a><a href=\"/about\">About</a><img src=\"data:image/png;base64,AA\">" +
            "<link rel=\"manifest\" href=\"/manifest.webmanifest\"><link href=\"/assets/pre.js\" rel=\"modulepreload\">";
        final List<WebsiteModeUpdater.Asset> assets = WebsiteModeUpdater.discoverMarkupAssets(html, root, root, true);
        final List<String> found = urls(assets);
        assertTrue(found.contains("https://app.example.com/assets/index-abc.js"));
        assertTrue(found.contains("https://app.example.com/assets/index-abc.css"));
        assertTrue(found.contains("https://app.example.com/img/a.png"));
        assertTrue(found.contains("https://app.example.com/img/b.png"));
        assertFalse(found.contains("https://cdn.other.com/x.js"));
        assertFalse(found.contains("https://app.example.com/about"));
        assertTrue(found.contains("https://app.example.com/manifest.webmanifest"));
        assertTrue(found.contains("https://app.example.com/assets/pre.js"));
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
    public void rejectsSchemeDowngradeOnSameHostAndPort() throws Exception {
        final URL root = new URL("https://app.example.com/");
        assertNull(WebsiteModeUpdater.sameOriginUrl("http://app.example.com:443/app.js", root, root));
        assertNull(WebsiteModeUpdater.sameOriginUrl("http://app.example.com/app.js", root, root));
        assertNotNull(WebsiteModeUpdater.sameOriginUrl("https://app.example.com:443/app.js", root, root));
        final List<String> found = urls(
            WebsiteModeUpdater.discoverMarkupAssets("<script src=\"http://app.example.com:443/app.js\"></script>", root, root, true)
        );
        assertTrue(found.isEmpty());
    }

    @Test
    public void marksJavaScriptCodeReferencesRequiredAcrossCandidates() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final URL js = new URL("https://app.example.com/assets/index.js");
        final List<WebsiteModeUpdater.Asset> assets = WebsiteModeUpdater.discoverJavaScriptAssets(
            "const a=[\"./Home-2.js\",\"../x/Abs.css\",\"/assets/Root.mjs\",\"https://app.example.com/assets/Full.js\"," +
                "\"assets/Bare-1.js\",\"pdf.worker.js\",\"src/foo.js\",\"./logo.png\"]",
            js,
            root
        );
        final Map<String, Integer> required = new HashMap<>();
        for (WebsiteModeUpdater.Asset asset : assets) {
            assertFalse(asset.required);
            required.put(asset.url.getPath(), asset.requiredCandidates.size());
        }
        assertEquals(Integer.valueOf(1), required.get("/assets/Home-2.js"));
        assertEquals(Integer.valueOf(1), required.get("/x/Abs.css"));
        assertEquals(Integer.valueOf(1), required.get("/assets/Root.mjs"));
        assertEquals(Integer.valueOf(1), required.get("/assets/Full.js"));
        // Bare names are tried module- and root-relative but stay best effort.
        assertEquals(Integer.valueOf(0), required.get("/assets/assets/Bare-1.js"));
        assertEquals(Integer.valueOf(0), required.get("/assets/Bare-1.js"));
        assertEquals(Integer.valueOf(0), required.get("/assets/pdf.worker.js"));
        assertEquals(Integer.valueOf(0), required.get("/src/foo.js"));
        assertEquals(Integer.valueOf(0), required.get("/assets/logo.png"));
    }

    @Test
    public void neverDiscoversVideoOrAudio() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final String html =
            "<video src=\"/media/intro.mp4\"></video><audio src=\"/a.mp3\"></audio><source src=\"/b.webm\">" +
            "<source src=\"/c.MOV\"><audio src=\"/d.m4a\"></audio><audio src=\"/e.ogg\"></audio><audio src=\"/f.wav\"></audio>" +
            "<img src=\"/g.png\">";
        assertEquals(1, WebsiteModeUpdater.discoverMarkupAssets(html, root, root, true).size());
        final String js = "const v=['./intro.mp4','./a.mp3','./b.webm','./c.mov','./d.m4a','./e.ogg','./f.wav','./g.png']";
        final List<String> found = urls(WebsiteModeUpdater.discoverJavaScriptAssets(js, root, root));
        assertEquals(1, found.size());
        assertEquals("https://app.example.com/g.png", found.get(0));
        // Media stays network loaded, so absolute media URLs are not rewritten either.
        final String video = "<video src=\"https://app.example.com/intro.mp4\"></video>";
        assertEquals(video, WebsiteModeUpdater.rewriteAbsoluteAssetUrls(video, root, root));
    }

    @Test
    public void detectsHtmlFallbackForCode() throws Exception {
        final URL js = new URL("https://app.example.com/assets/a.js");
        final URL css = new URL("https://app.example.com/assets/a.css");
        final URL png = new URL("https://app.example.com/a.png");
        final byte[] html = "  \n<!DOCTYPE html><html></html>".getBytes(StandardCharsets.UTF_8);
        final byte[] htmlTag = "\uFEFF<HTML lang=en>".getBytes(StandardCharsets.UTF_8);
        final byte[] code = "export{}".getBytes(StandardCharsets.UTF_8);
        assertTrue(WebsiteModeUpdater.isHtmlFallback(js, new WebsiteModeUpdater.FetchResponse(200, code, "text/html; charset=utf-8")));
        assertTrue(WebsiteModeUpdater.isHtmlFallback(js, new WebsiteModeUpdater.FetchResponse(200, html, "application/octet-stream")));
        assertTrue(WebsiteModeUpdater.isHtmlFallback(css, new WebsiteModeUpdater.FetchResponse(200, htmlTag, "")));
        assertFalse(WebsiteModeUpdater.isHtmlFallback(js, new WebsiteModeUpdater.FetchResponse(200, code, "text/javascript")));
        assertFalse(WebsiteModeUpdater.isHtmlFallback(png, new WebsiteModeUpdater.FetchResponse(200, html, "text/html")));
    }

    @Test
    public void rewritesAbsoluteSameOriginAssetUrlsInMarkup() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final String html =
            "<script src=\"https://app.example.com/assets/app.js\"></script>" +
            "<link rel=stylesheet href='https://app.example.com/assets/app.css?v=2'>" +
            "<img srcset=\"https://app.example.com/a.png 1x, /b.png 2x, https://cdn.other.com/c.png 3x\">" +
            "<a href=\"https://app.example.com/about\">x</a>" +
            "<script src=\"https://cdn.other.com/x.js\"></script><script src=\"http://app.example.com/old.js\"></script>";
        assertEquals(
            "<script src=\"/assets/app.js\"></script>" +
                "<link rel=stylesheet href='/assets/app.css?v=2'>" +
                "<img srcset=\"/a.png 1x, /b.png 2x, https://cdn.other.com/c.png 3x\">" +
                "<a href=\"https://app.example.com/about\">x</a>" +
                "<script src=\"https://cdn.other.com/x.js\"></script><script src=\"http://app.example.com/old.js\"></script>",
            WebsiteModeUpdater.rewriteAbsoluteAssetUrls(html, root, root)
        );
        final URL css = new URL("https://app.example.com/assets/app.css");
        assertEquals(
            "@import \"/assets/theme.css\"; .a{background:url(/img/bg.png)} .b{src:url('/f.woff2#iefix')}",
            WebsiteModeUpdater.rewriteAbsoluteAssetUrls(
                "@import \"https://app.example.com/assets/theme.css\"; .a{background:url(https://app.example.com/img/bg.png)} " +
                    ".b{src:url('//app.example.com/f.woff2#iefix')}",
                css,
                root
            )
        );
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
    public void downloadRewritesAbsoluteUrlsInHtmlAndCssButNotJs() throws Exception {
        final FakeSite site = new FakeSite();
        final String html =
            "<script type=module src=\"https://app.example.com/assets/index.js\"></script>" +
            "<link rel=stylesheet href=\"https://app.example.com/assets/index.css\">";
        final String js = "fetch('https://app.example.com/api/data.json')";
        site.put("https://app.example.com/assets/index.js", js, "application/javascript");
        site.put("https://app.example.com/assets/index.css", ".b{background:url(https://app.example.com/bg.png)}", "text/css");
        site.put("https://app.example.com/bg.png", "PNG", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final File dir = tmp.newFolder("absolute");
        updater.downloadWebsite(html.getBytes(StandardCharsets.UTF_8), new URL("https://app.example.com/"), null, dir);
        assertEquals(
            "<script type=module src=\"/assets/index.js\"></script><link rel=stylesheet href=\"/assets/index.css\">",
            new String(Files.readAllBytes(new File(dir, "index.html").toPath()), StandardCharsets.UTF_8)
        );
        assertEquals(
            ".b{background:url(/bg.png)}",
            new String(Files.readAllBytes(new File(dir, "assets/index.css").toPath()), StandardCharsets.UTF_8)
        );
        assertEquals(js, new String(Files.readAllBytes(new File(dir, "assets/index.js").toPath()), StandardCharsets.UTF_8));
        assertTrue(new File(dir, "bg.png").isFile());
    }

    @Test
    public void downloadFailsWhenJavaScriptChunkIsMissingOnEveryCandidate() throws Exception {
        final FakeSite site = new FakeSite();
        site.put(
            "https://app.example.com/assets/index.js",
            "import('./About-1.js');const c=['assets/Home-2.css']",
            "application/javascript"
        );
        site.put("https://app.example.com/assets/Home-2.css", ".a{}", "text/css");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<script src=\"/assets/index.js\"></script>".getBytes(StandardCharsets.UTF_8);
        final IOException error = assertThrows(IOException.class, () ->
            updater.downloadWebsite(html, new URL("https://app.example.com/"), null, tmp.newFolder("race"))
        );
        assertTrue(error.getMessage().contains("About-1.js"));
    }

    @Test
    public void downloadToleratesMissingCandidateAndNonCodeAssets() throws Exception {
        final FakeSite site = new FakeSite();
        // "assets/Home-2.js" 404s module-relative (/assets/assets/Home-2.js) but exists root-relative.
        site.put(
            "https://app.example.com/assets/index.js",
            "const m=['assets/Home-2.js','assets/missing.png','x/gone.json']",
            "text/javascript"
        );
        site.put("https://app.example.com/assets/Home-2.js", "export{}", "text/javascript");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<script src=\"/assets/index.js\"></script>".getBytes(StandardCharsets.UTF_8);
        final File dir = tmp.newFolder("partial");
        updater.downloadWebsite(html, new URL("https://app.example.com/"), null, dir);
        assertTrue(site.requested.contains("https://app.example.com/assets/assets/Home-2.js"));
        assertTrue(new File(dir, "assets/Home-2.js").isFile());
        assertFalse(new File(dir, "assets/missing.png").exists());
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
        assertEquals(Boolean.TRUE, site.bypassCache.get("https://cdn.example.com/v1/assets/index.js"));
    }

    @Test
    public void downloadSkipsOptionalAssetsOnAnyFailure() throws Exception {
        final FakeSite site = new FakeSite();
        site.put("https://app.example.com/assets/index.js", "const m=['assets/data.json','pdf.worker.js']", "text/javascript");
        site.put("https://app.example.com/manifest.webmanifest", 500, "", "text/plain");
        site.errors.put("https://app.example.com/icon.png", new IOException("Cross-origin redirect blocked"));
        site.errors.put("https://app.example.com/big.png", new IOException("Asset too large"));
        site.errors.put("https://app.example.com/assets/data.json", new IOException("timeout"));
        site.put("https://app.example.com/assets/pdf.worker.js", "<!doctype html><html></html>", "text/html");
        site.put("https://app.example.com/ok.png", "PNG", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final List<String> logs = new ArrayList<>();
        updater.setLog(logs::add);
        final String html =
            "<script src=\"/assets/index.js\"></script><link rel=manifest href=\"/manifest.webmanifest\">" +
            "<link rel=icon href=\"/icon.png\"><img src=\"/big.png\"><img src=\"/ok.png\">";
        final File dir = tmp.newFolder("optional");
        final int files = updater.downloadWebsite(html.getBytes(StandardCharsets.UTF_8), new URL("https://app.example.com/"), null, dir);
        assertEquals(3, files);
        assertTrue(new File(dir, "ok.png").isFile());
        assertFalse(new File(dir, "assets/pdf.worker.js").exists());
        assertFalse(new File(dir, "manifest.webmanifest").exists());
        assertTrue(logs.size() >= 5);
    }

    @Test
    public void downloadFailsWhenRequiredAssetFailsInAnyWay() throws Exception {
        final URL root = new URL("https://app.example.com/");
        final byte[] html = "<script src=\"/assets/index.js\"></script>".getBytes(StandardCharsets.UTF_8);

        final FakeSite serverError = new FakeSite();
        serverError.put("https://app.example.com/assets/index.js", 503, "", "text/plain");
        assertThrows(IOException.class, () ->
            new WebsiteModeUpdater(null, serverError, new MemoryStore()).downloadWebsite(html, root, null, tmp.newFolder("e1"))
        );

        final FakeSite network = new FakeSite();
        network.errors.put("https://app.example.com/assets/index.js", new IOException("offline"));
        assertThrows(IOException.class, () ->
            new WebsiteModeUpdater(null, network, new MemoryStore()).downloadWebsite(html, root, null, tmp.newFolder("e2"))
        );

        // SPA fallback: index.html served with 200 for a missing script.
        final FakeSite fallback = new FakeSite();
        fallback.put("https://app.example.com/assets/index.js", "<!DOCTYPE html><html></html>", "text/html");
        final IOException error = assertThrows(IOException.class, () ->
            new WebsiteModeUpdater(null, fallback, new MemoryStore()).downloadWebsite(html, root, null, tmp.newFolder("e3"))
        );
        assertTrue(error.getMessage().contains("HTML fallback"));

        // A required JS chunk answered with the HTML fallback counts as missing.
        final FakeSite chunk = new FakeSite();
        chunk.put("https://app.example.com/assets/index.js", "import('./About-1.js')", "text/javascript");
        chunk.put("https://app.example.com/assets/About-1.js", "\n <html><body></body></html>", "application/javascript");
        final IOException chunkError = assertThrows(IOException.class, () ->
            new WebsiteModeUpdater(null, chunk, new MemoryStore()).downloadWebsite(html, root, null, tmp.newFolder("e4"))
        );
        assertTrue(chunkError.getMessage().contains("About-1.js"));
    }

    @Test
    public void downloadRewritesSavedAbsoluteUrlsInJavaScript() throws Exception {
        final FakeSite site = new FakeSite();
        final String js =
            "const a=\"https://app.example.com/assets/logo.png\";const b='https://app.example.com/assets/missing.png';" +
            "fetch('https://app.example.com/api/users');fetch(`https://app.example.com/data/x.json`);" +
            "const c='https://cdn.other.com/assets/logo.png'";
        site.put("https://app.example.com/assets/index.js", js, "text/javascript");
        site.put("https://app.example.com/assets/logo.png", "PNG", "image/png");
        site.put("https://app.example.com/data/x.json", "{}", "application/json");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final File dir = tmp.newFolder("jsrewrite");
        final byte[] html = "<script src=\"/assets/index.js\"></script>".getBytes(StandardCharsets.UTF_8);
        updater.downloadWebsite(html, new URL("https://app.example.com/"), null, dir);
        assertTrue(new File(dir, "data/x.json").isFile());
        assertEquals(
            "const a=\"/assets/logo.png\";const b='https://app.example.com/assets/missing.png';" +
                "fetch('https://app.example.com/api/users');fetch(`https://app.example.com/data/x.json`);" +
                "const c='https://cdn.other.com/assets/logo.png'",
            new String(Files.readAllBytes(new File(dir, "assets/index.js").toPath()), StandardCharsets.UTF_8)
        );
    }

    @Test
    public void downloadDoesNotRewriteSkippedAssetsInMarkup() throws Exception {
        final FakeSite site = new FakeSite();
        final String html = "<link rel=icon href=\"https://app.example.com/missing.ico\"><img src=\"https://app.example.com/ok.png\">";
        site.put("https://app.example.com/ok.png", "PNG", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final File dir = tmp.newFolder("skipped");
        updater.downloadWebsite(html.getBytes(StandardCharsets.UTF_8), new URL("https://app.example.com/"), null, dir);
        assertEquals(
            "<link rel=icon href=\"https://app.example.com/missing.ico\"><img src=\"/ok.png\">",
            new String(Files.readAllBytes(new File(dir, "index.html").toPath()), StandardCharsets.UTF_8)
        );
    }

    @Test
    public void downloadFailsOverTotalByteBudget() throws Exception {
        final FakeSite site = new FakeSite();
        site.put("https://app.example.com/a.png", "0123456789", "image/png");
        site.put("https://app.example.com/b.png", "0123456789", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<img src=\"/a.png\"><img src=\"/b.png\">".getBytes(StandardCharsets.UTF_8);
        updater.maxTotalBytes = html.length + 15;
        final IOException error = assertThrows(IOException.class, () ->
            updater.downloadWebsite(html, new URL("https://app.example.com/"), null, tmp.newFolder("budget"))
        );
        assertTrue(error.getMessage().contains("budget"));
        assertEquals(300L * 1024L * 1024L, WebsiteModeUpdater.MAX_TOTAL_BYTES);
    }

    @Test
    public void downloadFailsOnCaseInsensitivePathCollisionWithDifferentBytes() throws Exception {
        final FakeSite site = new FakeSite();
        site.put("https://app.example.com/assets/App.png", "one", "image/png");
        site.put("https://app.example.com/assets/app.png", "two", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = "<img src=\"/assets/App.png\"><img src=\"/assets/app.png\">".getBytes(StandardCharsets.UTF_8);
        final IOException error = assertThrows(IOException.class, () ->
            updater.downloadWebsite(html, new URL("https://app.example.com/"), null, tmp.newFolder("collision"))
        );
        assertTrue(error.getMessage().contains("collision"));

        final FakeSite query = new FakeSite();
        query.put("https://app.example.com/a.css?v=1", ".a{}", "text/css");
        query.put("https://app.example.com/a.css?v=2", ".b{}", "text/css");
        final byte[] queryHtml = "<link rel=stylesheet href=\"/a.css?v=1\"><link rel=stylesheet href=\"/a.css?v=2\">".getBytes(
            StandardCharsets.UTF_8
        );
        assertThrows(IOException.class, () ->
            new WebsiteModeUpdater(null, query, new MemoryStore()).downloadWebsite(
                queryHtml,
                new URL("https://app.example.com/"),
                null,
                tmp.newFolder("collision2")
            )
        );
    }

    @Test
    public void downloadAcceptsSamePathWithSameBytes() throws Exception {
        final FakeSite site = new FakeSite();
        site.put("https://app.example.com/a.css?v=1", ".a{}", "text/css");
        site.put("https://app.example.com/a.css?v=2", ".a{}", "text/css");
        site.put("https://app.example.com/assets/Logo.png", "PNG", "image/png");
        site.put("https://app.example.com/assets/logo.png", "PNG", "image/png");
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, site, new MemoryStore());
        final byte[] html = (
            "<link rel=stylesheet href=\"/a.css?v=1\"><link rel=stylesheet href=\"/a.css?v=2\">" +
            "<img src=\"/assets/Logo.png\"><img src=\"/assets/logo.png\">"
        ).getBytes(StandardCharsets.UTF_8);
        final File dir = tmp.newFolder("same");
        updater.downloadWebsite(html, new URL("https://app.example.com/"), null, dir);
        assertTrue(new File(dir, "a.css").isFile());
        assertTrue(new File(dir, "assets/logo.png").isFile());
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
        // The live check carries no cache-bypass header (edge cacheable); website files bypass caches.
        assertEquals(Boolean.FALSE, site.bypassCache.get("https://plugin.capgo.app/website_live?app_id=com.example.app"));
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
        // Missing interval falls back to the 300 s floor.
        assertTrue(updater.isThrottled(2_000L + 299_000L));
        assertFalse(updater.isThrottled(2_000L + 300_000L));
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

    @Test
    public void failedWebsiteVersionsExpireAfterOneDay() {
        final MemoryStore store = new MemoryStore();
        final WebsiteModeUpdater updater = new WebsiteModeUpdater(null, new FakeSite(), store);
        final long day = WebsiteModeUpdater.FAILED_VERSION_TTL_MS;
        updater.markFailedVersion("web-aaaaaaaaaaaa", 1_000L);
        assertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa", 1_000L));
        assertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa", 1_000L + day - 1));
        assertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa", 1_000L + day));
        // Clock moved backwards: retry rather than block.
        assertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa", 500L));
        // Expired entries are dropped when a new failure is recorded.
        updater.markFailedVersion("web-bbbbbbbbbbbb", 1_000L + day);
        assertEquals("web-bbbbbbbbbbbb:" + (1_000L + day), store.getString(WebsiteModeUpdater.PREF_FAILED_VERSIONS, ""));
        // Legacy entries without a timestamp are retried.
        store.putString(WebsiteModeUpdater.PREF_FAILED_VERSIONS, "web-cccccccccccc");
        assertFalse(updater.isFailedVersion("web-cccccccccccc", 1_000L));
    }
}
