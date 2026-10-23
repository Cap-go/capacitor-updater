/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Website mode (Capgo Website Live plan): the deployed static website is the source of truth.
 * Capgo only answers whether the app may update and from which URL; files are fetched directly
 * from the website. No channels, stats, encryption or checksum signatures are involved.
 */
final class WebsiteModeUpdater {

    static final String DEFAULT_WEBSITE_LIVE_URL = "https://plugin.capgo.app/website_live";
    static final String VERSION_PREFIX = "web-";
    static final int MAX_ASSET_COUNT = 1000;
    static final long MAX_ASSET_BYTES = 100L * 1024L * 1024L;
    /** Total bytes a single crawl may download; past it the update fails. */
    static final long MAX_TOTAL_BYTES = 300L * 1024L * 1024L;
    static final long MAX_CHECK_INTERVAL_SECONDS = 24L * 60L * 60L;
    /** Floor for check_interval_seconds (also used when it is missing) so devices cannot stampede the backend. */
    static final long MIN_CHECK_INTERVAL_SECONDS = 300L;
    static final int MAX_FAILED_VERSIONS = 50;
    /** A failed website version is retried once this has elapsed (the site may be fixed without changing index.html). */
    static final long FAILED_VERSION_TTL_MS = 24L * 60L * 60L * 1000L;

    static final String PREF_LAST_CHECK_MS = "CapacitorUpdater.websiteMode.lastCheckMs";
    static final String PREF_CHECK_INTERVAL_MS = "CapacitorUpdater.websiteMode.checkIntervalMs";
    static final String PREF_LAST_MODE = "CapacitorUpdater.websiteMode.lastMode";
    static final String PREF_FAILED_VERSIONS = "CapacitorUpdater.websiteMode.failedVersions";

    static final String MODE_WEBSITE = "website";
    static final String MODE_CAPGO = "capgo";

    /**
     * href is only taken from {@code <link>} elements (stylesheets, icons, manifest, preloads) and SVG
     * {@code <use>}/{@code <image>} (sprites, also {@code xlink:href}): {@code <a href>} is navigation,
     * handled separately by {@link #PAGE_LINK_PATTERN}.
     */
    private static final String[] MARKUP_PATTERNS = new String[] {
        "src\\s*=\\s*[\"']([^\"']+)[\"']",
        "<link\\b[^>]*?\\bhref\\s*=\\s*[\"']([^\"']+)[\"']",
        "srcset\\s*=\\s*[\"']([^\"']+)[\"']",
        "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)",
        "@import\\s+[\"']([^\"']+)[\"']",
        "<(?:use|image|feimage)\\b[^>]*?\\bhref\\s*=\\s*[\"']([^\"']+)[\"']"
    };
    private static final Pattern SRCSET_PATTERN = Pattern.compile(MARKUP_PATTERNS[2], Pattern.CASE_INSENSITIVE);
    private static final Pattern[] COMPILED_MARKUP_PATTERNS = new Pattern[] {
        Pattern.compile(MARKUP_PATTERNS[0], Pattern.CASE_INSENSITIVE),
        Pattern.compile(MARKUP_PATTERNS[1], Pattern.CASE_INSENSITIVE),
        SRCSET_PATTERN,
        Pattern.compile(MARKUP_PATTERNS[3], Pattern.CASE_INSENSITIVE),
        Pattern.compile(MARKUP_PATTERNS[4], Pattern.CASE_INSENSITIVE),
        Pattern.compile(MARKUP_PATTERNS[5], Pattern.CASE_INSENSITIVE)
    };
    /**
     * {@code <a href>}/{@code <area href>} of the entry HTML: same-origin static pages (.html/.htm) are
     * bundled best effort so multi-page sites keep working offline. SPA routes (no extension) are not files.
     */
    static final Pattern PAGE_LINK_PATTERN = Pattern.compile(
        "<a(?:rea)?\\b[^>]*?\\bhref\\s*=\\s*[\"']([^\"']+)[\"']",
        Pattern.CASE_INSENSITIVE
    );
    private static final Pattern PAGE_EXTENSION = Pattern.compile("\\.html?$", Pattern.CASE_INSENSITIVE);
    private static final Pattern SRCSET_ITEM = Pattern.compile("^(\\s*)(\\S+)(.*)$", Pattern.DOTALL);
    private static final Pattern JS_ASSET_PATTERN = Pattern.compile(
        "[\"'`]([^\"'`\\s]+\\.(?:js|mjs|css|json|wasm|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|txt)(?:\\?[^\"'`\\s]*)?)[\"'`]",
        Pattern.CASE_INSENSITIVE
    );
    private static final Pattern REQUIRED_EXTENSION = Pattern.compile("\\.(?:js|mjs|css)$", Pattern.CASE_INSENSITIVE);
    /** Video and audio are never bundled: they stay loaded from the network. */
    private static final Pattern MEDIA_EXTENSION = Pattern.compile("\\.(?:mp4|webm|mov|mp3|m4a|ogg|wav)$", Pattern.CASE_INSENSITIVE);
    /** Data files referenced from JS may be API responses, so their URLs in JS are never rewritten. */
    private static final Pattern DATA_EXTENSION = Pattern.compile("\\.(?:json|txt)$", Pattern.CASE_INSENSITIVE);

    /** Parsed body of {@code GET website_live?app_id=}. Unknown fields are ignored. */
    static final class LiveResponse {

        final boolean allowed;
        final String mode;
        final String websiteUrl;
        final String downloadBaseUrl;
        final long checkIntervalSeconds;
        final String reason;

        LiveResponse(
            final boolean allowed,
            final String mode,
            final String websiteUrl,
            final String downloadBaseUrl,
            final long checkIntervalSeconds,
            final String reason
        ) {
            this.allowed = allowed;
            this.mode = mode;
            this.websiteUrl = websiteUrl;
            this.downloadBaseUrl = downloadBaseUrl;
            this.checkIntervalSeconds = checkIntervalSeconds;
            this.reason = reason;
        }

        boolean isCapgoMode() {
            return MODE_CAPGO.equals(this.mode);
        }

        /** True only when the website may be downloaded and its URL is usable. */
        boolean isWebsiteUpdateAllowed() {
            return this.allowed && MODE_WEBSITE.equals(this.mode) && parseHttpsUrl(this.websiteUrl) != null;
        }

