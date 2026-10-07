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
    static let maxCheckIntervalSeconds = 24 * 60 * 60
    static let maxFailedVersions = 50

    static let lastCheckKey = "CapacitorUpdater.websiteMode.lastCheckMs"
    static let checkIntervalKey = "CapacitorUpdater.websiteMode.checkIntervalMs"
    static let lastModeKey = "CapacitorUpdater.websiteMode.lastMode"
    static let failedVersionsKey = "CapacitorUpdater.websiteMode.failedVersions"

    static let modeWebsite = "website"
    static let modeCapgo = "capgo"

    /// Fetches a URL. The Bool is `bypassCache`: true for website files (always fetch the deployed
    /// bytes), false for the live check, whose answer is meant to be served from edge and device caches.
    typealias Fetcher = (URL, Bool) throws -> FetchResponse

    let websiteLiveUrl: String
    private let fetcher: Fetcher
    private let defaults: UserDefaults

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
        // No cache bypass: the live answer is device independent and meant to be cached.
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

    func isFailedVersion(_ version: String) -> Bool {
        readFailedVersions().contains(version)
    }

    func markFailedVersion(_ version: String) {
        guard Self.isWebsiteVersion(version) else {
            return
        }
        var failed = readFailedVersions().filter { $0 != version }
        failed.append(version)
        if failed.count > Self.maxFailedVersions {
            failed.removeFirst(failed.count - Self.maxFailedVersions)
        }
        defaults.set(failed.joined(separator: ","), forKey: Self.failedVersionsKey)
    }

    private func readFailedVersions() -> [String] {
        (defaults.string(forKey: Self.failedVersionsKey) ?? "").split(separator: ",").map(String.init)
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

    /// Crawls same-origin assets referenced by the entry HTML, CSS and JS into `targetDir`.
    /// Paths stay identical to the website so the bundle behaves like the webDir build.
    /// - Returns: number of files written (entry included)
    @discardableResult
    func downloadWebsite(entryHtml: Data, websiteUrl: URL, downloadBase: URL?, targetDir: URL) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let entryText = Self.text(entryHtml)
        let entryData = Self.withBundleAssetUrls(entryHtml, text: entryText, baseUrl: websiteUrl, rootUrl: websiteUrl)
        try Self.save(entryData, relativePath: "index.html", root: targetDir)
        var written: Set<String> = ["index.html"]
        var requiredReferences: [String: [URL]] = [:]
        var requiredOrder: [String] = []

        var queue: [Asset] = []
        var queued = Set<String>()
        func enqueue(_ assets: [Asset]) {
            for asset in assets where queued.insert(asset.url.absoluteString).inserted {
                queue.append(asset)
            }
        }
        enqueue(Self.discoverMarkupAssets(entryText, baseUrl: websiteUrl, rootUrl: websiteUrl, fromEntryHtml: true))

        var processed = 0
        var index = 0
        while index < queue.count {
            let asset = queue[index]
            index += 1
            processed += 1
            if processed > Self.maxAssetCount {
                throw WebsiteModeError.failed("Website references more than \(Self.maxAssetCount) assets")
            }
            let relativePath = try Self.localPath(for: asset.url)
            if written.contains(relativePath) {
                continue
            }
            let response: FetchResponse
            do {
                response = try fetcher(Self.rebase(asset.url, downloadBase: downloadBase), true)
            } catch {
                throw WebsiteModeError.failed("Failed to download \(asset.url.path): \(error.localizedDescription)")
            }
            if !response.isSuccess {
                if !asset.required && (400..<500).contains(response.statusCode) {
                    continue
                }
                throw WebsiteModeError.failed("HTTP \(response.statusCode) while downloading \(asset.url.path)")
            }

            if Self.isCss(asset.url, contentType: response.contentType) {
                let css = Self.text(response.data)
                let data = Self.withBundleAssetUrls(response.data, text: css, baseUrl: asset.url, rootUrl: websiteUrl)
                try Self.save(data, relativePath: relativePath, root: targetDir)
                written.insert(relativePath)
                enqueue(Self.discoverMarkupAssets(css, baseUrl: asset.url, rootUrl: websiteUrl, fromEntryHtml: false))
            } else if Self.isJavaScript(asset.url, contentType: response.contentType) {
                // JS is saved as is: same-origin absolute URLs in code may be API calls.
                try Self.save(response.data, relativePath: relativePath, root: targetDir)
                written.insert(relativePath)
                let jsText = Self.text(response.data)
                let children = Self.discoverJavaScriptAssets(jsText, baseUrl: asset.url, rootUrl: websiteUrl)
                for child in children where !child.requiredCandidates.isEmpty {
                    let key = child.requiredCandidates.map(\.absoluteString).joined(separator: "\n")
                    if requiredReferences[key] == nil {
                        requiredOrder.append(key)
                    }
                    requiredReferences[key] = child.requiredCandidates
                }
                enqueue(children)
            } else {
                try Self.save(response.data, relativePath: relativePath, root: targetDir)
                written.insert(relativePath)
            }
        }

        // A code chunk referenced from JS must exist under at least one of its candidate paths,
        // otherwise the bundle would break when the chunk is lazily loaded (e.g. deploy race).
        for key in requiredOrder {
            let candidates = requiredReferences[key] ?? []
            let found = try candidates.contains { try written.contains(Self.localPath(for: $0)) }
            if !found, let first = candidates.first {
                throw WebsiteModeError.failed("Missing code chunk referenced from JS: \(first.path)")
            }
        }
        return written.count
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
        #"["'`]([^"'`\s]+\.(?:js|mjs|css|json|wasm|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|mp3|mp4|webm|txt)(?:\?[^"'`\s]*)?)["'`]"#

    /// Asset refs found in HTML or CSS. Scripts and stylesheets referenced from the entry HTML are
    /// required (a 4xx fails the update); other refs (icons, links, manifests) are best effort.
    static func discoverMarkupAssets(_ text: String, baseUrl: URL, rootUrl: URL, fromEntryHtml: Bool) -> [Asset] {
        var result: [Asset] = []
        for (pattern, isSrcset) in markupPatterns {
            for value in regexCaptures(pattern: pattern, text: text) {
                let candidates = isSrcset ? srcsetCandidates(value) : [value]
                for candidate in candidates {
                    if let url = sameOriginUrl(candidate, baseUrl: baseUrl, rootUrl: rootUrl) {
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
    /// may miss. Code refs (.js/.mjs/.css) must resolve on at least one candidate; other refs are best effort.
    static func discoverJavaScriptAssets(_ text: String, baseUrl: URL, rootUrl: URL) -> [Asset] {
        var result: [Asset] = []
        for value in regexCaptures(pattern: javaScriptAssetPattern, text: text) {
            var candidates: [URL] = []
            let relativeToModule = sameOriginUrl(value, baseUrl: baseUrl, rootUrl: rootUrl)
            if let relativeToModule {
                candidates.append(relativeToModule)
            }
            if !value.hasPrefix("/") && !value.hasPrefix("./") && !value.hasPrefix("../") && !value.contains("://"),
               let relativeToRoot = sameOriginUrl(value, baseUrl: rootUrl, rootUrl: rootUrl),
               relativeToRoot != relativeToModule {
                candidates.append(relativeToRoot)
            }
            guard let first = candidates.first else {
                continue
            }
            let isCode = ["js", "mjs", "css"].contains(first.pathExtension.lowercased())
            for candidate in candidates {
                result.append(Asset(url: candidate, required: false, requiredCandidates: isCode ? candidates : []))
            }
        }
        return result
    }

    /// HTML/CSS only: discovered same-origin absolute asset URLs (https://app.example.com/assets/a.js) become
    /// root-relative (/assets/a.js), matching where they are stored in the bundle, so the WebView loads them
    /// from the bundle instead of the network. Values that are not discovered assets are left untouched.
    static func rewriteAbsoluteAssetUrls(_ text: String, baseUrl: URL, rootUrl: URL) -> String {
        var result = text
        for (pattern, isSrcset) in markupPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let source = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: source.length))
            let mutable = NSMutableString(string: result)
            // Replace from the end so earlier ranges stay valid.
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else {
                    continue
                }
                let value = source.substring(with: range)
                let rewritten = isSrcset
                    ? rewriteSrcset(value, baseUrl: baseUrl, rootUrl: rootUrl)
                    : rewriteAbsoluteValue(value, baseUrl: baseUrl, rootUrl: rootUrl)
                if let rewritten {
                    mutable.replaceCharacters(in: range, with: rewritten)
                }
            }
            result = mutable as String
        }
        return result
    }

    private static func rewriteAbsoluteValue(_ value: String, baseUrl: URL, rootUrl: URL) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("//"),
              let url = sameOriginUrl(trimmed, baseUrl: baseUrl, rootUrl: rootUrl),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        let fragment = trimmed.firstIndex(of: "#").map { String(trimmed[$0...]) } ?? ""
        return path + query + fragment
    }

    private static func rewriteSrcset(_ value: String, baseUrl: URL, rootUrl: URL) -> String? {
        var changed = false
        let items = value.components(separatedBy: ",").map { item -> String in
            let leading = item.prefix { $0.isWhitespace }
            let rest = item.dropFirst(leading.count)
            let token = rest.prefix { !$0.isWhitespace }
            guard !token.isEmpty,
                  let rewritten = rewriteAbsoluteValue(String(token), baseUrl: baseUrl, rootUrl: rootUrl) else {
                return item
            }
            changed = true
            return String(leading) + rewritten + String(rest.dropFirst(token.count))
        }
        return changed ? items.joined(separator: ",") : nil
    }

    /// Returns the original bytes unless a same-origin absolute asset URL had to be made root-relative.
    private static func withBundleAssetUrls(_ data: Data, text: String, baseUrl: URL, rootUrl: URL) -> Data {
        let rewritten = rewriteAbsoluteAssetUrls(text, baseUrl: baseUrl, rootUrl: rootUrl)
        return rewritten == text ? data : Data(rewritten.utf8)
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
