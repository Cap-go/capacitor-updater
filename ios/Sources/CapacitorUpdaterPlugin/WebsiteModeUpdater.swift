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

    typealias Fetcher = (URL) throws -> FetchResponse

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

    /// Only app_id is sent: the response is device independent and edge cached.
    static func buildLiveCheckUrl(websiteLiveUrl: String, appId: String) -> URL? {
        guard var components = URLComponents(string: websiteLiveUrl),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
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
        let response = try fetcher(url)
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

    /// Deterministic bundle version: web-<first 12 hex chars of sha256(entry HTML bytes)>.
    static func versionForEntryHtml(_ html: Data) -> String {
        versionPrefix + String(sha256Hex(html).prefix(12))
    }

    func fetchEntryHtml(websiteUrl: URL, downloadBase: URL?) throws -> Data {
        let response = try fetcher(Self.rebase(websiteUrl, downloadBase: downloadBase))
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
        try Self.save(entryHtml, relativePath: "index.html", root: targetDir)
        var written: Set<String> = ["index.html"]

        var queue: [Asset] = []
        var queued = Set<String>()
        func enqueue(_ assets: [Asset]) {
            for asset in assets where queued.insert(asset.url.absoluteString).inserted {
                queue.append(asset)
            }
        }
        let entryText = Self.text(entryHtml)
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
                response = try fetcher(Self.rebase(asset.url, downloadBase: downloadBase))
            } catch {
                throw WebsiteModeError.failed("Failed to download \(asset.url.path): \(error.localizedDescription)")
            }
            if !response.isSuccess {
                if !asset.required && (400..<500).contains(response.statusCode) {
                    continue
                }
                throw WebsiteModeError.failed("HTTP \(response.statusCode) while downloading \(asset.url.path)")
            }
            try Self.save(response.data, relativePath: relativePath, root: targetDir)
            written.insert(relativePath)

            if Self.isCss(asset.url, contentType: response.contentType) {
                let css = Self.text(response.data)
                enqueue(Self.discoverMarkupAssets(css, baseUrl: asset.url, rootUrl: websiteUrl, fromEntryHtml: false))
            } else if Self.isJavaScript(asset.url, contentType: response.contentType) {
                enqueue(Self.discoverJavaScriptAssets(Self.text(response.data), baseUrl: asset.url, rootUrl: websiteUrl))
            }
        }
        return written.count
    }
}

// MARK: - Asset discovery

extension WebsiteModeUpdater {
    private static let markupPatterns = [
        #"(?:src|href)\s*=\s*["']([^"']+)["']"#,
        #"srcset\s*=\s*["']([^"']+)["']"#,
        #"url\(\s*["']?([^"')]+)["']?\s*\)"#,
        #"@import\s+["']([^"']+)["']"#
    ]
    private static let javaScriptAssetPattern =
        #"["'`]([^"'`\s]+\.(?:js|mjs|css|json|wasm|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf|mp3|mp4|webm|txt)(?:\?[^"'`\s]*)?)["'`]"#

    /// Asset refs found in HTML or CSS. Scripts and stylesheets referenced from the entry HTML are
    /// required (a 4xx fails the update); other refs (icons, links, manifests) are best effort.
    static func discoverMarkupAssets(_ text: String, baseUrl: URL, rootUrl: URL, fromEntryHtml: Bool) -> [Asset] {
        var result: [Asset] = []
        for pattern in markupPatterns {
            let isSrcset = pattern.hasPrefix("srcset")
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
    /// and base-relative refs ("assets/chunk.js"), so both resolutions are tried; misses are tolerated.
    static func discoverJavaScriptAssets(_ text: String, baseUrl: URL, rootUrl: URL) -> [Asset] {
        var result: [Asset] = []
        for value in regexCaptures(pattern: javaScriptAssetPattern, text: text) {
            let relativeToModule = sameOriginUrl(value, baseUrl: baseUrl, rootUrl: rootUrl)
            if let relativeToModule {
                result.append(Asset(url: relativeToModule, required: false))
            }
            if !value.hasPrefix("/") && !value.hasPrefix("./") && !value.hasPrefix("../") && !value.contains("://"),
               let relativeToRoot = sameOriginUrl(value, baseUrl: rootUrl, rootUrl: rootUrl),
               relativeToRoot != relativeToModule {
                result.append(Asset(url: relativeToRoot, required: false))
            }
        }
        return result
    }

    static func sameOriginUrl(_ value: String, baseUrl: URL, rootUrl: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty || ["#", "data:", "blob:", "mailto:", "tel:", "javascript:"].contains(where: { lower.hasPrefix($0) }) {
            return nil
        }
        guard let url = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
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