        static LiveResponse parse(final String body) {
            if (body == null || body.trim().isEmpty()) {
                return null;
            }
            try {
                final JSONObject json = new JSONObject(body);
                final boolean allowed = json.optBoolean("allowed", false);
                final String mode = optString(json, "mode");
                final String websiteUrl = optString(json, "website_url");
                final String downloadBaseUrl = optString(json, "download_base_url");
                final String reason = optString(json, "reason");
                long interval = json.optLong("check_interval_seconds", 0L);
                if (interval < MIN_CHECK_INTERVAL_SECONDS) {
                    interval = MIN_CHECK_INTERVAL_SECONDS;
                }
                if (interval > MAX_CHECK_INTERVAL_SECONDS) {
                    interval = MAX_CHECK_INTERVAL_SECONDS;
                }
                return new LiveResponse(allowed, mode, websiteUrl, downloadBaseUrl, interval, reason);
            } catch (JSONException e) {
                return null;
            }
        }

        private static String optString(final JSONObject json, final String key) {
            if (!json.has(key) || json.isNull(key)) {
                return "";
            }
            final Object value = json.opt(key);
            return value instanceof String ? (String) value : "";
        }
    }

    static final class FetchResponse {

        final int statusCode;
        final byte[] data;
        final String contentType;

        FetchResponse(final int statusCode, final byte[] data, final String contentType) {
            this.statusCode = statusCode;
            this.data = data == null ? new byte[0] : data;
            this.contentType = contentType == null ? "" : contentType.toLowerCase(Locale.ROOT);
        }

        boolean isSuccess() {
            return this.statusCode >= 200 && this.statusCode < 300;
        }
    }

    interface Fetcher {
        /**
         * @param bypassCache true for website files (always fetch the deployed bytes); false for the
         *     live check, whose answer may come from the edge cache but never from a device cache
         */
        FetchResponse fetch(URL url, boolean bypassCache) throws IOException;
    }

    /** Minimal persistent key-value store so the logic stays testable on the JVM. */
    interface Store {
        String getString(String key, String fallback);

        long getLong(String key, long fallback);

        void putString(String key, String value);

        void putLong(String key, long value);
    }

    static Store sharedPreferencesStore(final SharedPreferences prefs) {
        return new Store() {
            @Override
            public String getString(final String key, final String fallback) {
                return prefs.getString(key, fallback);
            }

            @Override
            public long getLong(final String key, final long fallback) {
                return prefs.getLong(key, fallback);
            }

            @Override
            public void putString(final String key, final String value) {
                prefs.edit().putString(key, value).apply();
            }

            @Override
            public void putLong(final String key, final long value) {
                prefs.edit().putLong(key, value).apply();
            }
        };
    }

    static final int MAX_WEBSITE_REDIRECTS = 5;

    /** Logging hook so the crawl can report skipped optional assets. */
    interface Log {
        void info(String message);
    }

    static Fetcher okHttpFetcher() {
        return (url, bypassCache) -> {
            // Redirects are followed by hand so every hop can be checked against
            // the requested origin: files are saved under the requested path, so
            // another origin must never supply bundle code. The shared client and
            // its policy for other downloads stay unchanged.
            final OkHttpClient.Builder clientBuilder = DownloadService.sharedClient
                .newBuilder()
                .followRedirects(false)
                .followSslRedirects(false);
            if (!bypassCache) {
                // The live check must reach the network (the edge may cache it): no local
                // OkHttp cache, and no Cache-Control request header sent to the server.
                clientBuilder.cache(null);
            }
            final OkHttpClient client = clientBuilder.build();
            HttpUrl target = HttpUrl.get(url.toString());
            for (int hop = 0; hop <= MAX_WEBSITE_REDIRECTS; hop++) {
                final Request.Builder builder = new Request.Builder().url(target).header("Accept", "*/*").get();
                if (bypassCache) {
                    builder.header("Cache-Control", "no-cache");
                }
                final Request request = builder.build();
                try (Response response = client.newCall(request).execute()) {
                    if (response.isRedirect()) {
                        final String location = response.header("Location");
                        final HttpUrl next = location == null ? null : response.request().url().resolve(location);
                        if (next == null || !isSameOrigin(url, next.url())) {
                            throw new IOException("Cross-origin redirect from " + url + " blocked");
                        }
                        target = next;
                        continue;
                    }
                    final ResponseBody body = response.body();
                    final String contentType = response.header("Content-Type", "");
                    if (!response.isSuccessful() || body == null) {
                        return new FetchResponse(response.code(), new byte[0], contentType);
                    }
                    final long declared = body.contentLength();
                    if (declared > MAX_ASSET_BYTES) {
                        throw new IOException("Asset too large: " + url);
                    }
                    try (InputStream stream = body.byteStream()) {
                        return new FetchResponse(response.code(), readLimited(stream, url), contentType);
                    }
                }
            }
            throw new IOException("Too many redirects: " + url);
        };
    }

    private static byte[] readLimited(final InputStream stream, final URL url) throws IOException {
        final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        final byte[] buffer = new byte[16 * 1024];
        long total = 0;
        int read;
        while ((read = stream.read(buffer)) != -1) {
            total += read;
            if (total > MAX_ASSET_BYTES) {
                throw new IOException("Asset too large: " + url);
            }
            out.write(buffer, 0, read);
        }
        return out.toByteArray();
    }

    private final Fetcher fetcher;
    private final Store store;
    private final String websiteLiveUrl;
    private Log log = (message) -> {};
    /** Crawl byte budget; only lowered by tests. */
    long maxTotalBytes = MAX_TOTAL_BYTES;
    /** Per-asset size cap; only lowered by tests. */
    long maxAssetBytes = MAX_ASSET_BYTES;

    WebsiteModeUpdater(final String websiteLiveUrl, final Fetcher fetcher, final Store store) {
        this.websiteLiveUrl = websiteLiveUrl == null || websiteLiveUrl.trim().isEmpty() ? DEFAULT_WEBSITE_LIVE_URL : websiteLiveUrl.trim();
        this.fetcher = fetcher;
        this.store = store;
    }

    String getWebsiteLiveUrl() {
        return this.websiteLiveUrl;
    }

    void setLog(final Log log) {
        this.log = log == null ? (message) -> {} : log;
    }

    // ---- Backend contract ----

