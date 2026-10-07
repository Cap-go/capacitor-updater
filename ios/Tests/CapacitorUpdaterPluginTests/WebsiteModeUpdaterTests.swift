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

        func put(_ url: String, _ body: String, _ contentType: String) {
            responses[url] = WebsiteModeUpdater.FetchResponse(statusCode: 200, data: Data(body.utf8), contentType: contentType)
        }

        func fetch(_ url: URL) throws -> WebsiteModeUpdater.FetchResponse {
            requested.append(url.absoluteString)
            return responses[url.absoluteString] ?? WebsiteModeUpdater.FetchResponse(statusCode: 404, data: Data(), contentType: "text/plain")
        }
    }

    private func parse(_ json: String) -> WebsiteModeUpdater.LiveResponse? {
        WebsiteModeUpdater.LiveResponse.parse(Data(json.utf8))
    }

    private func makeUpdater(_ site: FakeSite) -> WebsiteModeUpdater {
        WebsiteModeUpdater(websiteLiveUrl: nil, fetcher: { try site.fetch($0) }, defaults: defaults)
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

    func testVersionIdIsDeterministicSha256Prefix() {
        let html = Data("<html></html>".utf8)
        let version = WebsiteModeUpdater.versionForEntryHtml(html)
        XCTAssertEqual(version, "web-" + String(WebsiteModeUpdater.sha256Hex(html).prefix(12)))
        XCTAssertEqual(version.count, 16)
        XCTAssertNotEqual(version, WebsiteModeUpdater.versionForEntryHtml(Data("<html> </html>".utf8)))
        XCTAssertEqual(WebsiteModeUpdater.versionForEntryHtml(Data()), "web-e3b0c44298fc")
    }

    // MARK: - Asset discovery

    func testDiscoversSameOriginMarkupAssets() throws {
        let root = URL(string: "https://app.example.com/")!
        let html = """
        <script type=module src="/assets/index-abc.js"></script>
        <link rel=stylesheet href='/assets/index-abc.css'>
        <img srcset="/img/a.png 1x, /img/b.png 2x">
        <script src="https://cdn.other.com/x.js"></script>
        <a href="#top"></a><img src="data:image/png;base64,AA">
        """
        let assets = WebsiteModeUpdater.discoverMarkupAssets(html, baseUrl: root, rootUrl: root, fromEntryHtml: true)
        let found = assets.map { $0.url.absoluteString }
        XCTAssertTrue(found.contains("https://app.example.com/assets/index-abc.js"))
        XCTAssertTrue(found.contains("https://app.example.com/assets/index-abc.css"))
        XCTAssertTrue(found.contains("https://app.example.com/img/a.png"))
        XCTAssertTrue(found.contains("https://app.example.com/img/b.png"))
        XCTAssertFalse(found.contains("https://cdn.other.com/x.js"))
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
        XCTAssertFalse(updater.isThrottled(nowMs: 2_001))
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
}
