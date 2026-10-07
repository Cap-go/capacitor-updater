/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
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
    static final long MAX_CHECK_INTERVAL_SECONDS = 24L * 60L * 60L;
    static final int MAX_FAILED_VERSIONS = 50;

    static final String PREF_LAST_CHECK_MS = "CapacitorUpdater.websiteMode.lastCheckMs";
    static final String PREF_CHECK_INTERVAL_MS = "CapacitorUpdater.websiteMode.checkIntervalMs";
    static final String PREF_LAST_MODE = "CapacitorUpdater.websiteMode.lastMode";
    static final String PREF_FAILED_VERSIONS = "CapacitorUpdater.websiteMode.failedVersions";

    static final String MODE_WEBSITE = "website";
    static final String MODE_CAPGO = "capgo";

    /**
     * href is only taken from {@code <link>} elements (stylesheets, icons, manifest, preloads):
     * {@code <a href>} is navigation, not an asset.
     */
    private static final String[] MARKUP_PATTERNS = new String[] {
        "src\\s*=\\s*[\"']([^\"']+)[\"']",
        "<link\\b[^>]*?\\bhref\\s*=\\s*[\"']([^\"']+)[\"']",
        "srcset\\s*=\\s*[\"']([^\"']+)[\"']",
        "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)",
        "@import\\s+[\"']([^\"']+)[\"']"
    };
    private static final Pattern SRCSET_PATTERN = Pattern.compile(MARKUP_PATTERNS[2], Pattern.CASE_INSENSITIVE);
    private static final Pattern[] COMPILED_MARKUP_PATTERNS = new Pattern[] {
        Pattern.compile(MARKUP_PATTERNS[0], Pattern.CASE_INSENSITIVE),
        Pattern.compile(MARKUP_PATTERNS[1], Pattern.CASE_INSENSITIVE),
        SRCSET_PATTERN,
        Pattern.compile(MARKUP_PATTERNS[3], Pattern.CASE_INSENSITIVE),
        Pattern.compile(MARKUP_PATTERNS[4], Pattern.CASE_INSENSITIVE)
    };
    private static final Pattern SRCSET_ITEM = Pattern.compile("^(\\s*)(\\S+)(.*)$", Pattern.DOTALL);
    private static final Pattern JS_ASSET_PATTERN = Pattern.compile(
        "[\"'`]([^\"'`\\s]+\\.(?:js|mjs|css|json|wasm|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|mp3|mp4|webm|txt)(?:\\?[^\"'`\\s]*)?)[\"'`]",
        Pattern.CASE_INSENSITIVE
    );
    private static final Pattern REQUIRED_EXTENSION = Pattern.compile("\\.(?:js|mjs|css)$", Pattern.CASE_INSENSITIVE);

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
                if (interval < 0) {
                    interval = 0;
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
         *     live check, whose answer is meant to be served from edge and device caches
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

    static Fetcher okHttpFetcher() {
        return (url, bypassCache) -> {
            // Redirects are followed by hand so every hop can be checked against
            // the requested origin: files are saved under the requested path, so
            // another origin must never supply bundle code. The shared client and
            // its policy for other downloads stay unchanged.
            final OkHttpClient client = DownloadService.sharedClient.newBuilder().followRedirects(false).followSslRedirects(false).build();
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

    WebsiteModeUpdater(final String websiteLiveUrl, final Fetcher fetcher, final Store store) {
        this.websiteLiveUrl = websiteLiveUrl == null || websiteLiveUrl.trim().isEmpty() ? DEFAULT_WEBSITE_LIVE_URL : websiteLiveUrl.trim();
        this.fetcher = fetcher;
        this.store = store;
    }

    String getWebsiteLiveUrl() {
        return this.websiteLiveUrl;
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
        // No cache bypass: the live answer is device independent and meant to be cached.
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
        return version != null && readFailedVersions().contains(version);
    }

    void markFailedVersion(final String version) {
        if (version == null || !version.startsWith(VERSION_PREFIX)) {
            return;
        }
        final List<String> failed = new ArrayList<>(readFailedVersions());
        failed.remove(version);
        failed.add(version);
        while (failed.size() > MAX_FAILED_VERSIONS) {
            failed.remove(0);
        }
        this.store.putString(PREF_FAILED_VERSIONS, String.join(",", failed));
    }

    private Set<String> readFailedVersions() {
        final String raw = this.store.getString(PREF_FAILED_VERSIONS, "");
        if (raw == null || raw.isEmpty()) {
            return Collections.emptySet();
        }
        final Set<String> result = new LinkedHashSet<>();
        for (String value : raw.split(",")) {
            if (!value.isEmpty()) {
                result.add(value);
            }
        }
        return result;
    }

    static boolean isWebsiteVersion(final String version) {
        return version != null && version.startsWith(VERSION_PREFIX);
    }

    // ---- Website download ----

    /**
     * Deterministic bundle version: web-&lt;first 12 hex chars of sha256(normalized website URL + "\n" +
     * entry HTML bytes)&gt;. The URL is part of the hash so moving the app to another domain also
     * produces a new version.
     */
    static String versionForWebsite(final URL websiteUrl, final byte[] html) {
        final byte[] prefix = (normalizedWebsiteUrl(websiteUrl) + "\n").getBytes(StandardCharsets.UTF_8);
        final byte[] input = new byte[prefix.length + html.length];
        System.arraycopy(prefix, 0, input, 0, prefix.length);
        System.arraycopy(html, 0, input, prefix.length, html.length);
        return VERSION_PREFIX + sha256Hex(input).substring(0, 12);
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
        return response.data;
    }

    /**
     * Crawls same-origin assets referenced by the entry HTML, CSS and JS into {@code targetDir}.
     * Paths stay identical to the website so the bundle behaves like the webDir build.
     *
     * @return number of files written (entry included)
     */
    int downloadWebsite(final byte[] entryHtml, final URL websiteUrl, final URL downloadBase, final File targetDir) throws IOException {
        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw new IOException("Unable to create website download directory");
        }
        final String entryText = new String(entryHtml, StandardCharsets.UTF_8);
        save(withBundleAssetUrls(entryHtml, entryText, websiteUrl, websiteUrl), new File(targetDir, "index.html"), targetDir);
        final Set<String> written = new HashSet<>();
        written.add("index.html");

        final ArrayDeque<Asset> queue = new ArrayDeque<>();
        final Set<String> queued = new HashSet<>();
        final Map<String, List<URL>> requiredReferences = new LinkedHashMap<>();
        for (Asset asset : discoverMarkupAssets(entryText, websiteUrl, websiteUrl, true)) {
            enqueue(asset, queue, queued);
        }

        int processed = 0;
        while (!queue.isEmpty()) {
            final Asset asset = queue.poll();
            if (++processed > MAX_ASSET_COUNT) {
                throw new IOException("Website references more than " + MAX_ASSET_COUNT + " assets");
            }
            final String relativePath = localPath(asset.url);
            if (written.contains(relativePath)) {
                continue;
            }
            final FetchResponse response;
            try {
                response = this.fetcher.fetch(rebase(asset.url, downloadBase), true);
            } catch (IOException e) {
                throw new IOException("Failed to download " + asset.url.getPath() + ": " + e.getMessage(), e);
            }
            if (!response.isSuccess()) {
                if (!asset.required && response.statusCode >= 400 && response.statusCode < 500) {
                    continue;
                }
                throw new IOException("HTTP " + response.statusCode + " while downloading " + asset.url.getPath());
            }

            if (isCss(asset.url, response.contentType)) {
                final String text = new String(response.data, StandardCharsets.UTF_8);
                save(withBundleAssetUrls(response.data, text, asset.url, websiteUrl), new File(targetDir, relativePath), targetDir);
                written.add(relativePath);
                for (Asset child : discoverMarkupAssets(text, asset.url, websiteUrl, false)) {
                    enqueue(child, queue, queued);
                }
            } else if (isJavaScript(asset.url, response.contentType)) {
                // JS is saved as is: same-origin absolute URLs in code may be API calls.
                save(response.data, new File(targetDir, relativePath), targetDir);
                written.add(relativePath);
                final String text = new String(response.data, StandardCharsets.UTF_8);
                for (Asset child : discoverJavaScriptAssets(text, asset.url, websiteUrl)) {
                    if (!child.requiredCandidates.isEmpty()) {
                        requiredReferences.put(candidatesKey(child.requiredCandidates), child.requiredCandidates);
                    }
                    enqueue(child, queue, queued);
                }
            } else {
                save(response.data, new File(targetDir, relativePath), targetDir);
                written.add(relativePath);
            }
        }

        // A code chunk referenced from JS must exist under at least one of its candidate paths,
        // otherwise the bundle would break when the chunk is lazily loaded (e.g. deploy race).
        for (List<URL> candidates : requiredReferences.values()) {
            boolean found = false;
            for (URL candidate : candidates) {
                if (written.contains(localPath(candidate))) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw new IOException("Missing code chunk referenced from JS: " + candidates.get(0).getPath());
            }
        }
        return written.size();
    }

    private static String candidatesKey(final List<URL> candidates) {
        final StringBuilder key = new StringBuilder();
        for (URL candidate : candidates) {
            key.append(candidate.toString()).append('\n');
        }
        return key.toString();
    }

    /** Returns the original bytes unless a same-origin absolute asset URL had to be made root-relative. */
    private static byte[] withBundleAssetUrls(final byte[] data, final String text, final URL baseUrl, final URL rootUrl) {
        final String rewritten = rewriteAbsoluteAssetUrls(text, baseUrl, rootUrl);
        return rewritten.equals(text) ? data : rewritten.getBytes(StandardCharsets.UTF_8);
    }

    /**
     * HTML/CSS only: discovered same-origin absolute asset URLs (https://app.example.com/assets/a.js) become
     * root-relative (/assets/a.js), matching where they are stored in the bundle, so the WebView loads them
     * from the bundle instead of the network. Values that are not discovered assets are left untouched.
     */
    static String rewriteAbsoluteAssetUrls(final String text, final URL baseUrl, final URL rootUrl) {
        if (text == null) {
            return null;
        }
        String result = text;
        for (Pattern pattern : COMPILED_MARKUP_PATTERNS) {
            final Matcher matcher = pattern.matcher(result);
            final StringBuilder out = new StringBuilder();
            int last = 0;
            while (matcher.find()) {
                final String value = matcher.group(1);
                final String rewritten =
                    pattern == SRCSET_PATTERN ? rewriteSrcset(value, baseUrl, rootUrl) : rewriteAbsoluteValue(value, baseUrl, rootUrl);
                if (rewritten != null) {
                    out.append(result, last, matcher.start(1)).append(rewritten);
                    last = matcher.end(1);
                }
            }
            if (last > 0) {
                out.append(result, last, result.length());
                result = out.toString();
            }
        }
        return result;
    }

    private static String rewriteAbsoluteValue(final String value, final URL baseUrl, final URL rootUrl) {
        final String trimmed = value.trim();
        final String lower = trimmed.toLowerCase(Locale.ROOT);
        if (!lower.startsWith("https://") && !lower.startsWith("http://") && !lower.startsWith("//")) {
            return null;
        }
        final URL url = sameOriginUrl(trimmed, baseUrl, rootUrl);
        if (url == null) {
            return null;
        }
        final String path = url.getPath() == null || url.getPath().isEmpty() ? "/" : url.getPath();
        final String query = url.getQuery() == null ? "" : "?" + url.getQuery();
        final int hash = trimmed.indexOf('#');
        return path + query + (hash >= 0 ? trimmed.substring(hash) : "");
    }

    private static String rewriteSrcset(final String value, final URL baseUrl, final URL rootUrl) {
        final String[] items = value.split(",", -1);
        boolean changed = false;
        for (int i = 0; i < items.length; i++) {
            final Matcher item = SRCSET_ITEM.matcher(items[i]);
            if (!item.matches()) {
                continue;
            }
            final String rewritten = rewriteAbsoluteValue(item.group(2), baseUrl, rootUrl);
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
     * required (a 4xx fails the update); other refs (icons, links, manifests) are best effort.
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
                    if (url != null) {
                        final boolean required = fromEntryHtml && REQUIRED_EXTENSION.matcher(url.getPath()).find();
                        result.add(new Asset(url, required));
                    }
                }
            }
        }
        return result;
    }

    /**
     * Heuristic string refs inside JS bundles. Bundlers emit both module-relative refs ("./chunk.js")
     * and base-relative refs ("assets/chunk.js"), so both resolutions are tried and a single candidate
     * may miss. Code refs (.js/.mjs/.css) must resolve on at least one candidate; other refs are best effort.
     */
    static List<Asset> discoverJavaScriptAssets(final String text, final URL baseUrl, final URL rootUrl) {
        final List<Asset> result = new ArrayList<>();
        if (text == null) {
            return result;
        }
        final Matcher matcher = JS_ASSET_PATTERN.matcher(text);
        while (matcher.find()) {
            final String value = matcher.group(1);
            final List<URL> candidates = new ArrayList<>(2);
            final URL relativeToModule = sameOriginUrl(value, baseUrl, rootUrl);
            if (relativeToModule != null) {
                candidates.add(relativeToModule);
            }
            if (!value.startsWith("/") && !value.startsWith("./") && !value.startsWith("../") && !value.contains("://")) {
                final URL relativeToRoot = sameOriginUrl(value, rootUrl, rootUrl);
                if (
                    relativeToRoot != null && (relativeToModule == null || !relativeToRoot.toString().equals(relativeToModule.toString()))
                ) {
                    candidates.add(relativeToRoot);
                }
            }
            if (candidates.isEmpty()) {
                continue;
            }
            final boolean code = REQUIRED_EXTENSION.matcher(candidates.get(0).getPath()).find();
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

    /** When download_base_url is set, fetch the same path (and query) from that base instead. */
    static URL rebase(final URL url, final URL downloadBase) throws MalformedURLException {
        if (downloadBase == null) {
            return url;
        }
        String basePath = downloadBase.getPath() == null ? "" : downloadBase.getPath();
        while (basePath.endsWith("/")) {
            basePath = basePath.substring(0, basePath.length() - 1);
        }
        final String path = url.getPath() == null || url.getPath().isEmpty() ? "/" : url.getPath();
        final String query = url.getQuery() == null ? "" : "?" + url.getQuery();
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
