/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import CryptoKit
import Foundation

/// Website mode (Capgo Website Live plan): the deployed static website is the source of truth.
/// Capgo only answers whether the app may update and from which URL; files are fetched directly
/// from the website. No channels, stats, encryption or checksum signatures are involved.
final class WebsiteModeUpdater {
    static let defaultWebsiteLiveUrl = "https://plugin.capgo.app/website_live"
    static let versionPrefix = "web-"
    static let maxAssetCount = 1000
    static let maxAssetBytes = 100 * 1024 * 1024
    /// Total bytes a single crawl may download; past it the update fails.
    static let maxTotalBytes = 300 * 1024 * 1024
    static let maxCheckIntervalSeconds = 24 * 60 * 60
    /// Floor for check_interval_seconds (also used when it is missing) so devices cannot stampede the backend.
    static let minCheckIntervalSeconds = 300
    static let maxFailedVersions = 50
    /// A failed website version is retried once this has elapsed (the site may be fixed without changing index.html).
    static let failedVersionTtlMs: Int64 = 24 * 60 * 60 * 1000

    static let lastCheckKey = "CapacitorUpdater.websiteMode.lastCheckMs"
    static let checkIntervalKey = "CapacitorUpdater.websiteMode.checkIntervalMs"
    static let lastModeKey = "CapacitorUpdater.websiteMode.lastMode"
    static let failedVersionsKey = "CapacitorUpdater.websiteMode.failedVersions"

    static let modeWebsite = "website"
    static let modeCapgo = "capgo"

    /// Fetches a URL. The Bool is `bypassCache`: true for website files (always fetch the deployed
    /// bytes), false for the live check, whose answer may come from the edge cache but never from a device cache.
    typealias Fetcher = (URL, Bool) throws -> FetchResponse

    let websiteLiveUrl: String
    private let fetcher: Fetcher
    private let defaults: UserDefaults
    /// Logging hook so the crawl can report skipped optional assets.
    var log: (String) -> Void = { _ in }
    /// Crawl byte budget; only lowered by tests.
    var totalBytesBudget = WebsiteModeUpdater.maxTotalBytes

    init(websiteLiveUrl: String?, fetcher: @escaping Fetcher, defaults: UserDefaults = .standard) {
        let trimmed = websiteLiveUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.websiteLiveUrl = trimmed.isEmpty ? Self.defaultWebsiteLiveUrl : trimmed
        self.fetcher = fetcher
        self.defaults = defaults
    }

    // MARK: - Backend contract