    /** Plain HTTP is only accepted for loopback hosts (local development). */
    static boolean isLoopbackHost(final String host) {
        return "localhost".equals(host) || "127.0.0.1".equals(host) || "::1".equals(host) || "[::1]".equals(host);
    }

    /** Same scheme, host and port: redirects must not change where bundle files come from. */
    static boolean isSameOrigin(final URL a, final URL b) {
        return (
            a.getProtocol().equalsIgnoreCase(b.getProtocol()) &&
            a.getHost().equalsIgnoreCase(b.getHost()) &&
            (a.getPort() == -1 ? a.getDefaultPort() : a.getPort()) == (b.getPort() == -1 ? b.getDefaultPort() : b.getPort())
        );
    }

    /** Asset paths are stored relative to the bundle root, so the website must be served from its root. */
    static boolean isRootWebsiteUrl(final URL url) {
        final String path = url.getPath();
        return path == null || path.isEmpty() || "/".equals(path) || "/index.html".equals(path);
    }

    /**
     * Only app_id is sent: the response is device independent and edge cached.
     * The live answer picks the code the app runs, so it must come over HTTPS.
     */
    static String buildLiveCheckUrl(final String websiteLiveUrl, final String appId) {
        final HttpUrl base = HttpUrl.parse(websiteLiveUrl);
        if (base == null || (!base.isHttps() && !isLoopbackHost(base.host()))) {
            return null;
        }
        return base
            .newBuilder()
            .removeAllQueryParameters("app_id")
            .addQueryParameter("app_id", appId == null ? "" : appId)
            .build()
            .toString();
    }

    LiveResponse fetchLiveResponse(final String appId) throws IOException {
        final String checkUrl = buildLiveCheckUrl(this.websiteLiveUrl, appId);
        if (checkUrl == null) {
            throw new IOException("Invalid websiteLiveUrl");
        }
        // No cache bypass header: the live answer is device independent and edge cached.
        // The fetcher never serves it from a device-side cache.
        final FetchResponse response = this.fetcher.fetch(new URL(checkUrl), false);
        if (!response.isSuccess()) {
            throw new IOException("Website live check failed with HTTP " + response.statusCode);
        }
        final LiveResponse parsed = LiveResponse.parse(new String(response.data, StandardCharsets.UTF_8));
        if (parsed == null) {
            throw new IOException("Website live check returned an invalid response");
        }
        return parsed;
    }

    // ---- Persistent state ----

    boolean isThrottled(final long nowMs) {
        final long last = this.store.getLong(PREF_LAST_CHECK_MS, 0L);
        final long interval = this.store.getLong(PREF_CHECK_INTERVAL_MS, 0L);
        if (last <= 0 || interval <= 0) {
            return false;
        }
        // A clock moved backwards must not block checks forever.
        if (nowMs < last) {
            return false;
        }
        return nowMs - last < interval;
    }

    void recordCheck(final long nowMs, final LiveResponse response) {
        this.store.putLong(PREF_LAST_CHECK_MS, nowMs);
        this.store.putLong(PREF_CHECK_INTERVAL_MS, response == null ? 0L : response.checkIntervalSeconds * 1000L);
        this.store.putString(PREF_LAST_MODE, response != null && response.isCapgoMode() ? MODE_CAPGO : MODE_WEBSITE);
    }

    boolean lastKnownModeIsCapgo() {
        return MODE_CAPGO.equals(this.store.getString(PREF_LAST_MODE, MODE_WEBSITE));
    }

    boolean isFailedVersion(final String version) {
        return isFailedVersion(version, System.currentTimeMillis());
    }

    /** A failed version is skipped for {@link #FAILED_VERSION_TTL_MS}, then retried. */
    boolean isFailedVersion(final String version, final long nowMs) {
        if (version == null) {
            return false;
        }
        final Long failedAt = readFailedVersions().get(version);
        return failedAt != null && !isFailedEntryExpired(failedAt, nowMs);
    }

    void markFailedVersion(final String version) {
        markFailedVersion(version, System.currentTimeMillis());
    }

    void markFailedVersion(final String version, final long nowMs) {
        if (version == null || !version.startsWith(VERSION_PREFIX)) {
            return;
        }
        final List<String> failed = new ArrayList<>();
        for (Map.Entry<String, Long> entry : readFailedVersions().entrySet()) {
            if (!entry.getKey().equals(version) && !isFailedEntryExpired(entry.getValue(), nowMs)) {
                failed.add(entry.getKey() + ":" + entry.getValue());
            }
        }
        failed.add(version + ":" + nowMs);
        while (failed.size() > MAX_FAILED_VERSIONS) {
            failed.remove(0);
        }
        this.store.putString(PREF_FAILED_VERSIONS, String.join(",", failed));
    }

    /** A clock moved backwards counts as expired so a version is never blocked for longer than intended. */
    private static boolean isFailedEntryExpired(final long failedAtMs, final long nowMs) {
        return failedAtMs <= 0 || nowMs < failedAtMs || nowMs - failedAtMs >= FAILED_VERSION_TTL_MS;
    }

