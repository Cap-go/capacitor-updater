import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class WebsiteModeUpdaterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        suiteName = "WebsiteModeUpdaterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private final class FakeSite {
        var responses: [String: WebsiteModeUpdater.FetchResponse] = [:]
        var requested: [String] = []
        var bypassCache: [String: Bool] = [:]
        var errors: [String: String] = [:]

        func put(_ url: String, _ body: String, _ contentType: String, status: Int = 200) {
            responses[url] = WebsiteModeUpdater.FetchResponse(statusCode: status, data: Data(body.utf8), contentType: contentType)
        }

        func fetch(_ url: URL, bypass: Bool) throws -> WebsiteModeUpdater.FetchResponse {
            requested.append(url.absoluteString)
            bypassCache[url.absoluteString] = bypass
            if let message = errors[url.absoluteString] {
                throw WebsiteModeUpdater.WebsiteModeError.failed(message)
            }
            return responses[url.absoluteString] ?? WebsiteModeUpdater.FetchResponse(statusCode: 404, data: Data(), contentType: "text/plain")
        }
    }

    private func parse(_ json: String) -> WebsiteModeUpdater.LiveResponse? {
        WebsiteModeUpdater.LiveResponse.parse(Data(json.utf8))
    }

    private func makeUpdater(_ site: FakeSite) -> WebsiteModeUpdater {
        WebsiteModeUpdater(websiteLiveUrl: nil, fetcher: { try site.fetch($0, bypass: $1) }, defaults: defaults)
    }

    // MARK: - Response parsing

    func testParsesAllowedWebsiteResponse() {
        let res = parse(#"{"allowed":true,"mode":"website","website_url":"https://app.example.com/","check_interval_seconds":600,"extra":1}"#)
        XCTAssertNotNil(res)
        XCTAssertTrue(res!.isWebsiteUpdateAllowed)
        XCTAssertFalse(res!.isCapgoMode)
        XCTAssertEqual(res!.websiteUrl, "https://app.example.com/")
        XCTAssertEqual(res!.downloadBaseUrl, "")
        XCTAssertEqual(res!.checkIntervalSeconds, 600)
    }

    func testParsesDeniedAndCapgoResponses() {
        let upgrade = WebsiteModeUpdater.LiveResponse.parse(Data(#"{"allowed":false,"mode":"website","reason":"need_plan_upgrade"}"#.utf8))
        XCTAssertEqual(upgrade?.isWebsiteUpdateAllowed, false)
        XCTAssertEqual(upgrade?.reason, "need_plan_upgrade")

        let capgo = WebsiteModeUpdater.LiveResponse.parse(Data(#"{"allowed":false,"mode":"capgo","reason":"full_capgo"}"#.utf8))
        XCTAssertEqual(capgo?.isCapgoMode, true)
        XCTAssertEqual(capgo?.isWebsiteUpdateAllowed, false)

        let notFound = WebsiteModeUpdater.LiveResponse.parse(Data(#"{"allowed":false,"reason":"app_not_found"}"#.utf8))
        XCTAssertEqual(notFound?.isCapgoMode, false)
        XCTAssertEqual(notFound?.isWebsiteUpdateAllowed, false)
    }

    func testParsesDownloadBaseUrlAndClampsInterval() {
        let res = parse(
            #"{"allowed":true,"mode":"website","website_url":"https://app.example.com/","# +
                #""download_base_url":"https://cdn.example.com/site","check_interval_seconds":99999999}"#
        )
        XCTAssertEqual(res?.downloadBaseUrl, "https://cdn.example.com/site")
        XCTAssertEqual(res?.checkIntervalSeconds, WebsiteModeUpdater.maxCheckIntervalSeconds)
    }

    func testFloorsCheckIntervalAtFiveMinutes() {
        XCTAssertEqual(parse(#"{"allowed":true,"mode":"website"}"#)?.checkIntervalSeconds, 300)
        XCTAssertEqual(parse(#"{"allowed":true,"mode":"website","check_interval_seconds":0}"#)?.checkIntervalSeconds, 300)
        XCTAssertEqual(parse(#"{"allowed":true,"mode":"website","check_interval_seconds":299}"#)?.checkIntervalSeconds, 300)
        XCTAssertEqual(parse(#"{"allowed":true,"mode":"website","check_interval_seconds":301}"#)?.checkIntervalSeconds, 301)
    }

    func testRejectsInvalidOrInsecureResponses() {
        XCTAssertNil(WebsiteModeUpdater.LiveResponse.parse(Data("not json".utf8)))
        XCTAssertNil(WebsiteModeUpdater.LiveResponse.parse(Data()))
        let http = WebsiteModeUpdater.LiveResponse.parse(Data(#"{"allowed":true,"mode":"website","website_url":"http://app.example.com/"}"#.utf8))
        XCTAssertEqual(http?.isWebsiteUpdateAllowed, false)
    }

    func testLiveCheckUrlOnlySendsAppId() {
        XCTAssertEqual(
            WebsiteModeUpdater.buildLiveCheckUrl(websiteLiveUrl: WebsiteModeUpdater.defaultWebsiteLiveUrl, appId: "com.example.app")?.absoluteString,
            "https://plugin.capgo.app/website_live?app_id=com.example.app"
        )
        XCTAssertNil(WebsiteModeUpdater.buildLiveCheckUrl(websiteLiveUrl: "not a url", appId: "com.example.app"))
        XCTAssertNil(WebsiteModeUpdater.buildLiveCheckUrl(websiteLiveUrl: "http://plugin.example.com/website_live", appId: "com.example.app"))
        XCTAssertEqual(
            WebsiteModeUpdater.buildLiveCheckUrl(websiteLiveUrl: "http://localhost:8788/website_live", appId: "com.example.app")?.absoluteString,
            "http://localhost:8788/website_live?app_id=com.example.app"
        )
    }

    func testRequiresWebsiteServedFromRoot() {
        XCTAssertTrue(WebsiteModeUpdater.isRootWebsiteUrl(URL(string: "https://app.example.com")!))
        XCTAssertTrue(WebsiteModeUpdater.isRootWebsiteUrl(URL(string: "https://app.example.com/")!))
        XCTAssertTrue(WebsiteModeUpdater.isRootWebsiteUrl(URL(string: "https://app.example.com/index.html")!))
        XCTAssertFalse(WebsiteModeUpdater.isRootWebsiteUrl(URL(string: "https://example.com/app/")!))
    }

    func testComparesOrigins() {
        XCTAssertTrue(WebsiteModeUpdater.isSameOrigin(URL(string: "https://a.example.com/x")!, URL(string: "https://A.example.com:443/y")!))
        XCTAssertFalse(WebsiteModeUpdater.isSameOrigin(URL(string: "https://a.example.com/x")!, URL(string: "https://evil.example.com/x")!))
        XCTAssertFalse(WebsiteModeUpdater.isSameOrigin(URL(string: "https://a.example.com/x")!, URL(string: "http://a.example.com/x")!))
    }

    // MARK: - Version id

    func testVersionIdHashesWebsiteUrlAndEntryHtml() {
        let site = URL(string: "https://app.example.com/")!
        let html = Data("<html></html>".utf8)
        let version = WebsiteModeUpdater.versionForWebsite(site, entryHtml: html)
        // sha256("https://app.example.com/\n<html></html>"), identical on Android.
        XCTAssertEqual(version, "web-1fa8d47e9e84")
        XCTAssertEqual(version, WebsiteModeUpdater.versionForWebsite(URL(string: "HTTPS://App.Example.com:443")!, entryHtml: html))
        XCTAssertNotEqual(version, WebsiteModeUpdater.versionForWebsite(site, entryHtml: Data("<html> </html>".utf8)))
        XCTAssertNotEqual(version, WebsiteModeUpdater.versionForWebsite(URL(string: "https://new.example.com/")!, entryHtml: html))
        XCTAssertEqual(
            WebsiteModeUpdater.normalizedWebsiteUrl(URL(string: "https://APP.example.com:8443/index.html?a=1#x")!),
            "https://app.example.com:8443/index.html?a=1"
        )
    }

    // MARK: - Asset discovery

    func testDiscoversSameOriginMarkupAssets() throws {
        let root = URL(string: "https://app.example.com/")!
        let html = """
        <script type=module src="/assets/index-abc.js"></script>
        <link rel=stylesheet href='/assets/index-abc.css'>
        <img srcset="/img/a.png 1x, /img/b.png 2x">
        <script src="https://cdn.other.com/x.js"></script>
        <a href="#top"></a><a href="/about">About</a><img src="data:image/png;base64,AA">
        <link rel="manifest" href="/manifest.webmanifest"><link href="/assets/pre.js" rel="modulepreload">
        """
        let assets = WebsiteModeUpdater.discoverMarkupAssets(html, baseUrl: root, rootUrl: root, fromEntryHtml: true)
        let found = assets.map { $0.url.absoluteString }
        XCTAssertTrue(found.contains("https://app.example.com/assets/index-abc.js"))
        XCTAssertTrue(found.contains("https://app.example.com/assets/index-abc.css"))
        XCTAssertTrue(found.contains("https://app.example.com/img/a.png"))
        XCTAssertTrue(found.contains("https://app.example.com/img/b.png"))
        XCTAssertFalse(found.contains("https://cdn.other.com/x.js"))
        XCTAssertFalse(found.contains("https://app.example.com/about"))
        XCTAssertTrue(found.contains("https://app.example.com/manifest.webmanifest"))
        XCTAssertTrue(found.contains("https://app.example.com/assets/pre.js"))
        for asset in assets {
            XCTAssertEqual(asset.required, ["js", "css"].contains(asset.url.pathExtension))
        }
    }

    func testDiscoversCssUrlsRelativeToStylesheet() {
        let root = URL(string: "https://app.example.com/")!
        let css = URL(string: "https://app.example.com/assets/index.css")!
        let text = #"@import "theme.css"; .a{background:url(../img/bg.png)} .b{src:url('/fonts/x.woff2?v=1#iefix')}"#
        let found = WebsiteModeUpdater.discoverMarkupAssets(text, baseUrl: css, rootUrl: root, fromEntryHtml: false).map { $0.url.absoluteString }
        XCTAssertTrue(found.contains("https://app.example.com/assets/theme.css"))
        XCTAssertTrue(found.contains("https://app.example.com/img/bg.png"))
        XCTAssertTrue(found.contains("https://app.example.com/fonts/x.woff2?v=1"))
    }

    func testDiscoversJavaScriptChunksModuleAndBaseRelative() {
        let root = URL(string: "https://app.example.com/")!
        let module = URL(string: "https://app.example.com/assets/index.js")!
        let text = #"import("./About-1.js");const m=["assets/Home-2.js","assets/Home-2.css"];fetch('/data/x.json')"#
        let found = WebsiteModeUpdater.discoverJavaScriptAssets(text, baseUrl: module, rootUrl: root).map { $0.url.absoluteString }
        XCTAssertTrue(found.contains("https://app.example.com/assets/About-1.js"))
        XCTAssertTrue(found.contains("https://app.example.com/assets/Home-2.js"))
        XCTAssertTrue(found.contains("https://app.example.com/assets/assets/Home-2.js"))
        XCTAssertTrue(found.contains("https://app.example.com/data/x.json"))
    }

    func testRejectsSchemeDowngradeOnSameHostAndPort() {
        let root = URL(string: "https://app.example.com/")!
        XCTAssertNil(WebsiteModeUpdater.sameOriginUrl("http://app.example.com:443/app.js", baseUrl: root, rootUrl: root))
        XCTAssertNil(WebsiteModeUpdater.sameOriginUrl("http://app.example.com/app.js", baseUrl: root, rootUrl: root))
        XCTAssertNotNil(WebsiteModeUpdater.sameOriginUrl("https://app.example.com:443/app.js", baseUrl: root, rootUrl: root))
        let html = #"<script src="http://app.example.com:443/app.js"></script>"#
        XCTAssertTrue(WebsiteModeUpdater.discoverMarkupAssets(html, baseUrl: root, rootUrl: root, fromEntryHtml: true).isEmpty)
    }

    func testMarksJavaScriptCodeReferencesRequiredAcrossCandidates() {
        let root = URL(string: "https://app.example.com/")!
        let module = URL(string: "https://app.example.com/assets/index.js")!
        let assets = WebsiteModeUpdater.discoverJavaScriptAssets(
            #"const a=["./Home-2.js","../x/Abs.css","/assets/Root.mjs","https://app.example.com/assets/Full.js","#
                + #""assets/Bare-1.js","pdf.worker.js","src/foo.js","./logo.png"]"#,
            baseUrl: module,
            rootUrl: root
        )
        var required: [String: Int] = [:]
        for asset in assets {
            XCTAssertFalse(asset.required)
            required[asset.url.path] = asset.requiredCandidates.count
        }
        XCTAssertEqual(required["/assets/Home-2.js"], 1)
        XCTAssertEqual(required["/x/Abs.css"], 1)
        XCTAssertEqual(required["/assets/Root.mjs"], 1)
        XCTAssertEqual(required["/assets/Full.js"], 1)
        // Bare names are tried module- and root-relative but stay best effort.
        XCTAssertEqual(required["/assets/assets/Bare-1.js"], 0)
        XCTAssertEqual(required["/assets/Bare-1.js"], 0)
        XCTAssertEqual(required["/assets/pdf.worker.js"], 0)
        XCTAssertEqual(required["/src/foo.js"], 0)
        XCTAssertEqual(required["/assets/logo.png"], 0)
    }

    func testNeverDiscoversVideoOrAudio() {
        let root = URL(string: "https://app.example.com/")!
        let html = #"<video src="/media/intro.mp4"></video><audio src="/a.mp3"></audio><source src="/b.webm">"#
            + #"<source src="/c.MOV"><audio src="/d.m4a"></audio><audio src="/e.ogg"></audio><audio src="/f.wav"></audio>"#
            + #"<img src="/g.png">"#
        XCTAssertEqual(WebsiteModeUpdater.discoverMarkupAssets(html, baseUrl: root, rootUrl: root, fromEntryHtml: true).count, 1)
        let js = "const v=['./intro.mp4','./a.mp3','./b.webm','./c.mov','./d.m4a','./e.ogg','./f.wav','./g.png']"
        let found = WebsiteModeUpdater.discoverJavaScriptAssets(js, baseUrl: root, rootUrl: root).map(\.url.absoluteString)
        XCTAssertEqual(found, ["https://app.example.com/g.png"])
        // Media stays network loaded, so absolute media URLs are not rewritten either.
        let video = #"<video src="https://app.example.com/intro.mp4"></video>"#
        XCTAssertEqual(WebsiteModeUpdater.rewriteAbsoluteAssetUrls(video, baseUrl: root, rootUrl: root), video)
    }

    func testDetectsHtmlFallbackForCode() {
        let js = URL(string: "https://app.example.com/assets/a.js")!
        let css = URL(string: "https://app.example.com/assets/a.css")!
        let png = URL(string: "https://app.example.com/a.png")!
        func response(_ body: String, _ type: String) -> WebsiteModeUpdater.FetchResponse {
            WebsiteModeUpdater.FetchResponse(statusCode: 200, data: Data(body.utf8), contentType: type)
        }
        XCTAssertTrue(WebsiteModeUpdater.isHtmlFallback(js, response: response("export{}", "text/html; charset=utf-8")))
        XCTAssertTrue(WebsiteModeUpdater.isHtmlFallback(js, response: response("  \n<!DOCTYPE html><html>", "application/octet-stream")))
        XCTAssertTrue(WebsiteModeUpdater.isHtmlFallback(css, response: response("\u{FEFF}<HTML lang=en>", "")))
        XCTAssertFalse(WebsiteModeUpdater.isHtmlFallback(js, response: response("export{}", "text/javascript")))
        XCTAssertFalse(WebsiteModeUpdater.isHtmlFallback(png, response: response("<!doctype html>", "text/html")))
    }

    func testRewritesAbsoluteSameOriginAssetUrlsInMarkup() {
        let root = URL(string: "https://app.example.com/")!
        let html = #"<script src="https://app.example.com/assets/app.js"></script>"# +
            #"<link rel=stylesheet href='https://app.example.com/assets/app.css?v=2'>"# +
            #"<img srcset="https://app.example.com/a.png 1x, /b.png 2x, https://cdn.other.com/c.png 3x">"# +
            #"<a href="https://app.example.com/about">x</a>"# +
            #"<script src="https://cdn.other.com/x.js"></script><script src="http://app.example.com/old.js"></script>"#
        let expected = #"<script src="/assets/app.js"></script>"# +
            #"<link rel=stylesheet href='/assets/app.css?v=2'>"# +
            #"<img srcset="/a.png 1x, /b.png 2x, https://cdn.other.com/c.png 3x">"# +
            #"<a href="https://app.example.com/about">x</a>"# +
            #"<script src="https://cdn.other.com/x.js"></script><script src="http://app.example.com/old.js"></script>"#
        XCTAssertEqual(WebsiteModeUpdater.rewriteAbsoluteAssetUrls(html, baseUrl: root, rootUrl: root), expected)

        let css = URL(string: "https://app.example.com/assets/app.css")!
        let cssText = #"@import "https://app.example.com/assets/theme.css"; "# +
            #".a{background:url(https://app.example.com/img/bg.png)} .b{src:url('//app.example.com/f.woff2#iefix')}"#
        XCTAssertEqual(
            WebsiteModeUpdater.rewriteAbsoluteAssetUrls(cssText, baseUrl: css, rootUrl: root),
            #"@import "/assets/theme.css"; .a{background:url(/img/bg.png)} .b{src:url('/f.woff2#iefix')}"#
        )
    }

    func testLocalPathRejectsTraversal() throws {
        XCTAssertEqual(try WebsiteModeUpdater.localPath(for: URL(string: "https://app.example.com/")!), "index.html")
        XCTAssertEqual(try WebsiteModeUpdater.localPath(for: URL(string: "https://app.example.com/docs/")!), "docs/index.html")
        XCTAssertEqual(try WebsiteModeUpdater.localPath(for: URL(string: "https://app.example.com/assets/a%20b.js?x=1")!), "assets/a b.js")
        XCTAssertThrowsError(try WebsiteModeUpdater.localPath(for: URL(string: "https://app.example.com/a/%2e%2e/b.js")!))
        XCTAssertThrowsError(try WebsiteModeUpdater.localPath(for: URL(string: "https://app.example.com/a/%2Fetc.js")!))
    }

    func testRebaseKeepsPathOnDownloadBase() {
        let asset = URL(string: "https://app.example.com/assets/a.js?v=2")!
        XCTAssertEqual(WebsiteModeUpdater.rebase(asset, downloadBase: nil), asset)
        XCTAssertEqual(
            WebsiteModeUpdater.rebase(asset, downloadBase: URL(string: "https://cdn.example.com/site/")!).absoluteString,
            "https://cdn.example.com/site/assets/a.js?v=2"
        )
    }

    // MARK: - Download

    func testDownloadsWebsiteIntoFolder() throws {
        let site = FakeSite()
        let html = #"<html><script type=module src="/assets/index.js"></script><link rel=stylesheet href="/assets/index.css">"# +
            #"<link rel=icon href="/missing.ico"></html>"#
        site.put("https://app.example.com/assets/index.js", "import('./chunk.js');const d=['assets/chunk.css']", "application/javascript")
        site.put("https://app.example.com/assets/chunk.js", "export const a=1", "text/javascript")
        site.put("https://app.example.com/assets/chunk.css", ".a{}", "text/css")
        site.put("https://app.example.com/assets/index.css", ".b{background:url(./bg.png)}", "text/css")
        site.put("https://app.example.com/assets/bg.png", "PNG", "image/png")

        let dir = tempRoot.appendingPathComponent("site", isDirectory: true)
        let files = try makeUpdater(site).downloadWebsite(entryHtml: Data(html.utf8), websiteUrl: URL(string: "https://app.example.com/")!, downloadBase: nil, targetDir: dir)

        XCTAssertEqual(files, 6)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8), html)
        for path in ["assets/index.js", "assets/chunk.js", "assets/chunk.css", "assets/bg.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.ico").path))
    }

    func testDownloadFailsWhenRequiredScriptIsMissing() {
        let html = Data(#"<script src="/assets/gone.js"></script>"#.utf8)
        XCTAssertThrowsError(try makeUpdater(FakeSite()).downloadWebsite(
            entryHtml: html,
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: tempRoot.appendingPathComponent("broken", isDirectory: true)
        ))
    }

    func testDownloadRewritesAbsoluteUrlsInHtmlAndCssButNotJs() throws {
        let site = FakeSite()
        let html = #"<script type=module src="https://app.example.com/assets/index.js"></script>"# +
            #"<link rel=stylesheet href="https://app.example.com/assets/index.css">"#
        let js = "fetch('https://app.example.com/api/data.json')"
        site.put("https://app.example.com/assets/index.js", js, "application/javascript")
        site.put("https://app.example.com/assets/index.css", ".b{background:url(https://app.example.com/bg.png)}", "text/css")
        site.put("https://app.example.com/bg.png", "PNG", "image/png")
        let dir = tempRoot.appendingPathComponent("absolute", isDirectory: true)
        try makeUpdater(site).downloadWebsite(
            entryHtml: Data(html.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: dir
        )
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8),
            #"<script type=module src="/assets/index.js"></script><link rel=stylesheet href="/assets/index.css">"#
        )
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("assets/index.css"), encoding: .utf8),
            ".b{background:url(/bg.png)}"
        )
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("assets/index.js"), encoding: .utf8), js)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bg.png").path))
    }

    func testDownloadFailsWhenJavaScriptChunkIsMissingOnEveryCandidate() {
        let site = FakeSite()
        site.put("https://app.example.com/assets/index.js", "import('./About-1.js');const c=['assets/Home-2.css']", "application/javascript")
        site.put("https://app.example.com/assets/Home-2.css", ".a{}", "text/css")
        XCTAssertThrowsError(try makeUpdater(site).downloadWebsite(
            entryHtml: Data(#"<script src="/assets/index.js"></script>"#.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: tempRoot.appendingPathComponent("race", isDirectory: true)
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("About-1.js"), error.localizedDescription)
        }
    }

    func testDownloadToleratesMissingCandidateAndNonCodeAssets() throws {
        let site = FakeSite()
        // "assets/Home-2.js" 404s module-relative (/assets/assets/Home-2.js) but exists root-relative.
        site.put(
            "https://app.example.com/assets/index.js",
            "const m=['assets/Home-2.js','assets/missing.png','x/gone.json']",
            "text/javascript"
        )
        site.put("https://app.example.com/assets/Home-2.js", "export{}", "text/javascript")
        let dir = tempRoot.appendingPathComponent("partial", isDirectory: true)
        try makeUpdater(site).downloadWebsite(
            entryHtml: Data(#"<script src="/assets/index.js"></script>"#.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: dir
        )
        XCTAssertTrue(site.requested.contains("https://app.example.com/assets/assets/Home-2.js"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/Home-2.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/missing.png").path))
    }

    func testDownloadUsesDownloadBaseUrl() throws {
        let site = FakeSite()
        site.put("https://cdn.example.com/v1/assets/index.js", "1", "application/javascript")
        let dir = tempRoot.appendingPathComponent("cdn", isDirectory: true)
        try makeUpdater(site).downloadWebsite(
            entryHtml: Data(#"<script src="/assets/index.js"></script>"#.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: URL(string: "https://cdn.example.com/v1")!,
            targetDir: dir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/index.js").path))
        XCTAssertTrue(site.requested.contains("https://cdn.example.com/v1/assets/index.js"))
        XCTAssertEqual(site.bypassCache["https://cdn.example.com/v1/assets/index.js"], true)
    }

    private func download(_ site: FakeSite, _ html: String, _ name: String, updater: WebsiteModeUpdater? = nil) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try (updater ?? makeUpdater(site)).downloadWebsite(
            entryHtml: Data(html.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: dir
        )
        return dir
    }

    private func exists(_ dir: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }

    func testDownloadSkipsOptionalAssetsOnAnyFailure() throws {
        let site = FakeSite()
        site.put("https://app.example.com/assets/index.js", "const m=['assets/data.json','pdf.worker.js']", "text/javascript")
        site.put("https://app.example.com/manifest.webmanifest", "", "text/plain", status: 500)
        site.errors["https://app.example.com/icon.png"] = "Cross-origin redirect blocked"
        site.errors["https://app.example.com/big.png"] = "Asset too large"
        site.errors["https://app.example.com/assets/data.json"] = "timeout"
        site.put("https://app.example.com/assets/pdf.worker.js", "<!doctype html><html></html>", "text/html")
        site.put("https://app.example.com/ok.png", "PNG", "image/png")
        let updater = makeUpdater(site)
        var logs: [String] = []
        updater.log = { logs.append($0) }
        let html = #"<script src="/assets/index.js"></script><link rel=manifest href="/manifest.webmanifest">"#
            + #"<link rel=icon href="/icon.png"><img src="/big.png"><img src="/ok.png">"#
        let dir = tempRoot.appendingPathComponent("optional", isDirectory: true)
        let files = try updater.downloadWebsite(
            entryHtml: Data(html.utf8),
            websiteUrl: URL(string: "https://app.example.com/")!,
            downloadBase: nil,
            targetDir: dir
        )
        XCTAssertEqual(files, 3)
        XCTAssertTrue(exists(dir, "ok.png"))
        XCTAssertFalse(exists(dir, "assets/pdf.worker.js"))
        XCTAssertFalse(exists(dir, "manifest.webmanifest"))
        XCTAssertGreaterThanOrEqual(logs.count, 5)
    }

    func testDownloadFailsWhenRequiredAssetFailsInAnyWay() {
        let html = #"<script src="/assets/index.js"></script>"#

        let serverError = FakeSite()
        serverError.put("https://app.example.com/assets/index.js", "", "text/plain", status: 503)
        XCTAssertThrowsError(try download(serverError, html, "e1"))

        let network = FakeSite()
        network.errors["https://app.example.com/assets/index.js"] = "offline"
        XCTAssertThrowsError(try download(network, html, "e2"))

        // SPA fallback: index.html served with 200 for a missing script.
        let fallback = FakeSite()
        fallback.put("https://app.example.com/assets/index.js", "<!DOCTYPE html><html></html>", "text/html")
        XCTAssertThrowsError(try download(fallback, html, "e3")) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTML fallback"), error.localizedDescription)
        }

        // A required JS chunk answered with the HTML fallback counts as missing.
        let chunk = FakeSite()
        chunk.put("https://app.example.com/assets/index.js", "import('./About-1.js')", "text/javascript")
        chunk.put("https://app.example.com/assets/About-1.js", "\n <html><body></body></html>", "application/javascript")
        XCTAssertThrowsError(try download(chunk, html, "e4")) { error in
            XCTAssertTrue(error.localizedDescription.contains("About-1.js"), error.localizedDescription)
        }
    }

    func testDownloadRewritesSavedAbsoluteUrlsInJavaScript() throws {
        let site = FakeSite()
        let js = #"const a="https://app.example.com/assets/logo.png";const b='https://app.example.com/assets/missing.png';"#
            + "fetch('https://app.example.com/api/users');fetch(`https://app.example.com/data/x.json`);"
            + "const c='https://cdn.other.com/assets/logo.png'"
        site.put("https://app.example.com/assets/index.js", js, "text/javascript")
        site.put("https://app.example.com/assets/logo.png", "PNG", "image/png")
        site.put("https://app.example.com/data/x.json", "{}", "application/json")
        let dir = try download(site, #"<script src="/assets/index.js"></script>"#, "jsrewrite")
        XCTAssertTrue(exists(dir, "data/x.json"))
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("assets/index.js"), encoding: .utf8),
            #"const a="/assets/logo.png";const b='https://app.example.com/assets/missing.png';"#
                + "fetch('https://app.example.com/api/users');fetch(`https://app.example.com/data/x.json`);"
                + "const c='https://cdn.other.com/assets/logo.png'"
        )
    }

    func testDownloadDoesNotRewriteSkippedAssetsInMarkup() throws {
        let site = FakeSite()
        let html = #"<link rel=icon href="https://app.example.com/missing.ico"><img src="https://app.example.com/ok.png">"#
        site.put("https://app.example.com/ok.png", "PNG", "image/png")
        let dir = try download(site, html, "skipped")
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8),
            #"<link rel=icon href="https://app.example.com/missing.ico"><img src="/ok.png">"#
        )
    }

    func testDownloadFailsOverTotalByteBudget() {
        let site = FakeSite()
        site.put("https://app.example.com/a.png", "0123456789", "image/png")
        site.put("https://app.example.com/b.png", "0123456789", "image/png")
        let html = #"<img src="/a.png"><img src="/b.png">"#
        let updater = makeUpdater(site)
        updater.totalBytesBudget = html.utf8.count + 15
        XCTAssertThrowsError(try download(site, html, "budget", updater: updater)) { error in
            XCTAssertTrue(error.localizedDescription.contains("budget"), error.localizedDescription)
        }
        XCTAssertEqual(WebsiteModeUpdater.maxTotalBytes, 300 * 1024 * 1024)
    }

    func testDownloadFailsOnCaseInsensitivePathCollisionWithDifferentBytes() {
        let site = FakeSite()
        site.put("https://app.example.com/assets/App.png", "one", "image/png")
        site.put("https://app.example.com/assets/app.png", "two", "image/png")
        XCTAssertThrowsError(try download(site, #"<img src="/assets/App.png"><img src="/assets/app.png">"#, "c1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("collision"), error.localizedDescription)
        }

        let query = FakeSite()
        query.put("https://app.example.com/a.css?v=1", ".a{}", "text/css")
        query.put("https://app.example.com/a.css?v=2", ".b{}", "text/css")
        let html = #"<link rel=stylesheet href="/a.css?v=1"><link rel=stylesheet href="/a.css?v=2">"#
        XCTAssertThrowsError(try download(query, html, "c2"))
    }

    func testDownloadAcceptsSamePathWithSameBytes() throws {
        let site = FakeSite()
        site.put("https://app.example.com/a.css?v=1", ".a{}", "text/css")
        site.put("https://app.example.com/a.css?v=2", ".a{}", "text/css")
        site.put("https://app.example.com/assets/Logo.png", "PNG", "image/png")
        site.put("https://app.example.com/assets/logo.png", "PNG", "image/png")
        let html = #"<link rel=stylesheet href="/a.css?v=1"><link rel=stylesheet href="/a.css?v=2">"#
            + #"<img src="/assets/Logo.png"><img src="/assets/logo.png">"#
        let dir = try download(site, html, "same")
        XCTAssertTrue(exists(dir, "a.css"))
        // The case variant with the same bytes is not written again (one file on a case-insensitive file system).
        XCTAssertTrue(exists(dir, "assets/Logo.png"))
    }

    func testFetchLiveResponseCallsEndpointWithAppId() throws {
        let site = FakeSite()
        site.put(
            "https://plugin.capgo.app/website_live?app_id=com.example.app",
            #"{"allowed":true,"mode":"website","website_url":"https://app.example.com/"}"#,
            "application/json"
        )
        let updater = makeUpdater(site)
        XCTAssertTrue(try updater.fetchLiveResponse(appId: "com.example.app").isWebsiteUpdateAllowed)
        // The live check carries no cache-bypass header (edge cacheable); website files bypass caches.
        XCTAssertEqual(site.bypassCache["https://plugin.capgo.app/website_live?app_id=com.example.app"], false)
        XCTAssertThrowsError(try updater.fetchLiveResponse(appId: "unknown.app"))
    }

    // MARK: - State

    func testThrottlesUsingCheckInterval() {
        let updater = makeUpdater(FakeSite())
        XCTAssertFalse(updater.isThrottled(nowMs: 1_000))
        updater.recordCheck(nowMs: 1_000, response: parse(#"{"allowed":true,"mode":"website","check_interval_seconds":600}"#))
        XCTAssertTrue(updater.isThrottled(nowMs: 1_000 + 599_000))
        XCTAssertFalse(updater.isThrottled(nowMs: 1_000 + 600_000))
        XCTAssertFalse(updater.isThrottled(nowMs: 500))
        XCTAssertFalse(updater.lastKnownModeIsCapgo)
        updater.recordCheck(nowMs: 2_000, response: WebsiteModeUpdater.LiveResponse.parse(Data(#"{"allowed":false,"mode":"capgo"}"#.utf8)))
        // Missing interval falls back to the 300 s floor.
        XCTAssertTrue(updater.isThrottled(nowMs: 2_000 + 299_000))
        XCTAssertFalse(updater.isThrottled(nowMs: 2_000 + 300_000))
        XCTAssertTrue(updater.lastKnownModeIsCapgo)
    }

    func testRemembersFailedWebsiteVersions() {
        let updater = makeUpdater(FakeSite())
        updater.markFailedVersion("web-aaaaaaaaaaaa")
        updater.markFailedVersion("1.0.0")
        XCTAssertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa"))
        XCTAssertFalse(updater.isFailedVersion("1.0.0"))
        for index in 0..<(WebsiteModeUpdater.maxFailedVersions + 5) {
            updater.markFailedVersion(String(format: "web-%012d", index))
        }
        XCTAssertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa"))
        XCTAssertTrue(updater.isFailedVersion(String(format: "web-%012d", WebsiteModeUpdater.maxFailedVersions + 4)))
    }

    func testFailedWebsiteVersionsExpireAfterOneDay() {
        let updater = makeUpdater(FakeSite())
        let day = WebsiteModeUpdater.failedVersionTtlMs
        updater.markFailedVersion("web-aaaaaaaaaaaa", nowMs: 1_000)
        XCTAssertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa", nowMs: 1_000))
        XCTAssertTrue(updater.isFailedVersion("web-aaaaaaaaaaaa", nowMs: 1_000 + day - 1))
        XCTAssertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa", nowMs: 1_000 + day))
        // Clock moved backwards: retry rather than block.
        XCTAssertFalse(updater.isFailedVersion("web-aaaaaaaaaaaa", nowMs: 500))
        // Expired entries are dropped when a new failure is recorded.
        updater.markFailedVersion("web-bbbbbbbbbbbb", nowMs: 1_000 + day)
        XCTAssertEqual(defaults.string(forKey: WebsiteModeUpdater.failedVersionsKey), "web-bbbbbbbbbbbb:\(1_000 + day)")
        // Legacy entries without a timestamp are retried.
        defaults.set("web-cccccccccccc", forKey: WebsiteModeUpdater.failedVersionsKey)
        XCTAssertFalse(updater.isFailedVersion("web-cccccccccccc", nowMs: 1_000))
    }
}