    /// The live answer picks the code the app runs, so it must come over HTTPS.
    /// Plain HTTP is only accepted for loopback hosts (local development).
    static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Same scheme, host and port: redirects must not change where bundle files come from.
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(lhs)) == (rhs.port ?? defaultPort(rhs))
    }

    private static func defaultPort(_ url: URL) -> Int {
        url.scheme?.lowercased() == "http" ? 80 : 443
    }

    /// Asset paths are stored relative to the bundle root, so the website must be served from its root.
    static func isRootWebsiteUrl(_ url: URL) -> Bool {
        let path = url.path
        return path.isEmpty || path == "/" || path == "/index.html"
    }

    /// Only app_id is sent: the response is device independent and edge cached.
    static func buildLiveCheckUrl(websiteLiveUrl: String, appId: String) -> URL? {
        guard var components = URLComponents(string: websiteLiveUrl),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else {
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "app_id" }
        items.append(URLQueryItem(name: "app_id", value: appId))
        components.queryItems = items
        return components.url
    }

    func fetchLiveResponse(appId: String) throws -> LiveResponse {
        guard let url = Self.buildLiveCheckUrl(websiteLiveUrl: websiteLiveUrl, appId: appId) else {
            throw WebsiteModeError.failed("Invalid websiteLiveUrl")
        }
        // No cache bypass header: the live answer is device independent and edge cached.
        // The fetcher never serves it from a device-side cache.
        let response = try fetcher(url, false)
        guard response.isSuccess else {
            throw WebsiteModeError.failed("Website live check failed with HTTP \(response.statusCode)")
        }
        guard let parsed = LiveResponse.parse(response.data) else {
            throw WebsiteModeError.failed("Website live check returned an invalid response")
        }
        return parsed
    }

    // MARK: - Persistent state

    func isThrottled(nowMs: Int64) -> Bool {
        let last = (defaults.object(forKey: Self.lastCheckKey) as? NSNumber)?.int64Value ?? 0
        let interval = (defaults.object(forKey: Self.checkIntervalKey) as? NSNumber)?.int64Value ?? 0
        if last <= 0 || interval <= 0 || nowMs < last {
            return false
        }
        return nowMs - last < interval
    }

    func recordCheck(nowMs: Int64, response: LiveResponse?) {
        defaults.set(NSNumber(value: nowMs), forKey: Self.lastCheckKey)
        defaults.set(NSNumber(value: Int64(response?.checkIntervalSeconds ?? 0) * 1000), forKey: Self.checkIntervalKey)
        defaults.set(response?.isCapgoMode == true ? Self.modeCapgo : Self.modeWebsite, forKey: Self.lastModeKey)
    }

    var lastKnownModeIsCapgo: Bool {
        defaults.string(forKey: Self.lastModeKey) == Self.modeCapgo
    }

    static func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// A failed version is skipped for `failedVersionTtlMs`, then retried.
    func isFailedVersion(_ version: String, nowMs: Int64 = WebsiteModeUpdater.currentTimeMs()) -> Bool {
        guard let failedAt = readFailedVersions().last(where: { $0.version == version })?.failedAt else {
            return false
        }
        return !Self.isFailedEntryExpired(failedAt, nowMs: nowMs)
    }

    func markFailedVersion(_ version: String, nowMs: Int64 = WebsiteModeUpdater.currentTimeMs()) {
        guard Self.isWebsiteVersion(version) else {
            return
        }
        var failed = readFailedVersions()
            .filter { $0.version != version && !Self.isFailedEntryExpired($0.failedAt, nowMs: nowMs) }
            .map { "\($0.version):\($0.failedAt)" }
        failed.append("\(version):\(nowMs)")
        if failed.count > Self.maxFailedVersions {
            failed.removeFirst(failed.count - Self.maxFailedVersions)
        }
        defaults.set(failed.joined(separator: ","), forKey: Self.failedVersionsKey)
    }

    /// A clock moved backwards counts as expired so a version is never blocked for longer than intended.
    private static func isFailedEntryExpired(_ failedAt: Int64, nowMs: Int64) -> Bool {
        failedAt <= 0 || nowMs < failedAt || nowMs - failedAt >= failedVersionTtlMs
    }

    /// Stored as "version:failedAtMs" entries; legacy entries without a timestamp count as expired.
    private func readFailedVersions() -> [(version: String, failedAt: Int64)] {
        let raw = defaults.string(forKey: Self.failedVersionsKey) ?? ""
        return raw.split(separator: ",").map { entry in
            guard let colon = entry.lastIndex(of: ":"), colon != entry.startIndex else {
                return (String(entry), 0)
            }
            return (String(entry[..<colon]), Int64(entry[entry.index(after: colon)...]) ?? 0)
        }
    }

    static func isWebsiteVersion(_ version: String) -> Bool {
        version.hasPrefix(versionPrefix)
    }

    // MARK: - Website download

    /// Deterministic bundle version:
    /// web-<first 12 hex chars of sha256(normalized website URL + "\n" + entry HTML bytes)>.
    /// The URL is part of the hash so moving the app to another domain also produces a new version.
    static func versionForWebsite(_ websiteUrl: URL, entryHtml: Data) -> String {
        var input = Data((normalizedWebsiteUrl(websiteUrl) + "\n").utf8)
        input.append(entryHtml)
        return versionPrefix + String(sha256Hex(input).prefix(12))
    }

    /// Lowercase scheme and host, default port dropped, empty path as "/", query kept, fragment dropped.
    static func normalizedWebsiteUrl(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        let portPart = url.port.map { $0 == defaultPort(url) ? "" : ":\($0)" } ?? ""
        let rawPath = components?.percentEncodedPath ?? ""
        let path = rawPath.isEmpty ? "/" : rawPath
        let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return scheme + "://" + host + portPart + path + query
    }

    func fetchEntryHtml(websiteUrl: URL, downloadBase: URL?) throws -> Data {
        let response = try fetcher(Self.rebase(websiteUrl, downloadBase: downloadBase), true)
        guard response.isSuccess else {
            throw WebsiteModeError.failed("HTTP \(response.statusCode) while fetching website entry")
        }
        guard !response.data.isEmpty else {
            throw WebsiteModeError.failed("Website entry is empty")
        }
        return response.data
    }

    /// A saved HTML, CSS or JS file whose same-origin absolute asset URLs are rewritten once the crawl is done.
    private struct TextFile {
        let path: String
        let baseUrl: URL
        let isJavaScript: Bool
    }

    /// Mutable state of one crawl.
    private struct Crawl {
        /// Keyed by lowercased path: iOS file systems are case-insensitive.
        var saved: [String: (path: String, url: URL, sha256: String)] = [:]
        var writtenPaths: Set<String> = []
        var textFiles: [TextFile] = []
        var requiredReferences: [String: [URL]] = [:]
        var requiredOrder: [String] = []
        var totalBytes = 0

        func isSaved(_ url: URL) -> Bool {
            guard let path = try? WebsiteModeUpdater.localPath(for: url) else {
                return false
            }
            return saved[path.lowercased()] != nil
        }

        mutating func addRequired(_ candidates: [URL]) {
            let key = candidates.map(\.absoluteString).joined(separator: "\n")
            if requiredReferences[key] == nil {
                requiredOrder.append(key)
            }
            requiredReferences[key] = candidates
        }
    }

    /// Crawls same-origin assets referenced by the entry HTML, CSS and JS into `targetDir`.
    /// Paths stay identical to the website so the bundle behaves like the webDir build.
    /// Required assets (scripts and stylesheets of the entry HTML, JS code chunks) fail the update when
    /// missing; every other asset is skipped on any failure.
    /// - Returns: number of files written (entry included)
    @discardableResult
    func downloadWebsite(entryHtml: Data, websiteUrl: URL, downloadBase: URL?, targetDir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Self.save(entryHtml, relativePath: "index.html", root: targetDir)
        var crawl = Crawl()
        crawl.saved["index.html"] = ("index.html", websiteUrl, Self.sha256Hex(entryHtml))
        crawl.writtenPaths.insert("index.html")
        crawl.textFiles.append(TextFile(path: "index.html", baseUrl: websiteUrl, isJavaScript: false))
        crawl.totalBytes = entryHtml.count

        var queue: [Asset] = []
        var queued = Set<String>()
        func enqueue(_ assets: [Asset]) {
            for asset in assets where queued.insert(asset.url.absoluteString).inserted {
                queue.append(asset)
            }
        }
        let entryText = Self.text(entryHtml)
        enqueue(Self.discoverMarkupAssets(entryText, baseUrl: websiteUrl, rootUrl: websiteUrl, fromEntryHtml: true))

        var index = 0
        while index < queue.count {
            let asset = queue[index]
            index += 1
            if index > Self.maxAssetCount {
                throw WebsiteModeError.failed("Website references more than \(Self.maxAssetCount) assets")
            }
            // The entry HTML is already saved; another URL mapping to it is ignored.
            guard let relativePath = try bundlePath(for: asset), relativePath.lowercased() != "index.html",
                  let response = try fetchAsset(asset, downloadBase: downloadBase, crawl: &crawl),
                  try saveAsset(asset, path: relativePath, response: response, root: targetDir, crawl: &crawl) else {
                continue
            }
            if Self.isCss(asset.url, contentType: response.contentType) {
                crawl.textFiles.append(TextFile(path: relativePath, baseUrl: asset.url, isJavaScript: false))
                let css = Self.text(response.data)
                enqueue(Self.discoverMarkupAssets(css, baseUrl: asset.url, rootUrl: websiteUrl, fromEntryHtml: false))
            } else if Self.isJavaScript(asset.url, contentType: response.contentType) {
                crawl.textFiles.append(TextFile(path: relativePath, baseUrl: asset.url, isJavaScript: true))
                let jsText = Self.text(response.data)
                let children = Self.discoverJavaScriptAssets(jsText, baseUrl: asset.url, rootUrl: websiteUrl)
                for child in children where !child.requiredCandidates.isEmpty {
                    crawl.addRequired(child.requiredCandidates)
                }
                enqueue(children)
            }
        }

        // A code chunk referenced from JS must exist under at least one of its candidate paths,
        // otherwise the bundle would break when the chunk is lazily loaded (e.g. deploy race).
        for key in crawl.requiredOrder {
            let candidates = crawl.requiredReferences[key] ?? []
            if !candidates.contains(where: crawl.isSaved), let first = candidates.first {
                throw WebsiteModeError.failed("Missing code chunk referenced from JS: \(first.path)")
            }
        }
        try rewriteSavedTextFiles(crawl, websiteUrl: websiteUrl, root: targetDir)
        return crawl.writtenPaths.count
    }

    /// Fetches one asset. Returns nil when an optional asset failed (logged and skipped).
    private func fetchAsset(_ asset: Asset, downloadBase: URL?, crawl: inout Crawl) throws -> FetchResponse? {
        var failure: String?
        var response: FetchResponse?
        do {
            response = try fetcher(Self.rebase(asset.url, downloadBase: downloadBase), true)
        } catch {
            failure = error.localizedDescription
        }
        if let response {
            crawl.totalBytes += response.data.count
            if crawl.totalBytes > totalBytesBudget {
                throw WebsiteModeError.failed("Website is larger than the \(totalBytesBudget) bytes download budget")
            }
            if !response.isSuccess {
                failure = "HTTP \(response.statusCode)"
            } else if Self.isHtmlFallback(asset.url, response: response) {
                failure = "HTML fallback page served instead of the file"
            }
        }
        if let failure {
            if asset.required {
                throw WebsiteModeError.failed("Failed to download \(asset.url.path): \(failure)")
            }
            log("Skipping website asset \(asset.url.path): \(failure)")
            return nil
        }
        return response
    }

    /// Bundle path of an asset. Returns nil when an optional asset has an invalid path (logged and skipped).
    private func bundlePath(for asset: Asset) throws -> String? {
        do {
            return try Self.localPath(for: asset.url)
        } catch {
            if asset.required {
                throw error
            }
            log("Skipping website asset \(asset.url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves a fetched asset. Returns false when nothing new was written (same path, same bytes).
    private func saveAsset(
        _ asset: Asset,
        path relativePath: String,
        response: FetchResponse,
        root: URL,
        crawl: inout Crawl
    ) throws -> Bool {
        let key = relativePath.lowercased()
        let hash = Self.sha256Hex(response.data)
        if let existing = crawl.saved[key] {
            guard existing.sha256 == hash else {
                throw WebsiteModeError.failed(
                    "Path collision: \(existing.url.path) and \(asset.url.path) map to the same bundle file "
                        + "\(relativePath) with different content"
                )
            }
            // Same bytes: nothing new for the exact path. A case variant is still written because
            // device file systems can be case-sensitive; a case-insensitive one already holds it.
            if crawl.writtenPaths.contains(relativePath) {
                return false
            }
            do {
                try Self.save(response.data, relativePath: relativePath, root: root)
            } catch CocoaError.fileWriteFileExists {
                return false
            }
            crawl.writtenPaths.insert(relativePath)
            return true
        } else {
            crawl.saved[key] = (relativePath, asset.url, hash)
        }
        try Self.save(response.data, relativePath: relativePath, root: root)
        crawl.writtenPaths.insert(relativePath)
        return true
    }

    /// Same-origin absolute URLs of saved files become root-relative so the app loads them from the bundle.
    private func rewriteSavedTextFiles(_ crawl: Crawl, websiteUrl: URL, root: URL) throws {
        for file in crawl.textFiles {
            let target = root.appendingPathComponent(file.path)
            let data = try Data(contentsOf: target)
            let text = Self.text(data)
            let base = file.baseUrl
            let rewritten = file.isJavaScript
                ? Self.rewriteJavaScriptAssetUrls(text, baseUrl: base, rootUrl: websiteUrl, isSaved: crawl.isSaved)
                : Self.rewriteAbsoluteAssetUrls(text, baseUrl: base, rootUrl: websiteUrl, accept: crawl.isSaved)
            if rewritten != text {
                try Self.save(Data(rewritten.utf8), relativePath: file.path, root: root)
            }
        }
    }

    /// SPA hosts often answer unknown paths with index.html and HTTP 200. For a script or stylesheet
    /// that HTML page means the file is missing.
    static func isHtmlFallback(_ url: URL, response: FetchResponse) -> Bool {
        guard ["js", "mjs", "css"].contains(url.pathExtension.lowercased()) else {
            return false
        }
        if response.contentType.lowercased().contains("text/html") {
            return true
        }
        var head = String(decoding: response.data.prefix(1024), as: UTF8.self)
        if head.hasPrefix("\u{FEFF}") {
            head.removeFirst()
        }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }
}

// MARK: - Asset discovery

extension WebsiteModeUpdater {
    /// href is only taken from `<link>` elements (stylesheets, icons, manifest, preloads):
    /// `<a href>` is navigation, not an asset.
    private static let markupPatterns: [(pattern: String, isSrcset: Bool)] = [
        (#"src\s*=\s*["']([^"']+)["']"#, false),
        (#"<link\b[^>]*?\bhref\s*=\s*["']([^"']+)["']"#, false),
        (#"srcset\s*=\s*["']([^"']+)["']"#, true),
        (#"url\(\s*["']?([^"')]+)["']?\s*\)"#, false),
        (#"@import\s+["']([^"']+)["']"#, false)
    ]
    private static let javaScriptAssetPattern =
        #"["'`]([^"'`\s]+\.(?:js|mjs|css|json|wasm|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|txt)"#
            + #"(?:\?[^"'`\s]*)?)["'`]"#
    /// Video and audio are never bundled: they stay loaded from the network.
    private static let mediaExtensions: Set<String> = ["mp4", "webm", "mov", "mp3", "m4a", "ogg", "wav"]
    /// Data files referenced from JS may be API responses, so their URLs in JS are never rewritten.
    private static let dataExtensions: Set<String> = ["json", "txt"]

    static func isMedia(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased())
    }

    /// Asset refs found in HTML or CSS. Scripts and stylesheets referenced from the entry HTML are
    /// required (any failure fails the update); other refs (icons, links, manifests) are best effort.
    /// Video and audio are never bundled.
    static func discoverMarkupAssets(_ text: String, baseUrl: URL, rootUrl: URL, fromEntryHtml: Bool) -> [Asset] {
        var result: [Asset] = []
        for (pattern, isSrcset) in markupPatterns {
            for value in regexCaptures(pattern: pattern, text: text) {
                let candidates = isSrcset ? srcsetCandidates(value) : [value]
                for candidate in candidates {
                    if let url = sameOriginUrl(candidate, baseUrl: baseUrl, rootUrl: rootUrl), !isMedia(url) {
                        let ext = url.pathExtension.lowercased()
                        let required = fromEntryHtml && ["js", "mjs", "css"].contains(ext)
                        result.append(Asset(url: url, required: required))
                    }
                }
            }
        }
        return result
    }

    /// Heuristic string refs inside JS bundles. Bundlers emit both module-relative refs ("./chunk.js")
    /// and base-relative refs ("assets/chunk.js"), so both resolutions are tried and a single candidate
    /// may miss. Only real bundler chunk URLs (literals starting with "./", "../", "/" or a same-origin
    /// absolute URL) of code (.js/.mjs/.css) must resolve; bare names ("pdf.worker.js") are best effort.
    static func discoverJavaScriptAssets(_ text: String, baseUrl: URL, rootUrl: URL) -> [Asset] {
        var result: [Asset] = []
        for value in regexCaptures(pattern: javaScriptAssetPattern, text: text) {
            let lower = value.lowercased()
            let absolute = lower.hasPrefix("https://") || lower.hasPrefix("http://")
            let explicit = absolute || value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../")
            var candidates: [URL] = []
            let relativeToModule = sameOriginUrl(value, baseUrl: baseUrl, rootUrl: rootUrl)
            if let relativeToModule {
                candidates.append(relativeToModule)
            }
            if !explicit && !value.contains("://"),
               let relativeToRoot = sameOriginUrl(value, baseUrl: rootUrl, rootUrl: rootUrl),
               relativeToRoot != relativeToModule {
                candidates.append(relativeToRoot)
            }
            guard let first = candidates.first, !isMedia(first) else {
                continue
            }
            let isCode = explicit && ["js", "mjs", "css"].contains(first.pathExtension.lowercased())
            for candidate in candidates {
                result.append(Asset(url: candidate, required: false, requiredCandidates: isCode ? candidates : []))
            }
        }
        return result
    }

    /// HTML/CSS: discovered same-origin absolute asset URLs (https://app.example.com/assets/a.js) become
    /// root-relative (/assets/a.js), matching where they are stored in the bundle, so the WebView loads them
    /// from the bundle instead of the network. Values that are not discovered assets, and media, are left untouched.
    static func rewriteAbsoluteAssetUrls(_ text: String, baseUrl: URL, rootUrl: URL) -> String {
        rewriteAbsoluteAssetUrls(text, baseUrl: baseUrl, rootUrl: rootUrl) { !isMedia($0) }
    }

    /// Same as `rewriteAbsoluteAssetUrls(_:baseUrl:rootUrl:)`, only for URLs accepted by `accept`.
    static func rewriteAbsoluteAssetUrls(_ text: String, baseUrl: URL, rootUrl: URL, accept: (URL) -> Bool) -> String {
        var result = text
        for (pattern, isSrcset) in markupPatterns {
            result = rewriteMatches(result, pattern: pattern) { value in
                isSrcset
                    ? rewriteSrcset(value, baseUrl: baseUrl, rootUrl: rootUrl, accept: accept)
                    : rewriteAbsoluteValue(value, baseUrl: baseUrl, rootUrl: rootUrl, accept: accept)
            }
        }
        return result
    }

    /// JS: only exact string literals that are same-origin absolute URLs of files saved into the bundle become
    /// root-relative. Other URLs (API endpoints, data files, anything not saved) are left untouched.
    static func rewriteJavaScriptAssetUrls(
        _ text: String,
        baseUrl: URL,
        rootUrl: URL,
        isSaved: (URL) -> Bool
    ) -> String {
        rewriteMatches(text, pattern: javaScriptAssetPattern) { value in
            rewriteAbsoluteValue(value, baseUrl: baseUrl, rootUrl: rootUrl) { url in
                !dataExtensions.contains(url.pathExtension.lowercased()) && isSaved(url)
            }
        }
    }

    private static func rewriteMatches(_ text: String, pattern: String, rewrite: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let source = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length))
        let mutable = NSMutableString(string: text)
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else {
                continue
            }
            if let rewritten = rewrite(source.substring(with: range)) {
                mutable.replaceCharacters(in: range, with: rewritten)
            }
        }
        return mutable as String
    }

    private static func rewriteAbsoluteValue(
        _ value: String,
        baseUrl: URL,
        rootUrl: URL,
        accept: (URL) -> Bool
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("//"),
              let url = sameOriginUrl(trimmed, baseUrl: baseUrl, rootUrl: rootUrl),
              accept(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        let fragment = trimmed.firstIndex(of: "#").map { String(trimmed[$0...]) } ?? ""
        return path + query + fragment
    }

    private static func rewriteSrcset(_ value: String, baseUrl: URL, rootUrl: URL, accept: (URL) -> Bool) -> String? {
        var changed = false
        let items = value.components(separatedBy: ",").map { item -> String in
            let leading = item.prefix { $0.isWhitespace }
            let rest = item.dropFirst(leading.count)
            let token = rest.prefix { !$0.isWhitespace }
            guard !token.isEmpty,
                  let rewritten = rewriteAbsoluteValue(
                      String(token), baseUrl: baseUrl, rootUrl: rootUrl, accept: accept
                  ) else {
                return item
            }
            changed = true
            return String(leading) + rewritten + String(rest.dropFirst(token.count))
        }
        return changed ? items.joined(separator: ",") : nil
    }

    static func sameOriginUrl(_ value: String, baseUrl: URL, rootUrl: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty || ["#", "data:", "blob:", "mailto:", "tel:", "javascript:"].contains(where: { lower.hasPrefix($0) }) {
            return nil
        }
        guard let url = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              // Scheme is part of the origin: an https site must never pull code over http.
              scheme == rootUrl.scheme?.lowercased(),
              url.host?.lowercased() == rootUrl.host?.lowercased(),
              effectivePort(url) == effectivePort(rootUrl),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Maps a website URL to a path inside the bundle; rejects traversal and control segments.
    static func localPath(for url: URL) throws -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        if path.isEmpty || path == "/" {
            return "index.html"
        }
        if path.hasSuffix("/") {
            path += "index.html"
        }
        var parts: [String] = []
        for rawPart in path.split(separator: "/") {
            let part = String(rawPart).removingPercentEncoding ?? String(rawPart)
            if part == "." || part == ".." || part.contains("\0") || part.contains("\\") || part.contains("/") || part.isEmpty {
                throw WebsiteModeError.failed("Invalid asset path: \(url.path)")
            }
            parts.append(part)
        }
        return parts.isEmpty ? "index.html" : parts.joined(separator: "/")
    }

    /// When download_base_url is set, fetch the same path (and query) from that base instead.
    static func rebase(_ url: URL, downloadBase: URL?) -> URL {
        guard let downloadBase,
              var base = URLComponents(url: downloadBase, resolvingAgainstBaseURL: false),
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var basePath = base.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let path = source.percentEncodedPath.isEmpty ? "/" : source.percentEncodedPath
        base.percentEncodedPath = basePath + path
        base.percentEncodedQuery = source.percentEncodedQuery
        base.fragment = nil
        return base.url ?? url
    }

    /// Website code is executed by the app, so only HTTPS origins are accepted.
    static func parseHttpsUrl(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func save(_ data: Data, relativePath: String, root: URL) throws {
        let target = root.appendingPathComponent(relativePath)
        let rootPath = root.standardizedFileURL.path
        guard target.standardizedFileURL.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw WebsiteModeError.failed("Asset path escapes bundle directory")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw WebsiteModeError.failed("Asset path collides with a directory: \(target.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    private static func isCss(_ url: URL, contentType: String) -> Bool {
        contentType.lowercased().contains("text/css") || url.path.lowercased().hasSuffix(".css")
    }

    private static func isJavaScript(_ url: URL, contentType: String) -> Bool {
        let path = url.path.lowercased()
        return contentType.lowercased().contains("javascript") || path.hasSuffix(".js") || path.hasSuffix(".mjs")
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }

    private static func regexCaptures(pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let swiftRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    private static func srcsetCandidates(_ value: String) -> [String] {
        value.split(separator: ",").compactMap { item in
            item.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
        }
    }
}