    /** Stored as "version:failedAtMs" entries; legacy entries without a timestamp count as expired. */
    private Map<String, Long> readFailedVersions() {
        final String raw = this.store.getString(PREF_FAILED_VERSIONS, "");
        final Map<String, Long> result = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) {
            return result;
        }
        for (String value : raw.split(",")) {
            if (value.isEmpty()) {
                continue;
            }
            final int colon = value.lastIndexOf(':');
            long failedAt = 0L;
            String version = value;
            if (colon > 0) {
                version = value.substring(0, colon);
                try {
                    failedAt = Long.parseLong(value.substring(colon + 1));
                } catch (NumberFormatException e) {
                    failedAt = 0L;
                }
            }
            result.remove(version);
            result.put(version, failedAt);
        }
        return result;
    }

    /**
     * keepUrlPathAfterReload default: a website is an SPA whose route must survive the reload that
     * applies an update (as in the website updater), so website mode keeps the path unless configured.
     */
    static boolean defaultKeepUrlPathAfterReload(final boolean websiteMode) {
        return websiteMode;
    }

    static boolean isWebsiteVersion(final String version) {
        return version != null && version.startsWith(VERSION_PREFIX);
    }

    // ---- Automatic notifyAppReady ----

    /**
     * Evaluated in the main frame after it finished loading. A website bundle is the customer's plain
     * website: it never imports the updater, so nothing calls notifyAppReady(). This script calls it
     * through the native plugin proxy (so the readiness generation guard still applies) once the
     * document is complete and shows content. A blank page never calls it, so the rollback still runs.
     */
    static final String AUTO_READY_SCRIPT =
        "(function(){" +
        "if(window.__capgoWebsiteAutoReady){return;}" +
        "window.__capgoWebsiteAutoReady=true;" +
        "var tries=0;" +
        "function hasContent(){var b=document.body;if(!b){return false;}" +
        "if(String(b.innerText||'').trim().length>0){return true;}" +
        "return !!b.querySelector('img,svg,canvas,video,picture,iframe,input,button,textarea,select');}" +
        "function tick(){try{var cap=window.Capacitor;var p=cap&&cap.Plugins&&cap.Plugins.CapacitorUpdater;" +
        "var call=p&&typeof p.notifyAppReady==='function'?function(){return p.notifyAppReady();}:" +
        "(cap&&typeof cap.nativePromise==='function'?function(){return cap.nativePromise('CapacitorUpdater','notifyAppReady',{});}:null);" +
        "if(document.readyState==='complete'&&hasContent()&&call){" +
        "var r=call();if(r&&typeof r.catch==='function'){r.catch(function(){});}return;}}catch(_){}" +
        "if(tries++<60){setTimeout(tick,500);}}" +
        "if(document.readyState==='complete'){tick();}else{window.addEventListener('load',tick);}" +
        "})();";

    /**
     * True when a finished main-frame load should auto-mark the current website bundle as ready:
     * website mode with auto notify enabled, a web-* bundle, and a page served from the app origin
     * that is not the Capacitor error page.
     */
    static boolean shouldAutoNotifyReady(
        final boolean websiteMode,
        final boolean autoNotifyReady,
        final String currentVersion,
        final String pageUrl,
        final String appUrl,
        final String errorUrl
    ) {
        if (!websiteMode || !autoNotifyReady || !isWebsiteVersion(currentVersion)) {
            return false;
        }
        if (pageUrl == null || pageUrl.isEmpty() || appUrl == null || appUrl.isEmpty()) {
            return false;
        }
        if (errorUrl != null && !errorUrl.isEmpty() && stripQueryAndFragment(pageUrl).equals(stripQueryAndFragment(errorUrl))) {
            return false;
        }
        final String pageOrigin = originOf(pageUrl);
        return pageOrigin != null && pageOrigin.equals(originOf(appUrl));
    }

    private static String stripQueryAndFragment(final String url) {
        int end = url.length();
        final int query = url.indexOf('?');
        final int fragment = url.indexOf('#');
        if (query >= 0) {
            end = Math.min(end, query);
        }
        if (fragment >= 0) {
            end = Math.min(end, fragment);
        }
        return url.substring(0, end);
    }

    private static String originOf(final String url) {
        try {
            final URI uri = new URI(url);
            final String scheme = uri.getScheme();
            final String host = uri.getHost();
            if (scheme == null || host == null) {
                return null;
            }
            final String normalizedScheme = scheme.toLowerCase(Locale.ROOT);
            final int port = uri.getPort() != -1 ? uri.getPort() : "http".equals(normalizedScheme) ? 80 : 443;
            return normalizedScheme + "://" + host.toLowerCase(Locale.ROOT) + ":" + port;
        } catch (final Exception e) {
            return null;
        }
    }

    // ---- Website download ----

    /** Result of crawling a website into a bundle directory. */
    static final class WebsiteDownloadResult {

        final int fileCount;
        /**
         * Sorted SHA-256 hex digests of the fetched bytes of each unique saved file (including
         * {@code index.html}). Text files are rewritten after hashing, so these do not match their
         * on-disk bytes.
         */
        final List<String> fileDigests;

        WebsiteDownloadResult(final int fileCount, final List<String> fileDigests) {
            this.fileCount = fileCount;
            this.fileDigests = fileDigests;
        }
    }

    /**
     * Deterministic bundle version: {@code web-}&lt;first 12 hex of sha256(normalized URL + "\n" + entry HTML +
     * "\n" + sorted file digests…)&gt;. The URL is part of the hash so moving the app to another domain also
     * produces a new version.
     */
    static String versionForWebsite(final URL websiteUrl, final byte[] html, final List<String> fileDigests) {
        final List<String> sorted = new ArrayList<>(fileDigests == null ? Collections.emptyList() : fileDigests);
        Collections.sort(sorted);
        final byte[] prefix = (normalizedWebsiteUrl(websiteUrl) + "\n").getBytes(StandardCharsets.UTF_8);
        int extra = 0;
        for (String digest : sorted) {
            extra += 1 + digest.getBytes(StandardCharsets.UTF_8).length;
        }
        final byte[] input = new byte[prefix.length + html.length + extra];
        System.arraycopy(prefix, 0, input, 0, prefix.length);
        System.arraycopy(html, 0, input, prefix.length, html.length);
        int offset = prefix.length + html.length;
        for (String digest : sorted) {
            input[offset++] = '\n';
            final byte[] bytes = digest.getBytes(StandardCharsets.UTF_8);
            System.arraycopy(bytes, 0, input, offset, bytes.length);
            offset += bytes.length;
        }
        return VERSION_PREFIX + sha256Hex(input).substring(0, 12);
    }

    /** URL and entry HTML only (no crawled assets). Used to assert URL normalization in unit tests. */
    static String versionForWebsite(final URL websiteUrl, final byte[] html) {
        return versionForWebsite(websiteUrl, html, Collections.emptyList());
    }

    /** Lowercase scheme and host, default port dropped, empty path as "/", query kept, fragment dropped. */
    static String normalizedWebsiteUrl(final URL url) {
        final String scheme = url.getProtocol().toLowerCase(Locale.ROOT);
        final String host = url.getHost().toLowerCase(Locale.ROOT);
        final int port = url.getPort();
        final String portPart = port == -1 || port == url.getDefaultPort() ? "" : ":" + port;
        final String path = url.getPath() == null || url.getPath().isEmpty() ? "/" : url.getPath();
        final String query = url.getQuery() == null ? "" : "?" + url.getQuery();
        return scheme + "://" + host + portPart + path + query;
    }

    byte[] fetchEntryHtml(final URL websiteUrl, final URL downloadBase) throws IOException {
        final FetchResponse response = this.fetcher.fetch(rebase(websiteUrl, downloadBase), true);
        if (!response.isSuccess()) {
            throw new IOException("HTTP " + response.statusCode + " while fetching website entry");
        }
        if (response.data.length == 0) {
            throw new IOException("Website entry is empty");
        }
        if (response.data.length > this.maxAssetBytes) {
            throw new IOException("Asset too large");
        }
        return response.data;
    }

    /** One file saved by the crawl. */
    private static final class SavedFile {

        final String path;
        final URL url;
        final String sha256;

        SavedFile(final String path, final URL url, final String sha256) {
            this.path = path;
            this.url = url;
            this.sha256 = sha256;
        }
    }

    /** A saved HTML, CSS or JS file whose same-origin absolute asset URLs are rewritten once the crawl is done. */
    private static final class TextFile {

        final String path;
        final URL baseUrl;
        final boolean javaScript;

        TextFile(final String path, final URL baseUrl, final boolean javaScript) {
            this.path = path;
            this.baseUrl = baseUrl;
            this.javaScript = javaScript;
        }
    }

    /**
     * Crawls same-origin assets referenced by the entry HTML, CSS and JS into {@code targetDir}.
     * Paths stay identical to the website so the bundle behaves like the webDir build.
     * Required assets (scripts and stylesheets of the entry HTML, JS code chunks) fail the update when
     * missing; every other asset is skipped on any failure.
     *
     * @return crawl result (file count and sorted per-file digests)
     */
    WebsiteDownloadResult downloadWebsite(final byte[] entryHtml, final URL websiteUrl, final URL downloadBase, final File targetDir)
        throws IOException {
        return downloadWebsite(entryHtml, websiteUrl, downloadBase, targetDir, null);
    }

    /** Crawl progress, 5..95 and never decreasing (the queue grows while files are parsed). */
    interface ProgressListener {
        void onProgress(int percent);
    }

    static int crawlPercent(final int processed, final int remaining) {
        return Math.min(95, 5 + (int) ((processed / (double) Math.max(processed + remaining, 1)) * 90));
    }

    WebsiteDownloadResult downloadWebsite(
        final byte[] entryHtml,
        final URL websiteUrl,
        final URL downloadBase,
        final File targetDir,
        final ProgressListener progress
    ) throws IOException {
        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw new IOException("Unable to create website download directory");
        }
        final String entryText = new String(entryHtml, StandardCharsets.UTF_8);
        save(entryHtml, new File(targetDir, "index.html"), targetDir);
        // Keyed by lowercased path: iOS file systems are case-insensitive.
        final Map<String, SavedFile> saved = new HashMap<>();
        final Set<String> writtenPaths = new LinkedHashSet<>();
        final List<TextFile> textFiles = new ArrayList<>();
        saved.put("index.html", new SavedFile("index.html", websiteUrl, sha256Hex(entryHtml)));
        writtenPaths.add("index.html");
        textFiles.add(new TextFile("index.html", websiteUrl, false));
        long totalBytes = entryHtml.length;

        final ArrayDeque<Asset> queue = new ArrayDeque<>();
        final Set<String> queued = new HashSet<>();
        final Map<String, List<URL>> requiredReferences = new LinkedHashMap<>();
        for (Asset asset : discoverMarkupAssets(entryText, websiteUrl, websiteUrl, true)) {
            enqueue(asset, queue, queued);
        }

        int processed = 0;
        int lastPercent = 0;
        while (!queue.isEmpty()) {
            final Asset asset = queue.poll();
            if (++processed > MAX_ASSET_COUNT) {
                throw new IOException("Website references more than " + MAX_ASSET_COUNT + " assets");
            }
            final int percent = crawlPercent(processed, queue.size());
            if (progress != null && percent > lastPercent) {
                lastPercent = percent;
                progress.onProgress(percent);
            }
            final String relativePath;
            try {
                relativePath = localPath(asset.url);
            } catch (IOException e) {
                if (asset.required) {
                    throw e;
                }
                this.log.info("Skipping website asset " + asset.url.getPath() + ": " + e.getMessage());
                continue;
            }
            final String key = relativePath.toLowerCase(Locale.ROOT);
            if ("index.html".equals(key)) {
                continue;
            }
            FetchResponse response = null;
            String failure;
            try {
                response = this.fetcher.fetch(rebase(asset.url, downloadBase), true);
                failure = null;
            } catch (IOException e) {
                failure = e.getMessage();
            }
            if (response != null) {
                if (response.data.length > this.maxAssetBytes) {
                    throw new IOException("Asset too large");
                }
                totalBytes += response.data.length;
                if (totalBytes > this.maxTotalBytes) {
                    throw new IOException("Website is larger than the " + this.maxTotalBytes + " bytes download budget");
                }
                if (!response.isSuccess()) {
                    failure = "HTTP " + response.statusCode;
                } else if (isHtmlFallback(asset.url, response)) {
                    failure = "HTML fallback page served instead of the file";
                } else if (isPage(asset.url) && Arrays.equals(response.data, entryHtml)) {
                    failure = "entry HTML served instead of the page";
                }
            }
            if (failure != null) {
                if (asset.required) {
                    throw new IOException("Failed to download " + asset.url.getPath() + ": " + failure);
                }
                this.log.info("Skipping website asset " + asset.url.getPath() + ": " + failure);
                continue;
            }

            final String hash = sha256Hex(response.data);
            final SavedFile existing = saved.get(key);
            if (existing != null) {
                if (!existing.sha256.equals(hash)) {
                    throw new IOException(
                        "Path collision: " +
                            existing.url.getPath() +
                            " and " +
                            asset.url.getPath() +
                            " map to the same bundle file " +
                            relativePath +
                            " with different content"
                    );
                }
                // Same bytes: nothing new for the exact path. A path differing only by case is still written
                // because Android file systems are case-sensitive (iOS skips it: there it is the same file).
                if (writtenPaths.contains(relativePath)) {
                    continue;
                }
            }
            try {
                save(response.data, new File(targetDir, relativePath), targetDir);
            } catch (IOException e) {
                // e.g. "/images" saved as a file and "/images/logo.png" needing it as a directory.
                if (asset.required) {
                    throw e;
                }
                this.log.info("Skipping website asset " + asset.url.getPath() + ": " + e.getMessage());
                continue;
            }
            if (existing == null) {
                saved.put(key, new SavedFile(relativePath, asset.url, hash));
            }
            writtenPaths.add(relativePath);

            if (isCss(asset.url, response.contentType)) {
                textFiles.add(new TextFile(relativePath, asset.url, false));
                final String text = new String(response.data, StandardCharsets.UTF_8);
                for (Asset child : discoverMarkupAssets(text, asset.url, websiteUrl, false)) {
                    enqueue(child, queue, queued);
                }
            } else if (isJavaScript(asset.url, response.contentType)) {
                textFiles.add(new TextFile(relativePath, asset.url, true));
                final String text = new String(response.data, StandardCharsets.UTF_8);
                for (Asset child : discoverJavaScriptAssets(text, asset.url, websiteUrl)) {
                    if (!child.requiredCandidates.isEmpty()) {
                        requiredReferences.put(candidatesKey(child.requiredCandidates), child.requiredCandidates);
                    }
                    enqueue(child, queue, queued);
                }
            } else if (isPage(asset.url)) {
                textFiles.add(new TextFile(relativePath, asset.url, false));
                final String text = new String(response.data, StandardCharsets.UTF_8);
                for (Asset child : discoverMarkupAssets(text, asset.url, websiteUrl, false)) {
                    enqueue(child, queue, queued);
                }
            }
        }

        // A code chunk referenced from JS must exist under at least one of its candidate paths,
        // otherwise the bundle would break when the chunk is lazily loaded (e.g. deploy race).
        final Predicate<URL> isSaved = (url) -> {
            try {
                return saved.containsKey(localPath(url).toLowerCase(Locale.ROOT));
            } catch (IOException e) {
                return false;
            }
        };
        for (List<URL> candidates : requiredReferences.values()) {
            boolean found = false;
            for (URL candidate : candidates) {
                if (isSaved.test(candidate)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw new IOException("Missing code chunk referenced from JS: " + candidates.get(0).getPath());
            }
        }

        // Same-origin absolute URLs of saved files become root-relative so the app loads them from the bundle.
        for (TextFile textFile : textFiles) {
            final File file = new File(targetDir, textFile.path);
            // Only UTF-8 files are rewritten: decoding with replacement and re-encoding would change other bytes.
            final String text = decodeUtf8(readFile(file));
            if (text == null) {
                this.log.info("Not rewriting non UTF-8 file " + textFile.path);
                continue;
            }
            final String rewritten = textFile.javaScript
                ? rewriteJavaScriptAssetUrls(text, textFile.baseUrl, websiteUrl, isSaved)
                : rewriteAbsoluteAssetUrls(text, textFile.baseUrl, websiteUrl, isSaved);
            if (!rewritten.equals(text)) {
                save(rewritten.getBytes(StandardCharsets.UTF_8), file, targetDir);
            }
        }
        final List<String> digests = new ArrayList<>();
        for (SavedFile file : saved.values()) {
            digests.add(file.sha256);
        }
        Collections.sort(digests);
        return new WebsiteDownloadResult(writtenPaths.size(), digests);
    }

    /**
     * SPA hosts often answer unknown paths with index.html and HTTP 200. For a script or stylesheet
     * that HTML page means the file is missing.
     */
    static boolean isHtmlFallback(final URL url, final FetchResponse response) {
        if (!REQUIRED_EXTENSION.matcher(url.getPath()).find()) {
            return false;
        }
        if (response.contentType.contains("text/html")) {
            return true;
        }
        final int length = Math.min(response.data.length, 1024);
        String head = new String(response.data, 0, length, StandardCharsets.UTF_8);
        if (head.startsWith("﻿")) {
            head = head.substring(1);
        }
        head = head.trim().toLowerCase(Locale.ROOT);
        return head.startsWith("<!doctype html") || head.startsWith("<html");
    }

    private static String candidatesKey(final List<URL> candidates) {
        final StringBuilder key = new StringBuilder();
        for (URL candidate : candidates) {
            key.append(candidate.toString()).append('\n');
        }
        return key.toString();
    }

    static boolean isMedia(final URL url) {
        return MEDIA_EXTENSION.matcher(url.getPath()).find();
    }

    /**
     * HTML/CSS: discovered same-origin absolute asset URLs (https://app.example.com/assets/a.js) become
     * root-relative (/assets/a.js), matching where they are stored in the bundle, so the WebView loads them
     * from the bundle instead of the network. Values that are not discovered assets, and media, are left untouched.
     */
    static String rewriteAbsoluteAssetUrls(final String text, final URL baseUrl, final URL rootUrl) {
        return rewriteAbsoluteAssetUrls(text, baseUrl, rootUrl, (url) -> !isMedia(url));
    }

    /** Same as {@link #rewriteAbsoluteAssetUrls(String, URL, URL)}, only for URLs accepted by {@code accept}. */
    static String rewriteAbsoluteAssetUrls(final String text, final URL baseUrl, final URL rootUrl, final Predicate<URL> accept) {
        if (text == null) {
            return null;
        }
        String result = text;
        for (Pattern pattern : COMPILED_MARKUP_PATTERNS) {
            final boolean srcset = pattern == SRCSET_PATTERN;
            result = rewriteMatches(result, pattern, (value) ->
                srcset ? rewriteSrcset(value, baseUrl, rootUrl, accept) : rewriteAbsoluteValue(value, baseUrl, rootUrl, accept)
            );
        }
        // Links only point into the bundle for pages that were saved; other links stay as they are.
        result = rewriteMatches(result, PAGE_LINK_PATTERN, (value) ->
            rewriteAbsoluteValue(value, baseUrl, rootUrl, (url) -> isPage(url) && accept.test(url))
        );
        return result;
    }

    /**
     * JS: only exact string literals that are same-origin absolute URLs of files saved into the bundle become
     * root-relative. Other URLs (API endpoints, data files, anything not saved) are left untouched.
     */
    static String rewriteJavaScriptAssetUrls(final String text, final URL baseUrl, final URL rootUrl, final Predicate<URL> isSaved) {
        if (text == null) {
            return null;
        }
        final Predicate<URL> accept = (url) -> !DATA_EXTENSION.matcher(url.getPath()).find() && isSaved.test(url);
        return rewriteMatches(text, JS_ASSET_PATTERN, (value) -> rewriteAbsoluteValue(value, baseUrl, rootUrl, accept));
    }

    private interface ValueRewriter {
        String rewrite(String value);
    }

    private static String rewriteMatches(final String text, final Pattern pattern, final ValueRewriter rewriter) {
        final Matcher matcher = pattern.matcher(text);
        final StringBuilder out = new StringBuilder();
        int last = 0;
        while (matcher.find()) {
            final String rewritten = rewriter.rewrite(matcher.group(1));
            if (rewritten != null) {
                out.append(text, last, matcher.start(1)).append(rewritten);
                last = matcher.end(1);
            }
        }
        if (last == 0) {
            return text;
        }
        out.append(text, last, text.length());
        return out.toString();
    }

    private static String rewriteAbsoluteValue(final String value, final URL baseUrl, final URL rootUrl, final Predicate<URL> accept) {
        final String trimmed = value.trim();
        final String lower = trimmed.toLowerCase(Locale.ROOT);
        if (!lower.startsWith("https://") && !lower.startsWith("http://") && !lower.startsWith("//")) {
            return null;
        }
        final URL url = sameOriginUrl(trimmed, baseUrl, rootUrl);
        if (url == null || !accept.test(url)) {
            return null;
        }
        final String path = url.getPath() == null || url.getPath().isEmpty() ? "/" : url.getPath();
        final String query = url.getQuery() == null ? "" : "?" + url.getQuery();
        final int hash = trimmed.indexOf('#');
        return path + query + (hash >= 0 ? trimmed.substring(hash) : "");
    }

    private static String rewriteSrcset(final String value, final URL baseUrl, final URL rootUrl, final Predicate<URL> accept) {
        final String[] items = value.split(",", -1);
        boolean changed = false;
        for (int i = 0; i < items.length; i++) {
            final Matcher item = SRCSET_ITEM.matcher(items[i]);
            if (!item.matches()) {
                continue;
            }
            final String rewritten = rewriteAbsoluteValue(item.group(2), baseUrl, rootUrl, accept);
            if (rewritten != null) {
                items[i] = item.group(1) + rewritten + item.group(3);
                changed = true;
            }
        }
        return changed ? String.join(",", items) : null;
    }

    private static void enqueue(final Asset asset, final ArrayDeque<Asset> queue, final Set<String> queued) {
        final String key = asset.url.toString();
        if (queued.add(key)) {
            queue.add(asset);
        }
    }

    static final class Asset {

        final URL url;
        final boolean required;
        /**
         * For JS code chunk references: every candidate URL of the reference. The update fails
         * unless at least one of them downloads; each single candidate may still 404.
         */
        final List<URL> requiredCandidates;

        Asset(final URL url, final boolean required) {
            this(url, required, Collections.emptyList());
        }

        Asset(final URL url, final boolean required, final List<URL> requiredCandidates) {
            this.url = url;
            this.required = required;
            this.requiredCandidates = requiredCandidates;
        }
    }

    /**
     * Asset refs found in HTML or CSS. Scripts and stylesheets referenced from the entry HTML are
     * required (any failure fails the update); other refs (icons, links, manifests) are best effort.
     * Video and audio are never bundled.
     */
    static List<Asset> discoverMarkupAssets(final String text, final URL baseUrl, final URL rootUrl, final boolean fromEntryHtml) {
        final List<Asset> result = new ArrayList<>();
        if (text == null) {
            return result;
        }
        for (Pattern pattern : COMPILED_MARKUP_PATTERNS) {
            final Matcher matcher = pattern.matcher(text);
            while (matcher.find()) {
                final String value = matcher.group(1);
                final List<String> candidates = pattern == SRCSET_PATTERN ? srcsetCandidates(value) : Collections.singletonList(value);
                for (String candidate : candidates) {
                    final URL url = sameOriginUrl(candidate, baseUrl, rootUrl);
                    if (url != null && !isMedia(url)) {
                        final boolean required = fromEntryHtml && REQUIRED_EXTENSION.matcher(url.getPath()).find();
                        result.add(new Asset(url, required));
                    }
                }
            }
        }
        if (fromEntryHtml) {
            // Linked static pages, one level deep (their own assets are crawled, their links are not).
            final Matcher matcher = PAGE_LINK_PATTERN.matcher(text);
            while (matcher.find()) {
                final URL url = sameOriginUrl(matcher.group(1), baseUrl, rootUrl);
                if (url != null && isPage(url)) {
                    result.add(new Asset(url, false));
                }
            }
        }
        return result;
    }

    /** A static HTML page (.html/.htm) other than the entry. */
    static boolean isPage(final URL url) {
        return PAGE_EXTENSION.matcher(url.getPath()).find();
    }

    /**
     * Heuristic string refs inside JS bundles. Bundlers emit both module-relative refs ("./chunk.js")
     * and base-relative refs ("assets/chunk.js"), so both resolutions are tried and a single candidate
     * may miss. Only real bundler chunk URLs (literals starting with "./", "../", "/" or a same-origin
     * absolute URL) of code (.js/.mjs/.css) must resolve; bare names ("pdf.worker.js") are best effort.
     */
    static List<Asset> discoverJavaScriptAssets(final String text, final URL baseUrl, final URL rootUrl) {
        final List<Asset> result = new ArrayList<>();
        if (text == null) {
            return result;
        }
        final Matcher matcher = JS_ASSET_PATTERN.matcher(text);
        while (matcher.find()) {
            final String value = matcher.group(1);
            final String lower = value.toLowerCase(Locale.ROOT);
            final boolean absolute = lower.startsWith("https://") || lower.startsWith("http://");
            final boolean explicit = absolute || value.startsWith("/") || value.startsWith("./") || value.startsWith("../");
            final List<URL> candidates = new ArrayList<>(2);
            final URL relativeToModule = sameOriginUrl(value, baseUrl, rootUrl);
            if (relativeToModule != null) {
                candidates.add(relativeToModule);
            }
            if (!explicit && !value.contains("://")) {
                final URL relativeToRoot = sameOriginUrl(value, rootUrl, rootUrl);
                if (
                    relativeToRoot != null && (relativeToModule == null || !relativeToRoot.toString().equals(relativeToModule.toString()))
                ) {
                    candidates.add(relativeToRoot);
                }
            }
            if (candidates.isEmpty() || isMedia(candidates.get(0))) {
                continue;
            }
            final boolean code = explicit && REQUIRED_EXTENSION.matcher(candidates.get(0).getPath()).find();
            final List<URL> required = code ? Collections.unmodifiableList(candidates) : Collections.emptyList();
            for (URL candidate : candidates) {
                result.add(new Asset(candidate, false, required));
            }
        }
        return result;
    }

    static URL sameOriginUrl(final String value, final URL baseUrl, final URL rootUrl) {
        try {
            final String trimmed = value == null ? "" : value.trim();
            if (
                trimmed.isEmpty() ||
                trimmed.startsWith("#") ||
                trimmed.startsWith("data:") ||
                trimmed.startsWith("blob:") ||
                trimmed.startsWith("mailto:") ||
                trimmed.startsWith("tel:") ||
                trimmed.startsWith("javascript:")
            ) {
                return null;
            }
            final URL url = new URL(baseUrl, trimmed);
            if (!"http".equals(url.getProtocol()) && !"https".equals(url.getProtocol())) {
                return null;
            }
            // Scheme is part of the origin: an https site must never pull code over http.
            if (
                !url.getProtocol().equalsIgnoreCase(rootUrl.getProtocol()) ||
                !url.getHost().equalsIgnoreCase(rootUrl.getHost()) ||
                effectivePort(url) != effectivePort(rootUrl)
            ) {
                return null;
            }
            final URI uri = url.toURI();
            return new URI(uri.getScheme(), null, uri.getHost(), uri.getPort(), uri.getPath(), uri.getQuery(), null).toURL();
        } catch (Exception e) {
            return null;
        }
    }

    /** Maps a website URL to a path inside the bundle; rejects traversal and control segments. */
    static String localPath(final URL url) throws IOException {
        String path = url.getPath();
        if (path == null || path.isEmpty() || "/".equals(path)) {
            return "index.html";
        }
        if (path.endsWith("/")) {
            path = path + "index.html";
        }
        final List<String> parts = new ArrayList<>();
        for (String rawPart : path.split("/")) {
            if (rawPart.isEmpty()) {
                continue;
            }
            final String part = URLDecoder.decode(rawPart.replace("+", "%2B"), StandardCharsets.UTF_8.name());
            if (".".equals(part) || "..".equals(part) || part.contains("\0") || part.contains("\\") || part.contains("/")) {
                throw new IOException("Invalid asset path: " + url.getPath());
            }
            parts.add(part);
        }
        if (parts.isEmpty()) {
            return "index.html";
        }
        return String.join("/", parts);
    }

    /** When download_base_url is set, fetch the same path (and query) from that base, keeping the base query. */
    static URL rebase(final URL url, final URL downloadBase) throws MalformedURLException {
        if (downloadBase == null) {
            return url;
        }
        String basePath = downloadBase.getPath() == null ? "" : downloadBase.getPath();
        while (basePath.endsWith("/")) {
            basePath = basePath.substring(0, basePath.length() - 1);
        }
        final String path = url.getPath() == null || url.getPath().isEmpty() ? "/" : url.getPath();
        // Query parameters of the base (e.g. a signed CDN token) are kept, followed by the asset's own query.
        final String baseQuery = downloadBase.getQuery() == null ? "" : downloadBase.getQuery();
        final String assetQuery = url.getQuery() == null ? "" : url.getQuery();
        final String joined = baseQuery.isEmpty() ? assetQuery : assetQuery.isEmpty() ? baseQuery : baseQuery + "&" + assetQuery;
        final String query = joined.isEmpty() ? "" : "?" + joined;
        return new URL(downloadBase.getProtocol(), downloadBase.getHost(), downloadBase.getPort(), basePath + path + query);
    }

    /** Website code is executed by the app, so only HTTPS origins are accepted. */
    static URL parseHttpsUrl(final String value) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        try {
            final URL url = new URL(value.trim());
            if (!"https".equals(url.getProtocol())) {
                return null;
            }
            if (url.getHost() == null || url.getHost().isEmpty()) {
                return null;
            }
            return url;
        } catch (MalformedURLException e) {
            return null;
        }
    }

    private static String decodeUtf8(final byte[] data) {
        try {
            return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data))
                .toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    private static byte[] readFile(final File file) throws IOException {
        try (FileInputStream input = new FileInputStream(file)) {
            final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            final byte[] buffer = new byte[16 * 1024];
            int read;
            while ((read = input.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            return out.toByteArray();
        }
    }

    private static void save(final byte[] data, final File target, final File root) throws IOException {
        final String rootPath = root.getCanonicalPath() + File.separator;
        if (!target.getCanonicalPath().startsWith(rootPath)) {
            throw new IOException("Asset path escapes bundle directory");
        }
        final File parent = target.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("Unable to create directory for asset");
        }
        if (target.isDirectory()) {
            // A route (e.g. /about) was saved as a file and now collides with a nested asset, or vice versa.
            throw new IOException("Asset path collides with a directory: " + target.getName());
        }
        try (FileOutputStream output = new FileOutputStream(target)) {
            output.write(data);
        }
    }

    private static boolean isCss(final URL url, final String contentType) {
        return contentType.contains("text/css") || url.getPath().toLowerCase(Locale.ROOT).endsWith(".css");
    }

    private static boolean isJavaScript(final URL url, final String contentType) {
        final String path = url.getPath().toLowerCase(Locale.ROOT);
        return contentType.contains("javascript") || path.endsWith(".js") || path.endsWith(".mjs");
    }

    private static int effectivePort(final URL url) {
        return url.getPort() == -1 ? url.getDefaultPort() : url.getPort();
    }

    private static List<String> srcsetCandidates(final String value) {
        final List<String> result = new ArrayList<>();
        for (String item : value.split(",")) {
            final String trimmed = item.trim();
            if (trimmed.isEmpty()) {
                continue;
            }
            result.add(trimmed.split("\\s+")[0]);
        }
        return result;
    }

    static String sha256Hex(final byte[] data) {
        try {
            final MessageDigest digest = MessageDigest.getInstance("SHA-256");
            final StringBuilder builder = new StringBuilder();
            for (byte b : digest.digest(data)) {
                builder.append(String.format(Locale.ROOT, "%02x", b));
            }
            return builder.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }
}
